const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdkRoot = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const drive = require('../../work/core-build/domain/DriveProtocol.js');
const state = require('../../work/core-build/domain/DriveTransferState.js');
const protocol = require('../../work/core-build/domain/DriveTransferProtocol.js');
const adapter = require('../../work/core-build/network/DriveTransferAdapter.js');
const transport = require('../../work/core-build/network/NasTransferTransport.js');
const { NasErrorKind: K, NasFailure } = dsm;
const clone = value => JSON.parse(JSON.stringify(value));
const folder = { fileId: '821014439470870977', name: '目录', kind: drive.DriveEntryKind.Folder, capabilities: { canRead: true, canWrite: true } };
const remoteFile = { fileId: '821014439470870978', name: '记录.txt', sizeBytes: 8, kind: drive.DriveEntryKind.File, capabilities: { canRead: true, canDownload: true } };
const State = { INITIALIZED: 0, WAITING: 16, RUNNING: 32, RETRYING: 33, PAUSED: 48, STOPPED: 49, COMPLETED: 64, FAILED: 65, REMOVED: 80 };

function fixture(options = {}) {
  const events = [], history = new Map(), tasks = new Map(), files = new Map(), descriptors = new Map(), failures = [];
  let uuid = 1, fd = 1, taskCounter = 1, reads = 0;
  files.set('file://selected', { bytes: Buffer.from('abcdefgh'), mtime: 1720000000 });
  const fileIo = {
    OpenMode: { READ_ONLY: 1, READ_WRITE: 2, CREATE: 4, TRUNC: 8 },
    async open(file, mode) {
      if (mode & 4) files.set(file, { bytes: Buffer.alloc(0), mtime: 1720000000 });
      if (!files.has(file)) throw Object.assign(new Error('missing file'), { code: 13900002 });
      const descriptor = fd++; descriptors.set(descriptor, { path: file, position: 0 }); return { fd: descriptor };
    },
    async stat(file) { const value = files.get(typeof file === 'number' ? descriptors.get(file).path : file); if (!value) throw Object.assign(new Error('missing'), { code: 13900002 });
      return { isFile: () => true, isDirectory: () => false, size: value.bytes.length, mtime: value.mtime }; },
    async read(id, buffer, option = {}) {
      const desc = descriptors.get(id), file = files.get(desc.path); desc.position += option.offset || 0;
      const count = Math.min(option.length ?? buffer.byteLength, file.bytes.length - desc.position);
      new Uint8Array(buffer).set(file.bytes.subarray(desc.position, desc.position + count)); desc.position += count; return count;
    },
    async write(id, buffer) { const desc = descriptors.get(id), file = files.get(desc.path); file.bytes = Buffer.concat([file.bytes, Buffer.from(buffer)]); return buffer.byteLength; },
    async fsync() {}, async rmdir(dir) { events.push(['rmdir', dir]); for (const name of files.keys()) { if (name.startsWith(dir + '/')) files.delete(name); } }, async close() {}
  };
  class Store {
    get identity() { return 'scope-' + this.account; }
    async load(context, origin, account) { this.account = account; this.directory = '/private/' + account; return clone(history.get(account) || options.records || []); }
    async save(records) { events.push(['save', clone(records)]); if (options.saveFailure?.(records)) throw new NasFailure(K.Protocol, '保存失败'); history.set(this.account, clone(records)); }
  }
  const sdk = {
    requireCapability() {},
    async create(context, config) {
      events.push(['create', clone(config)]); const id = String(taskCounter++);
      const task = { tid: id, config, state: State.INITIALIZED, handlers: {}, extras: undefined };
      tasks.set(id, task); if (options.createThrows) throw new NasFailure(K.Protocol, 'create result lost'); return task;
    },
    async show(id) { const task = tasks.get(id); if (!task) throw Object.assign(new Error('missing task'), { code: 21900006 });
      return { extras: task.config.extras, progress: { state: task.state, processed: 8, sizes: [8], extras: task.extras } }; },
    async search(filter) {
      events.push(['search', clone(filter)]);
      if (options.searchFailure) throw new NasFailure(K.Protocol, 'query failed');
      const after = filter.after ?? Date.now() - 86400000;
      return [...tasks.values()].filter(task => (task.createdAt ?? Date.now()) >= after).map(task => task.tid);
    },
    async getTask(context, id) { if (!tasks.has(id)) throw Object.assign(new Error('missing task'), { code: 21900006 }); return tasks.get(id); },
    async start(task) { events.push(['start', task.tid]); task.state = State.RUNNING; },
    async remove(id) { events.push(['remove', id]); if (options.removeFailure) throw new NasFailure(K.Protocol, 'stop failed'); tasks.delete(id); },
    async pause(task) { events.push(['pause', task.tid]); task.state = State.PAUSED; },
    async resume(task) { events.push(['resume-system', task.tid]); task.state = State.RUNNING; },
    observe(task, handlers) { task.handlers = handlers; return () => { events.push(['dispose', task.tid]); }; }
  };
  const filesPort = {
    async ensureTransferDirectory() {},
    async removeTransferFile(file) { files.delete(file); },
    async copyTransferFile(source, destination, bytes, current) { current(); const file = files.get(source); assert.equal(file.bytes.length, bytes); files.set(destination, { bytes: Buffer.from(file.bytes), mtime: file.mtime }); current(); },
    async hashTransferFile(file, bytes, current) { current(); assert.equal(files.get(file).bytes.length, bytes); return options.changedHash ? 'b'.repeat(32) : require('node:crypto').createHash('md5').update(files.get(file).bytes).digest('hex'); },
    async readTransferPrefix(file) { return { text: files.get(file).bytes.toString(), wholeFile: true }; }
  };
  const mocks = {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': { request: { agent: { State, Action: { UPLOAD: 1, DOWNLOAD: 0 }, Mode: { BACKGROUND: 0 } } } },
    '@kit.CoreFileKit': { fileIo, fileUri: { FileUri: class { name = '记录.txt'; } }, picker: {
      DocumentSelectOptions: class {}, DocumentSaveOptions: class {}, DocumentViewPicker: class { async select() { return ['file://selected']; } async save() { return ['file://export']; } } } },
    '@kit.ArkTS': { util: { generateRandomUUID: () => `11111111-1111-4111-8111-${String(uuid++).padStart(12, '0')}` } },
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
    '../../core/domain/DsmProtocol': dsm, '../../core/domain/DriveProtocol': drive, '../../core/domain/DriveTransferState': state,
    '../../core/domain/DriveTransferProtocol': protocol, '../../core/network/DriveTransferAdapter': adapter,
    '../../core/network/NasTransferTransport': transport, '../../core/network/NasConnector': {},
    '../../platform/SdkTransferAgent': { sdkTransferAgent: sdk },
    '../../platform/SdkBackgroundTransfer': { SdkBackgroundTransfer: class {
      static available() { return options.appBackground === true; }
      active = false;
      async start(context, title, interrupted) {
        events.push(['background-start']);
        if (options.backgroundFailure) throw new NasFailure(K.Unsupported, 'background denied');
        this.interrupted = interrupted; this.active = true;
      }
      check() { if (options.networkDenied) throw new NasFailure(K.Cancelled, 'network changed'); }
      progress() { this.check(); }
      async stop() { if (this.active) events.push(['background-stop']); this.active = false; }
    } },
    '../../platform/SdkTransferNetwork': { SdkTransferNetwork: class {
      async start(onLost) { this.onLost = onLost; if (options.networkDenied) throw new NasFailure(K.Cancelled, 'network changed'); }
      check() { if (options.networkDenied) throw new NasFailure(K.Cancelled, 'network changed'); }
      async stop() {}
    } },
    '../../platform/SdkFileIO': { async closeFile() {}, async writePrivateSnapshot(file, bytes) { files.set(file, { bytes: Buffer.from(bytes), mtime: 1720000000 }); } },
    '../transfers/TransferQueueFiles': filesPort, './DriveTransferStore': { DriveTransferStore: Store }
  };
  function load(name) {
    const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/drive/' + name + '.ets'), 'utf8').replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
    const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
    assert.equal((output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
    const mod = { exports: {} };
    vm.runInNewContext(output.outputText, { module: mod, exports: mod.exports, Date, canIUse: () => true, setInterval: () => 1, clearInterval() {},
      require(id) { assert.ok(Object.hasOwn(mocks, id), id); return mocks[id]; } }); return mod.exports;
  }
  mocks['./DriveBackgroundTransfer'] = load('DriveBackgroundTransfer');
  mocks['./DriveUploadSlice'] = load('DriveUploadSlice');
  mocks['./DriveDownloadVerification'] = load('DriveDownloadVerification');
  const model = new (load('DriveTransferModel').DriveTransferModel)();
  const origin = options.origin || 'https://nas.example.test:5001';
  const plan = (input, method) => ({ address: origin + '/webapi/entry.cgi', method,
    fields: [{ name: 'api', content: drive.DRIVE_FILES_API }, { name: 'method', content: method === 'POST' ? 'upload' : 'download' },
      ... (method === 'POST' ? protocol.driveUploadFields(input) : protocol.driveDownloadFields(input))], session: { sid: 'test-sid', synoToken: 'test-token' } });
  const kernel = {
    supportsDriveApi: () => true,
    async requestDrive(api, version, method) {
      events.push(['read-entry', api, version, method]); reads++;
      if (options.readEntry) return options.readEntry(reads);
      return { file_id: remoteFile.fileId, name: remoteFile.name, type: 'file', size: 8, version_id: '1',
        capabilities: { can_read: true, can_download: true } };
    },
    driveUploadPlan(input, token) { events.push(['upload-plan', clone(input), token]); const value = plan(input, 'POST'); if (token) value.headers = protocol.driveSliceHeaders(token, true); return value; },
    driveDownloadPlan(input) { return plan(input, 'GET'); },
    async probeDriveUpload(input, token, source, total, started) { events.push(['probe', token, clone(source), total, started]); const data = options.probe || { uploaded_size: started ? 3 : 0, tmp_newly_created: !started };
      return protocol.decodeDriveSliceProbe(200, JSON.stringify({ success: true, data }), total, started); },
    async uploadDriveSlice(input, token, source, total, control) { events.push(['slice', token, clone(source), total]);
      control.checkNetwork?.(); if (options.slice) await options.slice(control);
      if (options.sliceFailure) throw new NasFailure(K.Network, 'interrupted'); control.cancellation.check(); return { uploadedBytes: total }; },
    async uploadDrive(input, source, control) { events.push(['foreground-upload', clone(input)]);
      control.checkNetwork?.(); if (options.upload) await options.upload(control); control.cancellation.check(); return { uploadedBytes: source.bytes }; },
    async downloadDrive(input, target, control) { events.push(['foreground-download']); control.checkNetwork?.();
      if (options.download) await options.download(control);
      files.set(target.directory + '/content', { bytes: Buffer.from(options.remoteContent || 'abcdefgh'), mtime: 1 });
      control.cancellation.check(); return { path: target.directory + '/content', bytes: 8 }; }
  };
  const attach = (account = 'alice', insecureTls = false) => model.attach({ filesDir: '/private' }, kernel, origin, account,
    async error => { failures.push(error); if (options.onFailure) await options.onFailure(model); }, () => true, insecureTls);
  const upload = async (conflict = 'version') => { await model.prepareUpload(folder); model.conflict = conflict; await model.upload(); };
  const settle = async () => { await Promise.resolve(); await model.tail; await Promise.resolve(); await model.tail; };
  const complete = async (task, body, status = 200) => {
    task.state = State.COMPLETED; task.extras = body === undefined ? undefined : { body };
    task.handlers.response?.({ statusCode: status, headers: new Map([['content-length', ['8']]]) });
    task.handlers.completed?.({ state: State.COMPLETED, processed: 8, sizes: [8], extras: task.extras }); await settle();
  };
  return { model, events, history, files, tasks, failures, attach, upload, settle, complete, kernel, options };
}

test('background POST multipart keeps credentials out of records, persists ID and start intent before start', async () => {
  const f = fixture(); await f.attach(); await f.upload();
  const config = f.events.find(e => e[0] === 'create')[1];
  assert.equal(config.method, 'POST'); assert.equal(config.mode, 0); assert.equal(config.retry, false); assert.equal(config.redirect, false);
  assert.equal(config.headers.Cookie, 'id=test-sid'); assert.equal(config.headers['X-SYNO-TOKEN'], 'test-token');
  assert.equal(config.headers['X-TYPE-NAME'], 'SLICEUPLOAD'); assert.equal(config.begins, 0); assert.equal(config.ends, -1);
  assert.equal(config.data.at(-1).name, 'file');
  const startedIndex = f.events.findIndex(e => e[0] === 'start');
  const saved = f.events.slice(0, startedIndex).filter(e => e[0] === 'save').at(-1)[1][0];
  assert.equal(saved.background.taskId, '1'); assert.equal(saved.background.startAttempted, true);
  assert.equal(saved.uploadSession.started, true); assert.doesNotMatch(JSON.stringify(saved), /test-sid|test-token|Cookie/);
  f.model.setForeground(false); assert.equal(f.tasks.size, 1); assert.equal(f.model.items[0].state, 'running');
});

test('task ID persistence failure never starts; marker adoption does not automatically dispatch', async () => {
  const f = fixture({ saveFailure: records => records[0]?.background?.taskId === '1' }); await f.attach(); await f.upload();
  assert.equal(f.events.some(e => e[0] === 'start'), false); assert.equal(f.tasks.size, 0); assert.equal(f.model.ready, false);
  const g = fixture({ createThrows: true }); await g.attach(); await g.upload(); assert.equal(g.tasks.size, 1);
  await g.model.refresh(); assert.equal(g.model.items[0].state, 'paused', g.model.errorText); assert.equal(g.events.some(e => e[0] === 'start'), false);
  g.options.createThrows = false; await g.model.resume(g.model.items[0].id); assert.equal(g.events.filter(e => e[0] === 'create').length, 1);
  assert.equal(g.events.filter(e => e[0] === 'start').length, 1);
});

test('COMPLETED without the full Drive receipt stays unknown even when every byte is sent', async () => {
  const f = fixture(); await f.attach(); await f.upload(); const task = [...f.tasks.values()][0];
  await f.complete(task, undefined); assert.equal(f.model.items[0].state, 'unknown', f.model.errorText); assert.equal(f.tasks.size, 1);
  assert.equal(f.files.has('/private/alice/' + f.model.items[0].id + '/upload'), true);
  await f.complete(task, JSON.stringify({ success: true, data: { uploaded_size: 8 } }));
  assert.equal(f.model.items[0].state, 'completed'); assert.equal(f.tasks.size, 0);
});

test('process restoration rebinds the original system task without recreating or replaying uploads', async () => {
  const f = fixture(); await f.attach(); await f.upload(); const id = f.model.items[0].id;
  const count = f.events.filter(e => e[0] === 'create' || e[0] === 'start' || e[0] === 'probe').length;
  f.model.detach(); await f.attach(); assert.equal(f.model.ready, true, f.model.errorText); assert.equal(f.model.items[0].id, id); assert.equal(f.model.items[0].state, 'running');
  assert.equal(f.events.filter(e => e[0] === 'create' || e[0] === 'start' || e[0] === 'probe').length, count);
  await f.attach(); assert.equal(f.model.items[0].state, 'running');
  assert.equal(f.events.filter(e => e[0] === 'create' || e[0] === 'start' || e[0] === 'probe').length, count);
});

test('waiting system tasks remain pending across restoration and can be stopped without replay', async () => {
  const f = fixture(); await f.attach(); await f.upload(); const task = [...f.tasks.values()][0];
  assert.equal(task.config.metered, false); assert.equal(task.config.roaming, false);
  task.state = State.WAITING;
  await f.model.refresh(); assert.equal(f.model.items[0].state, 'waiting');
  assert.equal(f.model.hasPending, true); assert.equal(f.model.hasActive, true);
  assert.equal(state.driveTransferStateText(f.model.items[0].state), '等待执行');
  const saved = f.history.get('alice');
  assert.equal(state.decodeDriveTransfers(JSON.stringify({ version: 1, scope: 'scope-alice', records: saved }),
    'scope-alice', 'https://nas.example.test:5001', 'alice')[0].state, 'waiting');
  const count = f.events.filter(e => ['create', 'start', 'probe'].includes(e[0])).length;
  f.model.detach(); await f.attach(); assert.equal(f.model.items[0].state, 'waiting');
  assert.equal(f.events.filter(e => ['create', 'start', 'probe'].includes(e[0])).length, count);
  await f.model.remove(f.model.items[0].id); assert.equal(f.model.items.length, 1); assert.equal(f.tasks.size, 1);
  await f.model.cancelTask(f.model.items[0].id); assert.equal(f.tasks.size, 0); assert.equal(f.model.items[0].state, 'unknown');
});

test('account switches require stopping old tasks, and old callbacks cannot mutate the new account', async () => {
  const f = fixture(); await f.attach(); await f.upload(); const task = [...f.tasks.values()][0];
  await assert.rejects(f.attach('bob'), /停止原账号/); assert.equal(f.tasks.size, 1);
  await f.model.stopAll(); assert.equal(f.tasks.size, 0); await f.attach('bob');
  task.handlers.completed({ state: State.COMPLETED, processed: 8, extras: { body: '{"success":true,"data":{"uploaded_size":8}}' } }); await f.settle();
  assert.equal(f.model.items.length, 0); assert.equal(f.history.get('alice')[0].state, 'unknown');
});

test('stop failure is propagated so connection owner can block logout', async () => {
  const f = fixture(); await f.attach(); await f.upload(); f.options.removeFailure = true;
  await assert.rejects(f.model.stopAll(), /stop failed/); assert.equal(f.tasks.size, 1);
});

test('session expiry notification runs outside the task tail so account cleanup can await stopAll', async () => {
  let notify; const notified = new Promise(resolve => { notify = resolve; });
  const f = fixture({ onFailure: async model => { await model.stopAll(); notify(); } }); await f.attach(); await f.upload();
  await f.complete([...f.tasks.values()][0], '{"success":false,"error":{"code":119}}');
  let timer;
  try { await Promise.race([notified, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('expiry cleanup deadlocked')), 1000); })]); }
  finally { clearTimeout(timer); }
  assert.equal(f.tasks.size, 0); assert.equal(f.model.items[0].state, 'unknown'); assert.equal(f.failures.length, 1);
});

test('ignored HTTPS certificate uses foreground rcp, while HTTP remains eligible for background', async () => {
  const f = fixture(); await f.attach('alice', true); assert.equal(f.model.backgroundAvailable, false);
  await f.upload('autorename'); await f.model.download(remoteFile); assert.equal(f.events.some(e => e[0] === 'create'), false);
  assert.equal(f.events.some(e => e[0] === 'foreground-upload'), true); assert.equal(f.events.some(e => e[0] === 'foreground-download'), true);
  const g = fixture({ origin: 'http://nas.example.test:5000' }); await g.attach('alice', true); await g.upload();
  assert.equal(g.model.backgroundAvailable, true); assert.equal(g.events.some(e => e[0] === 'create'), true);
});

test('a process restart cannot switch accounts while a different scope still has an active system task', async () => {
  const f = fixture(); await f.attach(); await f.upload(); f.model.detach();
  await f.attach('bob', true); assert.equal(f.model.ready, false); assert.match(f.model.errorText, /原账号仍有/);
  await f.model.download(remoteFile); assert.equal(f.events.some(e => e[0] === 'foreground-download'), false);
  await f.attach('alice'); assert.equal(f.model.ready, true); await f.model.stopAll(); await f.attach('bob'); assert.equal(f.model.ready, true);
});

test('pause and explicit continue replace upload task with same token and remaining range only', async () => {
  const f = fixture(); await f.attach(); await f.upload(); const record = f.model.items[0], token = record.uploadSession.token;
  await f.model.pause(record.id); assert.equal(f.model.items[0].state, 'paused'); assert.equal(f.tasks.size, 0);
  await f.model.resume(record.id); const config = f.events.filter(e => e[0] === 'create').at(-1)[1];
  assert.equal(config.begins, 3); assert.equal(config.headers['X-TMP-FILE'], token); assert.equal(config.headers['X-FILE-CHUNK-END'], 'true');
  assert.equal(f.events.filter(e => e[0] === 'resume-system').length, 0); assert.equal(f.model.items[0].uploadSession.offset, 3);
});

test('expired token, complete-offset ambiguity and changed source never create a replacement upload', async () => {
  for (const changes of [{ probe: { uploaded_size: 0, tmp_newly_created: true } }, { probe: { uploaded_size: 8, tmp_newly_created: false } },
    { probe: { uploaded_size: 9, tmp_newly_created: false } }, { changedHash: true }]) {
    const f = fixture(); await f.attach(); await f.upload(); const record = f.model.items[0]; await f.model.pause(record.id);
    Object.assign(f.options, changes); await f.model.resume(record.id);
    assert.equal(f.model.items[0].state, 'unknown'); assert.equal(f.tasks.size, 0); assert.equal(f.events.filter(e => e[0] === 'create').length, 1);
    assert.equal(f.model.items[0].uploadSession.token, record.uploadSession.token);
  }
});

test('foreground continuation physically copies and uploads only the remaining bytes', async () => {
  const f = fixture({ sliceFailure: true }); await f.attach('alice', true); await f.upload(); assert.equal(f.model.items[0].state, 'unknown');
  const record = f.model.items[0], token = record.uploadSession.token; f.options.sliceFailure = false;
  await f.model.resume(record.id); const call = f.events.filter(e => e[0] === 'slice').at(-1);
  assert.equal(call[1], token); assert.equal(call[2].bytes, 5); assert.equal(call[3], 8);
  assert.equal(f.files.get(call[2].path).bytes.toString(), 'defgh'); assert.equal(f.model.items[0].state, 'completed');
});

test('moving a paused upload to foreground preserves the same token and recovers a lost final response as unknown', async () => {
  const f = fixture(); await f.attach(); await f.upload(); const record = f.model.items[0];
  await f.model.pause(record.id); f.model.useBackground = false; f.options.sliceFailure = true; await f.model.resume(record.id);
  assert.equal(f.model.items[0].background, undefined); assert.equal(f.model.items[0].uploadSession.token, record.uploadSession.token);
  assert.equal(f.model.items[0].state, 'unknown'); f.model.detach(); await f.attach(); assert.equal(f.model.items[0].state, 'unknown');
  assert.equal(f.events.filter(e => e[0] === 'create').length, 1);
});

test('background GET downloads validate HTTP, byte count and error envelope before allowing export', async () => {
  for (const content of ['abcdefgh', '{"success":false,"error":{"code":119}}', 'short']) {
    const f = fixture(); await f.attach(); await f.model.download(remoteFile); const record = f.model.items[0], task = [...f.tasks.values()][0];
    assert.equal(task.config.method, 'GET'); assert.match(task.config.url, /\?api=/); assert.equal(task.config.data, undefined);
    f.files.set(task.config.saveas, { bytes: Buffer.from(content), mtime: 1 });
    await f.complete(task, undefined); assert.equal(f.model.items[0].state, content === 'abcdefgh' ? 'completed' : 'failed', f.model.errorText);
    if (content === 'abcdefgh') { await f.model.exportDownload(record.id); assert.equal(f.files.get('file://export').bytes.toString(), content); }
  }
});

test('downloads reject pause/resume and legacy paused downloads remain cancellable', async () => {
  const f = fixture(); await f.attach(); await f.model.download(remoteFile); const record = f.model.items[0];
  await f.model.pause(record.id); assert.equal(f.events.some(e => e[0] === 'pause'), false);
  const task = [...f.tasks.values()][0]; task.state = State.PAUSED; await f.model.refresh();
  assert.equal(f.model.items[0].state, 'paused'); await f.model.resume(record.id);
  assert.equal(f.events.some(e => e[0] === 'resume-system'), false); assert.match(f.model.errorText, /不支持下载续传/);
  await f.model.cancelTask(record.id); assert.equal(f.tasks.size, 0); assert.equal(f.model.items[0].state, 'cancelled');
  const g = fixture(); await g.attach(); await g.upload('autorename'); await g.model.cancelTask(g.model.items[0].id);
  await g.model.resume(g.model.items[0].id); assert.equal(g.events.filter(e => e[0] === 'create').length, 1);
});

const gate = () => { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; };

test('account guard includes tasks older than 24 hours, and blocked account can exit without removing foreign tasks', async () => {
  const f = fixture(); await f.attach(); await f.upload(); const task = [...f.tasks.values()][0];
  task.createdAt = Date.now() - 25 * 3600000; task.state = State.WAITING;
  f.model.detach(); await f.attach('bob'); assert.equal(f.model.ready, false); assert.match(f.model.errorText, /原账号仍有/);
  assert.ok(f.events.some(e => e[0] === 'search' && e[1].after === 0));
  await f.model.stopAll(); assert.equal(f.tasks.size, 1);
  await f.attach('alice'); await f.model.stopAll(); assert.equal(f.tasks.size, 0);
});

test('background completion without response callbacks preserves file for explicit full-content verification', async () => {
  const f = fixture(); await f.attach(); await f.model.download(remoteFile); const id = f.model.items[0].id, task = [...f.tasks.values()][0];
  f.model.detach(); task.state = State.COMPLETED; task.extras = { 'content-length': '8', 'content-type': 'text/plain' };
  f.files.set(task.config.saveas, { bytes: Buffer.from('abcdefgh'), mtime: 1 });
  await f.attach(); assert.equal(f.model.items[0].state, 'verifying'); assert.equal(f.model.items[0].systemCompleted, true);
  assert.equal(f.model.items[0].background.httpStatus, 0); assert.equal(f.model.hasPending, true);
  assert.equal(f.events.some(e => e[0] === 'foreground-download'), false);
  await f.model.exportDownload(id); assert.equal(f.files.has('file://export'), false);
  f.model.detach(); await f.attach(); assert.equal(f.model.items[0].state, 'verifying');
  await f.model.verifyDownload(id); assert.equal(f.model.items[0].state, 'completed', f.model.errorText);
  assert.match(f.model.items[0].verifiedMd5, /^[0-9a-f]{32}$/); assert.equal(f.tasks.size, 0);
  assert.equal(f.events.filter(e => e[0] === 'foreground-download').length, 1);
  assert.equal(f.events.filter(e => e[0] === 'read-entry').length, 2);
  await f.model.exportDownload(id); assert.equal(f.files.get('file://export').bytes.toString(), 'abcdefgh');
  f.files.set('/private/alice/' + id + '/content', { bytes: Buffer.from('changed!'), mtime: 2 });
  await f.model.exportDownload(id); assert.match(f.model.errorText, /发生变化/);
});

test('legacy 206 completion requires full-file verification instead of comparing the final part length to total', async () => {
  const f = fixture(); await f.attach(); await f.model.download(remoteFile); const task = [...f.tasks.values()][0], id = f.model.items[0].id;
  f.files.set(task.config.saveas, { bytes: Buffer.from('abcdefgh'), mtime: 1 });
  task.state = State.COMPLETED;
  task.handlers.response({ statusCode: 206, headers: new Map([['content-length', ['5']], ['content-range', ['bytes 3-7/8']]]) });
  task.handlers.completed({ state: State.COMPLETED, processed: 8, sizes: [8] }); await f.settle();
  assert.equal(f.model.items[0].state, 'verifying'); await f.model.verifyDownload(id);
  assert.equal(f.model.items[0].state, 'completed', f.model.errorText);
});

test('verification rejects same-size wrong content, changed metadata and metered network without exporting', async () => {
  for (const changes of [{ remoteContent: 'ABCDEFGH' }, { networkDenied: true }, { readEntry: () => ({ file_id: remoteFile.fileId,
    name: remoteFile.name, type: 'file', size: 8, capabilities: { can_read: false, can_download: false } }) }]) {
    const f = fixture(); await f.attach(); await f.model.download(remoteFile); const task = [...f.tasks.values()][0], id = f.model.items[0].id;
    f.model.detach(); task.state = State.COMPLETED; f.files.set(task.config.saveas, { bytes: Buffer.from('abcdefgh'), mtime: 1 });
    await f.attach(); Object.assign(f.options, changes); await f.model.verifyDownload(id);
    assert.equal(f.model.items[0].state, 'verifying'); assert.equal(f.model.items[0].verifiedMd5, undefined);
    assert.notEqual(f.model.errorText, ''); assert.equal(f.files.get(task.config.saveas).bytes.toString(), 'abcdefgh');
    if (changes.networkDenied) assert.equal(f.events.some(e => e[0] === 'foreground-download'), false);
  }
});

test('ignored-certificate HTTPS uses a continuous RCP task and survives foreground loss for upload and download', async () => {
  for (const direction of ['upload', 'download']) {
    const started = gate(), release = gate();
    const f = fixture({ appBackground: true, [direction]: async control => {
      assert.equal(control.background, true); started.resolve(control); await release.promise;
    } });
    await f.attach('alice', true); assert.equal(f.model.backgroundAvailable, true); assert.equal(f.model.applicationBackground, true);
    const pending = direction === 'upload' ? f.upload('autorename') : f.model.download(remoteFile);
    const control = await started.promise; f.model.setForeground(false);
    assert.equal(control.cancellation.cancelled, false); release.resolve(); await pending;
    assert.equal(f.model.items[0].state, 'completed', f.model.errorText); assert.equal(f.model.items[0].executor, 'rcpBackground');
    assert.equal(f.events.some(e => e[0] === 'create'), false);
    assert.deepEqual(f.events.filter(e => e[0].startsWith('background-')).map(e => e[0]), ['background-start', 'background-stop']);
  }
});

test('continuous-task acquisition failure sends neither upload nor download and does not silently fall back', async () => {
  const f = fixture({ appBackground: true, backgroundFailure: true }); await f.attach('alice', true);
  await f.upload('autorename'); assert.equal(f.events.some(e => e[0] === 'foreground-upload'), false);
  assert.equal(f.model.items[0].state, 'failed');
  await f.model.download(remoteFile); assert.equal(f.events.some(e => e[0] === 'foreground-download'), false);
  assert.equal(f.events.some(e => e[0] === 'create'), false);
});

test('continuous RCP version upload pauses without deadlock and resumes using the same token and only remaining bytes', async () => {
  const started = gate(), release = gate();
  const f = fixture({ appBackground: true, slice: async control => { started.resolve(control); await release.promise; } });
  await f.attach('alice', true); const pending = f.upload(); await started.promise;
  const id = f.model.items[0].id, token = f.model.items[0].uploadSession.token;
  const paused = f.model.pause(id); release.resolve(); await Promise.all([pending, paused]);
  assert.equal(f.model.items[0].state, 'paused', f.model.errorText); assert.equal(f.model.busy, false);
  f.options.slice = undefined; await f.model.resume(id);
  assert.equal(f.model.items[0].state, 'completed', f.model.errorText);
  const call = f.events.filter(e => e[0] === 'slice').at(-1);
  assert.equal(call[1], token); assert.equal(call[2].bytes, 5); assert.equal(f.files.get(call[2].path).bytes.toString(), 'defgh');
});

test('system cancellation or network loss interrupts continuous RCP without replaying an upload', async () => {
  const started = gate(), release = gate();
  const f = fixture({ appBackground: true, upload: async control => { started.resolve(control); await release.promise; } });
  await f.attach('alice', true); const pending = f.upload('autorename'); const control = await started.promise;
  f.model.lease.interrupted(); assert.equal(control.cancellation.cancelled, true); release.resolve(); await pending;
  assert.equal(f.model.items[0].state, 'unknown'); assert.equal(f.events.filter(e => e[0] === 'foreground-upload').length, 1);
  assert.equal(f.model.lease.active, false);
});
