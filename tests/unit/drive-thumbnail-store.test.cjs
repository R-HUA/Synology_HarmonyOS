const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const protocol = require('../../work/core-build/domain/DriveThumbnailProtocol.js');
const transport = require('../../work/core-build/network/NasTransferTransport.js');
const gate = () => { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; };
const flush = () => new Promise(setImmediate);
const item = (id, versionId = '1') => ({ fileId: String(id), name: 'a.type' + id, kind: 'file', versionId,
  capabilities: { canRead: true, canPreview: true } });

function fixture(options = {}) {
  const calls = [], iconCalls = [], removed = [], failures = [], releases = [], directories = new Set();
  let counter = 0;
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/drive/DriveThumbnailStore.ets'), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const mocks = {
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'uuid-' + ++counter } },
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
    '@kit.CoreFileKit': { fileIo: { accessSync: p => directories.has(p), mkdirSync: p => directories.add(p),
      rmdirSync(p) { if (options.cleanupFailure) throw new Error('remove failed'); removed.push(p); directories.delete(p); } } },
    '@kit.ImageKit': { image: { createImageSource: p => ({
      async getImageInfo() { return { size: options.size || { width: 120, height: 120 } }; },
      async createPixelMap() { if (options.invalidImage) throw new Error('decode failed'); return { async release() { releases.push('pixels'); } }; },
      async release() { releases.push('source'); }
    }) } },
    '../../core/domain/DsmProtocol': dsm,
    '../../core/domain/DriveThumbnailProtocol': protocol,
    '../../core/domain/DriveProtocol': require('../../work/core-build/domain/DriveProtocol.js'),
    '../../core/network/NasTransferTransport': transport
  };
  const mod = { exports: {} };
  vm.runInNewContext(compiled.outputText, { module: mod, exports: mod.exports,
    require(id) { assert.ok(Object.hasOwn(mocks, id), id); return mocks[id]; } });
  const kernel = { async thumbnailDrive(input, directory, control) {
    calls.push({ input, directory, control }); directories.add(directory);
    if (options.download) await options.download(input, control);
    return { path: directory + '/content', bytes: options.bytes || 100 };
  }, async fileTypeIconDrive(filename, directory, control, folder) {
    iconCalls.push({ filename, directory, control, folder }); directories.add(directory);
    if (options.iconDownload) await options.iconDownload(filename, control);
    return { path: directory + '/content', bytes: options.bytes || 100 };
  } };
  const store = new mod.exports.DriveThumbnailStore();
  const attach = () => store.attach({ cacheDir: '/private/cache' }, kernel, async e => failures.push(e));
  attach();
  return { store, calls, iconCalls, removed, failures, releases, attach, directories };
}

test('folders, images and videos use static type icons; version changes reuse the asset', async () => {
  const f = fixture();
  const folder = { ...item(1), kind: 'folder' }, photo = { ...item(2), name: 'a.jpg' }, video = { ...item(3), name: 'a.mp4' };
  for (const entry of [folder, photo, video]) f.store.setVisible(entry, true);
  await flush();
  assert.equal(f.calls.length, 0); assert.equal(f.iconCalls.length, 3);
  assert.equal(f.iconCalls[0].folder, true);
  assert.ok(f.store.path(folder).endsWith('/content'));
  f.store.setVisible({ ...photo, versionId: '2' }, true); await flush();
  assert.equal(f.iconCalls.length, 3);
});
test('renaming an unchanged media revision reuses its cached thumbnail across row recreation', async () => {
  const f = fixture();
  const original = item(1);
  f.store.setVisible(original, true); await flush();
  const cached = f.store.path(original);
  assert.ok(cached.endsWith('/content'));
  f.store.setVisible(original, false);
  const renamed = { ...original, name: 'renamed.type1' };
  f.store.setVisible(renamed, true); await flush();
  assert.equal(f.iconCalls.length, 1);
  assert.equal(f.store.path(renamed), cached);
  assert.equal(f.removed.length, 0);
});

test('concurrency is bounded and hidden queued rows never start', async () => {
  const pending = gate(); const f = fixture({ iconDownload: () => pending.promise });
  for (let n = 1; n <= 8; n++) f.store.setVisible(item(n), true);
  assert.equal(f.iconCalls.length, 3);
  f.store.setVisible(item(8), false);
  pending.resolve(); await flush(); await flush();
  assert.equal(f.iconCalls.length, 7);
  assert.equal(f.iconCalls.some(c => c.filename === 'a.type8'), false);
});

test('account reset cancels in-flight reads and late results cannot enter the next cache', async () => {
  const pending = gate(); const f = fixture({ iconDownload: () => pending.promise });
  f.store.setVisible(item(1), true);
  const first = f.iconCalls[0];
  f.attach(); pending.resolve(); await flush();
  assert.equal(first.control.cancellation.cancelled, true);
  assert.equal(f.store.path(item(1)), '');
  assert.ok(f.removed.includes(first.directory));
  assert.equal(f.failures.length, 0);
});

test('background cancels reads; foreground resumes only still-visible rows', async () => {
  const pending = gate(); let n = 0;
  const f = fixture({ iconDownload: async () => { if (++n === 1) await pending.promise; } });
  f.store.setVisible(item(1), true); f.store.setForeground(false);
  assert.equal(f.iconCalls[0].control.cancellation.cancelled, true);
  pending.resolve(); await flush(); assert.equal(f.iconCalls.length, 1);
  f.store.setForeground(true); await flush(); assert.equal(f.iconCalls.length, 2);
  assert.ok(f.store.path(item(1)).length > 0);
});

test('malformed or oversized images are released, removed and retried only on explicit refresh', async () => {
  for (const options of [{ invalidImage: true }, { size: { width: 10000, height: 10000 } }]) {
    const f = fixture(options);
    f.store.setVisible(item(1), true); await flush();
    assert.equal(f.store.path(item(1)), '');
    assert.match(f.store.errorText, /图片/);
    assert.deepEqual(f.releases, ['source']);
    assert.equal(f.removed.length, 1);
    f.store.setVisible(item(1), false); f.store.setVisible(item(1), true); await flush();
    assert.equal(f.iconCalls.length, 1);
    f.store.retryVisible(); await flush(); assert.equal(f.iconCalls.length, 2);
  }
});

test('files without thumbnails share type icons and hiding one row keeps other visible rows loading', async () => {
  const pending = gate(); const f = fixture({ iconDownload: () => pending.promise });
  const first = { ...item(1), name: 'a.txt' }, second = { ...item(2), name: 'b.TXT' };
  f.store.setVisible(first, true); f.store.setVisible(second, true);
  assert.equal(f.iconCalls.length, 1); assert.equal(f.calls.length, 0);
  f.store.setVisible(first, false);
  assert.equal(f.iconCalls[0].control.cancellation.cancelled, false);
  pending.resolve(); await flush();
  assert.ok(f.store.path(second).endsWith('/content'));
  assert.equal(f.store.path(first), f.store.path(second));
  f.store.setVisible({ ...item(3), name: 'c.txt' }, true);
  assert.equal(f.iconCalls.length, 1);
});

test('session expiration is reported once without retrying or exposing credentials', async () => {
  const f = fixture({ iconDownload: () => { throw new dsm.NasFailure(dsm.NasErrorKind.SessionExpired, 'expired'); } });
  f.store.setVisible(item(1), true); await flush();
  assert.equal(f.failures.length, 1); assert.equal(f.iconCalls.length, 1);
  assert.equal(f.store.path(item(1)), '');
});

test('byte budget evicts old cache files and cleanup failure stops additional caching', async () => {
  const f = fixture({ bytes: 4 * 1024 * 1024 });
  for (let n = 1; n <= 8; n++) { f.store.setVisible(item(n), true); await flush(); f.store.setVisible(item(n), false); }
  assert.equal(Object.keys(f.store.paths).length, 6);
  assert.equal(f.store.path(item(1)), ''); assert.equal(f.removed.length, 2);
  const bad = fixture({ bytes: 4 * 1024 * 1024, cleanupFailure: true });
  for (let n = 1; n <= 7; n++) { bad.store.setVisible(item(n), true); await flush(); bad.store.setVisible(item(n), false); }
  bad.store.setVisible(item(8), true); await flush();
  assert.equal(bad.iconCalls.length, 7); assert.match(bad.store.errorText, /清理/);
});
