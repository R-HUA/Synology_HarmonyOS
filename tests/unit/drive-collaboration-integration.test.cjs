const { test } = require('node:test');
const assert = require('node:assert/strict');
const { NasConnector } = require('../../work/core-build/network/NasConnector.js');
const p = require('../../work/core-build/domain/DriveCollaborationProtocol.js');
const { NasFailure, NasErrorKind } = require('../../work/core-build/domain/DsmProtocol.js');

async function fixture() {
  const calls = [];
  const apis = {
    'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 6 },
    'SYNO.SynologyDrive.Files': { path: 'entry.cgi', minVersion: 1, maxVersion: 10 },
    [p.DRIVE_SHARING_API]: { path: 'entry.cgi', minVersion: 1, maxVersion: 1 },
    [p.DRIVE_NOTIFICATIONS_API]: { path: 'entry.cgi', minVersion: 1, maxVersion: 1 },
  };
  const options = { notifications: { items: [], total: 0 } };
  const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });
  const connector = new NasConnector({ async post(address, body, session) {
    const fields = Object.fromEntries(new URLSearchParams(body)); calls.push({ address, fields, session });
    if (fields.api === 'SYNO.API.Info') {
      return ok(Object.fromEntries(Object.entries(apis).filter(([api]) => fields.query.split(',').includes(api))));
    }
    if (fields.api === 'SYNO.API.Auth') return ok({ sid: 'SYNTHETIC-SID', synotoken: 'SYNTHETIC-TOKEN' });
    assert.deepEqual(session, { sid: 'SYNTHETIC-SID', synoToken: 'SYNTHETIC-TOKEN' });
    if (fields.api === p.DRIVE_SHARING_API) {
      assert.deepEqual(fields, { api: p.DRIVE_SHARING_API, version: '1', method: 'create_link', path: '"id:900000000000000001"' });
      return ok({ url: 'https://drive.example.test/?file_id=900000000000000001' });
    }
    assert.equal(fields.api, p.DRIVE_NOTIFICATIONS_API);
    assert.deepEqual(fields, { api: p.DRIVE_NOTIFICATIONS_API, version: '1', method: 'list', limit: '100' });
    return ok(options.notifications);
  }, close() {} });
  await connector.discover('https://nas.example.test:5001'); await connector.login('user', 'password', '');
  return { connector, calls, options };
}

test('query-filtered discovery exposes ordinary Drive links and notifications with the current authenticated session', async () => {
  const f = await fixture();
  assert.equal(f.connector.supportsDriveApi(p.DRIVE_SHARING_API, 1), true);
  assert.equal(f.connector.supportsDriveApi(p.DRIVE_NOTIFICATIONS_API, 1), true);
  const entry = { fileId: '900000000000000001', capabilities: { canRead: true, canShare: false } };
  assert.equal(p.decodeDriveFileLink(await f.connector.requestDrive(p.DRIVE_SHARING_API, 1, 'create_link', p.driveFileLinkFields(entry))),
    'https://drive.example.test/?file_id=900000000000000001');
  assert.deepEqual(p.decodeDriveNotifications(await f.connector.requestDrive(p.DRIVE_NOTIFICATIONS_API, 1, 'list', p.driveNotificationFields())),
    { items: [], total: 0 });
  assert.equal(f.calls.length, 4);
});

test('notification capability becomes available only after decoding a real response and records schema failures', async () => {
  const f = await fixture();
  const state = () => f.connector.capabilitySnapshots().find(row => row.feature === 'driveNotifications')?.state;
  assert.equal(state(), 'unverified');
  const read = () => f.connector.readDriveFeature('driveNotifications', async () => p.decodeDriveNotifications(
    await f.connector.requestDrive(p.DRIVE_NOTIFICATIONS_API, 1, 'list', p.driveNotificationFields())));
  await read(); assert.equal(state(), 'available');
  f.options.notifications = { items: 'unexpected', total: 0 };
  await assert.rejects(read(), error => error instanceof NasFailure && error.kind === NasErrorKind.Protocol);
  assert.equal(state(), 'schemaMismatch');
});
