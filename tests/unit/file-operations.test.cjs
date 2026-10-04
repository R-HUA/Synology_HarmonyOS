const { test } = require('node:test');
const assert = require('node:assert/strict');
const { NasConnector, NAS_DISCOVERY_QUERY } = require('../../work/core-build/network/NasConnector.js');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');
const { NasFileSortBy: Sort, NasFileSortDirection: Direction, NasFileTaskKind: Task,
  NasFileTaskUnit: Unit } = require('../../work/core-build/domain/FileOperations.js');

const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });
const fail = code => ({ status: 200, text: JSON.stringify({ success: false, error: { code } }) });
const isKind = kind => error => error instanceof NasFailure && error.kind === kind;
const descriptor = (version, json = true) => ({ path: 'entry.cgi', minVersion: 1,
  maxVersion: version, ...(json ? { requestFormat: 'JSON' } : {}) });
const row = (path, isdir = false) => ({ path, name: path.slice(path.lastIndexOf('/') + 1), isdir });

class FakeTransport {
  calls = [];
  replies = [];
  async post(address, body, session) {
    this.calls.push({ address, body: new URLSearchParams(body), session });
    assert.ok(this.replies.length, 'unexpected network request');
    const reply = this.replies.shift();
    return typeof reply === 'function' ? reply() : reply;
  }
  close() {}
}

async function connected({ json = true, login = true, alter = () => {} } = {}) {
  const capabilities = {
    'SYNO.API.Auth': descriptor(7, false), 'SYNO.FileStation.List': descriptor(2, json),
    'SYNO.FileStation.CreateFolder': descriptor(4, json), 'SYNO.FileStation.Rename': descriptor(3, json),
    'SYNO.FileStation.Delete': descriptor(4, json), 'SYNO.FileStation.CopyMove': descriptor(5, json)
  };
  alter(capabilities);
  const transport = new FakeTransport();
  transport.replies.push(ok(capabilities));
  const connector = new NasConnector(transport);
  await connector.discover('https://nas.example.test:5001');
  if (login) connector.restoreSession([{ name: 'FileStation', sid: 'test-sid', synoToken: 'test-token' }]);
  return { connector, transport };
}

test('discovery requests optional operations and reports only intersecting verified versions', async () => {
  const { connector, transport } = await connected({ alter: capabilities => {
    capabilities['SYNO.FileStation.CreateFolder'].minVersion = 3;
    capabilities['SYNO.FileStation.Rename'].maxVersion = 1;
    delete capabilities['SYNO.FileStation.Delete'];
  } });
  for (const name of ['CreateFolder', 'Rename', 'Delete', 'CopyMove']) {
    assert.ok(NAS_DISCOVERY_QUERY.split(',').includes('SYNO.FileStation.' + name));
  }
  assert.deepEqual(connector.fileOperationCapabilities(), {
    createFolder: false, renameFile: false, deleteFiles: false, copyFiles: true, moveFiles: true
  });
  const count = transport.calls.length;
  await assert.rejects(connector.createFolder('/Share', 'folder'), isKind(K.Unsupported));
  await assert.rejects(connector.renameFile('/Share/a', 'b'), isKind(K.Unsupported));
  await assert.rejects(connector.deleteFiles(['/Share/a']), isKind(K.Unsupported));
  assert.equal(transport.calls.length, count);
});

test('create and rename send version 2 arrays, preserve special characters and validate target identities', async () => {
  const { connector, transport } = await connected();
  const directory = '/共享/中文 " , &+\\目录';
  const name = '新建 " , &+\\名字';
  const renamed = '改名 " , &+\\名字';
  transport.replies.push(ok({ folders: [row(directory + '/' + name, true)] }),
    ok({ files: [row(directory + '/' + renamed, true)] }));
  assert.equal((await connector.createFolder(directory, name)).path, directory + '/' + name);
  const create = transport.calls.at(-1);
  assert.equal(create.body.get('api'), 'SYNO.FileStation.CreateFolder');
  assert.equal(create.body.get('method'), 'create');
  assert.equal(create.body.get('version'), '2');
  assert.deepEqual(JSON.parse(create.body.get('folder_path')), [directory]);
  assert.deepEqual(JSON.parse(create.body.get('name')), [name]);
  assert.equal(create.body.get('force_parent'), 'false');
  assert.equal((await connector.renameFile(directory + '/' + name, renamed)).name, renamed);
  const rename = transport.calls.at(-1);
  assert.equal(rename.body.get('api'), 'SYNO.FileStation.Rename');
  assert.equal(rename.body.get('method'), 'rename');
  assert.equal(rename.body.get('version'), '2');
  assert.deepEqual(JSON.parse(rename.body.get('path')), [directory + '/' + name]);
  assert.deepEqual(JSON.parse(rename.body.get('name')), [renamed]);
  for (const call of [create, rename]) {
    assert.equal(call.address, 'https://nas.example.test:5001/webapi/entry.cgi');
    assert.deepEqual(call.session, { sid: 'test-sid', synoToken: 'test-token' });
    assert.equal(call.body.has('_sid'), false);
    assert.equal(call.body.has('SynoToken'), false);
    assert.equal(call.address.includes('test-sid'), false);
  }
});

test('creation and rename reject missing, ambiguous or mismatched success responses', async () => {
  const { connector, transport } = await connected();
  for (const folders of [undefined, [], [row('/Share/a', true), row('/Share/a', true)],
    [row('/Share/other', true)], [row('/Share/a', false)],
    [{ ...row('/Share/a', true), isdir: 'true' }], [{ ...row('/Share/a', true), name: 'other' }],
    [{ ...row('/Share/a', true), additional: { size: -1 } }]]) {
    transport.replies.push(ok({ folders }));
    await assert.rejects(connector.createFolder('/Share', 'a'), isKind(K.Protocol));
  }
  for (const files of [undefined, [], [row('/Share/wrong')],
    [{ ...row('/Share/b'), isdir: 0 }], [{ ...row('/Share/b'), name: 'wrong' }]]) {
    transport.replies.push(ok({ files }));
    await assert.rejects(connector.renameFile('/Share/a', 'b'), isKind(K.Protocol));
  }
});

test('top-level and per-file errors remain failures even when an operation envelope says success', async () => {
  const { connector, transport } = await connected();
  transport.replies.push(fail(1100), ok({ folders: [{ ...row('/Share/a', true), error: { code: 403 } }] }),
    ok({ files: [row('/Share/b')], errors: [{ code: 408, path: '/Share/a' }] }));
  await assert.rejects(connector.createFolder('/Share', 'a'), error => isKind(K.Server)(error) && error.code === 1100);
  await assert.rejects(connector.createFolder('/Share', 'a'), error => isKind(K.Permission)(error) && error.code === 403);
  await assert.rejects(connector.renameFile('/Share/a', 'b'), error => isKind(K.Server)(error) && error.code === 408);
});

test('single names, canonical paths and shared-folder boundaries are validated before writes', async () => {
  const { connector, transport } = await connected();
  const count = transport.calls.length;
  for (const name of ['', ' ', '.', '..', 'nested/name', 'a:b', 'a\u0000', 'a\n', 'a\u007f']) {
    await assert.rejects(connector.createFolder('/Share', name), isKind(K.InvalidInput));
    await assert.rejects(connector.renameFile('/Share/a', name), isKind(K.InvalidInput));
  }
  for (const path of ['/', 'Share/a', '/Share/../private', '/Share/./a', '/Share/a\u0000']) {
    await assert.rejects(connector.createFolder(path, 'a'), isKind(K.Protocol));
  }
  for (const path of ['/Share/', '/Share//a', '/Share/a\u007f']) {
    await assert.rejects(connector.createFolder(path, 'a'), isKind(K.InvalidInput));
  }
  await assert.rejects(connector.renameFile('/Share', 'other'), isKind(K.InvalidInput));
  await assert.rejects(connector.deleteFiles(['/Share']), isKind(K.InvalidInput));
  await assert.rejects(connector.moveFiles(['/Share'], '/Other'), isKind(K.InvalidInput));
  assert.equal(transport.calls.length, count);
});

test('selection validation rejects empty, duplicate and overlapping paths without sending a request', async () => {
  const { connector, transport } = await connected();
  const count = transport.calls.length;
  for (const paths of [[], ['/Share/a', '/Share/a'], ['/Share/a', '/Share/a/b'], ['/Share/a/b', '/Share/a']]) {
    await assert.rejects(connector.deleteFiles(paths), isKind(K.InvalidInput));
    await assert.rejects(connector.copyFiles(paths, '/Other'), isKind(K.InvalidInput));
  }
  for (const directory of ['/Share/folder', '/Share/folder/child']) {
    await assert.rejects(connector.copyFiles(['/Share/folder'], directory), isKind(K.InvalidInput));
    await assert.rejects(connector.moveFiles(['/Share/folder'], directory), isKind(K.InvalidInput));
  }
  assert.equal(transport.calls.length, count);
});

test('delete starts exactly once, exposes the task ID and only status reports completion', async () => {
  const { connector, transport } = await connected();
  const paths = ['/共享/a " , &+\\file', '/共享/b'];
  transport.replies.push(ok({ taskid: 'delete-task' }), ok({ finished: false, processed_num: 0, total: -1, progress: 0 }),
    ok({ finished: false, processed_num: 1, total: 2, progress: 0.5 }),
    ok({ finished: true, processed_num: 2, total: 2, progress: 1 }));
  const task = await connector.deleteFiles(paths);
  assert.deepEqual(task, { taskId: 'delete-task', kind: Task.Delete });
  const start = transport.calls.at(-1).body;
  assert.equal(start.get('version'), '2');
  assert.equal(start.get('method'), 'start');
  assert.deepEqual(JSON.parse(start.get('path')), paths);
  assert.equal(start.get('recursive'), 'true');
  assert.equal(start.get('accurate_progress'), 'true');
  const counting = await connector.fileTaskStatus(task);
  assert.equal(counting.finished, false);
  assert.equal(counting.total, undefined);
  assert.equal(counting.unit, Unit.Files);
  const progress = await connector.fileTaskStatus(task);
  assert.equal(progress.finished, false);
  assert.equal(progress.processed, 1);
  assert.equal(progress.progress, 0.5);
  const done = await connector.fileTaskStatus(task);
  assert.equal(done.finished, true);
  assert.equal(done.total, 2);
  assert.equal(done.taskId, task.taskId);
  const status = transport.calls.at(-1).body;
  assert.equal(status.get('api'), 'SYNO.FileStation.Delete');
  assert.equal(status.get('version'), '2');
  assert.equal(status.get('method'), 'status');
  assert.equal(JSON.parse(status.get('taskid')), task.taskId);
  assert.equal(transport.calls.filter(call => call.body.get('method') === 'start').length, 1);
});

test('a task start rejects empty, malformed or per-file failed task responses', async () => {
  const { connector, transport } = await connected();
  for (const data of [{}, { taskid: '' }, { taskid: 12 }, { taskid: ' \t' }, { taskid: 'bad\n' },
    { taskid: 'task', errors: {} }]) {
    transport.replies.push(ok(data));
    await assert.rejects(connector.deleteFiles(['/Share/a']), isKind(K.Protocol));
  }
  transport.replies.push(ok({ taskid: 'task', errors: [{ code: 403 }] }));
  await assert.rejects(connector.deleteFiles(['/Share/a']), isKind(K.Permission));
});

test('copy and move use version 3 without overwrite/skip and expose byte progress', async () => {
  const { connector, transport } = await connected();
  const directory = '/共享/目标 " , &+\\目录';
  transport.replies.push(ok({ taskid: 'copy-task' }), ok({ taskid: 'move-task' }),
    ok({ finished: false, processed_size: 64, total: 128, progress: 0.5 }),
    ok({ finished: true, processed_size: 128, total: 128, progress: 1 }));
  const copy = await connector.copyFiles(['/Share/a'], directory);
  assert.equal(copy.kind, Task.Copy);
  const copyCall = transport.calls.at(-1).body;
  const move = await connector.moveFiles(['/Share/a'], directory);
  assert.equal(move.kind, Task.Move);
  const moveCall = transport.calls.at(-1).body;
  for (const call of [copyCall, moveCall]) {
    assert.equal(call.get('api'), 'SYNO.FileStation.CopyMove');
    assert.equal(call.get('version'), '3');
    assert.equal(call.get('method'), 'start');
    assert.deepEqual(JSON.parse(call.get('path')), ['/Share/a']);
    assert.equal(JSON.parse(call.get('dest_folder_path')), directory);
    assert.equal(call.has('overwrite'), false);
    assert.equal(call.get('accurate_progress'), 'true');
  }
  assert.equal(copyCall.get('remove_src'), 'false');
  assert.equal(moveCall.get('remove_src'), 'true');
  assert.equal((await connector.fileTaskStatus(copy)).unit, Unit.Bytes);
  const done = await connector.fileTaskStatus(move);
  assert.equal(done.finished, true);
  assert.equal(done.processed, 128);
  assert.equal(transport.calls.at(-1).body.get('version'), '3');
});

test('copy conflict and task-status errors are surfaced without retrying a mutation', async () => {
  const { connector, transport } = await connected();
  transport.replies.push(fail(1003), fail(900), ok({ finished: true, errors: [{ code: 403 }] }));
  await assert.rejects(connector.copyFiles(['/Share/a'], '/Other'), error => isKind(K.Server)(error) && error.code === 1003);
  await assert.rejects(connector.fileTaskStatus({ taskId: 'delete-task', kind: Task.Delete }),
    error => isKind(K.Server)(error) && error.code === 900);
  await assert.rejects(connector.fileTaskStatus({ taskId: 'delete-task', kind: Task.Delete }), isKind(K.Permission));
  assert.equal(transport.calls.filter(call => call.body.get('method') === 'start').length, 1);
});

test('official aggregate error.errors failure envelopes cannot become success or completed tasks', async () => {
  const { connector, transport } = await connected();
  for (const [code, run] of [
    [1100, () => connector.createFolder('/Share', 'folder')],
    [1200, () => connector.renameFile('/Share/a', 'b')],
    [900, () => connector.fileTaskStatus({ taskId: 'delete-task', kind: Task.Delete })],
    [1000, () => connector.fileTaskStatus({ taskId: 'copy-task', kind: Task.Copy })],
    [1001, () => connector.fileTaskStatus({ taskId: 'move-task', kind: Task.Move })]
  ]) {
    transport.replies.push({ status: 200, text: JSON.stringify({ success: false,
      error: { code, errors: [{ code: 407, path: '/Share/protected' }, { code: 408, path: '/Share/missing' }] },
      data: { finished: true, processed_num: 1, total: 2, progress: 1,
        folders: [row('/Share/folder', true)], files: [row('/Share/b')] } }) });
    await assert.rejects(run(), error => isKind(K.Server)(error) && error.code === code);
  }
  assert.equal(transport.calls.length, 6, 'each operation is sent once, with no automatic replay');
});

test('status response remains bound to the requested task when the caller later changes its handle', async () => {
  const { connector, transport } = await connected();
  let finish;
  transport.replies.push(() => new Promise(resolve => { finish = resolve; }));
  const task = { taskId: 'delete-task', kind: Task.Delete };
  const pending = connector.fileTaskStatus(task);
  task.taskId = 'other-task';
  task.kind = Task.Copy;
  finish(ok({ finished: true, processed_num: 1, total: 1, progress: 1 }));
  const result = await pending;
  assert.equal(result.taskId, 'delete-task');
  assert.equal(result.kind, Task.Delete);
  assert.equal(result.unit, Unit.Files);
  assert.equal(result.processed, 1);
});

test('status trusts only an explicit finished flag and accepts absent metrics without inventing totals', async () => {
  const { connector, transport } = await connected();
  const task = { taskId: 'task', kind: Task.Delete };
  transport.replies.push(ok({ finished: false, progress: 1 }), ok({ finished: true }));
  assert.equal((await connector.fileTaskStatus(task)).finished, false);
  const done = await connector.fileTaskStatus(task);
  assert.equal(done.finished, true);
  assert.equal(done.progress, undefined);
  assert.equal(done.processed, undefined);
  assert.equal(done.total, undefined);
  for (const data of [{}, { finished: 'true' }, { finished: false, progress: -1 },
    { finished: false, progress: 1.01 }, { finished: false, progress: '0.5' },
    { finished: false, total: -2 }, { finished: false, total: 1.5 },
    { finished: false, processed_num: -1 }, { finished: false, processed_num: '1' },
    { finished: true, total: 1, processed_num: 2 }]) {
    transport.replies.push(ok(data));
    await assert.rejects(connector.fileTaskStatus(task), isKind(K.Protocol));
  }
});

test('stop uses the correct API version, accepts an empty success and preserves failures', async () => {
  const { connector, transport } = await connected();
  for (const [kind, api, version] of [[Task.Delete, 'Delete', '2'], [Task.Copy, 'CopyMove', '3'], [Task.Move, 'CopyMove', '3']]) {
    transport.replies.push(ok(undefined));
    await connector.stopFileTask({ taskId: 'task', kind });
    const call = transport.calls.at(-1).body;
    assert.equal(call.get('api'), 'SYNO.FileStation.' + api);
    assert.equal(call.get('version'), version);
    assert.equal(call.get('method'), 'stop');
    assert.equal(JSON.parse(call.get('taskid')), 'task');
  }
  transport.replies.push(fail(105));
  await assert.rejects(connector.stopFileTask({ taskId: 'task', kind: Task.Delete }), isKind(K.Permission));
});

test('invalid task handles are rejected before status or stop requests', async () => {
  const { connector, transport } = await connected();
  const count = transport.calls.length;
  for (const task of [{ taskId: '', kind: Task.Delete }, { taskId: ' \t', kind: Task.Copy },
    { taskId: 'a\n', kind: Task.Move }, { taskId: 'task', kind: 999 }]) {
    await assert.rejects(connector.fileTaskStatus(task), isKind(K.InvalidInput));
    await assert.rejects(connector.stopFileTask(task), isKind(K.InvalidInput));
  }
  assert.equal(transport.calls.length, count);
});

test('non-JSON capability format keeps array contracts and uses plain scalar destinations and task IDs', async () => {
  const { connector, transport } = await connected({ json: false });
  transport.replies.push(ok({ folders: [row('/Share/a', true)] }), ok({ files: [row('/Share/b')] }),
    ok({ taskid: 'task " , &+\\id' }), ok({ finished: false }), ok(undefined));
  await connector.createFolder('/Share', 'a');
  assert.deepEqual(JSON.parse(transport.calls.at(-1).body.get('folder_path')), ['/Share']);
  await connector.renameFile('/Share/a', 'b');
  assert.deepEqual(JSON.parse(transport.calls.at(-1).body.get('name')), ['b']);
  const task = await connector.copyFiles(['/Share/b'], '/Other/中文 " , &+\\目录');
  assert.equal(transport.calls.at(-1).body.get('dest_folder_path'), '/Other/中文 " , &+\\目录');
  await connector.fileTaskStatus(task);
  assert.equal(transport.calls.at(-1).body.get('taskid'), task.taskId);
  await connector.stopFileTask(task);
  assert.equal(transport.calls.at(-1).body.get('taskid'), task.taskId);
});

test('list requests server sorting for every page and keeps existing name/ascending defaults', async () => {
  const { connector, transport } = await connected();
  transport.replies.push(ok({ files: [], offset: 100, total: 100 }), ok({ files: [], offset: 0, total: 0 }),
    ok({ shares: [], offset: 0, total: 0 }));
  await connector.list('/Share', 100, Sort.Size, Direction.Descending);
  let call = transport.calls.at(-1).body;
  assert.equal(JSON.parse(call.get('sort_by')), 'size');
  assert.equal(JSON.parse(call.get('sort_direction')), 'desc');
  assert.equal(call.get('offset'), '100');
  assert.equal(call.get('limit'), '100');
  await connector.list('/Share');
  call = transport.calls.at(-1).body;
  assert.equal(JSON.parse(call.get('sort_by')), 'name');
  assert.equal(JSON.parse(call.get('sort_direction')), 'asc');
  await connector.list('', 0, Sort.ModifiedTime, Direction.Descending);
  assert.equal(transport.calls.at(-1).body.get('method'), 'list_share');
  const count = transport.calls.length;
  for (const args of [['/Share', 0, 'unknown'], ['/Share', 0, Sort.Name, 'unknown'],
    ['', 0, Sort.Size], ['', 0, Sort.Type], ['/Share', Number.MAX_SAFE_INTEGER]]) {
    await assert.rejects(connector.list(...args), isKind(K.InvalidInput));
  }
  assert.equal(transport.calls.length, count);
});

test('plain scalar sorting is sent without JSON quotes when advertised format is not JSON', async () => {
  const { connector, transport } = await connected({ json: false });
  transport.replies.push(ok({ files: [], offset: 0, total: 0 }));
  await connector.list('/Share', 0, Sort.Type, Direction.Descending);
  assert.equal(transport.calls.at(-1).body.get('sort_by'), 'type');
  assert.equal(transport.calls.at(-1).body.get('sort_direction'), 'desc');
});

test('every write and task query requires a session; expiry invalidates later calls without replay', async () => {
  const { connector, transport } = await connected({ login: false });
  const task = { taskId: 'task', kind: Task.Delete };
  const methods = [() => connector.createFolder('/Share', 'a'), () => connector.renameFile('/Share/a', 'b'),
    () => connector.deleteFiles(['/Share/a']), () => connector.copyFiles(['/Share/a'], '/Other'),
    () => connector.moveFiles(['/Share/a'], '/Other'), () => connector.fileTaskStatus(task), () => connector.stopFileTask(task)];
  for (const call of methods) await assert.rejects(call(), isKind(K.SessionExpired));
  assert.equal(transport.calls.length, 1);
  connector.restoreSession([{ name: 'FileStation', sid: 'sid', synoToken: '' }]);
  transport.replies.push(fail(119));
  await assert.rejects(connector.deleteFiles(['/Share/a']), isKind(K.SessionExpired));
  for (const call of methods) await assert.rejects(call(), isKind(K.SessionExpired));
  assert.equal(transport.calls.length, 2);
});

test('HTTP or network failure leaves a mutation result unconfirmed and never retries automatically', async () => {
  const { connector, transport } = await connected();
  transport.replies.push({ status: 503, text: '<html>unavailable</html>' },
    () => { throw new NasFailure(K.Network, '网络连接失败。'); });
  await assert.rejects(connector.createFolder('/Share', 'a'), isKind(K.Http));
  await assert.rejects(connector.deleteFiles(['/Share/a']), isKind(K.Network));
  assert.equal(transport.calls.length, 3);
});

test('late mutation and status responses cannot report success after the connection closes', async () => {
  for (const run of [connector => connector.createFolder('/Share', 'a'),
    connector => connector.deleteFiles(['/Share/a']),
    connector => connector.fileTaskStatus({ taskId: 'task', kind: Task.Delete })]) {
    const { connector, transport } = await connected();
    let finish;
    transport.replies.push(() => new Promise(resolve => { finish = resolve; }));
    const pending = run(connector);
    connector.close();
    finish(ok({ folders: [row('/Share/a', true)], taskid: 'task', finished: true }));
    await assert.rejects(pending, isKind(K.Cancelled));
  }
});
