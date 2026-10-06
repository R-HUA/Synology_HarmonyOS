const { test } = require('node:test');
const assert = require('node:assert/strict');
const p = require('../../work/core-build/domain/DriveActionProtocol.js');
const state = require('../../work/core-build/domain/DriveActionState.js');
const { DriveActionAdapter } = require('../../work/core-build/network/DriveActionAdapter.js');
const { NasConnector } = require('../../work/core-build/network/NasConnector.js');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');
const entry = over => ({ fileId: '900000000000000001', parentId: '900000000000000002', name: 'a.txt', kind: 'file', revisionCount: 2,
  capabilities: { canRead: true, canRename: true, canDelete: true }, ...over });
const folder = over => entry({ fileId: '900000000000000003', parentId: undefined, name: '目标', kind: 'folder',
  capabilities: { canRead: true, canWrite: true }, ...over });
const named = fields => Object.fromEntries(fields.map(f => [f.name, f.content]));
const isKind = kind => error => error instanceof NasFailure && error.kind === kind;

async function discoveredActions(overrides = {}, preflightData = { result: [] }) {
  const capabilities = {
    'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 6 },
    'SYNO.SynologyDrive.Files': { path: 'entry.cgi', minVersion: 1, maxVersion: 10 },
    'SYNO.SynologyDrive.Tasks': { path: 'entry.cgi', minVersion: 1, maxVersion: 1 },
    ...overrides,
  };
  const calls = [];
  const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });
  const connector = new NasConnector({
    async post(address, body, session) {
      const fields = Object.fromEntries(new URLSearchParams(body));
      calls.push({ address, fields, session });
      if (fields.api === 'SYNO.API.Info') {
        const requested = fields.query.split(',');
        // 像真实 API.Info 一样只回答请求过的名字，不让全量 mock 掩盖发现遗漏。
        return ok(Object.fromEntries(Object.entries(capabilities).filter(([api, value]) => value && requested.includes(api))));
      }
      if (fields.api === 'SYNO.API.Auth' && fields.method === 'login') {
        return ok({ sid: 'SYNTHETIC-SID', synotoken: 'SYNTHETIC-TOKEN' });
      }
      if (fields.api === 'SYNO.SynologyDrive.Files') {
        assert.ok(['move', 'copy'].includes(fields.method));
        assert.equal(fields.version, '2');
        assert.equal(fields.dry_run, 'true');
        assert.equal(fields.conflict_action, undefined);
        return ok(preflightData);
      }
      assert.equal(fields.api, 'SYNO.SynologyDrive.Tasks');
      assert.equal(fields.method, 'get');
      return ok({ task_id: JSON.parse(fields.task_id), status: 'finished', progress: 100, result: { errors: [], skips: [] } });
    },
    close() {},
  });
  await connector.discover('https://nas.example.test:5001');
  return { connector, adapter: new DriveActionAdapter(connector), calls };
}

test('Drive actions become available through query-filtered discovery of Files and Tasks', async () => {
  const f = await discoveredActions();
  assert.equal(f.adapter.available(), true);
  assert.ok(f.calls[0].fields.query.split(',').includes('SYNO.SynologyDrive.Tasks'));
  assert.equal(f.calls[0].session, undefined);
  assert.equal(f.calls.length, 1);
});

test('discovered Drive task status uses the verified version and current login session', async () => {
  const f = await discoveredActions();
  await f.connector.login('synthetic-user', 'synthetic-password', '');
  assert.equal((await f.adapter.status('task-1')).state, 'completed');
  const call = f.calls.at(-1);
  assert.equal(call.address, 'https://nas.example.test:5001/webapi/entry.cgi');
  assert.deepEqual(call.fields, { api: 'SYNO.SynologyDrive.Tasks', version: '1', method: 'get', task_id: '"task-1"' });
  assert.deepEqual(call.session, { sid: 'SYNTHETIC-SID', synoToken: 'SYNTHETIC-TOKEN' });
  assert.equal(f.calls.length, 3);
});

test('move and copy accept empty preflight forms through authenticated NAS decoding without submitting a write', async () => {
  for (const action of ['move', 'copy']) {
    for (const result of [null, {}, [], [{ name: 'a.txt' }]]) {
      const f = await discoveredActions({}, { result });
      await f.connector.login('synthetic-user', 'synthetic-password', '');
      assert.equal(await f.adapter.preflight({ action, entry: entry(), target: folder() }), Array.isArray(result) ? result.length : 0);
      const call = f.calls.at(-1);
      assert.equal(call.fields.method, action);
      assert.equal(call.fields.files, '["id:900000000000000001"]');
      assert.equal(call.fields.to_parent_folder, '"id:900000000000000003"');
      assert.deepEqual(call.session, { sid: 'SYNTHETIC-SID', synoToken: 'SYNTHETIC-TOKEN' });
      assert.equal(f.calls.length, 3);
    }
  }
});

test('preflight rejects missing, malformed, oversized and task responses rather than assuming no conflicts', async () => {
  for (const data of [{}, { async_task_id: 'task-4' }, { result: null, async_task_id: 'task-4' }, { result: '[]' }, { result: false }, { result: 0 },
    { result: { errors: [] } }, { result: { length: 0 } }, { result: Array(1001).fill({}) }]) {
    assert.throws(() => p.decodeDrivePreflight(data), isKind(K.Protocol));
  }
  const f = await discoveredActions({}, { async_task_id: 'task-4' });
  await f.connector.login('synthetic-user', 'synthetic-password', '');
  await assert.rejects(f.adapter.preflight({ action: 'copy', entry: entry(), target: folder() }), isKind(K.Protocol));
  assert.equal(f.calls.length, 3);
});

test('Drive actions stay unavailable when either discovered API is missing or incompatible', async () => {
  for (const overrides of [
    { 'SYNO.SynologyDrive.Tasks': undefined },
    { 'SYNO.SynologyDrive.Tasks': { path: 'entry.cgi', minVersion: 2, maxVersion: 3 } },
    { 'SYNO.SynologyDrive.Files': undefined },
    { 'SYNO.SynologyDrive.Files': { path: 'entry.cgi', minVersion: 3, maxVersion: 10 } },
  ]) {
    const f = await discoveredActions(overrides);
    assert.equal(f.adapter.available(), false);
    assert.equal(f.calls.length, 1);
  }
});

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
