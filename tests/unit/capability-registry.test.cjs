const { test } = require('node:test');
const assert = require('node:assert/strict');
const { CapabilityRegistry } = require('../../work/core-build/capabilities/CapabilityRegistry.js');
const { NasConnector } = require('../../work/core-build/network/NasConnector.js');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');
const definition = { feature: 'files', api: 'SYNO.FileStation.List', verifiedVersions: [2] };
const api = { name: definition.api, path: 'entry.cgi', minVersion: 1, maxVersion: 20, jsonParameters: true };
const snapshot = registry => registry.snapshots()[0];

test('API discovery is not proof of installation or permission and only selects verified versions', () => {
  const registry = new CapabilityRegistry([definition]);
  registry.discover([], 10);
  assert.equal(snapshot(registry).state, 'unverified');
  assert.equal(snapshot(registry).reason, 'apiNotDiscovered');
  registry.discover([{ ...api, minVersion: 3 }], 20);
  assert.equal(snapshot(registry).state, 'unsupportedVersion');
  registry.discover([api], 30);
  assert.equal(snapshot(registry).state, 'unverified');
  assert.equal(snapshot(registry).apiVersion, 2);
  assert.equal(snapshot(registry).checkedAt, 30);
  const exported = snapshot(registry);
  exported.state = 'available';
  assert.equal(snapshot(registry).state, 'unverified');
});

test('discovered APIs without verified contracts remain unverified across ranges and resets', async () => {
  const registry = new CapabilityRegistry([{ ...definition, verifiedVersions: [] }]);
  for (const range of [{ minVersion: 1, maxVersion: 20 }, { minVersion: 100, maxVersion: 200 }]) {
    registry.discover([{ ...api, ...range }], 30);
    assert.equal(snapshot(registry).state, 'unverified');
    assert.equal(snapshot(registry).apiVersion, 0);
    assert.equal(snapshot(registry).reason, 'noVerifiedContract');
    await registry.read('files', async () => 'unrelated success');
    assert.equal(snapshot(registry).state, 'unverified');
    registry.invalidate('files');
    assert.equal(snapshot(registry).reason, 'noVerifiedContract');
  }
  registry.discover([]);
  assert.equal(snapshot(registry).state, 'unverified');
  assert.equal(snapshot(registry).reason, 'apiNotDiscovered');
  registry.clear();
  assert.deepEqual(registry.snapshots(), []);
});

test('validated reads distinguish permissions, network and response shape, and can recover', async () => {
  const registry = new CapabilityRegistry([definition]);
  registry.discover([api]);
  for (const [kind, state] of [[K.Permission, 'unauthorized'], [K.Network, 'unreachable'],
    [K.Tls, 'unreachable'], [K.Protocol, 'schemaMismatch'], [K.Unsupported, 'unverified']]) {
    const error = new NasFailure(kind, 'failure', 105);
    await assert.rejects(registry.read('files', async () => { throw error; }), value => value === error);
    assert.equal(snapshot(registry).state, state);
    assert.equal(snapshot(registry).errorCode, 105);
    assert.equal(snapshot(registry).apiVersion, 2);
    assert.equal(await registry.read('files', async () => 'valid'), 'valid');
    assert.equal(snapshot(registry).state, 'available');
    assert.equal(snapshot(registry).errorCode, undefined);
  }
});

test('cancellation, stale accounts and older concurrent reads cannot replace newer capability evidence', async () => {
  const registry = new CapabilityRegistry([definition]);
  registry.discover([api]);
  await registry.read('files', async () => 1);
  await assert.rejects(registry.read('files', async () => { throw new NasFailure(K.Cancelled, 'cancelled'); }));
  assert.equal(snapshot(registry).state, 'available');
  let rejectOld;
  const old = registry.read('files', () => new Promise((resolve, reject) => { rejectOld = reject; }));
  const oldFailure = assert.rejects(old);
  await registry.read('files', async () => 2);
  rejectOld(new NasFailure(K.Permission, 'old failure'));
  await oldFailure;
  assert.equal(snapshot(registry).state, 'available');
  let resolveOld;
  const stale = registry.read('files', () => new Promise(resolve => { resolveOld = resolve; }));
  registry.discover([api]);
  resolveOld(3);
  await stale;
  assert.equal(snapshot(registry).state, 'unverified');
  registry.clear();
  assert.deepEqual(registry.snapshots(), []);
});

test('connector marks root browsing available only after decoding and does not globalize folder permissions', async () => {
  const replies = [];
  const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });
  const connector = new NasConnector({ post() { assert.ok(replies.length); return Promise.resolve(replies.shift()); }, close() {} });
  replies.push(ok({ 'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 7 },
    'SYNO.FileStation.List': { path: 'entry.cgi', minVersion: 1, maxVersion: 2 } }));
  await connector.discover('https://nas.example');
  connector.restoreSession([{ name: 'FileStation', sid: 'synthetic-sid', synoToken: '' }]);
  const files = () => connector.capabilitySnapshots().find(value => value.feature === 'fileBrowse');
  assert.equal(files().state, 'unverified');
  replies.push(ok({ shares: [], total: 0, offset: 0 }));
  await connector.list('');
  assert.equal(files().state, 'available');
  replies.push({ status: 200, text: '{"success":false,"error":{"code":105}}' });
  await assert.rejects(connector.list('/restricted'));
  assert.equal(files().state, 'available');
  replies.push(ok({ shares: 'not-an-array' }));
  await assert.rejects(connector.list(''));
  assert.equal(files().state, 'schemaMismatch');
  replies.push({ status: 200, text: '{"success":false,"error":{"code":119}}' });
  await assert.rejects(connector.list(''));
  assert.equal(files().state, 'unverified');
  connector.close();
});

test('optional module discovery stays independent of package permissions and sends no speculative reads', async () => {
  const modules = [
    ['noteList', 'SYNO.NoteStation.Note'],
  ];
  for (const discovered of [true, false]) {
    const calls = [];
    const descriptors = {
      'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 7 },
      'SYNO.Core.Package': { path: 'packages.cgi', minVersion: 1, maxVersion: 1 },
    };
    if (discovered) for (const [, name] of modules) descriptors[name] = { path: 'entry.cgi', minVersion: 10, maxVersion: 99 };
    const replies = [
      { status: 200, text: JSON.stringify({ success: true, data: descriptors }) },
      { status: 200, text: '{"success":false,"error":{"code":105}}' },
    ];
    const connector = new NasConnector({ post(...args) { calls.push(args); return Promise.resolve(replies.shift()); }, close() {} });
    await connector.discover('https://nas.example');
    const queried = new URLSearchParams(calls[0][1]).get('query').split(',');
    for (const [, name] of modules) assert.ok(queried.includes(name));
    connector.restoreSession([{ name: 'FileStation', sid: 'synthetic-sid', synoToken: '' }]);
    assert.equal(calls.length, 1);
    await assert.rejects(connector.readPackageCatalog(() => connector.packageRequest('list', [])), error => error.kind === K.Permission);
    assert.equal(connector.sessionSnapshot().length, 1);
    for (const [feature] of modules) {
      const state = connector.capabilitySnapshots().find(value => value.feature === feature);
      assert.equal(state.state, 'unverified');
      assert.equal(state.apiVersion, 0);
      assert.equal(state.reason, discovered ? 'noVerifiedContract' : 'apiNotDiscovered');
    }
    assert.equal(calls.length, 2);
    assert.equal(new URLSearchParams(calls[1][1]).get('api'), 'SYNO.Core.Package');
    connector.close();
    assert.throws(() => connector.capabilitySnapshots(), error => error.kind === K.Cancelled);
  }
});
