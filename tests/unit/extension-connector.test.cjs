const { test } = require('node:test');
const assert = require('node:assert/strict');
const { NasConnector, NAS_DISCOVERY_QUERY } = require('../../work/core-build/network/NasConnector.js');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });

async function fixture(shareVersion = 3, downloadVersion = 20) {
  const calls = [];
  const responses = [ok({
    'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 6 },
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
  for (const [feature, version] of [['fileSharing', '3'], ['nasDownloads', '3']]) {
    responses.push(ok({}));
    await connector.extensionRequest(feature, 'list', []);
    const [address, body, session] = calls.at(-1);
    assert.equal(new URLSearchParams(body).get('version'), version);
    assert.doesNotMatch(address + body, /private-sid|private-token/);
    assert.equal(session.sid, 'private-sid');
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
  assert.ok(connector.sessionSnapshot());
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
