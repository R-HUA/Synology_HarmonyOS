const { test } = require('node:test');
const assert = require('node:assert/strict');
const p = require('../../work/core-build/domain/DriveCollaborationProtocol.js');
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const fixture = require('../fixtures/drive-collaboration-contract.json');
const clone = value => JSON.parse(JSON.stringify(value));
const entry = () => ({ fileId: '900000000000000001', name: '资料.txt', kind: 'file', capabilities: { canRead: true, canShare: false } });
const record = () => ({ id: '11111111-1111-4111-8111-111111111111', nasOrigin: 'https://nas.test', account: 'alice',
  fileId: entry().fileId, name: entry().name, createdAt: 1760000000000, state: 'unknown', url: undefined });
const snapshot = records => JSON.stringify({ version: 1, scope: 'scope-a', records });
const decodeRecords = records => p.decodeDriveLinks(snapshot(records), 'scope-a', 'https://nas.test', 'alice');
const protocolFailure = error => error instanceof dsm.NasFailure && error.kind === dsm.NasErrorKind.Protocol;

test('ordinary Drive file link only sends JSON id path and does not mutate sharing permissions', () => {
  assert.equal(p.driveFileLinkAllowed(entry()), true);
  assert.deepEqual(p.driveFileLinkFields(entry()), [{ name: 'path', content: '"id:900000000000000001"' }]);
  assert.throws(() => p.driveFileLinkFields({ ...entry(), capabilities: { canRead: false, canShare: true } }), /没有权限/);
  assert.equal(p.decodeDriveFileLink(fixture.fileLink), fixture.fileLink.url);
  for (const data of [{}, { items: [{ id: 1 }] }, { url: '' }, { url: 'javascript:alert(1)' }]) {
    assert.throws(() => p.decodeDriveFileLink(data), protocolFailure);
  }
});

test('generated URLs may use NAS custom domains but cannot leak login credentials or unsafe characters', () => {
  for (const url of ['http://nas.test:5000/file/abc', fixture.fileLink.url, 'https://[::1]:5001/file/abc']) {
    assert.equal(p.validateDriveFileLink(url), url);
  }
  for (const url of ['https://user:pass@nas.test/file/1', 'https://nas.test/?_sid=secret', 'https://nas.test/#SyNoToken=secret',
    'https://nas.test/?%74oken=secret', 'https://nas.test/?%2574oken=secret', 'https://nas.test/%0Aabc',
    'https://nas.test/%5cabc', 'https://nas.test\\evil.test/file/1', 'https://nas.test/%ZZ', 'file:///private/file']) {
    assert.throws(() => p.validateDriveFileLink(url), protocolFailure, url);
  }
});

test('private history rejects wrong NAS/account/scope, duplicates, malformed state and credential URLs', () => {
  assert.deepEqual(decodeRecords([record()]), [record()]);
  const completed = { ...record(), state: 'completed', url: fixture.fileLink.url };
  assert.deepEqual(decodeRecords([completed]), [completed]);
  for (const changed of [{ nasOrigin: 'https://other.test' }, { account: 'bob' }, { fileId: 'unsafe/1' }, { createdAt: -1 },
    { state: 'completed' }, { state: 'unknown', url: fixture.fileLink.url }, { state: 'completed', url: 'https://nas.test/?sid=x' }, { state: 'active' }]) {
    assert.throws(() => decodeRecords([{ ...record(), ...changed }]));
  }
  assert.throws(() => decodeRecords([record(), record()]), protocolFailure);
  assert.throws(() => p.decodeDriveLinks(snapshot([record()]), 'other-scope', 'https://nas.test', 'alice'), protocolFailure);
  assert.throws(() => p.decodeDriveLinks('invalid', 'scope-a', 'https://nas.test', 'alice'), protocolFailure);
});

test('notification list uses web limit and preserves explicit empty response; schema drift is not empty', () => {
  assert.deepEqual(p.driveNotificationFields(), [{ name: 'limit', content: '100' }]);
  assert.deepEqual(p.decodeDriveNotifications(fixture.notificationsEmpty), { items: [], total: 0 });
  for (const data of [{}, { items: [], total: '0' }, { items: {}, total: 0 }, { items: [{}], total: 1 }]) {
    assert.throws(() => p.decodeDriveNotifications(data));
  }
  const parsed = p.decodeDriveNotifications(fixture.notifications);
  assert.equal(parsed.items[0].title, '收到文件夹共享');
  assert.equal(parsed.items[0].name, '共享资料');
  assert.equal(parsed.items[0].senderName, '示例同事');
  assert.equal(parsed.items[0].time, 1760000000);
  assert.equal(parsed.items[1].title, '收到评论回复');
  assert.equal(parsed.items[2].title, '上传任务已完成');
  assert.equal(parsed.items[2].name, '示例照片.jpg、示例笔记.txt');
  assert.equal(parsed.items[2].id, '3');
  assert.equal(parsed.items[3].known, false);
  assert.equal(parsed.items[3].title, '收到 Drive 通知');
  assert.equal(JSON.stringify(parsed).includes('must not display'), false);
});

test('notification known types have formal messages and unknown metadata never supplies invented actors or file types', () => {
  const types = ['create', 'share_with_me', 'request', 'change_owner', 'comment', 'comment_reply', 'mention', 'upload_task', 'background_task', 'request_office_template'];
  for (const type of types) {
    const notification = p.decodeDriveNotifications({ total: 1, items: [{ notification_id: 'n', time: 1, type: 'drive#' + type }] }).items[0];
    assert.equal(notification.known, true);
    assert.equal(notification.name, ''); assert.equal(notification.senderName, '');
    assert.equal(notification.title.includes('notification:'), false);
  }
  assert.equal(p.decodeDriveNotifications({ total: 1, items: [{ notification_id: 'n', time: 1, type: 'drive#create' }] }).items[0].title, '新建项目');
});

test('notification malformed ids, timestamps, totals, sender/content and task names fail before publishing', () => {
  for (const patch of [{ notification_id: '' }, { notification_id: Number.MAX_SAFE_INTEGER + 1 }, { time: -1 },
    { time: '1760000000' }, { type: '' }, { sender: { display_name: 42 } }, { content: [] },
    { content: { name: 1 } }]) {
    const data = clone(fixture.notifications); data.items[0] = { ...data.items[0], ...patch };
    assert.throws(() => p.decodeDriveNotifications(data));
  }
  const duplicate = clone(fixture.notifications); duplicate.items[1].notification_id = duplicate.items[0].notification_id;
  assert.throws(() => p.decodeDriveNotifications(duplicate), protocolFailure);
  assert.throws(() => p.decodeDriveNotifications({ ...fixture.notifications, total: 1 }), protocolFailure);
  const badTask = clone(fixture.notifications); badTask.items[2].content.names = [42];
  assert.throws(() => p.decodeDriveNotifications(badTask), protocolFailure);
  const overflow = { total: 101, items: Array.from({ length: 101 }, (_, i) => ({ notification_id: String(i), time: 1, type: 'x' })) };
  assert.throws(() => p.decodeDriveNotifications(overflow), protocolFailure);
});
