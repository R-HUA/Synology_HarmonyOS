const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdkRoot = process.env.HARMONY_SDK_ROOT || path.join(process.env.DEVECO_CLI_CLT_PATH || 'C:/Program Files/command-line-tools', 'sdk/default');
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const MiB = 1024 * 1024;
const context = { cacheDir: '/private/cache' };
const plain = value => JSON.parse(JSON.stringify(value));

function loadSource(relative, mocks) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets', relative), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true,
  });
  assert.equal((output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, {
    module, exports: module.exports, Error, Date,
    require: id => { assert.ok(Object.hasOwn(mocks, id), `unexpected dependency ${id}`); return mocks[id]; },
  }, { filename: relative });
  return module.exports;
}

const protocol = loadSource('core/domain/DsmProtocol.ts', {});
const queueState = loadSource('core/domain/TransferQueueState.ts', { './DsmProtocol': protocol });
const uploadPolicy = loadSource('core/domain/PhotoUpload.ts', { './DsmProtocol': protocol });

function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}

function fixture() {
  let nextFd = 1;
  let picker = async () => ({ photoUris: [] });
  const files = new Map();
  const handles = new Map();
  const calls = { pick: [], open: [], stat: [], close: [], upload: [], plans: [], folders: [], assets: [], resultClose: 0, helperRelease: 0 };
  const io = {
    OpenMode: { READ_ONLY: 0 },
    async open(uri, mode) {
      calls.open.push({ uri, mode });
      const info = files.get(uri);
      assert.ok(info, `unregistered URI ${uri}`);
      if (info.openGate) await info.openGate;
      if (info.openError) throw info.openError;
      const fd = nextFd++;
      const file = { fd, name: info.name };
      Object.defineProperty(file, 'name', { get() { throw new Error('media URI file.name is not a resource display name'); } });
      handles.set(fd, info);
      return file;
    },
    async stat(fd) {
      calls.stat.push(fd);
      const info = handles.get(fd);
      assert.ok(info, `invalid fd ${fd}`);
      if (info.statGate) await info.statGate;
      if (info.statError) throw info.statError;
      return { size: info.bytes, mtime: 1704067200, isDirectory: () => info.directory === true };
    },
    async close(file) {
      calls.close.push(file.fd);
      const info = handles.get(file.fd);
      if (info.closeGate) await info.closeGate;
      handles.delete(file.fd);
      if (info.closeError) throw info.closeError;
    },
  };
  class PhotoSelectOptions {}
  class PhotoViewPicker {
    async select(options) { calls.pick.push(plain(options)); return picker(); }
  }
  const { PhotoUpload } = loadSource('features/photos/PhotoUpload.ets', {
    '../../platform/SdkFileIO': loadSource('platform/SdkFileIO.ets', {
      '@kit.CoreFileKit': { fileIo: io }, '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
      '../core/domain/DsmProtocol': protocol,
    }),
    '@kit.CoreFileKit': { fileIo: io },
    '@kit.ArkData': { dataSharePredicates: { DataSharePredicates: class {
      equalTo(key, value) { this.key = key; this.value = value; return this; }
    } } },
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
    '@kit.MediaLibraryKit': { photoAccessHelper: {
      PhotoSelectOptions, PhotoViewPicker, PhotoViewMIMETypes: { IMAGE_VIDEO_TYPE: '*/*' },
      PhotoKeys: { URI: 'uri', DATE_TAKEN_MS: 'date_taken_ms' },
      getPhotoAccessHelper(actualContext) {
        assert.equal(actualContext, context);
        return {
          async getAssets(options) {
            calls.assets.push(plain(options));
            assert.equal(options.predicates.key, 'uri');
            assert.deepEqual(Array.from(options.fetchColumns), ['date_taken_ms']);
            const info = files.get(options.predicates.value);
            assert.ok(info);
            if (info.assetError) throw info.assetError;
            return {
              getCount: () => info.missingAsset ? 0 : 1,
              async getFirstObject() {
                return { get displayName() { if (info.nameError) throw info.nameError; return info.name; },
                  get(key) { assert.equal(key, 'date_taken_ms'); return info.takenAtMs ?? 0; } };
              },
              close() { calls.resultClose++; },
            };
          },
          async release() { calls.helperRelease++; },
        };
      },
    } },
    '../../core/domain/DsmProtocol': protocol,
    '../../core/domain/TransferQueueState': queueState,
    '../../core/domain/PhotoUpload': uploadPolicy,
  });
  const backup = new PhotoUpload();
  const connector = { async ensurePhotoDirectory(segments) { calls.folders.push(plain(segments)); return 3; } };
  function add(uri, name, bytes = 12, extra = {}) { files.set(uri, { name, bytes, ...extra }); return uri; }
  async function select(uris, queue) { picker = async () => ({ photoUris: uris }); await backup.select(context, queue); }
  function setPicker(action) { picker = action; }
  function queue(result) {
    return { async uploadPhotos(directory, sources, automatic) {
      calls.plans.push({ directory, sources: plain(sources), automatic });
      calls.upload.push({ directory, sources: plain(sources).map(({ uri, name, bytes }) => ({ uri, name, bytes })) });
      return typeof result === 'function' ? result() : result;
    } };
  }
  return { backup, connector, add, select, setPicker, queue, calls, handles };
}

async function seed(f) {
  await f.select([f.add('file://media/Photo/100', '真实相片.heic', 25)]);
}

function assertIdle(backup) { assert.equal(backup.selecting, false); assert.equal(backup.submitting, false); }

function waitUntil(predicate) {
  return (async () => {
    for (let attempt = 0; attempt < 40; attempt++) {
      if (predicate()) return;
      await new Promise(resolve => setImmediate(resolve));
    }
    assert.ok(predicate(), 'asynchronous operation did not reach expected boundary');
  })();
}

test('picker selects images and videos up to 20; authorized PhotoAsset supplies the display name', async () => {
  const f = fixture();
  await seed(f);
  assert.deepEqual(f.calls.pick, [{ MIMEType: '*/*', maxSelectNumber: 20 }]);
  assert.deepEqual(plain(f.backup.sources), [{ uri: 'file://media/Photo/100', name: '真实相片.heic', bytes: 25, takenAt: 0, modifiedAt: 1704067200 }]);
  assert.deepEqual(f.calls.open, [{ uri: 'file://media/Photo/100', mode: 0 }]);
  assert.equal(f.calls.stat.length, 1);
  assert.equal(f.calls.close.length, 1);
  assert.equal(f.handles.size, 0);
  assert.equal(f.calls.resultClose, 1);
  assert.equal(f.calls.helperRelease, 1);
  assertIdle(f.backup);
});

test('image and video dates come from selected assets in milliseconds without decoding EXIF or video metadata', async () => {
  const f = fixture();
  const takenAtMs = Date.parse('2023-06-15T12:00:00Z');
  await f.select([f.add('picture', '无EXIF.png', 10, { takenAtMs }), f.add('video', '视频.mp4', 20, { takenAtMs })]);
  assert.deepEqual(plain(f.backup.sources).map(s => s.takenAt), [takenAtMs / 1000, takenAtMs / 1000]);
  assert.deepEqual(f.calls.assets.map(options => options.predicates.value), ['picture', 'video']);
  assert.equal(f.calls.resultClose, 2);
  assert.equal(f.calls.helperRelease, 1);
  assert.equal(f.backup.errorText, '');
});

test('cancel leaves all previous selections intact without reopening files', async () => {
  const f = fixture();
  await seed(f);
  await f.select([]);
  assert.equal(f.backup.sources.length, 1);
  assert.match(f.backup.status, /取消/);
  assert.equal(f.backup.errorText, '');
  assert.equal(f.calls.open.length, 1);
  assertIdle(f.backup);
});

test('picker permission failure preserves previous selection and hides raw service errors', async () => {
  const f = fixture();
  await seed(f);
  f.setPicker(async () => { throw { code: 201, message: 'private uri token' }; });
  await f.backup.select(context);
  assert.equal(f.backup.sources[0].name, '真实相片.heic');
  assert.match(f.backup.errorText, /授权/);
  assert.doesNotMatch(f.backup.errorText, /private|token/);
  assertIdle(f.backup);
});

test('one denied URI is skipped while previous and other authorized choices remain available', async () => {
  const f = fixture();
  await seed(f);
  await f.select([
    f.add('denied', '无权.jpg', 10, { openError: { code: 13900012 } }),
    f.add('video', '视频.mp4', 20),
  ]);
  assert.deepEqual(plain(f.backup.sources).map(s => s.name), ['真实相片.heic', '视频.mp4']);
  assert.match(f.backup.errorText, /授权/);
  assert.equal(f.calls.close.length, 2);
  assert.equal(f.handles.size, 0);
});

test('metadata and name failures always close their opened descriptors and preserve old choices', async () => {
  const f = fixture();
  await seed(f);
  await f.select([
    f.add('stat-failed', 'a.jpg', 10, { statError: { code: 13900002 } }),
    f.add('name-failed', 'b.jpg', 10, { nameError: { code: 13900012 } }),
  ]);
  assert.equal(f.backup.sources.length, 1);
  assert.equal(f.calls.close.length, 3);
  assert.equal(f.handles.size, 0);
  assert.notEqual(f.backup.errorText, '');
});

test('metadata failure remains the visible reason when closing the picker file also fails', async () => {
  const f = fixture();
  await f.select([f.add('missing', 'a.jpg', 10, {
    statError: { code: 13900002 }, closeError: { code: 13900042 },
  })]);
  assert.equal(f.backup.sources.length, 0);
  assert.match(f.backup.errorText, /已不可用/);
  assert.equal(f.calls.close.length, 1);
});

test('close failure is reported instead of presenting the file as successfully selected', async () => {
  const f = fixture();
  await f.select([f.add('close-failed', 'a.jpg', 10, { closeError: { code: 13900042 } })]);
  assert.equal(f.backup.sources.length, 0);
  assert.notEqual(f.backup.errorText, '');
  assert.equal(f.calls.close.length, 1);
});

test('duplicate URIs within a batch and across selections open only once', async () => {
  const f = fixture();
  const uri = f.add('file://media/Photo/100', '相片.jpg');
  await f.select([uri, uri]);
  await f.select([uri]);
  assert.equal(f.backup.sources.length, 1);
  assert.equal(f.calls.open.length, 1);
  assert.match(f.backup.status, /重复/);
});

test('different authorized URIs with equal display names retain all contents under distinct names', async () => {
  const f = fixture();
  await f.select([
    f.add('a', '相片.jpg'), f.add('b', '相片 (2).jpg'), f.add('c', '相片.jpg'),
    f.add('d', 'README'), f.add('e', 'README'),
  ]);
  assert.deepEqual(plain(f.backup.sources).map(s => s.name), ['相片.jpg', '相片 (2).jpg', '相片 (3).jpg', 'README', 'README (2)']);
  const names = f.backup.sources.map(s => s.name);
  assert.equal(new Set(names).size, 5);
});

test('exact 256 MiB per file and 512 MiB per batch pass; a later byte over the total is skipped', async () => {
  const f = fixture();
  await f.select([f.add('a', 'a.jpg', 256 * MiB), f.add('b', 'b.mp4', 256 * MiB)]);
  assert.equal(f.backup.sources.length, 2);
  assert.equal(f.backup.sources.reduce((total, s) => total + s.bytes, 0), 512 * MiB);
  await f.select([f.add('c', 'c.jpg', 1)]);
  assert.equal(f.backup.sources.length, 2);
  assert.match(f.backup.errorText, /512 MiB/);
  assert.equal(f.handles.size, 0);
});

test('an oversized file is skipped without rejecting smaller files in the same batch', async () => {
  const f = fixture();
  await f.select([f.add('large', '大视频.mp4', 256 * MiB + 1), f.add('small', '小相片.jpg', 0)]);
  assert.deepEqual(plain(f.backup.sources).map(s => s.uri), ['small']);
  assert.match(f.backup.errorText, /256 MiB/);
  assert.equal(f.calls.close.length, 2);
});

test('only 20 distinct items remain selectable even if the picker returns more', async () => {
  const f = fixture();
  const uris = Array.from({ length: 21 }, (_, i) => f.add(`uri-${i}`, `${i}.jpg`, 1));
  await f.select(uris);
  assert.equal(f.backup.sources.length, 20);
  assert.equal(f.calls.open.length, 20);
  assert.match(f.backup.errorText, /20/);
  await f.select([f.add('extra', 'extra.mp4', 1)]);
  assert.equal(f.calls.open.length, 20);
  assert.equal(f.backup.sources.length, 20);
});

test('invalid sizes, directory handles and unsafe names are skipped with clear errors', async () => {
  const f = fixture();
  const uris = [NaN, Infinity, -1, 1.5, Number.MAX_SAFE_INTEGER + 1].map((bytes, i) => f.add(`size-${i}`, `${i}.jpg`, bytes));
  uris.push(f.add('dir', '文件夹', 10, { directory: true }));
  for (const [index, name] of ['', '..', 'a/b.jpg', 'a\\b.jpg', 'a\u0000.jpg'].entries()) {
    uris.push(f.add(`name-${index}`, name));
  }
  await f.select(uris);
  assert.equal(f.backup.sources.length, 0);
  assert.notEqual(f.backup.errorText, '');
  assert.equal(f.calls.close.length, uris.length);
  assert.equal(f.handles.size, 0);
});

test('a second select or submit while the selector is active performs no additional work', async () => {
  const f = fixture();
  const gate = deferred();
  f.setPicker(() => gate.promise);
  const selecting = f.backup.select(context);
  await f.backup.select(context);
  await f.backup.submit(f.connector, f.queue({ acceptedIndices: [], issues: [] }));
  assert.equal(f.calls.pick.length, 1);
  assert.equal(f.calls.upload.length, 0);
  gate.resolve({ photoUris: [] });
  await selecting;
  assertIdle(f.backup);
});

test('accepted source with a startup issue is consumed; only unaccepted sources are retried', async () => {
  const f = fixture();
  await f.select([f.add('a', 'a.jpg', 12), f.add('b', 'b.mp4', 30)]);
  await f.backup.submit(f.connector, f.queue({
    acceptedIndices: [0], issues: [{ index: 0, errorText: '系统任务未能启动。' }, { index: 1, errorText: '本机存储空间不足。' }],
  }));
  assert.deepEqual(plain(f.backup.sources).map(s => s.uri), ['b']);
  assert.deepEqual(f.calls.upload[0], { directory: '/home/Photos', sources: [
    { uri: 'a', name: 'a.jpg', bytes: 12 }, { uri: 'b', name: 'b.mp4', bytes: 30 },
  ] });
  assert.match(f.backup.status, /传输队列/);
  assert.match(f.backup.errorText, /系统任务/);
  assert.doesNotMatch(f.backup.status, /已备份|备份成功|备份完成/);
  await f.backup.submit(f.connector, f.queue({ acceptedIndices: [0], issues: [] }));
  assert.deepEqual(f.calls.upload[1].sources, [{ uri: 'b', name: 'b.mp4', bytes: 30 }]);
  assert.equal(f.backup.sources.length, 0);
  await f.select(['a', 'b']);
  assert.equal(f.backup.sources.length, 0);
  assert.equal(f.calls.open.length, 2);
});

test('all accepted items remain consumed even if every system task reports a startup issue', async () => {
  const f = fixture();
  await seed(f);
  await f.backup.submit(f.connector, f.queue({ acceptedIndices: [0], issues: [{ index: 0, errorText: '请在任务页重试启动。' }] }));
  assert.equal(f.backup.sources.length, 0);
  assert.notEqual(f.backup.errorText, '');
  assert.match(f.backup.status, /上传结果.*传输任务/);
  await f.backup.submit(f.connector, f.queue({ acceptedIndices: [0], issues: [] }));
  assert.equal(f.calls.upload.length, 1);
  assertIdle(f.backup);
});

test('no accepted indices preserves sources; a returned empty result never claims success', async () => {
  const f = fixture();
  await seed(f);
  await f.backup.submit(f.connector, f.queue({ acceptedIndices: [], issues: [] }));
  assert.equal(f.backup.sources.length, 1);
  assert.match(f.backup.status, /没有项目/);
  assert.notEqual(f.backup.errorText, '');
  assertIdle(f.backup);
});

test('queue failure preserves pending sources and uses a readable error instead of raw diagnostics', async () => {
  const f = fixture();
  await seed(f);
  await f.backup.submit(f.connector, f.queue(async () => { throw new Error('sid=secret uri=private'); }));
  assert.equal(f.backup.sources.length, 1);
  assert.match(f.backup.errorText, /连接/);
  assert.doesNotMatch(f.backup.errorText, /secret|private/);
  assertIdle(f.backup);
});

test('failed Photos folder creation and no source never call the queue', async () => {
  const f = fixture();
  const queue = f.queue({ acceptedIndices: [], issues: [] });
  await f.backup.submit(f.connector, queue);
  assert.match(f.backup.errorText, /先选择/);
  await seed(f);
  f.connector.ensurePhotoDirectory = async () => { throw new Error('folder creation failed'); };
  await f.backup.submit(f.connector, queue);
  assert.equal(f.calls.upload.length, 0);
  assert.equal(f.backup.sources.length, 1);
  assertIdle(f.backup);
});

test('submitting serializes further picker and upload calls until the batch resolves', async () => {
  const f = fixture();
  await seed(f);
  const gate = deferred();
  const submitting = f.backup.submit(f.connector, f.queue(() => gate.promise));
  await f.backup.submit(f.connector, f.queue({ acceptedIndices: [0], issues: [] }));
  await f.backup.select(context);
  assert.equal(f.calls.upload.length, 1);
  assert.equal(f.calls.pick.length, 1);
  gate.resolve({ acceptedIndices: [0], issues: [] });
  await submitting;
  assertIdle(f.backup);
});

test('account reset ignores a stale picker response without altering the new selector flags', async () => {
  const f = fixture();
  const oldGate = deferred();
  f.setPicker(() => oldGate.promise);
  const oldSelect = f.backup.select(context);
  f.backup.reset();
  const newGate = deferred();
  f.setPicker(() => newGate.promise);
  const newSelect = f.backup.select(context);
  oldGate.resolve({ photoUris: [f.add('old', '旧账号.jpg')] });
  await oldSelect;
  assert.equal(f.backup.selecting, true);
  assert.equal(f.backup.sources.length, 0);
  assert.equal(f.calls.open.length, 0);
  newGate.resolve({ photoUris: [f.add('new', '新账号.mp4')] });
  await newSelect;
  assert.deepEqual(plain(f.backup.sources).map(s => s.uri), ['new']);
  assertIdle(f.backup);
});

test('account reset during asynchronous open closes the old handle and never publishes the old file', async () => {
  const f = fixture();
  const gate = deferred();
  const uri = f.add('old', '旧相片.jpg', 1, { openGate: gate.promise });
  f.setPicker(async () => ({ photoUris: [uri] }));
  const oldSelect = f.backup.select(context);
  await waitUntil(() => f.calls.open.length === 1);
  f.backup.reset();
  await f.select([f.add('new', '新相片.jpg')]);
  gate.resolve();
  await oldSelect;
  assert.deepEqual(plain(f.backup.sources).map(s => s.uri), ['new']);
  assert.equal(f.calls.close.length, 2);
  assert.equal(f.handles.size, 0);
  assertIdle(f.backup);
});

test('account reset during asynchronous stat closes the old handle and preserves the new selection', async () => {
  const f = fixture();
  const gate = deferred();
  const uri = f.add('old', '旧视频.mp4', 1, { statGate: gate.promise });
  f.setPicker(async () => ({ photoUris: [uri] }));
  const oldSelect = f.backup.select(context);
  await waitUntil(() => f.calls.stat.length === 1);
  f.backup.reset();
  await f.select([f.add('new', '新视频.mp4')]);
  gate.resolve();
  await oldSelect;
  assert.deepEqual(plain(f.backup.sources).map(s => s.uri), ['new']);
  assert.equal(f.handles.size, 0);
  assertIdle(f.backup);
});

test('stale accepted upload results neither consume new choices nor finish the new account batch', async () => {
  const f = fixture();
  await seed(f);
  const oldGate = deferred();
  const oldSubmit = f.backup.submit(f.connector, f.queue(() => oldGate.promise));
  f.backup.reset();
  await f.select(['file://media/Photo/100']);
  const newGate = deferred();
  const newSubmit = f.backup.submit(f.connector, f.queue(() => newGate.promise));
  oldGate.resolve({ acceptedIndices: [0], issues: [{ index: 0, errorText: '旧失败' }] });
  await oldSubmit;
  assert.equal(f.backup.sources.length, 1);
  assert.equal(f.backup.submitting, true);
  assert.equal(f.backup.errorText, '');
  assert.doesNotMatch(f.backup.status, /旧失败/);
  newGate.resolve({ acceptedIndices: [0], issues: [] });
  await newSubmit;
  assert.equal(f.backup.sources.length, 0);
  assertIdle(f.backup);
});

test('a stale rejected upload cannot replace the new account status or error', async () => {
  const f = fixture();
  await seed(f);
  const gate = deferred();
  const oldSubmit = f.backup.submit(f.connector, f.queue(() => gate.promise));
  await new Promise(resolve => setImmediate(resolve));
  f.backup.reset();
  await f.select([f.add('new', '新相片.jpg')]);
  const status = f.backup.status;
  gate.reject(new Error('old failure'));
  await oldSubmit;
  assert.deepEqual(plain(f.backup.sources).map(s => s.uri), ['new']);
  assert.equal(f.backup.status, status);
  assert.equal(f.backup.errorText, '');
  assertIdle(f.backup);
});

test('clear invalidates an active selection and old completion cannot unset a newer selection flag', async () => {
  const f = fixture();
  const oldGate = deferred();
  f.setPicker(() => oldGate.promise);
  const oldSelect = f.backup.select(context);
  f.backup.clear();
  const newGate = deferred();
  f.setPicker(() => newGate.promise);
  const newSelect = f.backup.select(context);
  oldGate.reject({ code: 201 });
  await oldSelect;
  assert.equal(f.backup.selecting, true);
  assert.equal(f.backup.errorText, '');
  newGate.resolve({ photoUris: [] });
  await newSelect;
  assertIdle(f.backup);
});

test('clear during upload waits for acceptance and retains duplicate protection for the current account', async () => {
  const f = fixture();
  await seed(f);
  const gate = deferred();
  const submitting = f.backup.submit(f.connector, f.queue(() => gate.promise));
  await new Promise(resolve => setImmediate(resolve));
  f.backup.clear();
  assert.equal(f.backup.sources.length, 0);
  assert.equal(f.backup.submitting, true);
  await f.backup.select(context);
  assert.equal(f.calls.pick.length, 1);
  gate.resolve({ acceptedIndices: [0], issues: [] });
  await submitting;
  assert.equal(f.backup.status, '');
  assertIdle(f.backup);
  await f.select(['file://media/Photo/100']);
  assert.equal(f.backup.sources.length, 0);
  assert.equal(f.calls.open.length, 1);
  f.backup.reset();
  await f.select(['file://media/Photo/100']);
  assert.equal(f.backup.sources.length, 1);
});

test('already accepted display names stay distinct for later batches until account reset', async () => {
  const f = fixture();
  await seed(f);
  await f.backup.submit(f.connector, f.queue({ acceptedIndices: [0], issues: [] }));
  f.backup.clear();
  await f.select([f.add('second', '真实相片.heic')]);
  assert.equal(f.backup.sources[0].name, '真实相片 (2).heic');
  f.backup.reset();
  await f.select(['second']);
  assert.equal(f.backup.sources[0].name, '真实相片.heic');
});

test('dispose invalidates an unfinished selection and clears all visible state', async () => {
  const f = fixture();
  await seed(f);
  const gate = deferred();
  f.setPicker(() => gate.promise);
  const selecting = f.backup.select(context);
  f.backup.dispose();
  gate.resolve({ photoUris: [f.add('late', '迟到.jpg')] });
  await selecting;
  assert.equal(f.backup.sources.length, 0);
  assert.equal(f.backup.status, '');
  assert.equal(f.backup.errorText, '');
  assertIdle(f.backup);
});
test('noncontiguous accepted indices refer to the original batch rather than issue or result order', async () => {
  const f = fixture();
  await f.select([f.add('a', 'a.jpg'), f.add('b', 'b.jpg'), f.add('c', 'c.mp4')]);
  await f.backup.submit(f.connector, f.queue({ acceptedIndices: [2, 0], issues: [{ index: 1, errorText: '读取授权已失效。' }] }));
  assert.deepEqual(plain(f.backup.sources).map(s => s.uri), ['b']);
  await f.backup.submit(f.connector, f.queue({ acceptedIndices: [0], issues: [] }));
  assert.deepEqual(f.calls.upload[1].sources.map(s => s.uri), ['b']);
});
function selectionQueue(remotePath, state, extras = {}) {
  return { ready: true, items: [{ direction: 'upload', remotePath, state }], ...extras };
}

async function acceptedSeed(f) {
  await seed(f);
  await f.backup.submit(f.connector, f.queue({ acceptedIndices: [0], issues: [] }));
}

test('explicitly closed upload releases its accepted URI and display name for a new selection', async () => {
  const f = fixture();
  await acceptedSeed(f);
  await f.select(['file://media/Photo/100'], selectionQueue('/home/Photos/PhotoLibrary/2024/01/真实相片.heic', 'closed'));
  assert.deepEqual(plain(f.backup.sources), [{ uri: 'file://media/Photo/100', name: '真实相片.heic', bytes: 25, takenAt: 0, modifiedAt: 1704067200 }]);
  assert.equal(f.calls.open.length, 2);
  await f.backup.submit(f.connector, f.queue({ acceptedIndices: [0], issues: [] }));
  assert.equal(f.calls.upload.length, 2);
  assert.equal(f.calls.upload[1].sources[0].name, '真实相片.heic');
});

test('a fully removed record in a ready queue releases both the accepted URI and occupied name', async () => {
  const f = fixture();
  await acceptedSeed(f);
  const loadedQueue = { ready: true, items: [] };
  await f.select(['file://media/Photo/100'], loadedQueue);
  assert.equal(f.backup.sources[0].name, '真实相片.heic');
  f.backup.clear();
  await f.select([f.add('other-photo', '真实相片.heic')], loadedQueue);
  assert.equal(f.backup.sources[0].name, '真实相片.heic');
});

test('existing uploads protect accepted URIs in every state except closed, including clearing', async () => {
  const f = fixture();
  await acceptedSeed(f);
  for (const state of ['preparing', 'queued', 'creating', 'running', 'waiting', 'verifying', 'completed', 'failed', 'cancelled', 'unknown', 'clearing']) {
    await f.select(['file://media/Photo/100'], selectionQueue('/home/Photos/PhotoLibrary/2024/01/真实相片.heic', state));
    assert.equal(f.backup.sources.length, 0, `URI must remain protected in ${state}`);
  }
  assert.equal(f.calls.open.length, 1);
  await f.select([f.add('other-photo', '真实相片.heic')], selectionQueue('/home/Photos/PhotoLibrary/2024/01/真实相片.heic', 'failed'));
  assert.equal(f.backup.sources[0].name, '真实相片 (2).heic');
});

test('an unloaded queue or absent queue cannot release accepted URIs even when its visible records are empty or closed', async () => {
  const f = fixture();
  await acceptedSeed(f);
  for (const queue of [undefined, { ready: false, items: [] }, selectionQueue('/home/Photos/PhotoLibrary/2024/01/真实相片.heic', 'closed', { ready: false })]) {
    await f.select(['file://media/Photo/100'], queue);
    assert.equal(f.backup.sources.length, 0);
  }
  assert.equal(f.calls.open.length, 1);
  await f.select([f.add('other-photo', '真实相片.heic')], { ready: false, items: [] });
  assert.equal(f.backup.sources[0].name, '真实相片 (2).heic');
});

test('target reconciliation matches upload direction and the exact original remote path', async () => {
  const f = fixture();
  await acceptedSeed(f, '/photos/');
  const queue = { ready: true, items: [
    { direction: 'download', remotePath: '/home/Photos/PhotoLibrary/2024/01/真实相片.heic', state: 'running' },
    { direction: 'upload', remotePath: '/other/真实相片.heic', state: 'unknown' },
  ] };
  await f.select(['file://media/Photo/100'], queue);
  assert.equal(f.backup.sources.length, 1);
  assert.equal(f.backup.sources[0].name, '真实相片.heic');
});

test('a closed target does not release protection while another upload of that same path remains unresolved', async () => {
  const f = fixture();
  await acceptedSeed(f);
  const queue = { ready: true, items: [
    { direction: 'upload', remotePath: '/home/Photos/PhotoLibrary/2024/01/真实相片.heic', state: 'closed' },
    { direction: 'upload', remotePath: '/home/Photos/PhotoLibrary/2024/01/真实相片.heic', state: 'unknown' },
  ] };
  await f.select(['file://media/Photo/100'], queue);
  assert.equal(f.backup.sources.length, 0);
  queue.items[1].state = 'closed';
  await f.select(['file://media/Photo/100'], queue);
  assert.equal(f.backup.sources.length, 1);
  assert.equal(f.backup.sources[0].name, '真实相片.heic');
});

test('late acceptance after clear records the real target even when task startup reported an issue', async () => {
  const f = fixture();
  await seed(f);
  const gate = deferred();
  const uploading = f.backup.submit(f.connector, f.queue(() => gate.promise));
  await new Promise(resolve => setImmediate(resolve));
  f.backup.clear();
  const queue = selectionQueue('/home/Photos/PhotoLibrary/2024/01/真实相片.heic', 'failed');
  gate.resolve({ acceptedIndices: [0], issues: [{ index: 0, errorText: '系统任务启动失败。' }] });
  await uploading;
  assert.equal(f.backup.status, '');
  assert.equal(f.backup.errorText, '');
  await f.select(['file://media/Photo/100'], queue);
  assert.equal(f.backup.sources.length, 0);
  assert.equal(f.calls.open.length, 1);
  queue.items[0].state = 'clearing';
  await f.select(['file://media/Photo/100'], queue);
  assert.equal(f.backup.sources.length, 0);
  queue.items = [];
  await f.select(['file://media/Photo/100'], queue);
  assert.equal(f.backup.sources.length, 1);
  assert.equal(f.backup.sources[0].name, '真实相片.heic');
});
