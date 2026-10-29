const { test } = require('node:test');
const assert = require('node:assert/strict');
const { NasConnector } = require('../../work/core-build/network/NasConnector.js');
const { NasFailure, NasErrorKind: K, decodeNasResponse } = require('../../work/core-build/domain/DsmProtocol.js');
const { NasTransferCancellation } = require('../../work/core-build/network/NasTransferTransport.js');
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });
const fail = code => ({ status: 200, text: JSON.stringify({ success: false, error: { code } }) });
const isKind = kind => error => error instanceof NasFailure && error.kind === kind;
const gate = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };

async function fixture(transfers) {
  const replies = [], calls = [];
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
    'SYNO.DownloadStation.Task': { path: 'task.cgi', minVersion: 1, maxVersion: 3 },
    'SYNO.SynologyDrive.Files': { path: 'entry.cgi', minVersion: 2, maxVersion: 2 },
  }));
  await connector.discover('https://nas.example.test');
  connector.restoreSession({ sid: 'primary-sid', synoToken: 'primary-token' });
  return { connector, transport, replies, calls };
}

test('logout blocks all business calls before server logout finishes', async () => {
  const f = await fixture(), pending = gate();
  f.replies.push(pending.promise);
  const logout = f.connector.logout(), count = f.calls.length;
  await assert.rejects(f.connector.login('other', 'password', ''), isKind(K.Cancelled));
  await assert.rejects(f.connector.extensionRequest('fileSharing', 'create', []), isKind(K.Cancelled));
  await assert.rejects(f.connector.requestDrive('SYNO.SynologyDrive.Files', 2, 'list', []), isKind(K.Cancelled));
  assert.equal(f.calls.length, count); pending.resolve(ok(undefined)); await logout;
  assert.equal(f.transport.closed, true);
});

test('closing during login rejects both a late success and a late network failure', async () => {
  for (const reject of [false, true]) {
    const f = await fixture(); f.replies.push(fail(119), fail(119));
    await assert.rejects(f.connector.list(''), isKind(K.SessionExpired));
    const pending = gate(); f.replies.push(pending.promise);
    const login = f.connector.login('other', 'password', '');
    f.connector.close();
    if (reject) pending.reject(new NasFailure(K.Network, 'closed'));
    else pending.resolve(ok({ sid: 'late' }));
    await assert.rejects(login, isKind(K.Cancelled));
  }
});

test('confirmed primary expiry cancels late successes and network failures from every suite', async () => {
  for (const reject of [false, true]) {
    const f = await fixture(), pending = gate();
    f.replies.push(pending.promise, fail(107), fail(119));
    const old = f.connector.extensionRequest('nasDownloads', 'list', []);
    await assert.rejects(f.connector.extensionRequest('fileSharing', 'list', []), isKind(K.SessionExpired));
    assert.equal(f.connector.sessionSnapshot(), undefined);
    if (reject) pending.reject(new NasFailure(K.Network, 'old'));
    else pending.resolve(ok({ tasks: [] }));
    await assert.rejects(old, isKind(K.Cancelled));
    const count = f.calls.length;
    await assert.rejects(f.connector.requestDrive('SYNO.SynologyDrive.Files', 2, 'list', []), isKind(K.SessionExpired));
    assert.equal(f.calls.length, count);
  }
});

test('local suite rejection and failed validation preserve the primary session without replay', async () => {
  for (const proof of [ok({ synotoken: 'primary-token' }), Promise.reject(new NasFailure(K.Network, 'offline'))]) {
    // Attach the rejection immediately while the first suite response is processed.
    if (proof instanceof Promise) proof.catch(() => {});
    const f = await fixture(); f.replies.push(fail(119), proof);
    await assert.rejects(f.connector.extensionRequest('nasDownloads', 'create', []));
    assert.equal(f.connector.sessionSnapshot().sid, 'primary-sid');
    assert.deepEqual(f.calls.slice(1).map(x => x.fields.get('method')), ['create', 'token']);
  }
});

test('confirmed primary expiry cancels active Drive transfers', async () => {
  const pending = gate(); let cancellation;
  const f = await fixture({ upload(plan, source, filename, control) { cancellation = control.cancellation; return pending.promise; } });
  const upload = f.connector.uploadDrive({ parentId: '123', filename: 'sample.bin', conflict: 'version', modifiedTime: 1000 },
    { path: '/cache/sample.bin', bytes: 1 }, { cancellation: new NasTransferCancellation() });
  f.replies.push(fail(119), fail(119));
  await assert.rejects(f.connector.extensionRequest('fileSharing', 'list', []), isKind(K.SessionExpired));
  assert.equal(cancellation.cancelled, true); pending.resolve(ok({ tmp_newly_created: true, uploaded_size: 1 }));
  await assert.rejects(upload, isKind(K.Cancelled));
});

test('contradictory success envelopes cannot become business success', () => {
  for (const envelope of [{ success: true, error: { code: 119 }, data: {} }, { success: true, error: null }]) {
    assert.throws(() => decodeNasResponse('SYNO.FileStation.CreateFolder', 200, JSON.stringify(envelope)), isKind(K.Protocol));
  }
});
