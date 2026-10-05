const { test } = require('node:test');
const assert = require('node:assert/strict');
const p = require('../../work/core-build/domain/DriveActionProtocol.js');
const state = require('../../work/core-build/domain/DriveActionState.js');
const { DriveActionAdapter } = require('../../work/core-build/network/DriveActionAdapter.js');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');
const entry = over => ({ fileId: '900000000000000001', parentId: '900000000000000002', name: 'a.txt', kind: 'file', revisionCount: 2,
  capabilities: { canRead: true, canRename: true, canDelete: true }, ...over });
const folder = over => entry({ fileId: '900000000000000003', parentId: undefined, name: '目标', kind: 'folder',
  capabilities: { canRead: true, canWrite: true }, ...over });
const named = fields => Object.fromEntries(fields.map(f => [f.name, f.content]));
const isKind = kind => error => error instanceof NasFailure && error.kind === kind;

test('Drive operation encoding uses real IDs and JSON parameters; delete remains non-permanent', () => {
  assert.deepEqual(named(p.driveActionFields({ action: 'rename', entry: entry(), name: ' 新名称.txt ' })),
    { path: '"id:900000000000000001"', name: '"新名称.txt"' });
  assert.deepEqual(named(p.driveActionFields({ action: 'delete', entry: entry() })),
    { files: '["id:900000000000000001"]', permanent: 'false', revisions: '2' });
  const input = { action: 'move', entry: entry(), target: folder() };
  const preview = named(p.driveActionFields(input, true));
  assert.equal(preview.dry_run, 'true'); assert.equal(preview.conflict_action, undefined);
  const send = named(p.driveActionFields(input));
  assert.equal(send.dry_run, undefined); assert.equal(send.conflict_action, '"autorename"');
  assert.equal(send.to_parent_folder, '"id:900000000000000003"');
  assert.equal(send.to_parent_folder_name, '"目标"');
  assert.equal(JSON.stringify(send).includes('FileStation'), false);
});

test('rename and target validation reject unsafe names, denied permissions and self/invalid destinations', () => {
  for (const name of ['', ' .. ', '.', 'a/b', 'a\\b', 'a\u0000b', 'a'.repeat(256), 'a.txt']) {
    assert.throws(() => p.driveActionFields({ action: 'rename', entry: entry(), name }), isKind(K.InvalidInput));
  }
  assert.throws(() => p.driveActionFields({ action: 'move', entry: entry({ capabilities: { canRead: true } }), target: folder() }), isKind(K.Permission));
  assert.equal(p.driveActionAllowed(entry({ capabilities: { canRead: true } }), 'copy'), true);
  for (const target of [undefined, folder({ fileId: entry().fileId }), folder({ capabilities: { canRead: true } }),
    folder({ kind: 'file' }), folder({ fileId: entry().parentId })]) {
    assert.throws(() => p.driveActionFields({ action: 'move', entry: entry(), target }), isKind(K.InvalidInput));
  }
  assert.doesNotThrow(() => p.driveActionFields({ action: 'copy', entry: entry(), target: folder({ fileId: entry().parentId }) }));
});

test('only a matching renamed entry or valid async task is accepted as a write result', () => {
  const input = { action: 'rename', entry: entry(), name: '新名称' };
  assert.equal(p.decodeDriveActionStart({ file_id: entry().fileId, name: '新名称', type: 'file' }, input), undefined);
  for (const data of [{}, { file_id: '2', name: '新名称', type: 'file' }, { file_id: entry().fileId, name: '旧名称', type: 'file' }]) {
    assert.throws(() => p.decodeDriveActionStart(data, input), isKind(K.Protocol));
  }
  assert.equal(p.decodeDriveActionStart({ async_task_id: 'task-4' }, { action: 'copy' }), 'task-4');
  for (const task of ['', '../task', 'https://other.test', 1]) {
    assert.throws(() => p.decodeDriveActionStart({ async_task_id: task }, { action: 'copy' }), isKind(K.Protocol));
  }
});

test('task HTTP success is not completion; finished errors, skipped work and unknown status stay truthful', () => {
  const status = over => ({ task_id: 'task-1', status: 'finished', progress: 100, result: { errors: [], skips: [] }, ...over });
  assert.equal(p.decodeDriveActionStatus(status(), 'task-1').state, 'completed');
  assert.equal(p.decodeDriveActionStatus(status({ result: { errors: [{}] } }), 'task-1').state, 'failed');
  assert.equal(p.decodeDriveActionStatus(status({ result: { skips: [{}] } }), 'task-1').state, 'partial');
  for (const raw of ['processing', 'new-value', 3]) {
    assert.equal(p.decodeDriveActionStatus(status({ status: raw }), 'task-1').state, 'accepted');
  }
  assert.equal(p.decodeDriveActionStatus(status({ status: 'processing', result: undefined }), 'task-1').state, 'accepted');
  assert.throws(() => p.decodeDriveActionStatus(status({ result: undefined }), 'task-1'), isKind(K.Protocol));
  for (const over of [{ task_id: 'other' }, { status: {} }, { progress: 101 }, { result: { errors: {} } }]) {
    assert.throws(() => p.decodeDriveActionStatus(status(over), 'task-1'), isKind(K.Protocol));
  }
});

test('folder preflight rejects a destination inside its own subtree before sending the dry run', async () => {
  const calls = [];
  const source = entry({ kind: 'folder' }), target = folder({ parentId: source.fileId });
  const kernel = { supportsDriveApi: () => true, readDriveFeature: (_, fn) => fn(), async requestDrive(api, version, method, fields) {
    calls.push(method);
    if (method === 'list_ancestor') return { total: 1, items: [{ file_id: source.fileId, name: source.name, type: 'dir' }] };
    return { result: [] };
  } };
  await assert.rejects(new DriveActionAdapter(kernel).preflight({ action: 'copy', entry: source, target }), isKind(K.InvalidInput));
  assert.deepEqual(calls, ['list_ancestor']);
  assert.throws(() => p.decodeDrivePreflight({}), isKind(K.Protocol));
  assert.equal(p.decodeDrivePreflight({ result: [{}] }), 1);
});

test('missing revisions remain unknown and prohibit deletion rather than becoming zero', () => {
  const { decodeDriveEntry, decodeDriveTeamFolder } = require('../../work/core-build/domain/DriveProtocol.js');
  const raw = { file_id: entry().fileId, name: 'a.txt', type: 'file', capabilities: { can_read: true, can_delete: true } };
  assert.equal(decodeDriveEntry(raw).revisionCount, undefined);
  assert.equal(decodeDriveTeamFolder(raw).revisionCount, undefined);
  assert.throws(() => p.driveActionFields({ action: 'delete', entry: decodeDriveEntry(raw) }), isKind(K.InvalidInput));
  assert.equal(p.driveActionFields({ action: 'delete', entry: decodeDriveEntry({ ...raw, revisions: 0 }) }).at(-1).content, '0');
});

test('durable action records reject another account, duplicate records and unqueryable accepted work', () => {
  const record = { id: '11111111-1111-4111-8111-111111111111', action: 'copy',
    resource: { nasOrigin: 'https://nas.test', account: 'alice', fileId: entry().fileId }, name: 'a.txt', destination: '目标',
    state: 'accepted', taskId: 'task-1', errorText: '' };
  const read = records => state.decodeDriveActions(JSON.stringify({ version: 1, scope: 'scope', records }), 'scope', 'https://nas.test', 'alice');
  assert.equal(read([record])[0].taskId, 'task-1');
  for (const records of [[record, record], [{ ...record, resource: { ...record.resource, account: 'bob' } }],
    [{ ...record, taskId: undefined }], [{ ...record, state: 'completed', taskId: undefined }]]) {
    assert.throws(() => read(records), isKind(K.Protocol));
  }
});
