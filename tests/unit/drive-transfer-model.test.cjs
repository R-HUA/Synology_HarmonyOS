const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const drive = require('../../work/core-build/domain/DriveProtocol.js');
const state = require('../../work/core-build/domain/DriveTransferState.js');
const transport = require('../../work/core-build/network/NasTransferTransport.js');
const adapter = require('../../work/core-build/network/DriveTransferAdapter.js');
const { NasFailure, NasErrorKind: K } = dsm;
const gate = () => { let resolve; const promise = new Promise(r => resolve = r); return { resolve, promise }; };
const clone = value => JSON.parse(JSON.stringify(value));
const folder = () => ({ fileId: '821014439470870977', name: '测试目录', kind: drive.DriveEntryKind.Folder,
  capabilities: { canRead: true, canWrite: true } });
const file = sizeBytes => ({ fileId: '821014439470870978', name: '记录.txt', sizeBytes, kind: drive.DriveEntryKind.File,
  capabilities: { canRead: true, canDownload: true } });

function fixture(options = {}) {
  const events = [], history = new Map(), sessions = [], failures = [];
  let counter = 1, saves = 0;
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/drive/DriveTransferModel.ets'), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  class Store {
    async load(context, origin, account) {
      this.key = account; this.directory = '/private/' + account;
      return clone(history.get(account) || options.records || []);
    }
    async save(records) {
      events.push(['save', clone(records)]); saves++;
      if (options.saveFailure?.(saves, records)) throw new NasFailure(K.Protocol, '保存失败');
      history.set(this.key, clone(records));
    }
  }
  const mocks = {
    '@kit.PreviewKit': { filePreview: {
      async canPreview(_context, uri) { events.push(['can-preview', uri]); return options.previewSupported !== false; },
      async openPreview(_context, info) { events.push(['preview', clone(info)]); if (options.previewFailure) throw options.previewFailure; }
    } },
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {},
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {} } },
    '@kit.ArkTS': { util: { generateRandomUUID: () => `11111111-1111-4111-8111-${String(counter++).padStart(12, '0')}` } },
    '@kit.CoreFileKit': {
      picker: { DocumentSelectOptions: class {}, DocumentSaveOptions: class {}, DocumentViewPicker: class {
        async select(option) { events.push(['select', option.maxSelectNumber]); return options.select ? options.select() : ['file://selected']; }
        async save(option) { events.push(['save-picker', option.newFileNames]); return options.saveUris || ['file://export']; }
      } },
      fileUri: { FileUri: class { name = options.filename || '记录.txt'; }, getUriFromPath: path => 'file://' + path },
      fileIo: { OpenMode: { READ_ONLY: 1 }, async open() { return { fd: 1 }; },
        async stat() { return { isFile: () => true, size: options.bytes ?? 3, mtime: 1720000000 }; },
        async rmdir(dir) { events.push(['rmdir', dir]); } }
    },
    '../../core/domain/DsmProtocol': dsm, '../../core/domain/DriveProtocol': drive,
    '../../core/domain/DriveTransferState': state, '../../core/network/DriveTransferAdapter': adapter,
    '../../core/network/NasConnector': {}, '../../core/network/NasTransferTransport': transport,
    '../../platform/SdkFileIO': { async closeFile() {} }, './DriveTransferStore': { DriveTransferStore: Store },
    './DriveBackgroundTransfer': { DriveBackgroundTransfer: class {} },
    '../../platform/SdkBackgroundTransfer': { SdkBackgroundTransfer: class { static available() { return false; } async stop() {} active = false; } },
    './DriveDownloadVerification': { async verifyDriveDownloadedFile() { throw new Error('unexpected verification'); } },
    './DriveUploadSlice': { async copyDriveUploadRemainder() {} },
    '../transfers/TransferQueueFiles': {
      async ensureTransferDirectory(dir) { events.push(['mkdir', dir]); },
      async removeTransferFile(file) { events.push(['unlink', file]); },
      async copyTransferFile(source, destination, bytes, current, exporting) {
        events.push(['copy', source, destination, bytes, exporting]); current();
        if (options.copyFailure) throw new Error('copy failed');
        if (options.copy) await options.copy();
        current();
      }
    }
  };
  const mod = { exports: {} };
  vm.runInNewContext(output.outputText, { module: mod, exports: mod.exports,
    canIUse: () => true,
    require(id) { assert.ok(Object.hasOwn(mocks, id), id); return mocks[id]; } });
  const model = new mod.exports.DriveTransferModel();
  const kernel = {
    supportsDriveApi: () => options.supported !== false,
    async uploadDrive(request, source, control) {
      events.push(['upload', clone(request), clone(source)]); sessions.push(control);
      control.cancellation.check();
      if (options.upload) await options.upload(request, source, control);
      control.cancellation.check();
      return { uploadedBytes: source.bytes };
    },
    async downloadDrive(request, target, control) {
      events.push(['download', clone(request), clone(target)]); sessions.push(control);
      if (options.download) await options.download(request, target, control);
      control.cancellation.check();
      return { path: target.directory + '/content', bytes: target.expectedBytes ?? 9 };
    }
  };
  const attach = account => model.attach({ filesDir: '/private' }, kernel, 'https://nas.example.test:5001', account,
    async error => failures.push(error), () => options.canStart !== false);
  return { model, events, history, sessions, failures, attach };
}

test('pending writes block uploads while unrelated downloads remain available', async () => {
  const options = { canStart: false }; const f = fixture(options); await f.attach('alice');
  await f.model.prepareUpload(folder()); await f.model.download(file(3));
  assert.ok(f.events.some(e => e[0] === 'download'));
  options.canStart = true; await f.model.prepareUpload(folder());
  assert.ok(f.model.draft); options.canStart = false; await f.model.upload();
  assert.equal(f.events.some(e => e[0] === 'upload'), false); assert.equal(f.model.items.length, 1);
});

test('file preview starts only after completed download and provides a named application URI', async () => {
  const f = fixture(); await f.attach('alice');
  assert.equal(f.model.canPreview(file(3)), true);
  assert.equal(f.model.canPreview({ ...file(3), name: '安装包.apk' }), false);
  await f.model.download(file(3), true);
  assert.equal(f.model.items[0].state, 'completed');
  assert.equal(f.model.items[0].executor, 'foreground');
  const preview = f.events.find(event => event[0] === 'preview');
  assert.ok(preview); assert.match(preview[1].uri, /记录\.txt$/);
  assert.equal(preview[1].title, '记录.txt');
  const saved = f.events.findIndex(event => event[0] === 'save' && event[1][0]?.state === 'completed');
  assert.ok(saved < f.events.indexOf(preview));
});

test('a cancelled file download never launches preview and unsupported local preview reports failure', async () => {
  const cancelled = fixture({ download: async (_request, _target, control) => { control.cancellation.cancel(); } });
  await cancelled.attach('alice'); await cancelled.model.download(file(3), true);
  assert.equal(cancelled.model.items[0].state, 'cancelled');
  assert.equal(cancelled.events.some(event => event[0] === 'preview'), false);
  assert.ok(cancelled.model.errorText);
  const unsupported = fixture({ previewSupported: false });
  await unsupported.attach('alice'); await unsupported.model.download(file(3), true);
  assert.equal(unsupported.model.items[0].state, 'completed');
  assert.match(unsupported.model.errorText, /不支持预览/);
  assert.equal(unsupported.events.some(event => event[0] === 'preview'), false);
});

test('choosing a file never uploads; confirmation sends selected conflict policy after private copy and running snapshot', async () => {
  const f = fixture(); await f.attach('alice');
  await f.model.prepareUpload(folder());
  assert.equal(f.model.draft.bytes, 3);
  assert.equal(f.events.some(e => e[0] === 'upload'), false);
  f.model.conflict = 'version';
  await f.model.upload();
  const i = f.events.findIndex(e => e[0] === 'upload');
  assert.equal(f.events[i - 1][0], 'save');
  assert.equal(f.events[i - 1][1][0].state, 'running');
  assert.ok(f.events.slice(0, i).some(e => e[0] === 'copy'));
  assert.equal(f.events[i][1].conflict, 'version');
  assert.equal(f.events[i][1].modifiedTime, 1720000000);
  assert.equal(f.model.items[0].resource.fileId, folder().fileId);
  assert.equal(f.model.items[0].state, 'completed');
  assert.equal(f.model.draft, undefined);
  assert.equal(f.history.get('alice')[0].state, 'completed');
});

test('cancelled selection, denied permissions and over-limit files cannot dispatch requests', async () => {
  const f = fixture({ select: async () => [] }); await f.attach('alice');
  await f.model.prepareUpload(folder());
  assert.equal(f.model.draft, undefined);
  await f.model.download({ ...file(3), capabilities: { canRead: true, canDownload: false } });
  await f.model.prepareUpload({ ...folder(), capabilities: { canRead: true, canWrite: false } });
  await f.model.download(file(state.DRIVE_TRANSFER_MAX_BYTES + 1));
  assert.equal(f.events.some(e => ['upload', 'download'].includes(e[0])), false);
  assert.equal(f.model.items.length, 0);
});

test('failed history save or local preparation prevents any remote write', async () => {
  for (const options of [{ saveFailure: count => count >= 3 }, { copyFailure: true }]) {
    const f = fixture(options); await f.attach('alice'); await f.model.prepareUpload(folder()); await f.model.upload();
    assert.equal(f.events.some(e => e[0] === 'upload'), false);
    assert.equal(f.model.items[0].state, 'failed');
    assert.ok(f.model.items[0].errorText.length > 0);
  }
});

test('stopped upload remains unknown, survives restart and blocks duplicate writes until explicit closure', async () => {
  const pending = gate(), started = gate();
  const f = fixture({ upload: async () => { started.resolve(); await pending.promise; } });
  await f.attach('alice'); await f.model.prepareUpload(folder());
  const uploading = f.model.upload(); await started.promise;
  f.model.cancel(); pending.resolve(); await uploading;
  assert.equal(f.model.items[0].state, 'unknown');
  await f.attach('alice');
  assert.equal(f.model.items[0].state, 'unknown');
  await f.model.prepareUpload(folder());
  assert.equal(f.model.draft, undefined);
  assert.match(f.model.errorText, /已有上传记录/);
  await f.model.remove(f.model.items[0].id);
  assert.equal(f.model.items.length, 1);
  const count = f.events.filter(e => e[0] === 'upload').length;
  await f.model.closeUnknown(f.model.items[0].id);
  assert.equal(f.model.items[0].state, 'closed');
  assert.equal(f.events.filter(e => e[0] === 'upload').length, count);
  await f.model.prepareUpload(folder());
  assert.ok(f.model.draft);
});

test('background stops active download and preparation cancellation does not imply remote upload', async () => {
  const pending = gate(), started = gate();
  const f = fixture({ download: async () => { started.resolve(); await pending.promise; } });
  await f.attach('alice'); const download = f.model.download(file(3)); await started.promise;
  f.model.setForeground(false); pending.resolve(); await download;
  assert.equal(f.model.items[0].state, 'cancelled');
  assert.equal(f.sessions[0].cancellation.cancelled, true);
  f.model.setForeground(true);
  const copying = gate(), copied = gate();
  const g = fixture({ copy: async () => { copied.resolve(); await copying.promise; } });
  await g.attach('alice'); await g.model.prepareUpload(folder());
  const upload = g.model.upload(); await copied.promise;
  g.model.cancel(); copying.resolve(); await upload;
  assert.equal(g.model.items[0].state, 'cancelled');
  assert.equal(g.events.some(e => e[0] === 'upload'), false);
});

test('account change cancels old request, stores its uncertainty under the old account and ignores late progress', async () => {
  const pending = gate(), started = gate();
  const f = fixture({ upload: async () => { started.resolve(); await pending.promise; } });
  await f.attach('alice'); await f.model.prepareUpload(folder());
  const upload = f.model.upload(); await started.promise;
  const attaching = f.attach('bob');
  f.sessions[0].onProgress({ direction: 'upload', processed: 9, total: 10 });
  assert.equal(f.model.progress, undefined);
  pending.resolve(); await upload; await attaching;
  assert.equal(f.history.get('alice')[0].state, 'unknown');
  assert.equal(f.model.items.length, 0);
  assert.equal(f.model.notice, '');
});

test('restored running tasks are terminal without network activity, including downloads', async () => {
  const f = fixture({ records: [{ id: '11111111-1111-4111-8111-111111111111', direction: 'upload',
    resource: { fileId: '1' }, name: '记录.txt', bytes: 3, state: 'running', locationName: '测试', errorText: '' }] });
  await f.attach('alice');
  assert.equal(f.model.items[0].state, 'unknown');
  assert.equal(f.events.some(e => ['upload', 'download'].includes(e[0])), false);
});

test('download uses ID and exact known length, zero-length files export only after completion', async () => {
  const f = fixture(); await f.attach('alice'); await f.model.download(file(0));
  const call = f.events.find(e => e[0] === 'download');
  assert.equal(call[1].fileId, file().fileId);
  assert.equal(call[2].expectedBytes, 0);
  assert.equal(call[2].maximumBytes, state.DRIVE_TRANSFER_MAX_BYTES);
  assert.equal(f.model.items[0].state, 'completed');
  await f.model.exportDownload(f.model.items[0].id);
  const copied = f.events.find(e => e[0] === 'copy');
  assert.equal(copied[2], 'file://export');
  assert.equal(copied[3], 0);
  assert.equal(copied[4], true);
  assert.match(f.model.notice, /已保存/);
});

test('failed download cannot be exported, failed or cancelled export never claims saving succeeded', async () => {
  const f = fixture({ download: async () => { throw new NasFailure(K.Protocol, '下载文件不完整'); } });
  await f.attach('alice'); await f.model.download(file(3)); await f.model.exportDownload(f.model.items[0].id);
  assert.equal(f.model.items[0].state, 'failed');
  assert.equal(f.events.some(e => e[0] === 'save-picker'), false);
  for (const options of [{ saveUris: [] }, { copyFailure: true }]) {
    const g = fixture(options); await g.attach('alice'); await g.model.download(file(3));
    await g.model.exportDownload(g.model.items[0].id);
    assert.equal(g.model.notice, '');
    assert.equal(g.model.items[0].state, 'completed');
  }
});

test('completion persistence failure freezes new transfers and retains unknown upload evidence', async () => {
  const f = fixture({ saveFailure: count => count >= 4 });
  await f.attach('alice'); await f.model.prepareUpload(folder()); await f.model.upload();
  assert.equal(f.model.ready, false);
  assert.equal(f.model.items[0].state, 'unknown');
  assert.equal(f.history.get('alice')[0].state, 'running');
  assert.equal(f.model.notice, '');
  await f.model.download(file(3));
  assert.equal(f.events.some(e => e[0] === 'download'), false);
});

test('session expiration records the ambiguous upload before notifying the connection owner', async () => {
  const f = fixture({ upload: async () => { throw new NasFailure(K.SessionExpired, '重新登录'); } });
  await f.attach('alice'); await f.model.prepareUpload(folder()); await f.model.upload();
  assert.equal(f.failures.length, 1);
  assert.equal(f.history.get('alice')[0].state, 'unknown');
});

test('resuming an upload cannot bypass another unresolved upload in the same module', async () => {
  for (const otherState of ['running', 'paused', 'unknown']) {
    const record = { id: '11111111-1111-4111-8111-111111111111', direction: 'upload',
      resource: { nasOrigin: 'https://nas.example.test:5001', account: 'alice', fileId: '1' },
      name: '原上传.txt', bytes: 3, state: 'paused', locationName: '测试', errorText: '' };
    const f = fixture({ records: [record, { ...record, id: '11111111-1111-4111-8111-111111111112',
      name: '另一上传.txt', state: otherState }] });
    await f.attach('alice');
    const saves = f.events.filter(e => e[0] === 'save').length;
    await f.model.resume(record.id);
    assert.match(f.model.errorText, /其他上传/);
    assert.equal(f.events.filter(e => e[0] === 'save').length, saves);
    assert.equal(f.events.some(e => e[0] === 'upload'), false);
  }
});
