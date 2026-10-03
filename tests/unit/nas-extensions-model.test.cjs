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
    capabilitySnapshots: () => ['fileSharing', 'nasDownloads'].map(feature => ({ feature, apiVersion: 1, state: 'unverified', reason: 'readNotVerified' })),
    readExtension: (feature, action) => action(),
    async list() { if (options.fileSessionError) throw options.fileSessionError; return {}; },
  };
  const model = new module.exports.NasExtensionsModel();
  await model.attach(connector, { filesDir: '/private' }, 'https://nas.example.test', 'alice', async () => { calls.expired++; });
  return { model, saved, calls, options, connector };
}

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
    if (fileSessionError === undefined) assert.match(model.downloadError, /文件会话仍有效/);
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
