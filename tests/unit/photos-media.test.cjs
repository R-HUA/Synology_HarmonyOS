const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const util = require('../helpers/arkts-text-decoder.cjs');
const sdkRoot = process.env.HARMONY_SDK_ROOT || path.join(process.env.DEVECO_CLI_CLT_PATH || 'C:/Program Files/command-line-tools', 'sdk/default');
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(relative, mocks = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets', relative), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, Error, Uint8Array, ArrayBuffer,
    require: id => { assert.ok(Object.hasOwn(mocks, id), 'unexpected dependency ' + id); return mocks[id]; } });
  return module.exports;
}
const dsm = load('core/domain/DsmProtocol.ts');
const utf8 = load('platform/Utf8Codec.ets', { '@kit.ArkTS': { util }, '../core/domain/DsmProtocol': dsm });
const photos = load('core/domain/PhotosProtocol.ts', { './DsmProtocol': dsm });
const { NasFailure, NasErrorKind: K } = dsm;
const { PhotosSpace: S } = photos;
const isKind = kind => error => error instanceof NasFailure && error.kind === kind;
const failure = kind => new NasFailure(kind, '失败');
const turn = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(a => { resolve = a; }); return { promise, resolve }; };
const jpeg = new Uint8Array([255, 216, 255, 224, 0, 0, 0, 0]);
const item = id => ({ id, space: S.Personal, filename: '照片-' + id + '.jpg', bytes: 8,
  mediaType: 'photo', thumbnail: { unitId: id, cacheKey: 'cache-' + id } });
const plan = (api = 'SYNO.Foto.Thumbnail') => ({ address: 'https://nas.example.test:5001/webapi/entry.cgi',
  session: { sid: 'private-sid', synoToken: 'private-token' }, fields: [
    { name: 'api', content: api }, { name: 'version', content: '1' }, { name: 'method', content: 'get' } ] });
function storage() {
  const files = new Map(); const dirs = new Set(); const handles = new Map(); let fd = 1;
  const removed = [];
  const io = { OpenMode: { CREATE: 64, READ_WRITE: 2, READ_ONLY: 0 },
    accessSync: name => files.has(name) || dirs.has(name), mkdirSync: name => dirs.add(name),
    openSync(name) { const handle = { fd: fd++ }; const entry = { name, bytes: new Uint8Array(0) }; files.set(name, entry); handles.set(handle.fd, entry); return handle; },
    writeSync(id, buffer) { const entry = handles.get(id); assert.ok(entry); const chunk = new Uint8Array(buffer);
      const combined = new Uint8Array(entry.bytes.length + chunk.length); combined.set(entry.bytes); combined.set(chunk, entry.bytes.length);
      entry.bytes = combined; return chunk.length; },
    statSync(id) { if (dirs.has(id)) return { size: 0, isDirectory: () => true };
      const entry = typeof id === 'number' ? handles.get(id) : files.get(id); assert.ok(entry); return { size: entry.bytes.length, isDirectory: () => false }; },
    closeSync(handle) { assert.ok(handles.delete(handle.fd)); },
    unlinkSync(name) { removed.push(name); files.delete(name); },
    async unlink(name) { removed.push(name); files.delete(name); },
    rmdirSync(name) { removed.push(name); dirs.delete(name); for (const key of files.keys()) if (key.startsWith(name + '/')) files.delete(key); },
  };
  return { io, files, dirs, handles, removed };
}
function transportFixture() {
  const disk = storage(); const replies = []; const sessions = []; const requests = [];
  const diagnostics = [];
  class Request { constructor(url, method, headers, content) { Object.assign(this, { url, method, headers, content }); } }
  const rcp = { Request, createSession(configuration) {
    assert.equal(configuration.requestConfiguration.transfer.autoRedirect, false);
    const session = { cancelled: false, async fetch(request) {
      requests.push(request); assert.ok(replies.length); const response = replies.shift();
      if (typeof response === 'function') return response(request, session);
      for (const chunk of response.chunks) { await request.destination(chunk); if (session.cancelled) throw new Error('cancelled'); }
      return { statusCode: response.status || 200, headers: response.headers || {}, toString() { throw new Error('no full response aggregation'); } };
    }, cancel() { session.cancelled = true; }, close() { session.closed = true; } };
    sessions.push(session); return session;
  } };
  const { RcpNasTransport } = load('core/network/RcpNasTransport.ets', { '@kit.RemoteCommunicationKit': { rcp },
    '@kit.PerformanceAnalysisKit': { hilog: { error(...args) { diagnostics.push(args); } } },
    '@kit.CoreFileKit': { fileIo: disk.io }, '../../platform/Utf8Codec': utf8, '../domain/DsmProtocol': dsm,
    '../domain/PhotosProtocol': photos });
  return { RcpNasTransport, disk, replies, sessions, requests, diagnostics };
}

test('media close failure prevents delivery and still removes the private file', async () => {
  const fixture = transportFixture();
  fixture.replies.push({ chunks: [jpeg.buffer], headers: { 'content-type': 'image/jpeg' } });
  fixture.disk.io.closeSync = () => { throw Object.assign(new Error('close failed'), { code: 13900005 }); };
  await assert.rejects(new fixture.RcpNasTransport().downloadMedia(plan(), '/cache/media', true, undefined, () => true),
    error => error.kind === K.Protocol && error.code === 13900005);
  assert.deepEqual(fixture.disk.removed, ['/cache/media']);
  assert.equal(fixture.disk.files.has('/cache/media'), false);
});

test('media cleanup failures cannot replace the original protocol or cancellation failure', async () => {
  for (const cancelled of [false, true]) {
    const fixture = transportFixture();
    fixture.replies.push({ status: 302, chunks: [jpeg.buffer] });
    fixture.disk.io.closeSync = () => { throw Object.assign(new Error('close failed'), { code: 13900005 }); };
    let removalAttempted = false;
    fixture.disk.io.unlinkSync = () => { removalAttempted = true; throw Object.assign(new Error('unlink failed'), { code: 13900013 }); };
    await assert.rejects(new fixture.RcpNasTransport().downloadMedia(plan(), '/cache/media', true, undefined, () => !cancelled),
      isKind(cancelled ? K.Cancelled : K.Http));
    assert.equal(removalAttempted, true);
    assert.equal(fixture.diagnostics.length, 2);
    assert.ok(fixture.diagnostics.every(args => !JSON.stringify(args).includes('/cache/media')));
  }
});

test('UTF-8 distinguishes complete text from truncated or binary prefixes', () => {
  assert.equal(utf8.decodeUtf8Complete(new Uint8Array()), '');
  assert.equal(utf8.decodeUtf8Complete(new TextEncoder().encode('\uFEFF中文😀')), '中文😀');
  assert.throws(() => utf8.decodeUtf8Complete(new Uint8Array([0xe4, 0xb8])), isKind(K.Protocol));
  assert.throws(() => utf8.decodeUtf8Complete(new Uint8Array([0xff])), isKind(K.Protocol));
  assert.equal(utf8.decodeResponsePrefix(new Uint8Array([0xe4, 0xb8])), '\uFFFD');
  assert.doesNotThrow(() => utf8.decodeResponsePrefix(jpeg));
  assert.equal(utf8.decodeResponsePrefix(new Uint8Array()), '');
});

test('RCP decodes aggregated UTF-8 across every network byte boundary', async () => {
  const text = JSON.stringify({ success: true, data: { name: '中文😀' } });
  const bytes = new TextEncoder().encode(text);
  for (let split = 1; split < bytes.length; split++) {
    const fixture = transportFixture();
    fixture.replies.push({ chunks: [bytes.slice(0, split).buffer, bytes.slice(split).buffer] });
    const reply = await new fixture.RcpNasTransport().post('https://nas.example.test/webapi/entry.cgi', '');
    assert.equal(reply.text, text);
  }
});

test('RCP reports malformed complete UTF-8 as a protocol error, not a network error', async () => {
  const fixture = transportFixture();
  fixture.replies.push({ chunks: [new Uint8Array([0xe4, 0xb8]).buffer] });
  await assert.rejects(new fixture.RcpNasTransport().post('https://nas.example.test/webapi/entry.cgi', ''), isKind(K.Protocol));
});

test('RCP uses POST Cookie/token/no-store, streams bounded chunks to a private file and never aggregates originals', async () => {
  const f = transportFixture(); const transport = new f.RcpNasTransport();
  f.replies.push({ chunks: [jpeg.slice(0, 4).buffer, jpeg.slice(4).buffer], headers: { 'Content-Type': 'image/jpeg', 'Content-Length': '8' } });
  assert.equal(await transport.downloadMedia(plan(), '/cache/random.media', true, undefined, () => true), 8);
  assert.deepEqual(Array.from(f.disk.files.get('/cache/random.media').bytes), Array.from(jpeg));
  const request = f.requests[0];
  assert.equal(request.method, 'POST');
  assert.equal(request.headers['X-SYNO-TOKEN'], 'private-token');
  assert.equal(request.cookies.id, 'private-sid');
  assert.equal(request.headers['Cache-Control'], 'no-store');
  assert.equal(request.cacheControl.noStore, true);
  assert.equal(request.configuration.transfer.autoRedirect, false);
  assert.ok(!request.url.includes('private'));
  assert.ok(!request.content.includes('private'));
  assert.equal(f.disk.handles.size, 0);
  transport.close();
});

test('RCP refuses HTTP, JSON business success/error, invalid MIME and wrong file lengths and removes every partial artifact', async () => {
  const cases = [
    { status: 302, chunks: [jpeg.buffer], headers: { 'content-type': 'image/jpeg' }, kind: K.Http },
    { chunks: [new TextEncoder().encode(JSON.stringify({ success: false, error: { code: 119 } })).buffer], headers: { 'content-type': 'application/json' }, kind: K.SessionExpired },
    { chunks: [new TextEncoder().encode(JSON.stringify({ success: true, data: {} })).buffer], headers: { 'content-type': 'application/json' }, kind: K.Protocol },
    { chunks: [jpeg.buffer], headers: { 'content-type': 'text/html' }, kind: K.Protocol },
    { chunks: [jpeg.buffer], headers: { 'content-type': 'image/jpeg', 'content-length': '9' }, kind: K.Protocol },
    { chunks: [jpeg.buffer], headers: { 'content-type': ['image/jpeg', 'image/png'] }, kind: K.Protocol },
  ];
  for (const response of cases) {
    const f = transportFixture(); const transport = new f.RcpNasTransport(); f.replies.push(response);
    await assert.rejects(transport.downloadMedia(plan(), '/cache/partial', true, undefined, () => true), isKind(response.kind));
    assert.equal(f.disk.files.has('/cache/partial'), false);
    assert.equal(f.disk.handles.size, 0);
    transport.close();
  }
});

test('RCP limits thumbnails while streaming and refuses oversized originals before requesting or allocating a file', async () => {
  const f = transportFixture(); const transport = new f.RcpNasTransport();
  f.replies.push({ chunks: [new ArrayBuffer(photos.PHOTO_THUMBNAIL_MAX_BYTES + 1)], headers: { 'content-type': 'image/jpeg' } });
  await assert.rejects(transport.downloadMedia(plan(), '/cache/oversize', true, undefined, () => true), isKind(K.Protocol));
  assert.equal(f.disk.files.has('/cache/oversize'), false);
  assert.equal(f.sessions[0].cancelled, true);
  await assert.rejects(transport.downloadMedia(plan('SYNO.Foto.Download'), '/cache/big-original', false,
    photos.PHOTO_ORIGINAL_MAX_BYTES + 1, () => true), isKind(K.InvalidInput));
  assert.equal(f.requests.length, 1);
  assert.equal(f.disk.files.has('/cache/big-original'), false);
  transport.close();
});

test('account switch or close stops further stream writes and cleans partial originals', async () => {
  const f = transportFixture(); const transport = new f.RcpNasTransport(); let current = true;
  f.replies.push(async (request, session) => {
    await request.destination(jpeg.slice(0, 4).buffer);
    current = false;
    await request.destination(jpeg.slice(4).buffer);
    assert.equal(f.disk.files.get('/cache/partial').bytes.length, 4);
    assert.equal(session.cancelled, true);
    throw new Error('cancelled');
  });
  await assert.rejects(transport.downloadMedia(plan('SYNO.Foto.Download'), '/cache/partial', false, 8, () => current), isKind(K.Cancelled));
  assert.equal(f.disk.files.size, 0);
  assert.equal(f.disk.handles.size, 0);
  transport.close();
});

test('bounded business JSON requests preserve HTTP status and cancel over 1 MiB before combining bytes', async () => {
  const f = transportFixture(); const transport = new f.RcpNasTransport();
  const text = JSON.stringify({ success: true, data: { list: [] } });
  f.replies.push({ chunks: [new TextEncoder().encode(text).buffer], headers: {} });
  const reply = await transport.post('https://nas.test/webapi/entry.cgi', 'api=query');
  assert.equal(reply.text, text);
  f.replies.push({ chunks: [new ArrayBuffer(1024 * 1024 + 1)], headers: {} });
  await assert.rejects(transport.post('https://nas.test/webapi/entry.cgi', 'api=query'), isKind(K.Protocol));
  assert.equal(f.sessions[0].cancelled, true);
  transport.close();
});

function storeFixture() {
  const disk = storage(); const jobs = []; let id = 1, concurrent = 0, maximum = 0, changed = 0;
  let destinations = [], copyFailure, copies = 0;
  class MockTransport {
    closed = false;
    async downloadMedia(plan, destination, thumbnail, expected, current) {
      const gate = deferred(); const job = { plan, destination, thumbnail, current, gate, transport: this };
      jobs.push(job); concurrent++; maximum = Math.max(maximum, concurrent);
      try {
        const bytes = await gate.promise;
        if (this.closed || !current()) throw failure(K.Cancelled);
        disk.files.set(destination, { name: destination, bytes: new Uint8Array(bytes) });
        return bytes;
      } finally { concurrent--; }
    }
    close() { this.closed = true; }
  }
  const connector = { photoThumbnailPlan: () => plan(), photoOriginalPlan: () => plan('SYNO.Foto.Download'),
    async photoMediaFailure(error) { throw error; } };
  const { PhotoMediaStore } = load('features/photos/PhotoMediaStore.ets', {
    '@kit.CoreFileKit': { fileIo: disk.io, picker: { DocumentSaveOptions: class {}, DocumentViewPicker: class { async save() { return destinations; } } } },
    '@kit.ArkTS': { util: { generateRandomUUID: () => '11111111-1111-4111-8111-' + String(id++).padStart(12, '0') } },
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } }, '../../core/domain/DsmProtocol': dsm,
    '../../core/domain/PhotosProtocol': photos, '../../core/network/RcpNasTransport': { RcpNasTransport: MockTransport },
    '../transfers/TransferQueueFiles': { async copyTransferFile(source, destination, bytes, current, exporting) {
      copies++; current(); assert.ok(disk.files.has(source)); assert.equal(exporting, true);
      if (copyFailure) throw copyFailure;
      disk.files.set(destination, { name: destination, bytes: new Uint8Array(bytes) });
    } },
  });
  const store = new PhotoMediaStore(); store.attach({ cacheDir: '/cache/alice' }, connector, () => { changed++; });
  return { store, jobs, disk, connector, PhotoMediaStore, max: () => maximum, change: () => changed,
    select: value => { destinations = value; }, failCopy: value => { copyFailure = value; }, copies: () => copies };
}

test('a failed cache directory creation is not reused on the next thumbnail attempt', async () => {
  const fixture = storeFixture();
  const mkdir = fixture.disk.io.mkdirSync;
  fixture.disk.io.mkdirSync = () => { throw new Error('mkdir failed'); };
  await assert.rejects(fixture.store.thumbnail(item(1)), isKind(K.Protocol));
  await turn();
  assert.equal(fixture.store.directory, '');
  assert.equal(fixture.jobs.length, 0);
  fixture.disk.io.mkdirSync = mkdir;
  const next = fixture.store.thumbnail(item(1));
  assert.ok(fixture.disk.dirs.has(fixture.store.directory));
  fixture.jobs[0].gate.resolve(8);
  await next;
  fixture.store.reset();
});

test('thumbnail work is deduplicated, capped at three active requests and caches stay bounded by count and bytes', async () => {
  const f = storeFixture(); const requests = Array.from({ length: 30 }, (_, id) => f.store.thumbnail(item(id + 1)));
  assert.equal(f.store.thumbnail(item(1)), requests[0]);
  assert.equal(f.jobs.length, 3);
  for (let index = 0; index < 30; index++) { f.jobs[index].gate.resolve(1024 * 1024); await turn(); }
  await Promise.all(requests);
  assert.equal(f.max(), 3);
  assert.equal(f.store.cache.length, 24);
  assert.equal(f.disk.files.size, 24);
  assert.equal(f.store.thumbnailPath(item(1)), '');
  assert.ok(f.store.thumbnailPath(item(30)).startsWith('/cache/alice/photos-v2/'));
  f.store.reset();
  assert.equal(f.disk.files.size, 0);
});

test('account reset cancels queued and inflight thumbnail jobs and never publishes the old paths into the next account', async () => {
  const f = storeFixture();
  const requests = Array.from({ length: 8 }, (_, id) => f.store.thumbnail(item(id + 1)));
  const results = Promise.allSettled(requests);
  const oldDirectory = f.store.directory;
  f.store.attach({ cacheDir: '/cache/bob' }, f.connector, () => {});
  for (const job of f.jobs) job.gate.resolve(8);
  const settled = await results;
  assert.ok(settled.every(result => result.status === 'rejected' && result.reason.kind === K.Cancelled));
  assert.equal(f.store.cache.length, 0);
  assert.equal(f.store.active, 0);
  assert.ok(f.disk.removed.includes(oldDirectory));
  const next = f.store.thumbnail(item(1));
  const newJob = f.jobs.at(-1);
  assert.ok(newJob.destination.startsWith('/cache/bob/photos-v2/'));
  newJob.gate.resolve(8); await next;
  assert.ok(f.store.thumbnailPath(item(1)).startsWith('/cache/bob/'));
  f.store.reset();
});

test('closing detail cancels foreground original and export reports only successful picker copies', async () => {
  const f = storeFixture();
  const old = f.store.original(item(1));
  const settled = Promise.allSettled([old]);
  f.store.closeDetail();
  f.jobs[0].gate.resolve(8);
  assert.equal((await settled)[0].reason.kind, K.Cancelled);
  assert.equal(f.store.originalFile, '');
  const next = f.store.original(item(1)); f.jobs.at(-1).gate.resolve(8); await next;
  assert.equal(await f.store.exportOriginal(item(1)), false);
  assert.equal(f.copies(), 0);
  f.select(['file://documents/photo.jpg']);
  assert.equal(await f.store.exportOriginal(item(1)), true);
  assert.equal(f.copies(), 1);
  f.failCopy(failure(K.Protocol));
  await assert.rejects(f.store.exportOriginal(item(1)), isKind(K.Protocol));
  assert.ok(f.disk.removed.includes('file://documents/photo.jpg'));
  f.store.reset();
});


test('a failed private-cache cleanup blocks new caching until a successful owned-path retry', async () => {
  const f = storeFixture();
  const first = f.store.thumbnail(item(1)); f.jobs[0].gate.resolve(8); await first;
  const remove = f.disk.io.rmdirSync;
  f.disk.io.rmdirSync = () => { throw new Error('I/O failure'); };
  f.store.attach({ cacheDir: '/cache/bob' }, f.connector, () => {});
  assert.ok(f.store.cleanupErrorText);
  await assert.rejects(f.store.thumbnail(item(2)), isKind(K.Protocol));
  assert.equal(f.jobs.length, 1);
  f.disk.io.rmdirSync = remove;
  f.store.attach({ cacheDir: '/cache/bob' }, f.connector, () => {});
  assert.equal(f.store.cleanupErrorText, '');
  const next = f.store.thumbnail(item(2)); f.jobs.at(-1).gate.resolve(8); await next;
  assert.ok(f.store.thumbnailPath(item(2)).startsWith('/cache/bob/'));
  f.store.reset();
});


test('original MIME must match a recognized image/video signature even when HTTP and length look successful', async () => {
  const mp4 = new Uint8Array([0, 0, 0, 24, 102, 116, 121, 112, 105, 115, 111, 109, 0, 0, 0, 0]);
  const cases = [
    { type: 'image/jpeg', body: new Uint8Array(8), expected: K.Protocol },
    { type: 'video/mp4', body: new Uint8Array(8), expected: K.Protocol },
    { type: 'video/mp4', body: jpeg, expected: K.Protocol },
    { type: 'image/jpeg', body: mp4, expected: K.Protocol },
    { type: 'image/unknown', body: jpeg, expected: K.Protocol },
    { type: 'application/octet-stream', body: new Uint8Array(8), expected: K.Protocol },
    { type: 'image/jpeg', body: jpeg },
    { type: 'video/mp4', body: mp4 },
    { type: 'application/octet-stream', body: mp4 },
  ];
  for (const response of cases) {
    const f = transportFixture(); const transport = new f.RcpNasTransport();
    f.replies.push({ chunks: [response.body.buffer], headers: { 'content-type': response.type, 'content-length': String(response.body.length) } });
    const result = transport.downloadMedia(plan('SYNO.Foto.Download'), '/cache/original', false, response.body.length, () => true);
    if (response.expected) {
      await assert.rejects(result, isKind(response.expected));
      assert.equal(f.disk.files.has('/cache/original'), false);
    } else assert.equal(await result, response.body.length);
    transport.close();
  }
});

test('shared album access creates independent private caches for identical item IDs without using passphrases as identity or filenames', async () => {
  const f = storeFixture();
  const shared = { ...item(1), space: S.WithMe, sourceSpace: S.Shared, thumbnail: { unitId: 1, cacheKey: 'server-cache' } };
  const firstAccess = { albumId: 3, scope: 'random-album3', passphrase: 'private-share-credential' };
  f.store.setAccess(firstAccess);
  const first = f.store.thumbnail(shared); f.jobs.at(-1).gate.resolve(8); const firstPath = await first;
  assert.ok(f.store.cache.every(entry => !entry.key.includes(firstAccess.passphrase)));
  assert.ok(!firstPath.includes(firstAccess.passphrase));
  f.store.setAccess({ albumId: 4, scope: 'random-album4', passphrase: 'other-share-credential' });
  assert.equal(f.store.thumbnailPath(shared), '');
  assert.equal(f.disk.files.has(firstPath), false);
  const second = f.store.thumbnail(shared); f.jobs.at(-1).gate.resolve(8); const secondPath = await second;
  assert.notEqual(firstPath, secondPath);
  assert.ok(f.store.cache[0].key.includes('random-album4'));
  assert.ok(!f.store.cache[0].key.includes('other-share-credential'));
  f.store.closeDetail();
  assert.equal(f.store.pinnedKeys.length, 0);
  f.store.reset();
  assert.equal(f.store.access, undefined);
});

function realLibrary(f, connector) {
  const { PhotoLibrary } = load('features/photos/PhotoLibrary.ets', {
    '@kit.ArkTS': { util: { generateRandomUUID: () => '11111111-1111-4111-8111-111111111111' } },
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } }, '../../core/domain/DsmProtocol': dsm,
    '../../core/domain/PhotosProtocol': photos, './PhotoMediaStore': { PhotoMediaStore: class { constructor() { return f.store; } } },
  });
  const library = new PhotoLibrary(); library.attach(connector, { cacheDir: '/cache/alice' }, async () => {}); return library;
}


test('an m fallback remains readable while get waits or fails despite 25 other thumbnail completions and byte eviction', async () => {
  const f = storeFixture(); const detail = deferred();
  const connector = { ...f.connector, async photos(space, offset) {
    return offset === 0 ? { items: Array.from({ length: 20 }, (_, i) => item(i + 1)), offset, hasMore: true } :
      { items: Array.from({ length: 6 }, (_, i) => item(i + 21)), offset, hasMore: false };
  }, async photoDetail() { await detail.promise; throw failure(K.Protocol); } };
  const model = realLibrary(f, connector);
  await model.open(S.Personal);
  f.jobs[0].gate.resolve(1024 * 1024); await turn();
  const fallback = model.thumbnailPath(model.items[0]);
  assert.ok(fallback);
  const opened = model.openDetail(model.items[0]);
  assert.equal(model.previewPath, fallback);
  await model.loadMore();
  for (let index = 1; index < 26; index++) { f.jobs[index].gate.resolve(1024 * 1024); await turn(); }
  assert.equal(f.store.cache.length, 24);
  assert.equal(f.disk.files.has(fallback), true);
  assert.equal(model.previewPath, fallback);
  detail.resolve(); await opened;
  assert.ok(model.mediaErrorText);
  assert.equal(f.disk.files.has(fallback), true);
  model.closeDetail();
  const after = f.store.thumbnail(item(27)); f.jobs.at(-1).gate.resolve(1024 * 1024); await after;
  assert.equal(f.disk.files.has(fallback), false);
  model.reset();
});

test('m stays pinned until xl is downloaded and published, then its pin is released', async () => {
  const f = storeFixture(); const detail = deferred();
  const connector = { ...f.connector, async photos() { return { items: [item(1)], offset: 0, hasMore: false }; },
    async photoDetail() { await detail.promise; return item(1); } };
  const model = realLibrary(f, connector);
  await model.open(S.Personal); f.jobs[0].gate.resolve(1024 * 1024); await turn();
  const fallback = model.thumbnailPath(model.items[0]);
  const opened = model.openDetail(model.items[0]);
  detail.resolve(); await turn();
  assert.equal(model.previewPath, fallback);
  assert.equal(f.store.pinnedKeys.length, 2);
  f.jobs.at(-1).gate.resolve(2 * 1024 * 1024); await opened;
  assert.notEqual(model.previewPath, fallback);
  assert.equal(f.disk.files.has(model.previewPath), true);
  assert.equal(f.store.pinnedKeys.length, 1);
  assert.ok(JSON.parse(f.store.pinnedKeys[0]).includes('xl'));
  model.closeDetail();
  assert.equal(f.store.pinnedKeys.length, 0);
  model.reset();
});
