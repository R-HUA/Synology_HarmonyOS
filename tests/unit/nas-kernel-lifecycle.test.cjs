const { test } = require('node:test');
const assert = require('node:assert/strict');
const { NasConnector } = require('../../work/core-build/network/NasConnector.js');
const { NasFailure, NasErrorKind: K, decodeNasResponse } = require('../../work/core-build/domain/DsmProtocol.js');
const { SessionRegistry } = require('../../work/core-build/network/SessionRegistry.js');
const { NasTransferCancellation } = require('../../work/core-build/network/NasTransferTransport.js');
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });
const fail = code => ({ status: 200, text: JSON.stringify({ success: false, error: { code } }) });
const isKind = kind => error => error instanceof NasFailure && error.kind === kind;
const gate = () => {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
};

async function fixture(transfers) {
  const replies = [];
  const calls = [];
  const transport = { transfers, closed: false, post(address, body, credentials) {
    calls.push({ address, fields: new URLSearchParams(body), credentials });
    assert.ok(replies.length, 'unexpected request');
    return Promise.resolve(replies.shift());
  }, close() { this.closed = true; } };
  const connector = new NasConnector(transport);
  replies.push(ok({
    'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 6, maxVersion: 6 },
    'SYNO.FileStation.List': { path: 'entry.cgi', minVersion: 2, maxVersion: 2 },
    'SYNO.FileStation.Sharing': { path: 'entry.cgi', minVersion: 3, maxVersion: 3 },
    'SYNO.DownloadStation.Task': { path: 'DownloadStation/task.cgi', minVersion: 1, maxVersion: 3 },
    'SYNO.SynologyDrive.Files': { path: 'entry.cgi', minVersion: 2, maxVersion: 2 },
  }));
  await connector.discover('https://nas.example.test');
  connector.restoreSession([
    { name: 'FileStation', sid: 'file-sid', synoToken: 'file-token' },
    { name: 'DownloadStation', sid: 'download-sid', synoToken: 'download-token' },
  ]);
  return { connector, transport, replies, calls };
}

test('logout blocks new logins and business calls before server logout finishes', async () => {
  const f = await fixture();
  const pending = gate();
  f.replies.push(pending.promise, ok(undefined));
  const logout = f.connector.logout();
  const count = f.calls.length;
  await assert.rejects(f.connector.login('other', 'password', ''), isKind(K.Cancelled));
  await assert.rejects(f.connector.extensionRequest('fileSharing', 'create', []), isKind(K.Cancelled));
  await assert.rejects(f.connector.requestDrive('SYNO.SynologyDrive.Files', 2, 'list', []), isKind(K.Cancelled));
  assert.equal(f.calls.length, count);
  pending.resolve(ok(undefined));
  await logout;
  assert.equal(f.transport.closed, true);
});

test('closing during an optional suite login cannot resolve the primary login as successful', async () => {
  for (const reject of [false, true]) {
    const f = await fixture();
    f.replies.push(fail(119));
    await assert.rejects(f.connector.list(''), isKind(K.SessionExpired));
    const pending = gate();
    f.replies.push(ok({ sid: 'new-file', synotoken: 'new-token' }), pending.promise);
    const login = f.connector.login('other', 'password', '');
    while (f.calls.at(-1).fields.get('session') !== 'DownloadStation') { await Promise.resolve(); }
    f.connector.close();
    if (reject) { pending.reject(new NasFailure(K.Network, 'network closed')); }
    else { pending.resolve(ok({ sid: 'late-download' })); }
    await assert.rejects(login, isKind(K.Cancelled));
    assert.equal(f.transport.closed, true);
  }
});

test('File Station expiry preserves in-flight Download Station reads and its capability evidence', async () => {
  for (const sharing of [false, true]) {
    const f = await fixture();
    await f.connector.readExtension('nasDownloads', async () => 'verified');
    const pending = gate();
    f.replies.push(pending.promise, fail(119));
    const download = f.connector.extensionRequest('nasDownloads', 'list', []);
    await assert.rejects(sharing ? f.connector.extensionRequest('fileSharing', 'list', []) : f.connector.list(''),
      isKind(K.SessionExpired));
    assert.deepEqual(f.connector.sessionSnapshot().map(row => row.name), ['DownloadStation']);
    pending.resolve(ok({ tasks: [], offset: 0, total: 0 }));
    await download;
    assert.equal(await f.connector.readExtension('nasDownloads', async () => 'still valid'), 'still valid');
    assert.equal(f.connector.capabilitySnapshots().find(row => row.feature === 'nasDownloads').state, 'available');
  }
});

test('suite expiry rejects its own late success and late transport failure without affecting File Station', async () => {
  for (const reject of [false, true]) {
    const f = await fixture();
    const pending = gate();
    f.replies.push(pending.promise, fail(107));
    const old = f.connector.extensionRequest('nasDownloads', 'list', []);
    await assert.rejects(f.connector.extensionRequest('nasDownloads', 'list', []), isKind(K.SessionExpired));
    if (reject) { pending.reject(new NasFailure(K.Network, 'old network error')); }
    else { pending.resolve(ok({ tasks: [], offset: 0, total: 0 })); }
    await assert.rejects(old, isKind(K.Cancelled));
    assert.equal(f.connector.hasBusinessSession('FileStation'), true);
    f.replies.push(ok({ shares: [], offset: 0, total: 0 }));
    await f.connector.list('');
  }
});

test('a sharing session rejection cancels active Drive transfers and invalidates late results', async () => {
  const pending = gate();
  let cancellation;
  const f = await fixture({ upload(plan, source, filename, control) {
    cancellation = control.cancellation;
    return pending.promise;
  } });
  const upload = f.connector.uploadDrive({ parentId: '123', filename: 'sample.bin', conflict: 'version', modifiedTime: 1000 },
    { path: '/cache/sample.bin', bytes: 1 }, { cancellation: new NasTransferCancellation() });
  f.replies.push(fail(119));
  await assert.rejects(f.connector.extensionRequest('fileSharing', 'list', []), isKind(K.SessionExpired));
  assert.equal(cancellation.cancelled, true);
  pending.resolve(ok({ tmp_newly_created: true, uploaded_size: 1 }));
  await assert.rejects(upload, isKind(K.Cancelled));
});

test('relogin never retains the previous account suite session if the new suite login fails', async () => {
  const f = await fixture();
  f.replies.push(fail(119));
  await assert.rejects(f.connector.list(''), isKind(K.SessionExpired));
  assert.equal(f.connector.hasBusinessSession('DownloadStation'), true);
  f.replies.push(ok({ sid: 'other-file-sid' }), fail(404));
  await f.connector.login('other', 'password', '');
  assert.deepEqual(f.connector.sessionSnapshot(), [{ name: 'FileStation', sid: 'other-file-sid', synoToken: '' }]);
  assert.equal(f.calls.at(-1).credentials, undefined);
});

test('Drive RPC requires its File Station authorization before submitting a request', async () => {
  const f = await fixture();
  f.replies.push(fail(119));
  await assert.rejects(f.connector.list(''), isKind(K.SessionExpired));
  const count = f.calls.length;
  await assert.rejects(f.connector.requestDrive('SYNO.SynologyDrive.Files', 2, 'list', []), isKind(K.SessionExpired));
  assert.equal(f.calls.length, count);
});

test('persisted tokens with the wrong JSON type are rejected without replacing valid sessions', () => {
  const registry = new SessionRegistry();
  registry.register('FileStation', { sid: 'sid', synoToken: 'token' });
  const revision = registry.revision();
  for (const synoToken of [null, 17, true, {}, []]) {
    assert.throws(() => registry.restore([{ name: 'DownloadStation', sid: 'download', synoToken }]), isKind(K.Protocol));
  }
  assert.equal(registry.revision(), revision);
  assert.deepEqual(registry.snapshot(), [{ name: 'FileStation', sid: 'sid', synoToken: 'token' }]);
});

test('DSM contradictory success envelopes cannot become business success', () => {
  for (const envelope of [
    { success: true, error: { code: 119 }, data: {} },
    { success: true, error: null },
  ]) {
    assert.throws(() => decodeNasResponse('SYNO.FileStation.CreateFolder', 200, JSON.stringify(envelope)), isKind(K.Protocol));
  }
});
