const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const protocol = require('../../work/core-build/domain/DriveOriginalProtocol.js');
const drive = require('../../work/core-build/domain/DriveProtocol.js');
const transport = require('../../work/core-build/network/NasTransferTransport.js');
const { DriveTransferAdapter } = require('../../work/core-build/network/DriveTransferAdapter.js');
const gate = () => { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; };
const flush = () => new Promise(setImmediate);
const entry = overrides => ({ fileId: '900000000000000001', name: 'a.jpg', kind: 'file', sizeBytes: 3, versionId: '1',
  capabilities: { canRead: true, canPreview: true, canDownload: true }, ...overrides });

function fixture(options = {}) {
  const events = [], failures = [], directories = new Set(options.staleDirectories || []);
  let counter = 0, reads = 0;
  const text = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/drive/DriveOriginalModel.ets'), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const compiled = ts.transpileModule(text, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const mocks = {
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'owned-' + ++counter } },
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
    '@kit.CoreFileKit': { fileIo: { async listFile(dir) {
      if (options.startupFailure) throw new Error('list');
      return [...directories].filter(value => value.startsWith(dir + '/')).map(value => value.slice(dir.length + 1));
    }, async mkdir(dir) { directories.add(dir); }, async rmdir(dir) {
      if (options.cleanupFailure) throw new Error('cleanup'); directories.delete(dir); events.push(['remove', dir]);
    } } },
    '@kit.ImageKit': { image: { createImageSource(file) {
      events.push(['image-source', file]);
      return { async getImageInfo() { return { size: { width: 10000, height: 8000 } }; },
        async getFrameCount() { return options.frames || 1; },
        async createPixelMap(size) { events.push(['decode', size]); if (options.decodeFailure) throw new Error('decode');
          return { async release() { events.push(['release-pixels']); } }; },
        async release() { events.push(['release-source']); } };
    } } },
    '../../core/domain/DsmProtocol': dsm, '../../core/domain/DriveProtocol': drive,
    '../../core/domain/DriveOriginalProtocol': protocol, '../../core/network/DriveTransferAdapter': { DriveTransferAdapter },
    '../../core/network/NasTransferTransport': transport,
  };
  const mod = { exports: {} };
  vm.runInNewContext(compiled.outputText, { module: mod, exports: mod.exports,
    require(name) { assert.ok(Object.hasOwn(mocks, name), name); return mocks[name]; } });
  const kernel = {
    async requestDrive(api, version, method, fields) {
      reads++; events.push(['read', api, version, method, fields]);
      if (options.read) await options.read(reads);
      return { file_id: entry().fileId, name: 'a.jpg', type: 'file', size: 3,
        version_id: options.changed && reads > 1 ? '2' : '1',
        capabilities: { can_read: true, can_download: options.denied !== true, can_preview: true } };
    },
    async downloadDrive(input, target, control) {
      events.push(['download', input, target, control]);
      control.onProgress?.({ processed: 1, total: 3 });
      if (options.download) await options.download(control);
      if (directories.has(target.directory)) throw new dsm.NasFailure(dsm.NasErrorKind.Protocol, '无法创建下载临时目录。');
      directories.add(target.directory);
      return { path: target.directory + '/content', bytes: 3 };
    }
  };
  const model = new mod.exports.DriveOriginalModel();
  const attach = () => model.attach({ cacheDir: '/private/cache' }, kernel, async error => failures.push(error));
  attach(); return { model, kernel, attach, events, failures, directories, options, io: mocks['@kit.CoreFileKit'].fileIo };
}

test('original preview respects download permission and image type; bounded decoding preserves aspect and limits memory', () => {
  assert.equal(protocol.canPreviewDriveOriginal(entry()), true);
  for (const overrides of [{ name: 'a.txt' }, { kind: 'folder' }, { capabilities: { canRead: true, canPreview: true, canDownload: false } }]) {
    assert.equal(protocol.canPreviewDriveOriginal(entry(overrides)), false);
  }
  assert.throws(() => protocol.validateDriveOriginal(entry({ sizeBytes: protocol.DRIVE_ORIGINAL_MAX_BYTES + 1 })));
  const size = protocol.driveOriginalDecodeSize(10000, 8000, 2000, 2000, 4);
  assert.ok(size.width * size.height <= protocol.DRIVE_ORIGINAL_DECODE_PIXELS);
  assert.ok(Math.abs(size.width / size.height - 1.25) < 0.002);
  assert.throws(() => protocol.driveOriginalDecodeSize(0, 8000, 1000, 1000));
});

test('preview downloads the original in ordinary mode, validates metadata twice and releases every private resource on close', async () => {
  const f = fixture({ frames: 2 }); await f.model.open(entry());
  assert.equal(f.model.errorText, ''); assert.ok(f.model.pixels);
  assert.equal(f.model.staticFrame, true);
  const download = f.events.find(e => e[0] === 'download');
  assert.equal(download[1].preview, false); assert.equal(download[2].expectedBytes, 3);
  assert.equal(f.events.filter(e => e[0] === 'read').length, 2);
  assert.equal(f.directories.size, 1);
  f.model.refine(4); await flush(); await f.model.close();
  assert.equal(f.model.pixels, undefined); assert.equal(f.directories.size, 0);
  assert.equal(f.events.filter(e => e[0] === 'release-source').length, 1);
  assert.equal(f.events.filter(e => e[0] === 'release-pixels').length, 2);
});

test('changed revision, denied permission and decoder failure never publish a stale or unverified image', async () => {
  for (const options of [{ changed: true }, { denied: true }, { decodeFailure: true }]) {
    const f = fixture(options); await f.model.open(entry());
    assert.equal(f.model.pixels, undefined); assert.notEqual(f.model.errorText, ''); assert.equal(f.directories.size, 0);
    if (options.denied) assert.equal(f.events.some(e => e[0] === 'download'), false);
  }
});

test('closing or changing the connection cancels the active original read and discards a late response', async () => {
  for (const action of ['close', 'attach', 'background']) {
    const pending = gate(), f = fixture({ download: () => pending.promise });
    const opening = f.model.open(entry()); await flush();
    const download = f.events.find(e => e[0] === 'download'); assert.ok(download);
    assert.ok(f.model.progress > 33 && f.model.progress < 34);
    if (action === 'close') f.model.close(); else if (action === 'attach') f.attach(); else f.model.setForeground(false);
    if (action === 'background') assert.equal(f.model.entry.fileId, entry().fileId);
    assert.equal(download[3].cancellation.cancelled, true);
    pending.resolve(); await opening; await f.model.close();
    assert.equal(f.model.pixels, undefined); assert.equal(f.directories.size, 0);
    assert.equal(f.events.some(e => e[0] === 'image-source'), false);
  }
});

test('cleanup failure retains ownership and blocks opening another image until cleanup can succeed', async () => {
  const f = fixture(); await f.model.open(entry()); f.options.cleanupFailure = true; await f.model.close();
  assert.equal(f.directories.size, 1); assert.match(f.model.errorText, /清理失败/);
  await f.model.open(entry()); assert.equal(f.events.filter(e => e[0] === 'download').length, 1);
  f.options.cleanupFailure = false; await f.model.open(entry());
  assert.ok(f.model.pixels); await f.model.close(); assert.equal(f.directories.size, 0);
});

test('startup removes only owned stale original directories and preserves unrelated cache data', async () => {
  const old = '/private/cache/drive-original-00000000-0000-4000-8000-000000000000';
  const unrelated = '/private/cache/drive-original-not-an-owned-directory';
  const f = fixture({ staleDirectories: [old, unrelated] }); await f.model.open(entry());
  assert.ok(f.model.pixels); assert.equal(f.directories.has(old), false); assert.equal(f.directories.has(unrelated), true);
  await f.model.close(); assert.deepEqual([...f.directories], [unrelated]);
});

test('an unreadable cache does not silently bypass startup cleanup and reconnect permits a fresh check', async () => {
  const f = fixture({ startupFailure: true }); await f.model.open(entry());
  assert.equal(f.model.pixels, undefined); assert.match(f.model.errorText, /缓存清理未完成/);
  assert.equal(f.events.some(e => e[0] === 'download'), false);
  f.options.startupFailure = false; f.attach(); await f.model.open(entry()); assert.ok(f.model.pixels); await f.model.close();
});

test('original model and real RCP transport agree on exclusive directory ownership and release the downloaded file', async () => {
  const f = fixture(), files = new Map(), descriptors = new Map(); let nextFd = 1, fetches = 0;
  const remove = dir => { f.directories.delete(dir); for (const name of files.keys()) if (name.startsWith(dir + '/')) files.delete(name); };
  Object.assign(f.io, {
    OpenMode: { CREATE: 64, READ_WRITE: 2 },
    mkdirSync(dir) { if (f.directories.has(dir)) throw new Error('already exists'); f.directories.add(dir); },
    accessSync(file) { return files.has(file); },
    openSync(file) { files.set(file, Buffer.alloc(0)); const fd = nextFd++; descriptors.set(fd, file); return { fd }; },
    writeSync(fd, buffer) { const name = descriptors.get(fd); files.set(name, Buffer.concat([files.get(name), Buffer.from(buffer)])); return buffer.byteLength; },
    statSync(fd) { return { isFile: () => true, size: files.get(descriptors.get(fd)).length }; },
    fsyncSync() {}, closeSync(fd) { descriptors.delete(fd); }, unlinkSync(file) { files.delete(file); },
    rmdirSync: remove, async rmdir(dir) { remove(dir); }
  });
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/core/network/RcpTransferTransport.ets'), 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
  const mocks = {
    '@kit.RemoteCommunicationKit': { rcp: { Request: class { constructor(url, method, headers) { Object.assign(this, { url, method, headers }); } } } },
    '../../platform/LocalSpaceBudget': require('../helpers/load-space-budget.cjs')(dsm),
    '@kit.CoreFileKit': { fileIo: f.io }, '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
    '../domain/DsmProtocol': dsm, './NasTransferTransport': transport,
    '../../platform/Utf8Codec': { decodeResponsePrefix: bytes => Buffer.from(bytes).toString(), decodeUtf8Complete: bytes => Buffer.from(bytes).toString() }
  };
  const mod = { exports: {} };
  vm.runInNewContext(compiled.outputText, { module: mod, exports: mod.exports, Error, Uint8Array, ArrayBuffer,
    require(id) { assert.ok(Object.hasOwn(mocks, id), id); return mocks[id]; } });
  const rcp = new mod.exports.RcpTransferTransport({ async fetch(request) {
    fetches++; request.destination(Uint8Array.from([255, 216, 255]).buffer);
    return { statusCode: 200, headers: { 'content-length': '3', 'content-type': 'image/jpeg' } };
  }, cancel() {} }, () => false, error => error);
  const transferProtocol = require('../../work/core-build/domain/DriveTransferProtocol.js');
  f.kernel.downloadDrive = (input, target, control) => rcp.download({ address: 'https://nas.test/webapi/entry.cgi', method: 'GET',
    fields: [], session: { sid: 'test', synoToken: 'test' } }, target, control,
    reply => transferProtocol.validateDriveDownload(reply, target));
  await f.model.open(entry()); assert.equal(f.model.errorText, ''); assert.ok(f.model.pixels);
  assert.equal(fetches, 1); assert.equal(files.size, 1);
  await f.model.close(); assert.equal(files.size, 0); assert.equal(f.directories.size, 0); assert.equal(descriptors.size, 0);
});
