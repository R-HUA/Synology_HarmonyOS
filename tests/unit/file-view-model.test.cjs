const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const { TextEncoder } = require('node:util');
const sdkRoot = process.env.HARMONY_SDK_ROOT || path.join(process.env.DEVECO_CLI_CLT_PATH || 'C:/Program Files/command-line-tools', 'sdk/default');
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

function loadSource(relative, mocks, globals = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets', relative), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true,
  });
  assert.equal((output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, {
    module, exports: module.exports, Error, Date, Uint8Array, ArrayBuffer,
    require: id => {
      if (id === '../../platform/SdkDigest') {
        return require('../helpers/load-sdk-digest.cjs')(mocks['@kit.CryptoArchitectureKit'].cryptoFramework, protocol);
      }
      assert.ok(Object.hasOwn(mocks, id), `unexpected dependency ${id}`); return mocks[id];
    },
    ...globals,
  }, { filename: relative });
  return module.exports;
}

const protocol = loadSource('core/domain/DsmProtocol.ts', {});
const photos = loadSource('core/domain/PhotosProtocol.ts', { './DsmProtocol': protocol });
class MockPhotoMediaStore { cleanupErrorText = ''; attach() {} reset() {} setAccess() {} pinPreview() { return ''; } cancelOriginal() {} closeDetail() {} thumbnailPath() { return ''; } }
const { PhotoLibrary } = loadSource('features/photos/PhotoLibrary.ets', {
  '@kit.ArkTS': { util: { generateRandomUUID: () => '11111111-1111-4111-8111-111111111111' } },
  '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
  '../../core/domain/DsmProtocol': protocol,
  '../../core/domain/PhotosProtocol': photos,
  '../../platform/PhotoExif': { readPhotoExif: async () => ({}) }, './PhotoMediaStore': { PhotoMediaStore: MockPhotoMediaStore },
});
const operations = loadSource('core/domain/FileOperations.ts', { './DsmProtocol': protocol });
const taskState = loadSource('core/domain/FileTaskState.ts', { './DsmProtocol': protocol, './FileOperations': operations });
const { NasFailure, NasErrorKind: K } = protocol;
const entry = { name: '报告.txt', path: '/share/报告.txt', isDirectory: false };
const plain = value => JSON.parse(JSON.stringify(value));
const failure = kind => new NasFailure(kind, '测试错误。');

async function fixture(options = {}) {
  let now = 1;
  let nextId = 1;
  const saved = new Map();
  const calls = { start: 0, status: 0, list: 0, writes: 0 };
  const storage = { failLoad: false, failSave: false };
  class MockFileTaskStore {
    async load(_context, origin, account) {
      if (storage.failLoad) throw failure(K.Protocol);
      this.key = JSON.stringify([origin, account]);
      return plain(saved.get(this.key) || []);
    }
    async save(tasks) {
      if (storage.failSave) throw failure(K.Protocol);
      assert.ok(this.key, 'an unread store must never save');
      saved.set(this.key, plain(tasks));
      calls.writes++;
    }
  }
  class MockSessionStore { async clear() {} }
  class MockQueue {
    busy = false;
    ready = true;
    items = [];
    async attach() { if (options.queueError) throw failure(K.Protocol); }
    detach() {}
    async stopAll() {}
  }
  const connector = {
    async createFolder() { if (options.writeError) throw options.writeError; },
    async renameFile() { if (options.writeError) throw options.writeError; },
    async deleteFiles() { calls.start++; return { taskId: 'delete-task', kind: operations.NasFileTaskKind.Delete }; },
    async copyFiles() { calls.start++; return { taskId: 'copy-task', kind: operations.NasFileTaskKind.Copy }; },
    async moveFiles() { calls.start++; return { taskId: 'move-task', kind: operations.NasFileTaskKind.Move }; },
    async fileTaskStatus(task) { calls.status++; return options.status ? options.status(task) : { finished: false }; },
    async list() { calls.list++; if (options.listError) throw options.listError; return { entries: [], offset: 0, total: 0 }; },
    async photos() { if (options.photoError) throw options.photoError; return { items: [], offset: 0, hasMore: false }; },
    close() {},
  };
  const { ConnectionViewModel } = loadSource('features/connection/ConnectionViewModel.ets', {
    './TrustedDeviceStore': { TrustedDeviceStore: class { async load() { return ''; } async save() {} } },
    '../../core/domain/DsmProtocol': protocol,
    '../../core/network/NasConnector': { NasConnector: class {} },
    '../../core/network/RcpNasTransport': { RcpNasTransport: class {} },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {} } },
    './NasSessionStore': { NasSessionStore: MockSessionStore, NasSessionStoreFailure: class extends Error {} },
    '../../core/domain/PhotosProtocol': photos,
    '../photos/PhotoLibrary': { PhotoLibrary },
    '../backup/AutomaticPhotoBackup': { AutomaticPhotoBackup: class { async attach() {} detach() {} } },
    '../telemetry/TelemetryMonitor': { TelemetryMonitor: class { attach() {} detach() {} } },
    './ConnectionAddressBook': { ConnectionAddressBook: class { ready = true; dispose() {} } },
    '../control/SystemControlModel': { SystemControlModel: class { deactivate() {} async open(_context, _connector, _origin, _tls, validate) { this.validate = validate; } } },
    '../extensions/NasExtensionsModel': { NasExtensionsModel: class { recordsReady = true; pending = []; busy = false; async attach() {} reset() {} } },
    '../packages/PackageCatalogModel': { PackageCatalogModel: class { attach() {} reset() {} } },
    '../packages/OfficialWebModel': { OfficialWebModel: class { attach() {} reset() {} close() {} } },
    '../containers/ContainerModel': { ContainerModel: class { attach() {} reset() {} } },
    '../cloudsync/CloudSyncModel': { CloudSyncModel: class { attach() {} reset() {} } },
    '../systemlogs/SystemLogModel': { SystemLogModel: class { attach() {} reset() {} } },
    '../notes/NoteModel': { NoteModel: class { attach() {} reset() {} } },
    '../drive/DriveBrowserModel': { DriveBrowserModel: class { attach() {} detach() {} reset() {} } },
    '../drive/DriveTransferModel': { DriveTransferModel: class {
      ready = true; busy = false; items = [];
      async attach(...args) { this.canStart = args[5]; } async stopAll() {} detach() {}
    } },
    '../drive/DriveThumbnailStore': { DriveThumbnailStore: class { attach() {} detach() {} } },
    '../drive/DriveOriginalModel': { DriveOriginalModel: class { attach() {} detach() {} async close() {} } },
    '../drive/DriveSharingModel': { DriveSharingModel: class {
      ready = true; busy = false; hasPending = false; async attach() {} detach() {} async stopAll() {}
    } },
    '../drive/DriveNotificationsModel': { DriveNotificationsModel: class { attach() {} detach() {} } },
    '../drive/DriveActionModel': { DriveActionModel: class {
      ready = true; busy = false; hasPending = false;
      async attach(...args) { this.canWrite = args[5]; } async stopAll() {} detach() {}
    } },
    '../transfers/TransferQueue': { TransferQueue: MockQueue },
    '../../core/domain/FileOperations': operations,
    '../sharing/SharedUploadInbox': { sharedUploadInbox: {} },
    './FileTaskStore': { FileTaskStore: MockFileTaskStore },
    '@kit.ArkTS': { util: { generateRandomUUID: () => `11111111-1111-4111-8111-${String(nextId++).padStart(12, '0')}` } },
  }, { Date: { now: () => now }, setTimeout: (resolve, milliseconds) => { now += milliseconds; Promise.resolve().then(resolve); } });
  const model = new ConnectionViewModel();
  Object.assign(model, { authenticated: true, connected: true, connector, context: { filesDir: '/private' },
    address: 'https://nas.example.test:5001', account: 'alice', directory: '/share' });
  await model.attachQueue(connector);
  return { model, connector, calls, storage, saved, options, now: () => now, ConnectionViewModel };
}

test('Drive write permission requires an idle authenticated connection with the original connector and generation', async () => {
  const { model } = await fixture();
  const canWrite = model.driveActions.canWrite, canStart = model.driveTransfers.canStart;
  assert.equal(canWrite(), true); assert.equal(canStart(), true);
  for (const change of [{ busy: true }, { authenticated: false }, { connector: {} }, { generation: model.generation + 1 }]) {
    const previous = Object.fromEntries(Object.keys(change).map(key => [key, model[key]]));
    Object.assign(model, change);
    assert.equal(canWrite(), false); assert.equal(canStart(), false);
    Object.assign(model, previous);
    assert.equal(canWrite(), true); assert.equal(canStart(), true);
  }
});

test('structured download receipts retain task identity and still route session expiry through the connection owner', async () => {
  const { model } = await fixture();
  const expired = failure(K.SessionExpired);
  const receipt = { status: 'unconfirmed', taskId: 'retained', message: '任务提交未完成', failure: expired };
  let handled;
  model.queue.download = async () => receipt;
  model.showFailure = async (error, feature) => { handled = { error, feature }; };
  assert.equal(await model.downloadFile(entry), receipt);
  assert.equal(handled.error, expired); assert.equal(handled.feature, 'download');
  model.busy = true; assert.equal((await model.downloadFile(entry)).status, 'rejected');
});

test('File Station appends short pages once, preserves a failed page and resets on refresh', async () => {
  const { model, connector } = await fixture();
  const offsets = []; let reject = false; let release;
  connector.list = async (_path, offset) => {
    offsets.push(offset);
    if (offset === 1 && release === undefined) await new Promise(resolve => { release = resolve; });
    if (reject) throw failure(K.Network);
    return { entries: [{ name: String(offset), path: '/share/' + offset, isDirectory: false }], offset, total: 3 };
  };
  await model.refresh();
  const pending = model.nextPage(); await model.nextPage();
  assert.deepEqual(offsets, [0, 1]); release(); await pending;
  assert.deepEqual(Array.from(model.entries, item => item.path), ['/share/0', '/share/1']);
  reject = true; await model.nextPage();
  assert.equal(model.entries.length, 2);
  reject = false; await model.nextPage();
  assert.deepEqual(offsets, [0, 1, 2, 2]);
  assert.equal(model.filesMore, false);
  await model.nextPage(); assert.equal(offsets.length, 4);
  await model.refresh(); assert.equal(model.entries.length, 1); assert.equal(model.filesMore, true);
});

test('ambiguous File Station start is persisted before sending and cannot be sent twice', async () => {
  const { model, connector, calls, saved } = await fixture();
  let sent = 0;
  connector.deleteFiles = async () => { sent++; assert.ok(calls.writes > 0); throw failure(K.Network); };
  await model.deleteEntry(entry);
  await model.deleteEntry(entry);
  assert.equal(sent, 1);
  assert.equal(model.fileTasks[0].state, 'unknown');
  assert.equal([...saved.values()][0][0].state, 'unknown');
});

test('an accepted File Station write blocks another write including Drive and ordinary uploads', async () => {
  const { model, calls } = await fixture();
  await model.deleteEntry(entry);
  await model.deleteEntry(entry);
  assert.equal(calls.start, 1);
  assert.equal(model.driveActions.canWrite(), false);
  assert.equal(model.driveTransfers.canStart(), false);
});

test('unread or unsaved File Station intent prevents synchronous remote writes', async () => {
  const { model, connector, storage } = await fixture();
  let sent = 0;
  connector.createFolder = async () => { sent++; };
  connector.renameFile = async () => { sent++; };
  model.fileTasksReady = false;
  await model.createFolder('new');
  await model.renameEntry(entry, 'new.txt');
  model.fileTasksReady = true;
  storage.failSave = true;
  await model.createFolder('new');
  assert.equal(sent, 0);
});

test('system control refuses unread, active or unknown Drive transfers without stopping or replaying them', async () => {
  const { model } = await fixture();
  model.queue.ready = true;
  model.queue.items = [];
  model.fileTasks = [];
  await model.openSystemControl();
  const validate = model.systemControl.validate;
  assert.equal(typeof validate, 'function');
  assert.doesNotThrow(validate);
  model.driveTransfers.ready = false;
  assert.throws(validate, /成功读取/);
  model.driveTransfers.ready = true;
  model.driveTransfers.busy = true;
  assert.throws(validate, /仍有进行中/);
  model.driveTransfers.busy = false;
  for (const state of ['preparing', 'running', 'unknown']) {
    model.driveTransfers.items = [{ state }];
    assert.throws(validate, /仍有进行中/);
  }
  for (const state of ['completed', 'cancelled', 'failed', 'closed']) {
    model.driveTransfers.items = [{ state }];
    assert.doesNotThrow(validate);
  }
});

test('opening, closing and failed album reads preserve unrelated queue recovery errors', async () => {
  const { model, options } = await fixture({ queueError: true });
  const errorText = model.errorText;
  assert.ok(errorText);
  await model.openPhotos();
  model.closePhotos();
  assert.equal(model.errorText, errorText);
  options.photoError = failure(K.Network);
  await model.openPhotos();
  assert.equal(model.errorText, errorText);
  assert.ok(model.photosErrorText);
  model.closePhotos();
  assert.equal(model.photosErrorText, '');
  assert.equal(model.errorText, errorText);
});

test('completed writes remain completed when refreshing the directory fails', async () => {
  for (const method of ['createFolder', 'renameEntry']) {
    const { model, calls } = await fixture({ listError: failure(K.Network) });
    const result = method === 'createFolder' ? await model.createFolder('文件夹') : await model.renameEntry(entry, '新名称');
    assert.equal(result, 'completed');
    assert.match(model.actionNotice, /已创建|已更新/);
    assert.match(model.directoryErrorText, /操作已完成，但目录刷新失败/);
    assert.equal(model.errorText, model.directoryErrorText);
    assert.equal(calls.list, 1);
  }
});

test('rejected, busy, unauthenticated and stale edits return failed explicitly', async () => {
  const { model, connector, calls } = await fixture({ writeError: failure(K.Permission) });
  assert.equal(await model.createFolder('文件夹'), 'failed');
  assert.equal(await model.renameEntry(entry, '新名称'), 'failed');
  model.busy = true;
  for (const run of [() => model.createFolder('目录'), () => model.renameEntry(entry, '名称'),
    () => model.deleteEntry(entry), () => model.copyEntry(entry, '/other'), () => model.moveEntry(entry, '/other')]) {
    assert.equal(await run(), 'failed');
  }
  assert.equal(calls.start, 0);
  model.busy = false;
  model.authenticated = false;
  assert.equal(await model.copyEntry(entry, '/other'), 'failed');
  model.authenticated = true;
  connector.createFolder = async () => { model.generation++; };
  assert.equal(await model.createFolder('目录'), 'failed');
  assert.equal(model.actionNotice, '');
});

test('copy, move and delete keep their IDs after 15 seconds and only query status afterward', async () => {
  for (const method of ['copyEntry', 'moveEntry', 'deleteEntry']) {
    const { model, calls, options, saved, now } = await fixture();
    assert.equal(await model[method](entry, '/other'), 'pending');
    assert.ok(now() >= 15000);
    assert.equal(calls.start, 1);
    assert.equal(model.fileTasks[0].state, 'pending');
    const task = plain(model.fileTasks[0]);
    assert.ok(task.task.taskId);
    assert.equal([...saved.values()][0][0].task.taskId, task.task.taskId);
    options.status = async handle => { assert.equal(handle.taskId, task.task.taskId); return { finished: true }; };
    await model.checkFileTask(task.id);
    assert.equal(model.fileTasks[0].state, 'completed');
    assert.equal(calls.start, 1);
    assert.match(model.actionNotice, /已完成/);
  }
});

test('multi-selection submits all paths once and persists them in a single file task', async () => {
  const entries = [entry, { name: '目录', path: '/share/目录', isDirectory: true }];
  for (const [method, action] of [['copyEntries', 'copyFiles'], ['moveEntries', 'moveFiles'], ['deleteEntries', 'deleteFiles']]) {
    const { model, connector, saved } = await fixture({ status: () => ({ finished: true }) });
    let starts = 0;
    const original = connector[action];
    connector[action] = async (paths, directory) => {
      starts++;
      assert.deepEqual(plain(paths), entries.map(item => item.path));
      if (action !== 'deleteFiles') assert.equal(directory, '/other');
      return original();
    };
    assert.equal(await model[method](entries, '/other'), 'completed');
    assert.equal(starts, 1);
    assert.deepEqual(plain(model.fileTasks[0].sources), entries.map(item => item.path));
    assert.equal([...saved.values()][0].length, 1);
  }
});

test('network failure after start leaves an unknown task; successful later queries never restart it', async () => {
  const { model, calls, options } = await fixture({ status: () => { throw failure(K.Network); } });
  assert.equal(await model.copyEntry(entry, '/other'), 'pending');
  const task = plain(model.fileTasks[0]);
  assert.equal(task.state, 'unknown');
  assert.match(task.errorText, /继续查询.*请勿重复提交/);
  options.status = async () => ({ finished: false });
  await model.checkFileTask(task.id);
  assert.equal(model.fileTasks[0].state, 'pending');
  options.status = async () => ({ finished: true });
  await model.checkFileTask(task.id);
  assert.equal(model.fileTasks[0].state, 'completed');
  assert.equal(calls.start, 1);
});

test('confirmed task failure and expired sessions do not report an edit as successful', async () => {
  const failed = await fixture({ status: () => { throw new NasFailure(K.Server, '删除未全部完成。', 900); } });
  assert.equal(await failed.model.deleteEntry(entry), 'failed');
  assert.equal(failed.model.fileTasks[0].state, 'failed');
  assert.equal(failed.calls.start, 1);
  const expired = await fixture({ status: () => { throw failure(K.SessionExpired); } });
  assert.equal(await expired.model.copyEntry(entry, '/other'), 'failed');
  assert.equal(expired.model.authenticated, false);
  assert.equal([...expired.saved.values()][0][0].state, 'unknown');
  assert.equal([...expired.saved.values()][0][0].task.taskId, 'copy-task');
});

test('completed server tasks keep completion when their directory refresh fails', async () => {
  const { model } = await fixture({ status: async () => ({ finished: true }), listError: failure(K.Network) });
  assert.equal(await model.moveEntry(entry, '/other'), 'completed');
  assert.equal(model.fileTasks[0].state, 'completed');
  assert.match(model.actionNotice, /移动已完成/);
  assert.match(model.directoryErrorText, /操作已完成，但目录刷新失败/);
});

test('rejected, busy and missing status queries return pending for accepted tasks instead of inviting another start', async () => {
  for (const error of [failure(K.Permission), new NasFailure(K.Server, 'NAS 当前繁忙。', 402),
    new NasFailure(K.Server, '任务不存在。', 599)]) {
    for (const method of ['copyEntry', 'moveEntry', 'deleteEntry']) {
      const { model, calls, options } = await fixture({ status: () => { throw error; } });
      assert.equal(await model[method](entry, '/other'), 'pending');
      assert.equal(model.fileTasks[0].state, 'unknown');
      assert.match(model.actionNotice, /任务页继续查询.*请勿重复提交/);
      const task = plain(model.fileTasks[0]);
      options.status = async handle => { assert.equal(handle.taskId, task.task.taskId); return { finished: true }; };
      await model.checkFileTask(task.id);
      assert.equal(model.fileTasks[0].state, 'completed');
      assert.equal(calls.start, 1);
    }
  }
});

test('a connection switch after start retains the old task under its original account without publishing it to the new one', async () => {
  const { model, connector, saved } = await fixture();
  connector.copyFiles = async () => {
    model.generation++;
    model.clearAccount();
    model.account = 'bob';
    model.fileTasks = [{ ...persistedTask, task: { taskId: 'bob-task', kind: 1 } }];
    return { taskId: 'alice-task', kind: 1 };
  };
  assert.equal(await model.copyEntry(entry, '/other'), 'failed');
  assert.equal(model.fileTasks[0].task.taskId, 'bob-task');
  assert.equal([...saved.values()][0][0].task.taskId, 'alice-task');
  assert.equal([...saved.keys()][0], JSON.stringify(['https://nas.example.test:5001', 'alice']));
});

test('restoring task records and switching accounts never issue a start request', async () => {
  const { model, calls, options } = await fixture();
  await model.deleteEntry(entry);
  const id = model.fileTasks[0].id;
  model.clearAccount();
  model.authenticated = true;
  await model.attachFileTasks();
  assert.equal(model.fileTasks[0].id, id);
  model.account = 'bob';
  model.clearAccount();
  model.authenticated = true;
  await model.attachFileTasks();
  assert.equal(model.fileTasks.length, 0);
  model.account = 'alice';
  await model.attachFileTasks();
  options.status = async () => ({ finished: true });
  await model.checkFileTask(id);
  assert.equal(model.fileTasks[0].state, 'completed');
  assert.equal(calls.start, 1);
});

test('read failures block new long operations without overwriting saved records and can be retried', async () => {
  const { model, calls, storage, saved } = await fixture();
  await model.deleteEntry(entry);
  const original = plain([...saved.values()][0]);
  model.clearAccount();
  model.authenticated = true;
  storage.failLoad = true;
  await model.reloadFileTasks();
  assert.equal(model.fileTasksReady, false);
  const writes = calls.writes;
  assert.equal(await model.copyEntry(entry, '/other'), 'failed');
  assert.equal(calls.start, 1);
  assert.equal(calls.writes, writes);
  assert.deepEqual([...saved.values()][0], original);
  storage.failLoad = false;
  await model.reloadFileTasks();
  assert.equal(model.fileTasksReady, true);
  assert.equal(model.fileTasks[0].id, original[0].id);
});

test('a failed intent save prevents remote submission until records can be saved', async () => {
  const { model, calls, storage, options } = await fixture({ status: () => { throw failure(K.Network); } });
  storage.failSave = true;
  assert.equal(await model.copyEntry(entry, '/other'), 'failed');
  assert.equal(model.fileTasks.length, 0);
  assert.equal(model.fileTasksReady, false);
  assert.equal(await model.moveEntry(entry, '/other'), 'failed');
  assert.equal(calls.start, 0);
  storage.failSave = false;
  await model.reloadFileTasks();
  assert.equal(model.fileTasksReady, true);
  options.status = async () => ({ finished: true });
  await model.copyEntry(entry, '/other');
  assert.equal(model.fileTasks[0].state, 'completed');
  assert.equal(calls.start, 1);
});

function fileStoreFixture() {
  const files = new Map();
  const fds = new Map();
  const writes = [];
  let nextFd = 1;
  const faults = { read: false, readCode: 13900012, rename: false, fsync: false, close: false };
  const io = {
    OpenMode: { READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
    async mkdir() {},
    async stat(file) { if (!files.has(file)) throw { code: 13900002 }; return { size: Buffer.byteLength(files.get(file)) }; },
    async readText(file) { if (faults.read) throw { code: faults.readCode }; return files.get(file); },
    async open(file) { const fd = nextFd++; fds.set(fd, file); files.set(file, ''); writes.push(file); return { fd }; },
    async write(fd, bytes) { const buffer = Buffer.from(bytes); const count = Math.min(7, buffer.length);
      const file = fds.get(fd); const existing = Buffer.from(files.get(file), 'latin1');
      files.set(file, Buffer.concat([existing, buffer.subarray(0, count)]).toString('latin1')); return count; },
    async fsync() { if (faults.fsync) throw { code: 13900025 }; },
    async close() { if (faults.close) throw { code: 13900005 }; },
    async unlink(file) { files.delete(file); },
    async rename(oldPath, newPath) { if (faults.rename) throw { code: 13900012 };
      files.set(newPath, Buffer.from(files.get(oldPath), 'latin1').toString('utf8')); files.delete(oldPath); },
  };
  const { FileTaskStore } = loadSource('features/connection/FileTaskStore.ets', {
    '../../platform/SdkFileIO': loadSource('platform/SdkFileIO.ets', {
      '@kit.CoreFileKit': { fileIo: io }, '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
      '../core/domain/DsmProtocol': protocol,
    }),
    '@kit.CoreFileKit': { fileIo: io }, '@kit.ArkTS': { util: { TextEncoder: class {
      encodeInto(text) { return new TextEncoder().encode(text); }
    } } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd() { const hash = crypto.createHash('sha256');
      return { async update({ data }) { hash.update(data); }, async digest() { return { data: new Uint8Array(hash.digest()) }; } }; } } },
    '../../core/domain/DsmProtocol': protocol, '../../core/domain/FileTaskState': taskState,
  });
  return { FileTaskStore, files, writes, faults };
}

const persistedTask = { id: '11111111-1111-4111-8111-111111111111', task: { taskId: 'server-task', kind: 1 },
  operation: 'copy', sources: ['/share/报告.txt'], target: '/other', createdAt: 1,
  label: '复制 报告.txt', state: 'unknown', errorText: '结果待确认。' };

test('account-wide write admission checks every store and other module while allowing reads', async () => {
  const { model, calls } = await fixture();
  for (const change of [() => { model.driveSharing.hasPending = true; }, () => { model.driveActions.ready = false; },
    () => { model.extensions.pending = [{ feature: 'nasDownloads' }]; },
    () => { model.queue.items = [{ direction: 'upload', state: 'unknown' }]; },
    () => { model.driveTransfers.items = [{ direction: 'upload', state: 'running' }]; }]) {
    change(); assert.equal(await model.deleteEntry(entry), 'failed');
    model.driveSharing.hasPending = false; model.driveActions.ready = true; model.extensions.pending = [];
    model.queue.items = []; model.driveTransfers.items = [];
  }
  assert.equal(calls.start, 0);
  model.queue.items = [{ direction: 'download', state: 'running' }];
  assert.equal(model.driveActions.canWrite(), true);
  await model.refresh(); assert.ok(calls.list > 0);
});

test('closing an uncertain synchronous write requires saving and never repeats the request', async () => {
  const { model, connector, storage } = await fixture();
  let sent = 0; connector.renameFile = async () => { sent++; throw failure(K.Network); };
  assert.equal(await model.renameEntry(entry, '新名称.txt'), 'pending');
  const id = model.fileTasks[0].id;
  storage.failSave = true; await model.closeFileTask(id); assert.equal(model.fileTasks[0].state, 'unknown');
  storage.failSave = false; await model.reloadFileTasks(); await model.closeFileTask(id);
  assert.equal(model.fileTasks[0].state, 'closed'); assert.equal(sent, 1);
});

test('actual private task store round-trips partial writes and isolates NAS/account scopes', async () => {
  const { FileTaskStore, files } = fileStoreFixture();
  const store = new FileTaskStore();
  const context = { filesDir: '/private' };
  await store.load(context, 'https://nas.example.test:5001', 'alice');
  await store.save([persistedTask]);
  assert.deepEqual(plain(await new FileTaskStore().load(context, 'https://nas.example.test:5001', 'alice')), [persistedTask]);
  for (const [origin, account] of [['https://nas.example.test:5001', 'bob'], ['https://other.example.test:5001', 'alice']]) {
    assert.deepEqual(plain(await new FileTaskStore().load(context, origin, account)), []);
  }
  assert.equal(files.size, 1);
  const text = [...files.values()][0];
  assert.doesNotMatch(text, /sid|synoToken|cookie|password|nas\.example|alice/i);
});

test('actual store preserves corrupt or unreadable originals and refuses subsequent overwrite', async () => {
  for (const corrupt of [true, false]) {
    const { FileTaskStore, files, faults, writes } = fileStoreFixture();
    const context = { filesDir: '/private' };
    const initial = new FileTaskStore();
    await initial.load(context, 'https://nas.example.test', 'alice');
    await initial.save([persistedTask]);
    const path = [...files.keys()][0];
    if (corrupt) files.set(path, '{malformed');
    else faults.read = true;
    const original = files.get(path);
    const store = new FileTaskStore();
    await assert.rejects(store.load(context, 'https://nas.example.test', 'alice'));
    const count = writes.length;
    await assert.rejects(store.save([]));
    assert.equal(writes.length, count);
    assert.equal(files.get(path), original);
  }
});

test('a private snapshot fsync, close or rename failure leaves the previous task snapshot intact', async () => {
  for (const fault of ['fsync', 'close', 'rename']) {
    const { FileTaskStore, files, faults } = fileStoreFixture();
    const store = new FileTaskStore();
    await store.load({ filesDir: '/private' }, 'https://nas.example.test', 'alice');
    await store.save([persistedTask]);
    const path = [...files.keys()][0];
    const original = files.get(path);
    faults[fault] = true;
    await assert.rejects(store.save([{ ...persistedTask, state: 'completed' }]));
    assert.equal(files.get(path), original);
    assert.equal(files.has(path + '.tmp'), false);
  }
});

test('readText ENOENT after a successful stat rejects recovery and cannot enable an empty overwrite', async () => {
  const { FileTaskStore, files, faults, writes } = fileStoreFixture();
  const context = { filesDir: '/private' };
  const store = new FileTaskStore();
  assert.deepEqual(plain(await store.load(context, 'https://nas.example.test', 'alice')), []);
  await store.save([persistedTask]);
  const path = [...files.keys()][0];
  const original = files.get(path);
  faults.read = true;
  faults.readCode = 13900002;
  await assert.rejects(store.load(context, 'https://nas.example.test', 'alice'), error => error.code === 13900002);
  const count = writes.length;
  await assert.rejects(store.save([]));
  assert.equal(writes.length, count);
  assert.equal(files.get(path), original);
});

test('stored task schema rejects foreign scopes, duplicate handles and malformed status metadata', () => {
  const snapshot = { version: 1, scope: 'scope-a', tasks: [persistedTask] };
  assert.equal(taskState.decodeFileTasks(JSON.stringify(snapshot), 'scope-a')[0].task.taskId, 'server-task');
  assert.throws(() => taskState.decodeFileTasks(JSON.stringify(snapshot), 'scope-b'));
  for (const task of [{ ...persistedTask, state: 'made-up' }, { ...persistedTask, errorText: 3 },
    { ...persistedTask, id: '../secret' }, { ...persistedTask, task: { taskId: 'bad\n', kind: 1 } },
    { ...persistedTask, task: { taskId: 'task', kind: 999 } }]) {
    assert.throws(() => taskState.decodeFileTasks(JSON.stringify({ ...snapshot, tasks: [task] }), 'scope-a'));
  }
  assert.throws(() => taskState.decodeFileTasks(JSON.stringify({ ...snapshot, tasks: [persistedTask, persistedTask] }), 'scope-a'));
  assert.throws(() => taskState.decodeFileTasks(JSON.stringify({ ...snapshot, tasks: [persistedTask,
    { ...persistedTask, id: '22222222-2222-4222-8222-222222222222' }] }), 'scope-a'));
});
