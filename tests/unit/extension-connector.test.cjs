const { test } = require('node:test');
const assert = require('node:assert/strict');
const { NasConnector, NAS_DISCOVERY_QUERY } = require('../../work/core-build/network/NasConnector.js');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });

async function fixture(shareVersion = 3, downloadVersion = 20, downloadSession = true) {
  const calls = [];
  const responses = [ok({
    'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 6 },
    'SYNO.FileStation.List': { path: 'entry.cgi', minVersion: 1, maxVersion: 2 },
    'SYNO.FileStation.Sharing': { path: 'entry.cgi', minVersion: shareVersion, maxVersion: shareVersion },
    'SYNO.DownloadStation.Task': { path: 'DownloadStation/task.cgi', minVersion: 1, maxVersion: downloadVersion },
  })];
  const connector = new NasConnector({ post(...args) { calls.push(args); return Promise.resolve(responses.shift()); }, close() {} });
  await connector.discover('https://nas.example.test');
  const sessions = [{ name: 'FileStation', sid: 'private-sid', synoToken: 'private-token' }];
  if (downloadSession) { sessions.push({ name: 'DownloadStation', sid: 'download-sid', synoToken: 'download-token' }); }
  connector.restoreSession(sessions);
  return { connector, calls, responses };
}

test('extension discovery selects only the tested versions and uses protected POST authentication', async () => {
  assert.match(NAS_DISCOVERY_QUERY, /SYNO.FileStation.Sharing/);
  assert.match(NAS_DISCOVERY_QUERY, /SYNO.DownloadStation.Task/);
  const { connector, calls, responses } = await fixture();
  for (const [feature, version, sid] of [['fileSharing', '3', 'private-sid'], ['nasDownloads', '3', 'download-sid']]) {
    responses.push(ok({}));
    await connector.extensionRequest(feature, 'list', []);
    const [address, body, session] = calls.at(-1);
    assert.equal(new URLSearchParams(body).get('version'), version);
    assert.doesNotMatch(address + body, /private-sid|private-token|download-sid|download-token/);
    assert.equal(session.sid, sid);
  }
  await assert.rejects(connector.extensionRequest('fileSharing', 'clear_invalid', []), error => error.kind === K.InvalidInput);
});

test('unverified share versions fail before any write is sent', async () => {
  const { connector, calls } = await fixture(4);
  await assert.rejects(connector.extensionRequest('fileSharing', 'create', []), error => error.kind === K.Unsupported);
  assert.equal(calls.length, 1);
});

test('capability reads include schema validation rather than trusting API discovery', async () => {
  const { connector } = await fixture();
  const state = () => connector.capabilitySnapshots().find(item => item.feature === 'nasDownloads').state;
  assert.equal(state(), 'unverified');
  await connector.readExtension('nasDownloads', async () => []);
  assert.equal(state(), 'available');
  await assert.rejects(connector.readExtension('nasDownloads', async () => { throw new NasFailure(K.Protocol, 'schema'); }));
  assert.equal(state(), 'schemaMismatch');
});

test('Download Station session errors do not invalidate a still-valid File Station session', async () => {
  const { connector, responses } = await fixture();
  responses.push({ status: 200, text: '{"success":false,"error":{"code":107}}' });
  await assert.rejects(connector.extensionRequest('nasDownloads', 'list', []), error => error.kind === K.SessionExpired);
  assert.deepEqual(connector.sessionSnapshot().map(record => record.name), ['FileStation']);
  responses.push(ok({ shares: [], total: 0, offset: 0 }));
  await connector.list('');
  assert.equal(connector.hasBusinessSession('DownloadStation'), false);
  await assert.rejects(connector.extensionRequest('nasDownloads', 'list', []), error => error.kind === K.SessionExpired);
});

test('a missing Download Station session is rejected before any request is sent', async () => {
  const { connector, calls } = await fixture(3, 20, false);
  const before = calls.length;
  await assert.rejects(connector.extensionRequest('nasDownloads', 'list', []),
    error => error.kind === K.SessionExpired && /下载套件需要重新验证/.test(error.message));
  assert.equal(calls.length, before);
});

test('Download Station OTP recovery replaces only its session and does not replay a write', async () => {
  const { connector, calls, responses } = await fixture(3, 20, false);
  responses.push({ status: 200, text: '{"success":false,"error":{"code":403}}' });
  await assert.rejects(connector.authenticateDownloadStation('alice', 'password', ''), error => error.kind === K.OtpRequired);
  assert.deepEqual(connector.sessionSnapshot().map(x => x.name), ['FileStation']);
  responses.push(ok({ sid: 'new-download-sid', synotoken: 'new-download-token' }));
  await connector.authenticateDownloadStation('alice', 'password', '123456');
  assert.equal(connector.sessionSnapshot()[0].sid, 'private-sid');
  assert.equal(connector.sessionSnapshot()[1].sid, 'new-download-sid');
  const fields = new URLSearchParams(calls.at(-1)[1]);
  assert.equal(fields.get('session'), 'DownloadStation'); assert.equal(fields.get('otp_code'), '123456');
  assert.equal(calls.filter(([, body]) => new URLSearchParams(body).get('method') === 'create').length, 0);
});

test('suite authentication failure cannot invalidate the main session', async () => {
  const { connector, responses } = await fixture();
  responses.push({ status: 200, text: '{"success":false,"error":{"code":119}}' });
  await assert.rejects(connector.authenticateDownloadStation('alice', 'password', ''));
  assert.equal(connector.sessionSnapshot()[0].sid, 'private-sid');
});

test('login establishes the Download Station suite session only when its API is discovered', async () => {
  const responses = [ok({
    'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 6 },
    'SYNO.FileStation.List': { path: 'entry.cgi', minVersion: 1, maxVersion: 2 },
    'SYNO.DownloadStation.Task': { path: 'DownloadStation/task.cgi', minVersion: 1, maxVersion: 20 },
  })];
  responses.push(ok({ sid: 'file-station-sid', synotoken: 'file-station-token' }));
  responses.push(ok({ sid: 'download-station-sid', synotoken: 'download-station-token' }));
  const calls = [];
  const connector = new NasConnector({ post(...args) { calls.push(args); return Promise.resolve(responses.shift()); }, close() {} });
  await connector.discover('https://nas.example.test');
  await connector.login('alice', 'password', '');
  const logins = calls.filter(([, body]) => new URLSearchParams(body).get('method') === 'login');
  assert.deepEqual(logins.map(([, body]) => new URLSearchParams(body).get('session')), ['FileStation', 'DownloadStation']);
  assert.deepEqual(connector.sessionSnapshot(), [
    { name: 'FileStation', sid: 'file-station-sid', synoToken: 'file-station-token' },
    { name: 'DownloadStation', sid: 'download-station-sid', synoToken: 'download-station-token' }]);
});

test('a failed Download Station suite login keeps the primary session usable', async () => {
  const responses = [ok({
    'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 6 },
    'SYNO.FileStation.List': { path: 'entry.cgi', minVersion: 1, maxVersion: 2 },
    'SYNO.DownloadStation.Task': { path: 'DownloadStation/task.cgi', minVersion: 1, maxVersion: 20 },
  })];
  responses.push(ok({ sid: 'file-station-sid', synotoken: 'file-station-token' }));
  responses.push({ status: 200, text: '{"success":false,"error":{"code":404}}' });
  const connector = new NasConnector({ post(...args) { return Promise.resolve(responses.shift()); }, close() {} });
  await connector.discover('https://nas.example.test');
  await connector.login('alice', 'password', '');
  assert.deepEqual(connector.sessionSnapshot().map(record => record.name), ['FileStation']);
  await assert.rejects(connector.extensionRequest('nasDownloads', 'list', []), error => error.kind === K.SessionExpired);
});

test('logout ends every established business session', async () => {
  const { connector, responses, calls } = await fixture();
  responses.push(ok(undefined));
  responses.push(ok(undefined));
  await connector.logout();
  const logouts = calls.filter(([, body]) => new URLSearchParams(body).get('method') === 'logout');
  assert.deepEqual(logouts.map(([, body]) => new URLSearchParams(body).get('session')), ['FileStation', 'DownloadStation']);
  assert.deepEqual(logouts.map(([, , session]) => session.sid), ['private-sid', 'download-sid']);
});

test('NAS download creation uses the documented v3 contract, not the legacy v1 example', async () => {
  const { connector, responses, calls } = await fixture();
  responses.push(ok({}));
  await connector.extensionRequest('nasDownloads', 'create', []);
  assert.equal(new URLSearchParams(calls.at(-1)[1]).get('version'), '3');
});

test('extension decoding preserves Download Station control arrays and share item errors', async () => {
  const { connector, responses } = await fixture();
  responses.push(ok([{ id: 'task-id', error: 0 }]));
  assert.deepEqual(await connector.extensionRequest('nasDownloads', 'pause', []), [{ id: 'task-id', error: 0 }]);
  const partial = { success: false, error: { code: 2002, errors: [{ id: 'share-id', code: 403 }] } };
  responses.push({ status: 200, text: JSON.stringify(partial) });
  assert.deepEqual(await connector.extensionRequest('fileSharing', 'delete', []), partial);
});

test('a v1-only Download Station permits reads but rejects link creation before submission', async () => {
  const { connector, responses, calls } = await fixture(3, 1);
  assert.equal(connector.supportsExtensionAction('nasDownloads', 'create'), false);
  assert.equal(connector.supportsExtensionAction('nasDownloads', 'list'), true);
  await assert.rejects(connector.extensionRequest('nasDownloads', 'create', []), error => error.kind === K.Unsupported);
  assert.equal(calls.length, 1);
  responses.push(ok({ tasks: [], offset: 0, total: 0 }));
  await connector.extensionRequest('nasDownloads', 'list', []);
  assert.equal(new URLSearchParams(calls.at(-1)[1]).get('version'), '1');
});

test('discovery no longer requires File Station but authentication remains mandatory', async () => {
  const responses = [ok({
    'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 6 },
    'SYNO.DownloadStation.Task': { path: 'DownloadStation/task.cgi', minVersion: 1, maxVersion: 20 },
  })];
  responses.push(ok({ sid: 'file-station-sid', synotoken: 'file-station-token' }));
  responses.push(ok({ sid: 'download-station-sid', synotoken: 'download-station-token' }));
  const connector = new NasConnector({ post(...args) { return Promise.resolve(responses.shift()); }, close() {} });
  const capabilities = await connector.discover('https://nas.example.test');
  assert.equal(capabilities.some(api => api.name === 'SYNO.FileStation.List'), false);
  const fileBrowse = connector.capabilitySnapshots().find(item => item.feature === 'fileBrowse');
  assert.equal(fileBrowse.state, 'unverified');
  assert.equal(fileBrowse.reason, 'apiNotDiscovered');
  await connector.login('alice', 'password', '');
  await assert.rejects(connector.list(''), error => error.kind === K.Unsupported);

  const authless = new NasConnector({ post() { return Promise.resolve(ok({})); }, close() {} });
  await assert.rejects(authless.discover('https://nas.example.test'), error => error.kind === K.Unsupported);
});
