const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdkRoot = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const protocol = require('../../work/core-build/domain/DsmProtocol.js');
const state = require('../../work/core-build/domain/ExtensionWriteState.js');
const plain = value => JSON.parse(JSON.stringify(value));
const failure = kind => new protocol.NasFailure(kind, '合成错误', 107);
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };

async function fixture(options = {}) {
  const saved = [];
  const calls = { expired: 0, remote: 0, requests: [] };
  class MockStore {
    async load() { if (options.loadError) throw options.loadError; return options.pending || []; }
    async save(records) {
      if (options.saveError || options.failClear && saved.length === 1) throw new Error('disk full');
      saved.push(plain(records));
    }
  }
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/extensions/NasExtensionsModel.ets'), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
  const mocks = {
    '@kit.CoreFileKit': { fileIo: {}, fileUri: {}, picker: {} },
    '@kit.ArkTS': { util: {} },
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
    '../../core/domain/DsmProtocol': protocol,
    '../../core/domain/ExtensionWriteState': state,
    './ExtensionWriteStore': { ExtensionWriteStore: MockStore },
  };
  const module = { exports: {} };
  const cache = new Map();
  const sourceRoot = path.join(__dirname, '../../entry/src/main/ets');
  function requireSource(relative, parent = 'features/extensions/NasExtensionsModel.ets') {
    if (Object.hasOwn(mocks, relative)) return mocks[relative];
    const base = path.resolve(sourceRoot, path.dirname(parent), relative);
    const file = fs.existsSync(base + '.ts') ? base + '.ts' : base + '.ets';
    if (cache.has(file)) return cache.get(file);
    const child = { exports: {} };
    cache.set(file, child.exports);
    const text = fs.readFileSync(file, 'utf8');
    const compiled = ts.transpileModule(text, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
    vm.runInNewContext(compiled.outputText, { module: child, exports: child.exports, Error,
      require: id => requireSource(id, path.relative(sourceRoot, file)) });
    return child.exports;
  }
  vm.runInNewContext(output.outputText, { module, exports: module.exports, Error, Date, require: requireSource });
  const connector = {
    supportsExtensionAction: () => true,
    async extensionRequest(feature, method, fields) {
      calls.requests.push({ feature, method, fields: plain(fields) });
      assert.ok(options.replies?.length, 'unexpected extension request');
      return options.replies.shift();
    },
    capabilitySnapshots: () => ['fileSharing', 'nasDownloads', 'photos'].map(feature => ({ feature, apiVersion: 1, state: 'unverified', reason: 'readNotVerified' })),
    supportsPhotoAction: () => true,
    readExtension: (feature, action) => action(),
    async list() { if (options.fileSessionError) throw options.fileSessionError; return {}; },
  };
  const model = new module.exports.NasExtensionsModel();
  await model.attach(connector, { filesDir: '/private' }, 'https://nas.example.test', 'alice', async () => { calls.expired++; });
  return { model, saved, calls, options, connector };
}

const download = (id, status = 'downloading') => ({ id: String(id), title: '文件' + id, status });

test('NAS pagination uses the raw page cursor, replaces duplicate IDs and records changing totals', async () => {
  const first = Array.from({ length: 50 }, (_, id) => download(id));
  const second = [download(0, 'paused'), ...Array.from({ length: 49 }, (_, id) => download(id + 50))];
  const f = await fixture({ replies: [{ tasks: first, total: 160, offset: 0 },
    { tasks: second, total: 160, offset: 50 }, { tasks: [], total: 90, offset: 100 }] });
  assert.equal(await f.model.refreshDownloads(), true);
  assert.equal(await f.model.loadMoreDownloads(), true);
  assert.equal(f.model.downloads.length, 99); assert.equal(f.model.downloadOffset, 100);
  assert.equal(f.model.downloads[0].id, '0'); assert.equal(f.model.downloads[0].status, 'paused');
  assert.equal(f.model.downloadListChanged, true);
  assert.equal(await f.model.loadMoreDownloads(), true);
  assert.equal(f.model.downloadHasMore, false); assert.equal(f.model.downloadOffset, 100);
  assert.equal(f.model.downloadTotal, 90); assert.equal(f.model.downloads.length, 99);
  assert.deepEqual(f.calls.requests.map(request => request.fields.find(field => field.name === 'offset').content), ['0', '50', '100']);
});

test('NAS append and refresh failures retain data and cursor, with a retry matching the failed operation', async () => {
  const f = await fixture({ replies: [{ tasks: [download('a')], total: 100, offset: 0 }] });
  await f.model.refreshDownloads();
  f.connector.extensionRequest = async () => { throw failure(protocol.NasErrorKind.Network); };
  assert.equal(await f.model.loadMoreDownloads(), false);
  assert.equal(f.model.downloadRetryAppend, true); assert.ok(f.model.downloadListError);
  assert.equal(f.model.downloads.length, 1); assert.equal(f.model.downloadOffset, 1);
  assert.equal(await f.model.refreshDownloads(), false);
  assert.equal(f.model.downloadRetryAppend, false); assert.equal(f.model.downloads[0].id, 'a');
  f.connector.extensionRequest = async () => ({ tasks: [download('b')], total: 1, offset: 0 });
  assert.equal(await f.model.refreshDownloads(), true);
  assert.equal(f.model.downloads.length, 1); assert.equal(f.model.downloads[0].id, 'b');
  assert.equal(f.model.downloadOffset, 1); assert.equal(f.model.downloadHasMore, false); assert.equal(f.model.downloadListError, '');
});

test('NAS list serializes requests and ignores late results after page exit or account reset', async () => {
  for (const reset of [false, true]) {
    const f = await fixture(); const gate = deferred(); let count = 0;
    f.connector.extensionRequest = async () => { count++; return gate.promise; };
    const reading = f.model.refreshDownloads();
    assert.equal(f.model.downloadsLoading, true);
    assert.equal(await f.model.refreshDownloads(), false); assert.equal(count, 1);
    if (reset) f.model.reset(); else f.model.deactivateDownloads();
    gate.resolve({ tasks: [download('old')], total: 1, offset: 0 });
    assert.equal(await reading, false); assert.equal(f.model.downloads.length, 0);
    assert.equal(f.model.downloadsLoaded, false); assert.equal(f.model.downloadsLoading, false);
  }
});

test('NAS details preserve the list snapshot on failure and cannot refill a closed or changed instance', async () => {
  const f = await fixture();
  f.model.downloads = [download('a'), download('b')];
  f.connector.extensionRequest = async () => { throw failure(protocol.NasErrorKind.Network); };
  await f.model.showDownload('a');
  assert.equal(f.model.selectedDownload.id, 'a'); assert.ok(f.model.downloadDetailError);
  for (const action of ['close', 'switch', 'account']) {
    const gate = deferred(); f.connector.extensionRequest = async () => gate.promise;
    const reading = f.model.showDownload('a');
    assert.equal(f.model.downloadDetailLoading, true);
    if (action === 'close') f.model.closeDownloadDetail();
    else if (action === 'switch') await f.model.showDownload('b');
    else f.model.reset();
    gate.resolve({ tasks: [download('a', 'finished')] }); await reading;
    assert.equal(f.model.selectedDownload?.id, action === 'switch' ? 'b' : undefined);
    assert.equal(f.model.downloadDetailLoading, false);
  }
});

test('photo mutation saves identity before submission, retains accepted task and never replays it', async () => {
  const f = await fixture();
  let submitted = 0;
  f.connector.photoAction = async () => {
    submitted++; assert.equal(f.saved[0][0].photoId, 42); return { completed: false, taskId: 12 };
  };
  const input = { action: 'delete', item: { id: 42, space: 0, filename: 'a.jpg' } };
  assert.equal(await f.model.performPhotoAction(input), false);
  assert.equal(f.model.pending[0].taskId, 12);
  assert.equal(await f.model.performPhotoAction(input), false); assert.equal(submitted, 1);
  f.connector.photoTaskDone = async () => false; await f.model.refreshPhotoTask(); assert.equal(f.model.pending.length, 1);
  f.connector.photoTaskDone = async () => true; await f.model.refreshPhotoTask(); assert.equal(f.model.pending.length, 0);
  const blocked = await fixture({ saveError: new Error('disk') });
  blocked.connector.photoAction = async () => { throw new Error('must not send'); };
  assert.equal(await blocked.model.performPhotoAction(input), false); assert.equal(blocked.model.recordsReady, false);
});

test('write guard is durable before submission and cannot replay an accepted request without a unique result', async () => {
  const { model, saved, calls } = await fixture();
  const action = async () => { calls.remote++; assert.equal(saved[0][0].feature, 'nasDownloads'); return false; };
  assert.equal(await model.write('nasDownloads', 'create', action), false);
  assert.equal(await model.write('nasDownloads', 'create', action), false);
  assert.equal(calls.remote, 1);
  assert.equal(model.hasPending('nasDownloads'), true);
  assert.match(model.downloadNotice, /不要重复提交/);
  await model.acknowledge('nasDownloads');
  assert.equal(model.hasPending('nasDownloads'), false);
  assert.match(model.downloadNotice, /不代表远端操作成功/);
});

test('independent suite authentication clears credentials on every outcome and retains uncertain writes', async () => {
  const { model, connector, calls } = await fixture();
  model.pending = [{ feature: 'nasDownloads', operation: 'create', createdAt: 1 }];
  model.downloadAuthenticationRequired = true; model.downloadPassword = 'secret';
  connector.authenticateDownloadStation = async () => { throw failure(protocol.NasErrorKind.OtpRequired); };
  assert.equal(await model.authenticateDownloads(), false); assert.equal(model.downloadNeedsOtp, true);
  assert.equal(model.downloadPassword, ''); assert.equal(model.downloadOtp, '');
  model.downloadPassword = 'secret'; model.downloadOtp = '123456';
  connector.authenticateDownloadStation = async (...args) => { assert.deepEqual(args, ['alice', 'secret', '123456']); };
  assert.equal(await model.authenticateDownloads(), true);
  assert.equal(model.downloadAuthenticationRequired, false); assert.equal(model.pending.length, 1);
  assert.equal(model.downloadPassword, ''); assert.equal(model.downloadOtp, ''); assert.equal(calls.remote, 0);
});

test('confirmed and explicitly rejected writes clear guards; uncertain errors preserve them', async () => {
  for (const kind of [undefined, protocol.NasErrorKind.Permission, protocol.NasErrorKind.Network]) {
    const { model, calls, saved } = await fixture();
    const result = await model.write('fileSharing', 'create', async () => { calls.remote++; if (kind !== undefined) throw failure(kind); return true; });
    assert.equal(calls.remote, 1);
    assert.equal(result, kind === undefined);
    assert.equal(model.hasPending('fileSharing'), kind === protocol.NasErrorKind.Network);
    assert.equal(saved.length, kind === protocol.NasErrorKind.Network ? 1 : 2);
  }
});

test('failed record loading or saving prevents the remote request', async () => {
  for (const options of [{ loadError: new Error('corrupt') }, { saveError: new Error('disk full') }]) {
    const { model, calls } = await fixture(options);
    await model.write('fileSharing', 'create', async () => { calls.remote++; return true; });
    assert.equal(calls.remote, 0);
    assert.equal(model.recordsReady, false);
    assert.ok(model.recordsError);
  }
});

test('failed clearing after confirmed success preserves the guard and the confirmed result notice', async () => {
  const { model, calls } = await fixture({ failClear: true });
  await model.write('fileSharing', 'delete', async () => { calls.remote++; return true; });
  assert.equal(model.hasPending('fileSharing'), true);
  assert.match(model.shareNotice, /已确认/);
  await model.write('fileSharing', 'delete', async () => { calls.remote++; return true; });
  assert.equal(calls.remote, 1);
});

test('account switches isolate late write responses and leave the old durable record pending', async () => {
  const { model, saved } = await fixture();
  const gate = deferred();
  const write = model.write('nasDownloads', 'create', async () => gate.promise);
  await Promise.resolve(); await Promise.resolve();
  model.reset();
  gate.resolve(true);
  assert.equal(await write, false);
  assert.equal(saved.length, 1);
  assert.equal(model.downloadNotice, '');
  assert.equal(model.pending.length, 0);
});

test('package-specific session errors require a confirmed File Station expiry before clearing login', async () => {
  for (const fileSessionError of [undefined, failure(protocol.NasErrorKind.Network), failure(protocol.NasErrorKind.SessionExpired)]) {
    const { model, calls } = await fixture({ fileSessionError });
    await model.read('nasDownloads', async () => { throw failure(protocol.NasErrorKind.SessionExpired); });
    assert.equal(calls.expired, fileSessionError?.kind === protocol.NasErrorKind.SessionExpired ? 1 : 0);
    if (fileSessionError === undefined) assert.match(model.downloadError, /下载套件需要重新验证/);
  }
});

test('actual Download Station integration keeps no-ID creation pending and refreshes without a second create', async () => {
  const { model, calls } = await fixture({ replies: [{}, { tasks: [], offset: 0, total: 0 }] });
  model.downloadUri = 'https://public.example.test/file.iso';
  model.downloadDestination = 'downloads';
  assert.equal(await model.createDownload(), false);
  assert.equal(model.hasPending('nasDownloads'), true);
  assert.equal(model.downloadUri, '');
  assert.equal(model.downloadsLoaded, true);
  assert.deepEqual(calls.requests.map(request => request.method), ['create', 'list']);
  await model.createDownload();
  assert.equal(calls.requests.filter(request => request.method === 'create').length, 1);
});

test('actual share integration exposes every partially failed path and never uploads shared intake', async () => {
  const paths = ['/share/中文,报告.txt', '/share/blocked.txt'];
  const { model, calls } = await fixture({ replies: [
    { links: [{ path: paths[0], error: 0, id: 'share-id', url: 'https://public.example.test/fbsharing/share-id' },
      { path: paths[1], error: 403 }] },
    { links: [], offset: 0, total: 0 },
  ] });
  model.shareDraftPaths = paths;
  assert.equal(await model.createShares({ password: { mode: 'retain' } }), true);
  assert.equal(model.shareResults.length, 2);
  assert.equal(model.shareResults[1].failure.kind, protocol.NasErrorKind.Permission);
  assert.equal(model.hasPending('fileSharing'), false);
  assert.match(model.shareNotice, /已创建 1.*1 项未成功/);
  assert.deepEqual(calls.requests.map(request => request.feature), ['fileSharing', 'fileSharing']);
  assert.deepEqual(JSON.parse(calls.requests[0].fields.find(field => field.name === 'path').content), paths);
});

test('actual task permission rejection is a confirmed failure, not an uncertain write to replay', async () => {
  const { model, calls } = await fixture({ replies: [[{ id: 'task-id', error: 402 }]] });
  await model.controlDownload('task-id', 'pause');
  assert.equal(model.hasPending('nasDownloads'), false);
  assert.match(model.downloadError, /写入权限/);
  assert.equal(calls.requests.length, 1);
});
