const { test } = require('node:test');
const assert = require('node:assert/strict');
const { NasConnector, NAS_DISCOVERY_QUERY } = require('../../work/core-build/network/NasConnector.js');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });

async function fixture(shareVersion = 3, downloadVersion = 20) {
  const calls = [];
  const responses = [ok({
    'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 6 },
    'SYNO.DSM.Info': { path: 'entry.cgi', minVersion: 2, maxVersion: 2 },
    'SYNO.FileStation.List': { path: 'entry.cgi', minVersion: 1, maxVersion: 2 },
    'SYNO.FileStation.Sharing': { path: 'entry.cgi', minVersion: shareVersion, maxVersion: shareVersion },
    'SYNO.DownloadStation.Task': { path: 'DownloadStation/task.cgi', minVersion: 1, maxVersion: downloadVersion },
  })];
  const connector = new NasConnector({ post(...args) { calls.push(args); return Promise.resolve(responses.shift()); }, close() {} });
  await connector.discover('https://nas.example.test');
  connector.restoreSession({ sid: 'private-sid', synoToken: 'private-token' });
  return { connector, calls, responses };
}

test('extension discovery selects only the tested versions and uses protected POST authentication', async () => {
  assert.match(NAS_DISCOVERY_QUERY, /SYNO.FileStation.Sharing/);
  assert.match(NAS_DISCOVERY_QUERY, /SYNO.DownloadStation.Task/);
  const { connector, calls, responses } = await fixture();
  for (const [feature, version, sid] of [['fileSharing', '3', 'private-sid'], ['nasDownloads', '3', 'private-sid']]) {
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

test('a suite rejection checks the primary session without replaying the operation', async () => {
  const { connector, responses, calls } = await fixture();
  responses.push({ status: 200, text: '{"success":false,"error":{"code":107}}' }, ok({ model: 'Synthetic NAS' }));
  await assert.rejects(connector.extensionRequest('nasDownloads', 'create', []), error => error.kind === K.Permission);
  assert.equal(connector.sessionSnapshot().sid, 'private-sid');
  assert.deepEqual(calls.slice(1).map(([, body]) => new URLSearchParams(body).get('method')), ['create', 'getinfo']);
  responses.push({ status: 200, text: '{"success":false,"error":{"code":119}}' }, { status: 200, text: '{"success":false,"error":{"code":119}}' });
  await assert.rejects(connector.extensionRequest('nasDownloads', 'list', []), error => error.kind === K.SessionExpired);
  assert.equal(connector.sessionSnapshot(), undefined);
});

test('one login with OTP serves all suites and one logout ends the primary session', async () => {
  const calls = [];
  const responses = [ok({ 'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 6 },
    'SYNO.DownloadStation.Task': { path: 'task.cgi', minVersion: 1, maxVersion: 3 } }),
    { ...ok({ sid: 'primary', synotoken: 'token' }), setCookies: ['id=primary; Path=/; Secure; HttpOnly'] }, ok({ tasks: [] }), ok(undefined)];
  const connector = new NasConnector({ post(...args) { calls.push(args); return Promise.resolve(responses.shift()); }, close() {} });
  await connector.discover('https://nas.example.test');
  await connector.login('alice', 'password', '123456');
  assert.deepEqual(connector.webSessionCookies(), ['id=primary; Path=/; Secure; HttpOnly']);
  const copiedCookies = connector.webSessionCookies(); copiedCookies[0] = 'mutated';
  assert.equal(connector.webSessionCookies()[0], 'id=primary; Path=/; Secure; HttpOnly');
  await connector.extensionRequest('nasDownloads', 'list', []);
  await connector.logout();
  const login = new URLSearchParams(calls[1][1]);
  assert.equal(login.get('session'), null); assert.equal(login.get('format'), 'cookie'); assert.equal(login.get('otp_code'), '123456');
  assert.equal(calls[2][2].sid, 'primary'); assert.equal(calls[3][2].sid, 'primary');
  assert.equal(new URLSearchParams(calls[3][1]).get('session'), null);
  assert.equal(calls.filter(([, body]) => new URLSearchParams(body).get('method') === 'login').length, 1);
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
  const connector = new NasConnector({ post(...args) { return Promise.resolve(responses.shift()); }, close() {} });
  const capabilities = await connector.discover('https://nas.example.test');
  assert.equal(capabilities.some(api => api.name === 'SYNO.FileStation.List'), false);
  const fileBrowse = connector.capabilitySnapshots().find(item => item.feature === 'fileBrowse');
  assert.equal(fileBrowse.state, 'unverified');
  assert.equal(fileBrowse.reason, 'apiNotDiscovered');
  await connector.login('alice', 'password', '');
  assert.equal(responses.length, 0);
  await assert.rejects(connector.list(''), error => error.kind === K.Unsupported);

  const authless = new NasConnector({ post() { return Promise.resolve(ok({})); }, close() {} });
  await assert.rejects(authless.discover('https://nas.example.test'), error => error.kind === K.Unsupported);
});
