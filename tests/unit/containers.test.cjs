const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'D:/Program Files/DevEco Studio/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const common = require('../../work/core-build/domain/ReadOnlyProtocol.js');
const { NasConnector } = require('../../work/core-build/network/NasConnector.js');
const plain = value => JSON.parse(JSON.stringify(value));
const tick = () => new Promise(resolve => setImmediate(resolve));
function load(name, timers = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/containers', name), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, Date, Error, setTimeout, clearTimeout, ...timers,
    require: id => {
      if (id === '../../core/domain/DsmProtocol') return dsm;
      if (id === '../../core/domain/ReadOnlyProtocol') return common;
      if (id === '@kit.PerformanceAnalysisKit') return { hilog: { error() {} } };
      if (id.startsWith('./')) return load(id.slice(2) + '.ts', timers);
      throw new Error('Unexpected dependency ' + id);
    } });
  return module.exports;
}
const p = load('ContainerProtocol.ts');
const { ContainerRepository } = load('ContainerRepository.ts');
const item = { id: 'original-id', name: 'app', image: 'image:latest', state: 'running' };
const detail = (id = item.id) => ({ details: { Id: id, Config: { Image: 'image:latest', Env: ['SECRET=private'] },
  State: { Status: 'running' }, Mounts: [], NetworkSettings: { Ports: {} } } });
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });
const bad = code => ({ status: 200, text: JSON.stringify({ success: false, error: { code } }) });
const failure = kind => new dsm.NasFailure(kind, '合成失败', 105);
const isProtocol = error => error instanceof dsm.NasFailure && error.kind === dsm.NasErrorKind.Protocol;

test('containers use real list identities, unknown states and a display-only inspect projection', () => {
  assert.equal(p.decodeContainers({ containers: [{ ...item, status: 'future' }] })[0].state, 'unknown');
  assert.throws(() => p.decodeContainers({ project: {} }), isProtocol);
  assert.throws(() => p.decodeContainers({ containers: [item, item] }), isProtocol);
  assert.equal(p.filterContainers([item], ' APP ', 'running').length, 1);
  assert.equal(p.filterContainers([item], '', 'stopped').length, 0);
  const decoded = p.decodeContainerDetail(detail(), item);
  assert.equal(decoded.item.id, item.id);
  assert.doesNotMatch(JSON.stringify(decoded), /SECRET|private|Env|profile/);
  assert.throws(() => p.decodeContainerDetail(detail('replacement-id'), item), isProtocol);
  const resource = p.decodeContainerResource({ resources: [] }, { ...item, state: 'stopped' }, 12);
  assert.deepEqual(plain(resource), { sampledAt: 12 });
});

test('JSON preserves opaque large integers and log windows bound lines and UTF-8 bytes', () => {
  const result = common.decodeReadOnlyResponse('suite', 200, '{"success":true,"data":{"id":9007199254740993,"text":"9007199254740993","ids":[9007199254740995]}}');
  assert.equal(result.id, '9007199254740993'); assert.equal(result.ids[0], '9007199254740995');
  assert.equal(result.text, '9007199254740993');
  const lines = p.decodeContainerLogs({ logs: [{ created: '', stream: '', text: 'one\n'.repeat(600) + '\x1b[31mred\x00' }] });
  assert.equal(lines.truncated, true); assert.ok(lines.text.split('\n').length <= 500);
  const bytes = common.limitLogText('😀'.repeat(200000));
  assert.ok(Buffer.byteLength(bytes.text) <= 512 * 1024); assert.equal(bytes.truncated, true);
  assert.doesNotMatch(common.readableLog('\x1b[31mred\x00'), /\x1b|\x00/);
});

async function connectorFixture() {
  const replies = [], calls = [];
  const connector = new NasConnector({ post(...args) { calls.push(args); assert.ok(replies.length); return Promise.resolve(replies.shift()); }, close() {} });
  const descriptors = {};
  for (const name of ['SYNO.API.Auth', 'SYNO.FileStation.List', 'SYNO.Docker.Container', 'SYNO.Docker.Container.Log', 'SYNO.Docker.Container.Resource']) {
    descriptors[name] = { path: 'suite/entry.cgi', minVersion: 1, maxVersion: name === 'SYNO.API.Auth' ? 6 : 99, requestFormat: 'JSON' };
  }
  replies.push(ok(descriptors)); await connector.discover('https://nas.example');
  connector.restoreSession({ sid: 'private-sid', synoToken: '' });
  return { connector, calls, replies, state: feature => connector.capabilitySnapshots().find(value => value.feature === feature).state };
}

test('container connector fixes read methods, version, bounds and per-operation capability evidence', async () => {
  const f = await connectorFixture();
  f.replies.push(ok({ containers: [item] }));
  await f.connector.readContainers('list', '', p.decodeContainers);
  assert.equal(f.state('containerList'), 'available'); assert.equal(f.state('containerLogs'), 'unverified');
  assert.equal(f.calls.length, 2);
  const fields = new URLSearchParams(f.calls.at(-1)[1]);
  assert.equal(fields.get('api'), 'SYNO.Docker.Container'); assert.equal(fields.get('version'), '1');
  assert.doesNotMatch(f.calls.at(-1)[0] + f.calls.at(-1)[1], /private-sid|_sid|synotoken/);
  f.replies.push(ok({ logs: [] })); await f.connector.readContainers('logs', item.name, p.decodeContainerLogs);
  const logs = new URLSearchParams(f.calls.at(-1)[1]);
  assert.equal(logs.get('method'), 'get'); assert.equal(logs.get('limit'), '500'); assert.equal(logs.get('name'), '"app"');
  const count = f.calls.length;
  await assert.rejects(f.connector.readContainers('stop', item.name, value => value), error => error.kind === dsm.NasErrorKind.InvalidInput);
  assert.equal(f.calls.length, count);
});

test('suite session rejection retains the main session unless protected main reading proves expiry', async () => {
  for (const proof of ['valid', 'network', 'expired']) {
    const f = await connectorFixture();
    f.replies.push(bad(107));
    if (proof === 'valid') f.replies.push(ok({ shares: [], total: 0, offset: 0 }));
    else if (proof === 'network') f.replies.push({ status: 503, text: '' });
    else f.replies.push(bad(106));
    await assert.rejects(f.connector.readContainers('list', '', p.decodeContainers), error =>
      error.kind === (proof === 'expired' ? dsm.NasErrorKind.SessionExpired : proof === 'network' ? dsm.NasErrorKind.Http : dsm.NasErrorKind.Permission));
    assert.equal(Number(f.connector.sessionSnapshot() !== undefined), proof === 'expired' ? 0 : 1);
  }
});

test('name-only resource and log reads verify inspect identity, and cancellation prevents follow-up reads', async () => {
  let calls = 0, cancelled = false;
  const repository = new ContainerRepository({ async readContainers(operation, name, decode) {
    calls++;
    return decode(operation === 'detail' ? detail(calls > 2 ? 'replacement-id' : item.id) : { resources: [] });
  } });
  await assert.rejects(repository.resources(item, () => {}), isProtocol);
  assert.equal(calls, 3);
  calls = 0;
  const check = () => { cancelled = true; throw failure(dsm.NasErrorKind.Cancelled); };
  await assert.rejects(repository.logs(item, check));
  assert.equal(cancelled, true); assert.equal(calls, 1);
});

test('model keeps list cache on failed refresh and drops responses after hiding or resetting', async () => {
  const { ContainerModel } = load('ContainerModel.ets');
  const model = new ContainerModel(); let resolve;
  model.repository = { async list() { return [item]; } };
  model.setVisible(true); await tick(); const checked = model.checkedAt;
  assert.equal(model.loaded, true);
  model.repository.list = async () => { throw failure(dsm.NasErrorKind.Network); };
  await model.refresh(); assert.equal(model.items.length, 1); assert.equal(model.checkedAt, checked);
  model.repository.list = () => new Promise(yes => { resolve = yes; });
  const old = model.refresh(); model.setVisible(false); resolve([]); await old;
  assert.equal(model.items.length, 1); assert.equal(model.loading, false);
  model.reset(); assert.equal(model.items.length, 0); assert.equal(model.checkedAt, 0);
});

test('following schedules five-second reads and stops on old-record browsing, background or read failure', async () => {
  const timers = new Map(); let serial = 0;
  const { ContainerModel } = load('ContainerModel.ets', { setTimeout(fn, ms) { assert.equal(ms, 5000); timers.set(++serial, fn); return serial; },
    clearTimeout(id) { timers.delete(id); } });
  const model = new ContainerModel(); model.visible = true; model.selected = item;
  model.repository = { async logs() { return { text: 'latest', truncated: false }; } };
  model.startFollowing(); await tick(); assert.equal(model.following, true); assert.equal(timers.size, 1);
  model.stopFollowing(); assert.equal(timers.size, 0);
  model.startFollowing(); await tick(); model.setVisible(false); assert.equal(model.following, false); assert.equal(timers.size, 0);
  model.setVisible(true); model.repository.logs = async () => { throw failure(dsm.NasErrorKind.Network); };
  model.startFollowing(); await tick(); assert.equal(model.following, false); assert.equal(timers.size, 0); assert.equal(model.logs, 'latest');
});
