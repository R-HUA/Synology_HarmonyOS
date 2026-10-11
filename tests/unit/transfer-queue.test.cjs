const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const protocol = require('../../work/core-build/domain/DsmProtocol.js');
const state = require('../../work/core-build/domain/TransferQueueState.js');
const ts = require(path.join(process.env.HARMONY_SDK_ROOT || 'C:/Program Files/command-line-tools/sdk/default',
  'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

function loadEts(relative, mocks) {
  mocks = { '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd(algorithm) {
    const digest = crypto.createHash(algorithm.toLowerCase());
    return { async update(blob) { digest.update(blob.data); }, async digest() { return { data: new Uint8Array(digest.digest()) }; } };
  } } }, ...mocks };
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets', relative), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true,
  });
  assert.equal((output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, {
    module, exports: module.exports, require: id => {
      if (id === '../../platform/LocalSpaceBudget') { return mocks[id] || require('../helpers/load-space-budget.cjs')(mocks['../domain/DsmProtocol'] || mocks['../../core/domain/DsmProtocol']); }
      if (id === '../../platform/SdkTransferAgent') {
        return require('../helpers/load-sdk-transfer-agent.cjs')(mocks['@kit.BasicServicesKit'].request.agent, protocol);
      }
      if (id === '../../platform/SdkDigest') {
        return require('../helpers/load-sdk-digest.cjs')(mocks['@kit.CryptoArchitectureKit'].cryptoFramework, protocol);
      }
      if (id === '../../platform/SdkFileIO') {
        return loadEts('platform/SdkFileIO.ets', {
          '@kit.CoreFileKit': mocks['@kit.CoreFileKit'],
          '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
          '../core/domain/DsmProtocol': protocol,
        });
      }
      if (id === '../../platform/Utf8Codec') {
        return loadEts('platform/Utf8Codec.ets', {
          '@kit.ArkTS': { util: require('../helpers/arkts-text-decoder.cjs') },
          '../core/domain/DsmProtocol': protocol,
        });
      }
      assert.ok(Object.hasOwn(mocks, id), `unexpected dependency ${id}`);
      return mocks[id];
    }, setInterval: () => 1, clearInterval: () => {}, Date, Uint8Array, ArrayBuffer, console,
  }, { filename: relative });
  return module.exports;
}

function record(overrides = {}) {
  return {
    id: '11111111-1111-4111-8111-111111111111', direction: 'upload', name: '中文.json', remotePath: '/share/中文.json',
    bytes: 37, localName: '11111111-1111-4111-8111-111111111111-1.bin', localReady: true, state: 'unknown',
    taskId: '100', attempts: 1, startAttempted: true, uploadAccepted: false, httpStatus: 200,
    contentType: '', attachmentName: '', processed: 37, createdAt: 1, updatedAt: 1, errorText: '', ...overrides,
  };
}

test('unknown/cancelled started uploads cannot retry; read-only downloads and explicit rejection can retry', () => {
  assert.equal(state.transferCanRetry(record()), false);
  assert.equal(state.transferCanRetry(record({ state: 'cancelled' })), false);
  assert.equal(state.transferCanRetry(record({ state: 'failed' })), true);
  assert.equal(state.transferCanRetry(record({ state: 'failed', localReady: false })), false);
  assert.equal(state.transferCanRetry(record({ direction: 'download' })), true);
  assert.equal(state.transferCanRetry(record({ state: 'cancelled', startAttempted: false })), true);
});

test('persistent records reject foreign accounts, duplicate identities and path traversal', () => {
  const snapshot = { version: 1, scope: 'scope-a', records: [record()] };
  assert.equal(state.decodeTransferQueue(JSON.stringify(snapshot), 'scope-a')[0].bytes, 37);
  assert.throws(() => state.decodeTransferQueue(JSON.stringify(snapshot), 'scope-b'));
  for (const bad of [
    { localName: '../sid' }, { remotePath: '/share/../secret' }, { bytes: -1 }, { httpStatus: 999 },
    { localReady: 'yes' }, { state: 'made-up' }, { taskId: 'id=secret' },
  ]) {
    assert.throws(() => state.decodeTransferQueue(JSON.stringify({ ...snapshot, records: [record(bad)] }), 'scope-a'));
  }
  assert.throws(() => state.decodeTransferQueue(JSON.stringify({ ...snapshot, records: [record(), record()] }), 'scope-a'));
  assert.equal(state.decodeTransferQueue(JSON.stringify({ ...snapshot, records: [record({ bytes: 5 * 1024 ** 3 })] }), 'scope-a')[0].bytes, 5 * 1024 ** 3);
});

test('upload HTTP 200 success=false, malformed body and absent HTTP success never count as completion', () => {
  assert.doesNotThrow(() => state.acceptTransferUpload(200, '{"success":true,"data":{}}'));
  assert.throws(() => state.acceptTransferUpload(200, '{"success":false,"error":{"code":119}}'));
  assert.throws(() => state.acceptTransferUpload(200, '<html>login</html>'));
  assert.throws(() => state.acceptTransferUpload(0, '{"success":true}'));
});

test('download validates HTTP, size, login/error responses and legitimate HTML/DSM-shaped JSON attachments', () => {
  const error = '{"success":false,"error":{"code":119}}';
  assert.throws(() => state.checkTransferDownload(200, error.length, error.length, 'application/json', error, true));
  assert.throws(() => state.checkTransferDownload(200, 19, 19, 'text/html', '<html>login</html>', true));
  assert.throws(() => state.checkTransferDownload(0, 2, 2, '', '{}', true));
  assert.throws(() => state.checkTransferDownload(200, 3, 2, '', '{}', true));
  assert.doesNotThrow(() => state.checkTransferDownload(200, error.length, error.length, 'application/json', error, true, '原文.json', '原文.json'));
  assert.doesNotThrow(() => state.checkTransferDownload(200, 19, 19, 'text/html', '<html>login</html>', true, '文档.html', '文档.html'));
  assert.throws(() => state.checkTransferDownload(200, 2, 2, '', '{}', true, 'other.json', 'wanted.json'));
  assert.equal(state.transferAttachmentName('attachment; filename="hello world.json"'), 'hello world.json');
  assert.equal(state.transferAttachmentName("attachment; filename*=UTF-8''%E4%B8%AD%E6%96%87.json"), '中文.json');
  assert.equal(state.transferAttachmentName('inline; filename="login.html"'), '');
  assert.equal(state.transferAttachmentName('attachment; filename="../secret"'), '');
});

function fixture() {
  const snapshots = new Map();
  const tasks = new Map();
  const files = new Map();
  const calls = [];
  let tid = 100;
  let uuid = 0;
  let failIdSave = false;
  let stopFailure = false;
  let createFailure = false;
  let readFailure = false;
  let clearFailure = false;
  let checksumSupported = false;
  let checksumFinished = true;
  let remoteMd5 = '1'.repeat(32);
  let localMd5 = '1'.repeat(32);
  let downloadPrefix = 'downloaded bytes';
  let photoUpload = async () => ({ status: 200, text: '{"success":true,"data":{}}' });
  const State = { INITIALIZED: 0, WAITING: 16, RUNNING: 32, RETRYING: 33, PAUSED: 48, STOPPED: 49, COMPLETED: 64, FAILED: 65, REMOVED: 80 };
  const util = {
    generateRandomUUID: () => `${(++uuid).toString().padStart(8, '0')}-1111-4111-8111-111111111111`,
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
  };
  const agent = {
    State, Faults: { SSL: 112, OTHERS: 255 }, Mode: { BACKGROUND: 0 }, Action: { UPLOAD: 0, DOWNLOAD: 1 }, Network: { WIFI: 1, ANY: 0 },
    async create(context, config) {
      const task = { tid: `${tid++}`, config, state: State.INITIALIZED, handlers: new Map(),
        on(event, callback) { this.handlers.set(event, callback); }, off(event) { this.handlers.delete(event); },
        async start() { calls.push(`start:${this.tid}`); this.state = State.RUNNING; },
        async pause() { calls.push(`pause:${this.tid}`); this.state = State.PAUSED; },
        async resume() { calls.push(`resume:${this.tid}`); this.state = State.RUNNING; },
      };
      tasks.set(task.tid, task);
      calls.push(`create:${task.tid}`);
      if (createFailure) throw new Error('lost create reply');
      return task;
    },
    async show(id) {
      const task = tasks.get(id);
      if (!task) throw Object.assign(new Error('missing task'), { code: 21900006 });
      return { tid: id, extras: task.config.extras, faults: task.faults ?? 255,
        progress: { state: task.state, processed: task.processed ?? 37, extras: task.progressExtras || (task.body ? { body: task.body } : undefined) } };
    },
    async getTask(context, id) { return tasks.get(id); },
    async search() { return [...tasks.keys()]; },
    async remove(id) {
      if (stopFailure) throw new Error('system stop failed');
      calls.push(`remove:${id}`); tasks.delete(id);
    },
  };
  const helper = {
    transferQueueDirectory: (context, scope) => `/files/transfers/${scope}`,
    async ensureTransferDirectory() {},
    async readTransferRecords(directory, scope) {
      if (readFailure) throw new Error('queue read failed');
      return snapshots.has(scope) ? state.decodeTransferQueue(snapshots.get(scope), scope) : [];
    },
    async saveTransferRecords(directory, scope, records) {
      if (failIdSave && records.some(r => r.taskId && !r.startAttempted)) throw new Error('disk full');
      snapshots.set(scope, JSON.stringify({ version: 2, scope, records }));
      calls.push(`save:${records.map(r => r.taskId).join(',')}`);
    },
    async copyTransferFile(source, destination, bytes, current) { current(); files.set(destination, bytes); },
    async removeTransferFile(name) { files.delete(name); },
    async removeTransferArtifacts(directory, record) {
      if (clearFailure) throw new Error('local cleanup failed');
      for (const name of files.keys()) if (name.startsWith(`${directory}/${record.id}-`)) files.delete(name);
    },
    async readTransferPrefix() { return { text: downloadPrefix, wholeFile: true }; },
    async hashTransferFile(name, bytes, current) { current(); calls.push('hash'); return localMd5; },
  };
  const fileIo = {
    OpenMode: { READ_ONLY: 0 }, async open(uri) { return { fd: uri }; }, async close() {},
    async stat(name) { return { size: files.get(name) ?? 37, isDirectory: () => false }; },
    async rename(source, target) { files.set(target, files.get(source)); files.delete(source); },
  };
  const connector = {
    async uploadPhoto(...args) { calls.push('photo-rcp'); return photoUpload(...args); },
    photoUploadPlan: (id, name, modifiedAt) => ({ address: 'https://nas.example/webapi/entry.cgi',
      fields: [{ name: 'api', content: 'SYNO.Foto.Upload.Item' }, { name: 'target_folder_id', content: id.toString() }, { name: 'mtime', content: modifiedAt.toString() }],
      session: { sid: 'PRIVATE-SID', synoToken: 'PRIVATE-TOKEN' } }),
    transferUploadPlan: directory => ({ address: 'https://nas.example/webapi/entry.cgi',
      fields: [{ name: 'path', content: directory }], session: { sid: 'PRIVATE-SID', synoToken: 'PRIVATE-TOKEN' } }),
    transferDownloadPlan: remote => ({ address: 'https://nas.example/webapi/entry.cgi',
      fields: [{ name: 'path', content: remote }], session: { sid: 'PRIVATE-SID', synoToken: 'PRIVATE-TOKEN' } }),
    async getFileInfo(remote) { return { path: remote, name: '中文.json', isDirectory: false, bytes: 37 }; },
    async startFileChecksum(remote) {
      if (!checksumSupported) throw new protocol.NasFailure(protocol.NasErrorKind.Unsupported, 'NAS 不支持文件内容校验，结果待确认。');
      calls.push(`checksum:${remote}`); return 'checksum-1';
    },
    async fileChecksumStatus(id) { calls.push(`checksum-status:${id}`); return { finished: checksumFinished, md5: remoteMd5 }; },
    async stopFileChecksum(id) { calls.push(`checksum-stop:${id}`); },
  };
  const { TransferQueue } = loadEts('features/transfers/TransferQueue.ets', {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': { request: { agent } }, '@kit.CoreFileKit': {
      fileIo, picker: { DocumentSaveOptions: class {}, DocumentViewPicker: class { async save() { return []; } } },
    },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd() {
      let data; return { async update(blob) { data = blob.data; }, async digest() { return { data: new Uint8Array(crypto.createHash('sha256').update(data).digest()) }; } };
    } } }, '@kit.ArkTS': { util }, '@kit.PerformanceAnalysisKit': { hilog: { error() {}, info() {} } },
    '../../core/network/NasTransferTransport': require('../../work/core-build/network/NasTransferTransport.js'),
    '../../core/network/NasConnector': {}, '../../core/domain/DsmProtocol': protocol,
    '../../core/domain/TransferQueueState': state, './TransferQueueFiles': helper,
  });
  const queue = new TransferQueue();
  const context = { filesDir: '/files' };
  return { queue, context, connector, tasks, snapshots, files, calls, State,
    attach: (account, insecureTls = false) => queue.attach(context, connector, 'https://nas.example', account, () => true, insecureTls),
    setPhotoUpload: action => { photoUpload = action; },
    setFailIdSave: () => { failIdSave = true; }, setStopFailure: () => { stopFailure = true; },
    setCreateFailure: value => { createFailure = value; },
    setReadFailure: value => { readFailure = value; }, setClearFailure: value => { clearFailure = value; },
    setChecksum: (md5 = '1'.repeat(32), finished = true) => { checksumSupported = true; remoteMd5 = md5; checksumFinished = finished; },
    setLocalMd5: value => { localMd5 = value; }, setDownloadPrefix: value => { downloadPrefix = value; } };
}

test('task ID reaches durable storage before start; multipart file is last and credentials never enter snapshots', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'file://selected', name: '中文.json', bytes: 37 }]);
  const start = f.calls.indexOf('start:100');
  assert.ok(f.calls.indexOf('save:100') < start);
  assert.equal([...f.tasks.values()][0].config.data.at(-1).name, 'file');
  assert.equal([...f.tasks.values()][0].config.retry, false);
  for (const snapshot of f.snapshots.values()) {
    assert.doesNotMatch(snapshot, /PRIVATE-SID|PRIVATE-TOKEN|Cookie|file:\/\/selected|webapi/);
  }
  f.queue.detach();
});

test('Photos queue uses its own protocol, pauses and resumes the same automatic task, and confirms only the Photos receipt', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.setBackupAllowed(true);
  await f.queue.uploadPhotos('/home/Photos/MobileBackup/Phone', [{ uri: 'selected', name: '照片.jpg', bytes: 37,
    folderId: 12, modifiedAt: 1704067200, wifiOnly: true, backupKey: 'asset-version-target' }], true);
  const task = f.tasks.get('100');
  assert.equal(task.config.network, 1); assert.equal(task.config.metered, true);
  assert.equal(task.config.data[0].value, 'SYNO.Foto.Upload.Item'); assert.equal(task.config.data.at(-1).name, 'file');
  await f.queue.setBackupAllowed(false); assert.equal(task.state, f.State.PAUSED);
  await f.queue.setBackupAllowed(true); assert.equal(task.state, f.State.RUNNING);
  assert.equal(f.calls.filter(call => call.startsWith('create:')).length, 1);
  const completed = [];
  f.queue.backupCompleted = async key => { completed.push(key); };
  task.state = f.State.COMPLETED; task.body = '{"success":true,"data":{}}';
  task.handlers.get('response')({ statusCode: 200, headers: new Map() }); await new Promise(resolve => setImmediate(resolve));
  await f.queue.reconcile(); assert.equal(f.queue.items[0].state, 'completed');
  assert.deepEqual(completed, ['asset-version-target']); assert.ok(!f.calls.includes('hash'));
  f.queue.detach();
});

test('Photos certificate exception uses the current connection upload and completes only after its receipt', async () => {
  const f = fixture(); await f.attach('alice', true);
  let complete;
  f.setPhotoUpload((folder, name, modified, source) => {
    assert.equal(folder, 12); assert.equal(name, '照片.jpg'); assert.equal(modified, 1704067200);
    assert.equal(source.bytes, 37); assert.ok(source.path.startsWith('/files/transfers/'));
    return new Promise(resolve => { complete = resolve; });
  });
  await f.queue.uploadPhotos('/home/Photos/PhotoLibrary/2024/01', [{ uri: 'selected', name: '照片.jpg', bytes: 37,
    folderId: 12, modifiedAt: 1704067200, wifiOnly: false }], false);
  assert.equal(f.tasks.size, 0); assert.equal(f.queue.items[0].state, 'running');
  await f.queue.reconcile(); assert.equal(f.queue.items[0].state, 'running');
  complete({ status: 200, text: '{"success":true,"data":{}}' });
  await new Promise(resolve => setImmediate(resolve)); await f.queue.tail;
  assert.equal(f.queue.items[0].state, 'completed');
  const saved = [...f.snapshots.values()].join('');
  assert.doesNotMatch(saved, /PRIVATE-SID|PRIVATE-TOKEN|entry.cgi/);
  f.queue.detach();
});

test('Photos connection upload rejects DSM failure and freezes missing or malformed receipts', async () => {
  for (const [reply, expected] of [
    [{ status: 200, text: '{"success":false,"error":{"code":119}}' }, 'failed'],
    [{ status: 200, text: '<html>login</html>' }, 'unknown'],
    [{ status: 502, text: 'gateway' }, 'unknown'],
  ]) {
    const f = fixture(); await f.attach('alice', true); f.setPhotoUpload(async () => reply);
    await f.queue.uploadPhotos('/home/Photos', [{ uri: 'selected', name: '照片.jpg', bytes: 37,
      folderId: 12, modifiedAt: 1704067200, wifiOnly: false }], false);
    await new Promise(resolve => setImmediate(resolve)); await f.queue.tail;
    assert.equal(f.queue.items[0].state, expected); assert.equal(f.queue.items[0].canRetry, expected === 'failed');
    f.queue.detach();
  }
});

test('interrupted connection upload restores as unknown and never submits a second request', async () => {
  const f = fixture(); await f.attach('alice', true);
  f.setPhotoUpload((folder, name, modified, source, control) => new Promise((resolve, reject) => {
    control.cancellation.subscribe(() => reject(new protocol.NasFailure(protocol.NasErrorKind.Cancelled, '已取消')));
  }));
  await f.queue.uploadPhotos('/home/Photos', [{ uri: 'selected', name: '照片.jpg', bytes: 37,
    folderId: 12, modifiedAt: 1704067200, wifiOnly: false }], false);
  await f.attach('alice', true);
  assert.equal(f.queue.items[0].state, 'unknown'); assert.equal(f.queue.items[0].canRetry, false);
  assert.equal(f.calls.filter(call => call === 'photo-rcp').length, 1); assert.equal(f.tasks.size, 0);
  f.queue.detach();
});

test('cancel interrupts the active connection upload while keeping its result pending verification', async () => {
  const f = fixture(); await f.attach('alice', true);
  let interrupted = false;
  f.setPhotoUpload((folder, name, modified, source, control) => new Promise((resolve, reject) => {
    control.cancellation.subscribe(() => { interrupted = true; reject(new protocol.NasFailure(protocol.NasErrorKind.Cancelled, '已取消')); });
  }));
  await f.queue.uploadPhotos('/home/Photos', [{ uri: 'selected', name: '照片.jpg', bytes: 37,
    folderId: 12, modifiedAt: 1704067200, wifiOnly: false }], false);
  await f.queue.cancel(f.queue.items[0].id);
  await new Promise(resolve => setImmediate(resolve)); await f.queue.tail;
  assert.equal(interrupted, true); assert.equal(f.queue.items[0].state, 'unknown');
  assert.equal(f.queue.items[0].canRetry, false); f.queue.detach();
});

test('only SSL failure before any sent bytes or HTTP response is eligible for explicit retry', async () => {
  for (const [faults, processed, httpStatus, expected] of [[112, 0, 0, 'failed'], [112, 1, 0, 'unknown'], [112, 0, 200, 'unknown'], [255, 0, 0, 'unknown']]) {
    const f = fixture(); await f.attach('alice');
    await f.queue.uploadPhotos('/home/Photos', [{ uri: 'selected', name: '照片.jpg', bytes: 37,
      folderId: 12, modifiedAt: 1704067200, wifiOnly: false }], false);
    const task = f.tasks.get('100'); task.state = f.State.FAILED; task.faults = faults; task.processed = processed;
    f.queue.session.records[0].httpStatus = httpStatus;
    await f.queue.reconcile(); assert.equal(f.queue.items[0].state, expected);
    assert.equal(f.queue.items[0].canRetry, expected === 'failed'); f.queue.detach();
  }
});

test('Photos recovery without a receipt remains unknown, even when a File Station checksum could match', async () => {
  const f = fixture(); await f.attach('alice'); f.setChecksum();
  await f.queue.uploadPhotos('/home/Photos/PhotoLibrary/2024/01', [{ uri: 'selected', name: '照片.jpg', bytes: 37,
    folderId: 12, modifiedAt: 1704067200, wifiOnly: false }], false);
  assert.equal(f.tasks.get('100').config.metered, true);
  f.tasks.get('100').state = f.State.COMPLETED;
  await f.queue.reconcile(); assert.equal(f.queue.items[0].state, 'unknown');
  assert.ok(!f.calls.some(call => call.startsWith('checksum:'))); f.queue.detach();
});

test('failed task-ID persistence removes the unstarted system task', async () => {
  const f = fixture(); await f.attach('alice'); f.setFailIdSave();
  const result = await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  assert.deepEqual(Array.from(result.acceptedIndices), [0]);
  assert.equal(result.issues.length, 1);
  assert.equal(f.tasks.size, 0);
  assert.ok(f.calls.includes('remove:100'));
  assert.ok(!f.calls.includes('start:100'));
  f.queue.detach();
});

test('restart adopts an orphan INITIALIZED task through the persistent marker instead of uploading twice', async () => {
  const f = fixture(); await f.attach('alice'); f.setCreateFailure(true);
  const result = await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  assert.deepEqual(Array.from(result.acceptedIndices), [0]);
  assert.equal(result.issues.length, 1);
  f.queue.detach(); f.setCreateFailure(false); await f.attach('alice');
  assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
  assert.ok(f.calls.includes('start:100'));
  assert.equal(f.queue.items[0].state, 'running');
  f.queue.detach();
});

test('recovered completed upload without business/HTTP response stays unknown and explicit retry is refused', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  f.tasks.get('100').state = f.State.COMPLETED;
  await f.queue.reconcile();
  assert.equal(f.queue.items[0].state, 'unknown');
  await assert.rejects(() => f.queue.retry(f.queue.items[0].id));
  assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
  f.queue.detach();
});

test('a broken SDK off call does not interrupt account detach or leave live callbacks', async () => {
  const f = fixture();
  await f.attach('alice');
  await f.queue.download({ path: '/share/a.txt', name: 'a.txt', isDirectory: false });
  const task = f.tasks.get('100');
  const callbacks = [...task.handlers.values()];
  const removed = [];
  task.off = event => { removed.push(event); if (event === 'response') throw { code: 201 }; };
  assert.doesNotThrow(() => f.queue.detach());
  assert.deepEqual(removed, ['response', 'progress', 'completed', 'failed']);
  assert.equal(f.queue.ready, false);
  assert.equal(f.queue.items.length, 0);
  await f.attach('bob');
  for (const callback of callbacks) callback({ processed: 999, state: f.State.COMPLETED });
  assert.equal(f.queue.items.length, 0);
  f.queue.detach();
});

test('same origin different accounts have distinct records and detached callbacks cannot populate new account', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  const callback = f.tasks.get('100').handlers.get('progress');
  f.queue.detach(); assert.equal(f.queue.items.length, 0);
  await f.attach('bob'); callback({ processed: 20 });
  assert.equal(f.queue.items.length, 0);
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  assert.equal(f.snapshots.size, 2);
  f.queue.detach(); await f.attach('alice');
  assert.equal(f.queue.items[0].id, '00000001-1111-4111-8111-111111111111');
  f.queue.detach();
});

test('logout stop is a no-op before attach, propagates stop errors, and preserves unknown upload semantics', async () => {
  const f = fixture(); await f.queue.stopAll(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  await f.queue.stopAll();
  assert.equal(f.tasks.size, 0);
  assert.equal(f.queue.items[0].state, 'unknown');
  assert.equal(f.queue.items[0].canRetry, false);
  const g = fixture(); await g.attach('alice');
  await g.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  g.setStopFailure(); await assert.rejects(() => g.queue.stopAll());
  f.queue.detach(); g.queue.detach();
});

test('private file copy handles partial reads/writes with bounded allocations and fsync before closing', async () => {
  const input = Buffer.alloc(700003);
  for (let index = 0; index < input.length; index++) input[index] = index % 251;
  const chunks = [];
  const handles = new Map();
  const events = [];
  let readOffset = 0;
  let written = 0;
  let maxRead = 0;
  let maxWrite = 0;
  let fd = 0;
  const fileIo = {
    OpenMode: { READ_ONLY: 0, READ_WRITE: 1, CREATE: 2, TRUNC: 4 },
    async open(name) { const handle = { fd: ++fd }; handles.set(handle.fd, name); return handle; },
    async stat(descriptor) { return { size: handles.get(descriptor) === 'source' ? input.length : written, isDirectory: () => false }; },
    async read(descriptor, buffer, options) {
      maxRead = Math.max(maxRead, buffer.byteLength);
      const length = Math.min(options.length, 11001, input.length - readOffset);
      new Uint8Array(buffer).set(input.subarray(readOffset, readOffset + length));
      readOffset += length;
      return length;
    },
    async write(descriptor, buffer) {
      maxWrite = Math.max(maxWrite, buffer.byteLength);
      const count = Math.min(buffer.byteLength, 3001);
      chunks.push(Buffer.from(buffer).subarray(0, count)); written += count; return count;
    },
    async fsync(descriptor) { events.push(`sync:${descriptor}`); },
    async close(handle) { events.push(`close:${handle.fd}`); },
  };
  const { copyTransferFile } = loadEts('features/transfers/TransferQueueFiles.ets', {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {}, '@kit.CoreFileKit': { fileIo }, '@kit.ArkTS': {},
    '../../core/domain/DsmProtocol': protocol, '../../core/domain/TransferQueueState': state,
  });
  await copyTransferFile('source', 'destination', input.length, () => {});
  assert.deepEqual(Buffer.concat(chunks), input);
  assert.ok(maxRead <= 256 * 1024 && maxWrite <= 256 * 1024);
  assert.deepEqual(events, ['sync:2', 'close:2', 'close:1']);
});

test('copy cancellation remains primary while both descriptors still attempt close', async () => {
  const closed = [];
  const cancelled = new protocol.NasFailure(protocol.NasErrorKind.Cancelled, 'cancelled');
  const fileIo = {
    OpenMode: { READ_ONLY: 0, READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
    async open(name) { return { fd: name === 'source' ? 1 : 2 }; },
    async stat() { return { size: 10, isDirectory: () => false }; },
    async close(file) { closed.push(file.fd); throw { code: 13900005 }; },
  };
  const { copyTransferFile } = loadEts('features/transfers/TransferQueueFiles.ets', {
    '@kit.CoreFileKit': { fileIo }, '@kit.ArkTS': {},
    '../../core/domain/DsmProtocol': protocol, '../../core/domain/TransferQueueState': state,
  });
  await assert.rejects(copyTransferFile('source', 'destination', 10, () => { throw cancelled; }), error => error === cancelled);
  assert.deepEqual(closed, [2, 1]);
});

test('private snapshots commit only after complete writes, fsync and close, preserving the old record on every failure', async () => {
  for (const fault of ['', 'open', 'write', 'short', 'fsync', 'close', 'rename', 'write-close-cleanup']) {
    const files = new Map([['/private/queue.json', Buffer.from('old')]]);
    const events = [];
    const diagnostics = [];
    const fileIo = {
      OpenMode: { READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
      async open(name) {
        events.push('open');
        if (fault === 'open') throw { code: 13900013 };
        files.set(name, Buffer.alloc(0)); return { fd: 1 };
      },
      async write(descriptor, bytes) {
        events.push('write');
        if (fault.startsWith('write')) throw { code: 13900028 };
        if (fault === 'short') return 0;
        const part = Buffer.from(bytes).subarray(0, 3);
        files.set('/private/queue.json.tmp', Buffer.concat([files.get('/private/queue.json.tmp'), part]));
        return part.length;
      },
      async fsync() { events.push('fsync'); if (fault === 'fsync') throw { code: 13900025 }; },
      async close() { events.push('close'); if (fault.includes('close')) throw { code: 13900005 }; },
      async rename(source, destination) {
        events.push('rename'); if (fault === 'rename') throw { code: 13900012 };
        files.set(destination, files.get(source)); files.delete(source);
      },
      async unlink(name) {
        events.push('unlink'); if (fault.includes('cleanup')) throw { code: 13900013 };
        assert.equal(name, '/private/queue.json.tmp'); files.delete(name);
      },
    };
    const { writePrivateSnapshot } = loadEts('platform/SdkFileIO.ets', {
      '@kit.CoreFileKit': { fileIo }, '../core/domain/DsmProtocol': protocol,
      '@kit.PerformanceAnalysisKit': { hilog: { error(...args) { diagnostics.push(args); } } },
    });
    const bytes = new TextEncoder().encode('中文快照😀');
    if (fault === '') {
      await writePrivateSnapshot('/private/queue.json', bytes);
      assert.deepEqual(files.get('/private/queue.json'), Buffer.from(bytes));
      assert.deepEqual(events.slice(-3), ['fsync', 'close', 'rename']);
    } else {
      await assert.rejects(writePrivateSnapshot('/private/queue.json', bytes), error =>
        error.kind === protocol.NasErrorKind.Protocol && (!fault.startsWith('write') || error.code === 13900028));
      assert.equal(files.get('/private/queue.json').toString(), 'old');
      assert.equal(events.includes('rename'), fault === 'rename');
      assert.equal(events.includes('close'), fault !== 'open');
      assert.equal(events.includes('unlink'), fault !== 'open');
    }
    assert.ok(diagnostics.every(args => !JSON.stringify(args).includes('/private/')));
  }
});

test('transfer snapshot size cannot exceed the recovery bound', async () => {
  let opened = false;
  const { saveTransferRecords } = loadEts('features/transfers/TransferQueueFiles.ets', {
    '@kit.CoreFileKit': { fileIo: { async open() { opened = true; throw new Error('must not open'); } } },
    '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } } },
    '../../core/domain/DsmProtocol': protocol, '../../core/domain/TransferQueueState': state,
  });
  await assert.rejects(saveTransferRecords('/private', 'scope', [record({ errorText: 'x'.repeat(4 * 1024 * 1024) })]),
    error => error.kind === protocol.NasErrorKind.Protocol);
  assert.equal(opened, false);
});

test('file prefix decoding tolerates binary and cut UTF-8 without changing wholeFile evidence', async () => {
  for (const size of [0, 8, 65537]) {
    const content = new Uint8Array(size).fill(0x61);
    if (size > 65536) { content.set([0xe4, 0xb8, 0xad], 65534); }
    else if (size > 0) { content[0] = 0xff; }
    let offset = 0;
    let closed = false;
    const fileIo = {
      OpenMode: { READ_ONLY: 0 },
      async open() { return { fd: 1 }; },
      async read(descriptor, buffer) {
        const count = Math.min(997, buffer.byteLength, content.length - offset);
        new Uint8Array(buffer).set(content.subarray(offset, offset + count));
        offset += count;
        return count;
      },
      async close() { closed = true; },
    };
    const { readTransferPrefix } = loadEts('features/transfers/TransferQueueFiles.ets', {
      '@kit.CoreFileKit': { fileIo }, '@kit.ArkTS': {}, '../../core/domain/DsmProtocol': protocol,
      '../../core/domain/TransferQueueState': state,
    });
    const prefix = await readTransferPrefix('download.bin', size);
    assert.equal(prefix.wholeFile, size <= 65536);
    assert.equal(offset, Math.min(size, 65536));
    assert.equal(closed, true);
    if (size > 65536) assert.ok(prefix.text.endsWith('\uFFFD'));
    else if (size > 0) assert.ok(prefix.text.startsWith('\uFFFD'));
    else assert.equal(prefix.text, '');
  }
});

test('downloads with missing HTTP and checksum evidence remain unconfirmed and never expose export', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.download({ path: '/share/中文.json', name: '中文.json', isDirectory: false });
  const task = f.tasks.get('100');
  task.state = f.State.COMPLETED;
  await f.queue.reconcile();
  assert.equal(f.queue.items[0].state, 'unknown');
  assert.equal(f.queue.items[0].canExport, false);
  await assert.rejects(() => f.queue.exportDownload(f.queue.items[0].id));
  f.queue.detach();
});

test('successful upload requires response, DSM acceptance and target size; completion releases the system task', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  const task = f.tasks.get('100');
  task.handlers.get('response')({ statusCode: 200, headers: new Map() });
  task.handlers.get('completed')({ state: f.State.COMPLETED, processed: 37, extras: { body: '{"success":true}' } });
  await f.queue.tail;
  assert.equal(f.queue.items[0].state, 'completed');
  assert.equal(f.queue.items[0].canRetry, false);
  assert.equal(f.tasks.size, 0);
  assert.equal(JSON.parse([...f.snapshots.values()][0]).records[0].uploadAccepted, true);
  f.queue.detach();
});

test('HTTP 200 DSM rejection is shown as failed; matching remote size alone cannot turn it into success', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  const task = f.tasks.get('100');
  task.handlers.get('response')({ statusCode: 200, headers: new Map() });
  task.handlers.get('completed')({ state: f.State.COMPLETED, processed: 37, extras: { body: '{"success":false,"error":{"code":119}}' } });
  await f.queue.tail;
  assert.equal(f.queue.items[0].state, 'failed');
  assert.match(f.queue.items[0].errorText, /登录已失效/);
  f.queue.detach();
});

test('successful download persists its HTTP identity before completion and enables export', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.download({ path: '/share/中文.json', name: '中文.json', isDirectory: false });
  const task = f.tasks.get('100');
  task.handlers.get('response')({ statusCode: 200, headers: new Map([
    ['Content-Type', ['application/json']], ['Content-Disposition', ["attachment; filename*=UTF-8''%E4%B8%AD%E6%96%87.json"]],
  ]) });
  task.handlers.get('completed')({ state: f.State.COMPLETED, processed: 37 });
  await f.queue.tail;
  assert.equal(f.queue.items[0].state, 'completed');
  assert.equal(f.queue.items[0].canExport, true);
  assert.equal(f.tasks.size, 0);
  const saved = JSON.parse([...f.snapshots.values()][0]).records[0];
  assert.equal(saved.httpStatus, 200);
  assert.equal(saved.attachmentName, '中文.json');
  f.queue.detach();
});

test('shared multi-file admission returns only durable source indices, preserves original names and reports partial failure', async () => {
  const f = fixture(); await f.attach('alice');
  const result = await f.queue.uploadSources('/share', [
    { uri: 'file://uuid.share', name: '原始名称.txt' },
    { uri: 'file://invalid.share', name: '../secret', bytes: 37 },
    { uri: 'file://another.share', name: '第二个文件.json', bytes: 37 },
  ]);
  assert.deepEqual(Array.from(result.acceptedIndices), [0, 2]);
  assert.equal(result.issues.length, 1);
  assert.equal(result.issues[0].index, 1);
  assert.equal(f.tasks.get('100').config.data.at(-1).value.filename, '原始名称.txt');
  assert.equal(f.queue.items.length, 2);
  f.queue.detach();
});

test('FAILED upload with HTTP 200 and explicit DSM rejection can be retried by the user', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  const task = f.tasks.get('100');
  task.handlers.get('response')({ statusCode: 200, headers: new Map() });
  task.handlers.get('failed')({ state: f.State.FAILED, processed: 37,
    extras: { body: '{"success":false,"error":{"code":119}}' } });
  await f.queue.tail;
  assert.equal(f.queue.items[0].state, 'failed');
  assert.equal(f.queue.items[0].canRetry, true);
  assert.match(f.queue.items[0].errorText, /登录已失效/);
  assert.equal(JSON.parse([...f.snapshots.values()][0]).records[0].state, 'failed');
  await f.queue.retry(f.queue.items[0].id);
  assert.equal(f.queue.items[0].state, 'running');
  assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 2);
  f.queue.detach();
});

test('FAILED upload without verifiable HTTP/DSM rejection stays unknown and cannot retry', async () => {
  const rejection = '{"success":false,"error":{"code":119}}';
  for (const [status, body] of [[200, undefined], [0, rejection], [503, rejection], [200, '<html>login</html>'],
    [200, '{"success":false,"error":{}}'], [200, '{"success":true}']]) {
    const f = fixture(); await f.attach('alice');
    await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
    const task = f.tasks.get('100');
    if (status !== 0) task.handlers.get('response')({ statusCode: status, headers: new Map() });
    task.handlers.get('failed')({ state: f.State.FAILED, processed: 37, extras: body === undefined ? undefined : { body } });
    await f.queue.tail;
    assert.equal(f.queue.items[0].state, 'unknown', `status=${status} body=${body}`);
    assert.equal(f.queue.items[0].canRetry, false);
    await assert.rejects(() => f.queue.retry(f.queue.items[0].id));
    assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
    f.queue.detach();
  }
});

test('STOPPED and REMOVED uploads remain unknown even when their extras contain a DSM rejection', async () => {
  for (const stateName of ['STOPPED', 'REMOVED']) {
    const f = fixture(); await f.attach('alice');
    await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
    const task = f.tasks.get('100');
    task.handlers.get('response')({ statusCode: 200, headers: new Map() });
    task.handlers.get('failed')({ state: f.State[stateName], processed: 37,
      extras: { body: '{"success":false,"error":{"code":119}}' } });
    await f.queue.tail;
    assert.equal(f.queue.items[0].state, 'unknown', stateName);
    assert.equal(f.queue.items[0].canRetry, false);
    await assert.rejects(() => f.queue.retry(f.queue.items[0].id));
    assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
    f.queue.detach();
  }
});

test('queue read or decode failure blocks all mutations, preserves history and reloads the original task', async () => {
  for (const corruption of [false, true]) {
    const f = fixture(); await f.attach('alice');
    await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'original.txt', bytes: 37 }]);
    const [scope, original] = [...f.snapshots.entries()][0];
    f.queue.detach();
    if (corruption) f.snapshots.set(scope, '{broken queue');
    else f.setReadFailure(true);
    const retained = f.snapshots.get(scope);
    const before = f.calls.length;
    await assert.rejects(() => f.attach('alice'));
    assert.equal(f.queue.ready, false);
    await assert.rejects(() => f.queue.uploadSources('/share', [{ uri: 'selected', name: 'new.txt', bytes: 37 }]));
    await assert.rejects(() => f.queue.download({ path: '/share/file.txt', name: 'file.txt', isDirectory: false }));
    await assert.rejects(() => f.queue.clearHistory());
    await assert.rejects(() => f.queue.stopAll());
    assert.equal(f.calls.length, before);
    assert.equal(f.snapshots.get(scope), retained);
    assert.equal(f.tasks.get('100').state, f.State.RUNNING);
    f.setReadFailure(false); f.snapshots.set(scope, original);
    await f.queue.reconcile();
    assert.equal(f.queue.ready, true);
    assert.equal(f.queue.items[0].name, 'original.txt');
    assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
    f.queue.detach();
  }
});

test('only confirmed absence at stat permits empty history; later read failure is not first use', async () => {
  let missingAtStat = true;
  const { readTransferRecords } = loadEts('features/transfers/TransferQueueFiles.ets', {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {}, '@kit.CoreFileKit': { fileIo: {
      async stat() { if (missingAtStat) throw { code: 13900002 }; return { size: 10 }; },
      async readText() { throw { code: 13900002 }; },
    } }, '@kit.ArkTS': {}, '../../core/domain/DsmProtocol': protocol, '../../core/domain/TransferQueueState': state,
  });
  assert.equal((await readTransferRecords('/queue', 'scope')).length, 0);
  missingAtStat = false;
  await assert.rejects(() => readTransferRecords('/queue', 'scope'));
});

test('unknown upload closes only after explicit action, unblocks the path and never replays the old task', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  const id = f.queue.items[0].id;
  await assert.rejects(() => f.queue.closeUnknownUpload(id));
  await f.queue.cancel(id);
  assert.equal(f.queue.items[0].canClose, true);
  await assert.rejects(() => f.queue.removeRecord(id));
  await assert.rejects(() => f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]), /仍有写入/);
  await f.queue.closeUnknownUpload(id);
  assert.equal(f.queue.items[0].state, 'closed');
  assert.equal(f.queue.items[0].canRetry, false);
  assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
  const admitted = await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  assert.deepEqual(Array.from(admitted.acceptedIndices), [0]);
  assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 2);
  f.queue.detach();
});

test('photo backup sources survive recovery and batches wait behind an uncertain upload', async () => {
  const f = fixture(); await f.attach('alice');
  const result = await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'a.jpg', bytes: 37 },
    { uri: 'selected', name: 'b.jpg', bytes: 37 }], 'photoBackup');
  assert.deepEqual(Array.from(result.acceptedIndices), [0, 1]);
  assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
  assert.deepEqual(Array.from(f.queue.items, x => x.source), ['photoBackup', 'photoBackup']);
  await f.queue.cancel(f.queue.items[0].id); await f.queue.reconcile();
  assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
  await f.queue.closeUnknownUpload(f.queue.items[0].id); await f.queue.reconcile();
  assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 2);
  f.queue.detach(); await f.attach('alice');
  assert.deepEqual(Array.from(f.queue.items, x => x.source), ['photoBackup', 'photoBackup']);
  f.queue.detach();
});

test('legacy sources are explicit and are never inferred from photo extensions', () => {
  const rows = state.decodeTransferQueue(JSON.stringify({ version: 1, scope: 'legacy', records: [record({ name: 'old.jpg' })] }), 'legacy');
  assert.equal(rows[0].source, 'legacy');
  assert.throws(() => state.decodeTransferQueue(JSON.stringify({ version: 2, scope: 'legacy', records: [record({ source: 'photoGuess' })] }), 'legacy'));
});

test('system stop failure prevents closing an unknown upload or unblocking the remote path', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  f.tasks.get('100').state = f.State.FAILED;
  await f.queue.reconcile();
  f.setStopFailure();
  await assert.rejects(() => f.queue.closeUnknownUpload(f.queue.items[0].id));
  assert.equal(f.queue.items[0].state, 'unknown');
  await assert.rejects(() => f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]), /仍有写入/);
  assert.equal(f.tasks.size, 1);
  f.queue.detach();
});

test('cleanup resumes after restart from a durable tombstone and never creates a task', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  const id = f.queue.items[0].id;
  await f.queue.cancel(id); await f.queue.closeUnknownUpload(id);
  f.setClearFailure(true);
  await assert.rejects(() => f.queue.removeRecord(id));
  assert.equal(f.queue.items[0].state, 'clearing');
  assert.equal(f.queue.items[0].canRetry, false);
  assert.equal(JSON.parse([...f.snapshots.values()][0]).records[0].state, 'clearing');
  assert.equal(f.files.size, 1);
  f.queue.detach(); f.setClearFailure(false); await f.attach('alice');
  assert.equal(f.queue.items.length, 0);
  assert.equal(f.files.size, 0);
  assert.equal(JSON.parse([...f.snapshots.values()][0]).records.length, 0);
  assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
  f.queue.detach();
});

test('cleanup releases a full queue slot while keeping running and unconfirmed uploads', async () => {
  const f = fixture(); await f.attach('alice');
  const scope = f.queue.session.scope;
  const records = Array.from({ length: 1000 }, (_, i) => {
    const id = `${(i + 1).toString(16).padStart(8, '0')}-2222-4222-8222-222222222222`;
    return record({ id, localName: `${id}-1.bin`, state: 'closed', taskId: '' });
  });
  f.snapshots.set(scope, JSON.stringify({ version: 1, scope, records }));
  await f.attach('alice');
  const full = await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'new.txt', bytes: 37 }]);
  assert.equal(full.acceptedIndices.length, 0);
  assert.match(full.issues[0].errorText, /清理历史/);
  await f.queue.removeRecord(records[0].id);
  const admitted = await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'new.txt', bytes: 37 }]);
  assert.deepEqual(Array.from(admitted.acceptedIndices), [0]);
  await f.queue.clearHistory();
  assert.equal(f.queue.items.length, 1);
  assert.equal(f.queue.items[0].state, 'running');
  await f.queue.cancel(f.queue.items[0].id); await f.queue.clearHistory();
  assert.equal(f.queue.items[0].state, 'unknown');
  assert.equal(f.queue.items[0].canRemove, false);
  f.queue.detach();
});

test('artifact cleanup only removes private copies owned by the selected record', async () => {
  const r = record();
  const kept = ['queue.json', 'queue.json.tmp', 'other-1.bin', `${r.id}-0.bin`, `${r.id}-1.bin.unrelated`];
  const owned = [`${r.id}-1.bin`, `${r.id}-2.bin.tmp`, `${r.id}-3.bin`];
  const removed = [];
  const { removeTransferArtifacts } = loadEts('features/transfers/TransferQueueFiles.ets', {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {}, '@kit.CoreFileKit': { fileIo: {
      async listFile() { return [...kept, ...owned]; }, async unlink(name) { removed.push(name); },
    } }, '@kit.ArkTS': {}, '../../core/domain/DsmProtocol': protocol, '../../core/domain/TransferQueueState': state,
  });
  await removeTransferArtifacts('/private', r);
  assert.deepEqual(removed, owned.map(name => `/private/${name}`));
});

test('upload completed while detached recovers by content checksum without replaying the upload', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  f.queue.detach(); f.setChecksum();
  f.tasks.get('100').state = f.State.COMPLETED;
  await f.attach('alice');
  const item = f.queue.items[0];
  assert.equal(item.state, 'completed');
  assert.equal(item.stateText, '上传内容已核验');
  assert.equal(item.canRetry, false);
  assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
  const saved = JSON.parse([...f.snapshots.values()][0]).records[0];
  assert.equal(saved.uploadAccepted, false);
  assert.equal(saved.contentVerified, true);
  assert.equal(saved.httpStatus, 0);
  assert.equal(saved.localMd5, '1'.repeat(32));
  assert.equal(f.tasks.size, 0);
  f.queue.detach(); await f.attach('alice');
  assert.equal(f.queue.items[0].stateText, '上传内容已核验');
  assert.equal(f.calls.filter(c => c.startsWith('checksum:')).length, 1);
  f.queue.detach();
});

test('download completed while detached recovers by full content and export rechecks private bytes', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.download({ path: '/share/中文.json', name: '中文.json', isDirectory: false });
  f.queue.detach(); f.setChecksum(); f.tasks.get('100').state = f.State.COMPLETED;
  await f.attach('alice');
  const item = f.queue.items[0];
  assert.equal(item.state, 'completed');
  assert.equal(item.stateText, '下载内容已核验');
  assert.equal(item.canExport, true);
  await f.queue.exportDownload(item.id);
  f.setLocalMd5('2'.repeat(32));
  await assert.rejects(() => f.queue.exportDownload(item.id), /下载副本已变化/);
  assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
  f.queue.detach();
});

test('same size different contents never confirms upload or permits download export', async () => {
  for (const direction of ['upload', 'download']) {
    const f = fixture(); await f.attach('alice');
    if (direction === 'upload') await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
    else await f.queue.download({ path: '/share/中文.json', name: '中文.json', isDirectory: false });
    f.queue.detach(); f.setChecksum('2'.repeat(32)); f.tasks.get('100').state = f.State.COMPLETED;
    await f.attach('alice');
    assert.equal(f.queue.items[0].state, 'unknown');
    assert.equal(f.queue.items[0].canExport, false);
    assert.match(f.queue.items[0].errorText, /内容不符/);
    if (direction === 'upload') assert.equal(f.queue.items[0].canRetry, false);
    assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
    f.queue.detach();
  }
});

test('pending checksum resumes its original server task across restart and system-task expiry', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  f.queue.detach(); f.setChecksum('1'.repeat(32), false); f.tasks.get('100').state = f.State.COMPLETED;
  await f.attach('alice');
  assert.equal(f.queue.items[0].state, 'verifying');
  assert.equal(JSON.parse([...f.snapshots.values()][0]).records[0].checksumTaskId, 'checksum-1');
  f.queue.detach(); f.tasks.delete('100'); f.setChecksum(); await f.attach('alice');
  assert.equal(f.queue.items[0].state, 'completed');
  assert.equal(f.calls.filter(c => c.startsWith('checksum:')).length, 1);
  assert.equal(f.calls.filter(c => c === 'hash').length, 1);
  assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
  f.queue.detach();
});

test('an explicitly expired NAS checksum task is replaced without replaying the transfer', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  f.queue.detach(); f.setChecksum('1'.repeat(32), false); f.tasks.get('100').state = f.State.COMPLETED;
  await f.attach('alice');
  f.connector.startFileChecksum = async path => { f.calls.push(`checksum-new:${path}`); return 'checksum-2'; };
  f.connector.fileChecksumStatus = async id => {
    f.calls.push(`checksum-status:${id}`);
    if (id === 'checksum-1') throw protocol.dsmFailure('SYNO.FileStation.MD5', 599);
    return { finished: true, md5: '1'.repeat(32) };
  };
  f.queue.detach(); f.tasks.delete('100'); await f.attach('alice');
  assert.equal(f.queue.items[0].stateText, '上传内容已核验');
  assert.equal(f.calls.filter(c => c.startsWith('checksum-new:')).length, 1);
  assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
  assert.equal(JSON.parse([...f.snapshots.values()][0]).records[0].checksumTaskId, '');
  f.queue.detach();
});

test('a missing readonly checksum task does not prevent confirmed closure of an unknown upload', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  f.queue.detach(); f.setChecksum('1'.repeat(32), false); f.tasks.get('100').state = f.State.COMPLETED;
  await f.attach('alice');
  f.connector.fileChecksumStatus = async () => { throw protocol.dsmFailure('SYNO.FileStation.MD5', 407); };
  await f.queue.reconcile();
  assert.equal(f.queue.items[0].state, 'unknown');
  f.connector.stopFileChecksum = async () => { throw protocol.dsmFailure('SYNO.FileStation.MD5', 599); };
  await f.queue.closeUnknownUpload(f.queue.items[0].id);
  assert.equal(f.queue.items[0].state, 'closed');
  assert.equal(f.tasks.size, 0);
  assert.equal(JSON.parse([...f.snapshots.values()][0]).records[0].checksumTaskId, '');
  assert.equal(f.calls.filter(c => c.startsWith('create:')).length, 1);
  f.queue.detach();
});

test('checksum stop errors other than confirmed absence remain visible and keep the upload blocked', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]);
  f.queue.detach(); f.setChecksum('1'.repeat(32), false); f.tasks.get('100').state = f.State.COMPLETED;
  await f.attach('alice');
  f.connector.fileChecksumStatus = async () => { throw protocol.dsmFailure('SYNO.FileStation.MD5', 407); };
  await f.queue.reconcile();
  for (const error of [protocol.dsmFailure('SYNO.FileStation.MD5', 407),
    new protocol.NasFailure(protocol.NasErrorKind.Network, '网络故障', 599)]) {
    f.connector.stopFileChecksum = async () => { throw error; };
    await assert.rejects(() => f.queue.closeUnknownUpload(f.queue.items[0].id), error);
    assert.equal(f.queue.items[0].state, 'unknown');
    assert.equal(JSON.parse([...f.snapshots.values()][0]).records[0].checksumTaskId, 'checksum-1');
    await assert.rejects(() => f.queue.uploadSources('/share', [{ uri: 'selected', name: 'file.txt', bytes: 37 }]), /仍有写入/);
  }
  f.queue.detach();
});

test('download retry stops its pending NAS checksum before creating another system transfer', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.download({ path: '/share/中文.json', name: '中文.json', isDirectory: false });
  f.queue.detach(); f.setChecksum('1'.repeat(32), false); f.tasks.get('100').state = f.State.COMPLETED;
  await f.attach('alice');
  f.connector.fileChecksumStatus = async () => { throw new protocol.NasFailure(protocol.NasErrorKind.Network, '网络故障'); };
  await f.queue.reconcile();
  assert.equal(f.queue.items[0].canRetry, true);
  await f.queue.retry(f.queue.items[0].id);
  assert.ok(f.calls.indexOf('checksum-stop:checksum-1') < f.calls.indexOf('create:101'));
  assert.equal(f.queue.items[0].state, 'running');
  assert.equal(JSON.parse([...f.snapshots.values()][0]).records[0].checksumTaskId, '');
  f.queue.detach();
});

test('download recovery extracts persisted response headers without copying other extras into history', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.download({ path: '/share/中文.json', name: '中文.json', isDirectory: false });
  const [scope, json] = [...f.snapshots.entries()][0];
  const snapshot = JSON.parse(json); snapshot.records[0].httpStatus = 200;
  f.queue.detach(); f.snapshots.set(scope, JSON.stringify(snapshot));
  const task = f.tasks.get('100'); task.state = f.State.COMPLETED;
  // show 的 Progress.extras 由系统保存，采用原实现中的小写响应头映射。
  task.body = undefined;
  task.progressExtras = { 'content-type': 'text/html', 'content-disposition': "attachment; filename*=UTF-8''%E4%B8%AD%E6%96%87.json", 'set-cookie': 'PRIVATE-SID' };
  await f.attach('alice');
  assert.equal(f.queue.items[0].state, 'completed');
  const saved = f.snapshots.get(scope);
  assert.equal(JSON.parse(saved).records[0].attachmentName, '中文.json');
  assert.equal(saved.includes('set-cookie'), false);
  assert.equal(saved.includes('PRIVATE-SID'), false);
  f.queue.detach();
});

test('streamed checksum handles partial reads and zero-byte files with bounded memory', async () => {
  for (const bytes of [0, 700003]) {
    const input = Buffer.alloc(bytes, 0x51);
    let position = 0;
    let maxRead = 0;
    let checks = 0;
    const { hashTransferFile } = loadEts('features/transfers/TransferQueueFiles.ets', {
      '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {}, '@kit.CoreFileKit': { fileIo: {
        OpenMode: { READ_ONLY: 0 }, async open() { return { fd: 1 }; }, async close() {},
        async stat() { return { size: bytes, isDirectory: () => false }; },
        async read(fd, buffer, options) {
          maxRead = Math.max(maxRead, buffer.byteLength);
          const count = Math.min(options.length, 11001, bytes - position);
          new Uint8Array(buffer).set(input.subarray(position, position + count)); position += count; return count;
        },
      } }, '@kit.ArkTS': {}, '../../core/domain/DsmProtocol': protocol, '../../core/domain/TransferQueueState': state,
    });
    assert.equal(await hashTransferFile('/private/file', bytes, () => { checks++; }), crypto.createHash('md5').update(input).digest('hex'));
    assert.ok(maxRead <= 256 * 1024);
    assert.ok(checks > 0);
  }
});

test('ambiguous HTML or DSM-shaped JSON download needs exact content checksum when attachment evidence is absent', async () => {
  for (const prefix of ['<html>user file</html>', '{"success":false,"error":{"code":119}}']) {
    for (const sameContent of [false, true]) {
      const f = fixture(); await f.attach('alice');
      await f.queue.download({ path: '/share/中文.json', name: '中文.json', isDirectory: false });
      f.setDownloadPrefix(prefix); f.setChecksum(sameContent ? '1'.repeat(32) : '2'.repeat(32));
      const task = f.tasks.get('100');
      task.handlers.get('response')({ statusCode: 200, headers: new Map() });
      task.handlers.get('completed')({ state: f.State.COMPLETED, processed: 37 });
      await f.queue.tail;
      assert.equal(f.queue.items[0].state, sameContent ? 'completed' : 'failed');
      assert.equal(f.queue.items[0].canExport, sameContent);
      if (sameContent) assert.equal(f.queue.items[0].stateText, '下载内容已核验');
      f.queue.detach();
    }
  }
});

test('pending checksum uses fresh private contents after restart rather than a previously persisted digest', async () => {
  const f = fixture(); await f.attach('alice');
  await f.queue.download({ path: '/share/中文.json', name: '中文.json', isDirectory: false });
  f.queue.detach(); f.setChecksum('1'.repeat(32), false); f.tasks.get('100').state = f.State.COMPLETED;
  await f.attach('alice');
  const [scope, json] = [...f.snapshots.entries()][0];
  const snapshot = JSON.parse(json); snapshot.records[0].localMd5 = '1'.repeat(32);
  f.queue.detach(); f.snapshots.set(scope, JSON.stringify(snapshot));
  f.setLocalMd5('2'.repeat(32)); f.setChecksum(); await f.attach('alice');
  assert.equal(f.queue.items[0].state, 'unknown');
  assert.equal(f.queue.items[0].canExport, false);
  assert.match(f.queue.items[0].errorText, /内容不符/);
  assert.equal(f.calls.filter(c => c.startsWith('checksum:')).length, 1);
  f.queue.detach();
});
