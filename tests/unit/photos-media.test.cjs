const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const util = require('../helpers/arkts-text-decoder.cjs');
const sdkRoot = process.env.HARMONY_SDK_ROOT || path.join(process.env.DEVECO_CLI_CLT_PATH || 'C:/Program Files/command-line-tools', 'sdk/default');
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(relative, mocks = {}, globals = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets', relative), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, Error, Uint8Array, ArrayBuffer, setTimeout, clearTimeout, ...globals,
    require: id => {
      if (id === '../../platform/LocalSpaceBudget') { return mocks[id] || require('../helpers/load-space-budget.cjs')(mocks['../domain/DsmProtocol'] || mocks['../../core/domain/DsmProtocol']); } assert.ok(Object.hasOwn(mocks, id), 'unexpected dependency ' + id); return mocks[id]; } });
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
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
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
  const contracts = load('core/network/NasTransferTransport.ts', { '../domain/DsmProtocol': dsm });
  const transferTransport = load('core/network/RcpTransferTransport.ets', { '@kit.RemoteCommunicationKit': { rcp },
    '@kit.PerformanceAnalysisKit': { hilog: { error(...args) { diagnostics.push(args); } } },
    '@kit.CoreFileKit': { fileIo: disk.io }, '../domain/DsmProtocol': dsm, './NasTransferTransport': contracts,
    '../../platform/Utf8Codec': utf8 });
  const { RcpNasTransport } = load('core/network/RcpNasTransport.ets', { '@kit.RemoteCommunicationKit': { rcp },
    '@kit.PerformanceAnalysisKit': { hilog: { error(...args) { diagnostics.push(args); } } },
    '@kit.CoreFileKit': { fileIo: disk.io }, '../../platform/Utf8Codec': utf8, '../domain/DsmProtocol': dsm,
    '../domain/PhotosProtocol': photos, './NasTransferTransport': contracts, './RcpTransferTransport': transferTransport });
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
    let checks = 0;
    fixture.disk.io.unlinkSync = () => { removalAttempted = true; throw Object.assign(new Error('unlink failed'), { code: 13900013 }); };
    await assert.rejects(new fixture.RcpNasTransport().downloadMedia(plan(), '/cache/media', true, undefined,
      () => !cancelled || checks++ === 0),
      isKind(cancelled ? K.Cancelled : K.Http));
    assert.equal(removalAttempted, true);
    assert.equal(fixture.diagnostics.length, 2);
    assert.ok(fixture.diagnostics.every(args => !JSON.stringify(args).includes('/cache/media')));
  }
});

test('cancelled media reads stop before network dispatch or file creation', async () => {
  const fixture = transportFixture();
  await assert.rejects(new fixture.RcpNasTransport().downloadMedia(plan(), '/cache/media', true, undefined, () => false),
    isKind(K.Cancelled));
  assert.equal(fixture.requests.length, 0);
  assert.equal(fixture.disk.files.size, 0);
  assert.equal(fixture.disk.removed.length, 0);
});

test('duplicate media headers and impossible write counts cannot publish a private file', async () => {
  for (const badWrite of [false, true]) {
    const fixture = transportFixture();
    fixture.replies.push({ chunks: [jpeg.buffer], headers: { 'Content-Type': 'image/jpeg',
      ...(badWrite ? {} : { 'content-type': 'text/html' }) } });
    if (badWrite) { fixture.disk.io.writeSync = () => jpeg.length + 1; }
    await assert.rejects(new fixture.RcpNasTransport().downloadMedia(plan(), '/cache/media', true, undefined, () => true),
      isKind(K.Protocol));
    assert.equal(fixture.disk.files.size, 0);
    assert.equal(fixture.disk.handles.size, 0);
  }
});

test('RCP close still releases its session when cancellation throws', () => {
  const fixture = transportFixture();
  const transport = new fixture.RcpNasTransport();
  fixture.sessions[0].cancel = () => { throw new Error('cancel failed'); };
  assert.throws(() => transport.close(), /cancel failed/);
  assert.equal(fixture.sessions[0].closed, true);
  assert.doesNotThrow(() => transport.close());
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

function storeFixture(globals = {}) {
  const disk = storage(); const jobs = []; let id = 1, concurrent = 0, maximum = 0, changed = 0;
  const diagnostics = []; let honourCancellation = true;
  let destinations = [], copyFailure, copies = 0;
  class MockTransport {
    closed = false;
    async downloadMedia(plan, destination, thumbnail, expected, current) {
      const gate = deferred(); const job = { plan, destination, thumbnail, current, gate, transport: this };
      jobs.push(job); concurrent++; maximum = Math.max(maximum, concurrent);
      try {
        const bytes = await gate.promise;
        if (honourCancellation && (this.closed || !current())) throw failure(K.Cancelled);
        disk.files.set(destination, { name: destination, bytes: new Uint8Array(bytes) });
        return bytes;
      } finally { concurrent--; }
    }
    close() { this.closed = true; }
  }
  const connector = { photoThumbnailPlan: item => ({ ...plan(), itemId: item.id }), photoOriginalPlan: () => plan('SYNO.Foto.Download'),
    async photoMediaFailure(error) { throw error; } };
  const { PhotoMediaStore } = load('features/photos/PhotoMediaStore.ets', {
    '@kit.CoreFileKit': { fileIo: disk.io, picker: { DocumentSaveOptions: class {}, DocumentViewPicker: class { async save() { return destinations; } } } },
    '@kit.ArkTS': { util: { generateRandomUUID: () => '11111111-1111-4111-8111-' + String(id++).padStart(12, '0') } },
    '@kit.PerformanceAnalysisKit': { hilog: { error(...args) { diagnostics.push(args); } } }, '../../core/domain/DsmProtocol': dsm,
    '../../core/domain/PhotosProtocol': photos, '../../core/network/RcpNasTransport': { RcpNasTransport: MockTransport },
    '../transfers/TransferQueueFiles': { async copyTransferFile(source, destination, bytes, current, exporting) {
      copies++; current(); assert.ok(disk.files.has(source)); assert.equal(exporting, true);
      if (copyFailure) throw copyFailure;
      disk.files.set(destination, { name: destination, bytes: new Uint8Array(bytes) });
    } },
  }, globals);
  const store = new PhotoMediaStore(); store.attach({ cacheDir: '/cache/alice' }, connector, () => { changed++; });
  return { store, jobs, disk, connector, PhotoMediaStore, diagnostics,
    ignoreCancellation: () => { honourCancellation = false; }, max: () => maximum, change: () => changed,
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

function realLibrary(f, connector, globals = {}) {
  const { PhotoLibrary } = load('features/photos/PhotoLibrary.ets', {
    '@kit.ArkTS': { util: { generateRandomUUID: () => '11111111-1111-4111-8111-111111111111' } },
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } }, '../../core/domain/DsmProtocol': dsm,
    '../../core/domain/PhotosProtocol': photos, './PhotoMediaStore': { PhotoMediaStore: class { constructor() { return f.store; } } },
  }, globals);
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
  model.updateViewport('photos', model.items.slice(0, 1), [], false, model.items.length);
  f.jobs[0].gate.resolve(1024 * 1024); await turn();
  const fallback = model.thumbnailPath(model.items[0]);
  assert.ok(fallback);
  const opened = model.openDetail(model.items[0]);
  assert.equal(model.previewPath, fallback);
  await model.loadMore();
  f.store.setDemand([], model.items.slice(1));
  const others = model.items.slice(1).map(photo => f.store.thumbnail(photo));
  for (let index = 1; index < 26; index++) { f.jobs[index].gate.resolve(1024 * 1024); await turn(); }
  await Promise.all(others);
  assert.equal(f.store.cache.length, 24);
  assert.equal(f.disk.files.has(fallback), true);
  assert.equal(model.previewPath, fallback);
  detail.resolve(); await opened;
  assert.ok(model.mediaErrorText);
  assert.equal(f.disk.files.has(fallback), true);
  model.closeDetail();
  model.releaseView('photos');
  f.store.setDemand([], [item(27)]);
  const after = f.store.thumbnail(item(27)); f.jobs.at(-1).gate.resolve(1024 * 1024); await after;
  assert.equal(f.disk.files.has(fallback), false);
  model.reset();
});

test('m stays pinned until xl is downloaded and published, then its pin is released', async () => {
  const f = storeFixture(); const detail = deferred();
  const connector = { ...f.connector, async photos() { return { items: [item(1)], offset: 0, hasMore: false }; },
    async photoDetail() { await detail.promise; return item(1); } };
  const model = realLibrary(f, connector);
  await model.open(S.Personal);
  model.updateViewport('photos', model.items, [], false, model.items.length);
  f.jobs[0].gate.resolve(1024 * 1024); await turn();
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

async function pagedLibrary(f, total = 80, globals = {}) {
  const calls = [];
  const connector = { ...f.connector, async photos(space, offset) {
    calls.push(offset);
    return { items: Array.from({ length: Math.min(20, total - offset) }, (_, i) => item(offset + i + 1)),
      hasMore: offset + 20 < total };
  } };
  const model = realLibrary(f, connector, globals);
  await model.open(S.Personal);
  return { model, calls };
}

async function finishJobs(f, start = 0, bytes = 8) {
  for (let index = start; index < f.jobs.length; index++) {
    f.jobs[index].gate.resolve(bytes); await turn();
  }
}

test('real library does not warm pages; leaving the viewport removes queued work and late results cannot evict visible files', async () => {
  const f = storeFixture(); const { model } = await pagedLibrary(f, 40);
  assert.equal(f.jobs.length, 0);
  model.updateViewport('active', model.items.slice(0, 4), model.items.slice(4, 8), false, model.items.length);
  assert.equal(f.jobs.length, 3);
  assert.equal(f.store.pending.length, 5);
  const old = f.jobs.slice();
  model.updateViewport('active', model.items.slice(8, 12), model.items.slice(12, 16), false, model.items.length);
  assert.ok(old.every(job => job.transport.closed));
  assert.equal(f.jobs.length, 3, 'cancelled transports keep their slot until they exit');
  await finishJobs(f);
  assert.ok(f.jobs.slice(3).every(job => job.plan.itemId >= 9));
  assert.equal(f.max(), 3);
  assert.equal(f.store.cache.length, 8);
  assert.ok(old.every(job => !f.disk.files.has(job.destination)));
  assert.ok(model.thumbnailPath(model.items[8]));
  assert.equal(f.diagnostics.length, 0, 'normal offscreen cancellation does not write error logs');
  model.releaseView('inactive');
  assert.equal(f.store.visibleKeys.size, 4, 'an inactive sibling cannot release the active owner');
  model.releaseView('active');
  assert.equal(f.store.visibleKeys.size, 0);
  model.reset();
});

test('real library coalesces scrolling for 80ms and stop immediately prioritizes visible rows plus the provided adjacent rows', async () => {
  const f = storeFixture(); const timers = new Map(); let id = 0;
  const globals = { setTimeout(fn, delay) { assert.equal(delay, 80); timers.set(++id, fn); return id; }, clearTimeout(id) { timers.delete(id); } };
  const { model } = await pagedLibrary(f, 20, globals);
  model.updateViewport('active', model.items.slice(0, 3), model.items.slice(3, 6), false, 20, true);
  model.updateViewport('active', model.items.slice(6, 9), model.items.slice(9, 12), false, 20, true);
  assert.equal(timers.size, 1); assert.equal(f.jobs.length, 0);
  const callback = [...timers.values()][0]; timers.clear(); callback();
  assert.deepEqual(f.jobs.map(job => job.plan.itemId), [7, 8, 9]);
  assert.equal(f.store.pending.length, 0, 'prefetch waits until scrolling stops');
  model.updateViewport('active', model.items.slice(12, 15), [], false, 20, true);
  assert.equal(timers.size, 1);
  model.updateViewport('active', model.items.slice(15, 18), model.items.slice(18), false, 20, false);
  assert.equal(timers.size, 0);
  await finishJobs(f);
  assert.deepEqual(f.jobs.slice(3).map(job => job.plan.itemId), [16, 17, 18, 19, 20]);
  model.reset();
});

test('new visible reads overtake retained prefetch work after an in-flight viewport change', async () => {
  const f = storeFixture(); const { model } = await pagedLibrary(f, 20);
  model.updateViewport('active', model.items.slice(0, 3), model.items.slice(3, 8), false, 20);
  const old = f.jobs.slice();
  model.updateViewport('active', model.items.slice(8, 11), model.items.slice(3, 8), false, 20);
  for (const job of old) { job.gate.resolve(8); await turn(); }
  assert.deepEqual(f.jobs.slice(3, 6).map(job => job.plan.itemId), [9, 10, 11]);
  await finishJobs(f, 3);
  assert.equal(f.max(), 3);
  model.reset();
});

test('visible cache references survive count eviction, eviction clears only its state and scrolling back fetches automatically', async () => {
  const f = storeFixture(); const { model } = await pagedLibrary(f, 80);
  await model.loadMore(); await model.loadMore(); await model.loadMore();
  model.updateViewport('active', model.items.slice(0, 1), model.items.slice(1, 61), false, 80);
  await finishJobs(f);
  const pinned = model.thumbnailPath(model.items[0]);
  assert.ok(pinned); assert.equal(f.disk.files.has(pinned), true);
  assert.equal(f.store.cache.length, 60);
  const evicted = model.thumbnailState(model.items[1]);
  assert.equal(evicted.path, '');
  const before = f.jobs.length;
  model.updateViewport('active', model.items.slice(1, 2), [], false, 80);
  assert.equal(f.jobs.length, before + 1);
  assert.equal(f.jobs.at(-1).plan.itemId, 2);
  f.jobs.at(-1).gate.resolve(8); await turn();
  assert.strictEqual(model.thumbnailState(model.items[1]), evicted);
  assert.ok(evicted.path); assert.equal(f.disk.files.has(evicted.path), true);
  assert.equal(f.store.cache.length, 60);
  model.reset();
});

test('one thumbnail completion never maps or searches the whole list and pagination does not stale an ongoing thumbnail', async () => {
  const f = storeFixture(); const { model } = await pagedLibrary(f, 40);
  const photo = model.items[0]; const other = model.thumbnailState(model.items[1]);
  const list = model.items;
  list.map = () => { throw new Error('whole-list map on media completion'); };
  list.find = () => { throw new Error('whole-list lookup on media completion'); };
  model.updateViewport('active', [photo], [], false, 20);
  const state = model.thumbnailState(photo);
  f.jobs[0].gate.resolve(8); await turn();
  assert.strictEqual(model.items, list);
  assert.strictEqual(model.thumbnailState(model.items[1]), other);
  assert.equal(other.path, ''); assert.equal(other.loading, false);
  model.updateViewport('active', [model.items[2]], [], false, 20);
  await model.loadMore();
  f.jobs.at(-1).gate.resolve(8); await turn();
  assert.equal(model.thumbnailState(model.items[2]).loading, false);
  assert.ok(model.thumbnailPath(model.items[2]));
  assert.ok(state.path);
  model.reset();
});

test('network failures stay per item and require explicit retry; Image error refetches once per visible cycle', async () => {
  const f = storeFixture(); const { model } = await pagedLibrary(f, 20);
  const photo = model.items[0]; const state = model.thumbnailState(photo);
  model.updateViewport('active', [photo], [], false, 20);
  f.jobs[0].gate.reject(failure(K.Http)); await turn();
  assert.ok(state.errorText); assert.equal(state.loading, false); assert.equal(model.errorText, '');
  model.updateViewport('active', [photo], [], false, 20);
  assert.equal(f.jobs.length, 1);
  model.retryThumbnail(photo); f.jobs[1].gate.resolve(8); await turn();
  assert.equal(state.errorText, ''); const first = state.path;
  model.thumbnailImageError(photo, first);
  assert.equal(f.disk.files.has(first), false); assert.equal(f.jobs.length, 3);
  f.jobs[2].gate.resolve(8); await turn(); const second = state.path;
  model.thumbnailImageError(photo, first);
  assert.equal(state.path, second, 'late decode callback cannot invalidate the new source');
  model.thumbnailImageError(photo, second);
  assert.equal(f.jobs.length, 3); assert.ok(state.errorText); assert.equal(state.path, '');
  model.retryThumbnail(photo); f.jobs[3].gate.resolve(8); await turn();
  model.updateViewport('active', [], [], false, 20);
  model.updateViewport('active', [photo], [], false, 20);
  model.thumbnailImageError(photo, state.path);
  assert.equal(f.jobs.length, 5, 'a new visible cycle gets one automatic decode retry');
  f.jobs[4].gate.resolve(8); await turn();
  model.reset();
});

test('scrolling back before a cancelled inflight read exits requeues it once; background and disposal release demands', async () => {
  const f = storeFixture(); const { model } = await pagedLibrary(f, 20);
  const photo = model.items[0];
  model.updateViewport('active', [photo], [], false, 20);
  model.updateViewport('active', [], [], false, 20);
  model.updateViewport('active', [photo], [], false, 20);
  assert.equal(f.jobs.length, 1);
  f.jobs[0].gate.resolve(8); await turn();
  assert.equal(f.jobs.length, 2);
  model.setForeground(false);
  assert.equal(f.store.visibleKeys.size, 0); assert.ok(f.jobs[1].transport.closed);
  f.jobs[1].gate.resolve(8); await turn();
  assert.equal(f.jobs.length, 2);
  model.setForeground(true);
  assert.equal(f.jobs.length, 3);
  f.jobs[2].gate.resolve(8); await turn();
  assert.ok(model.thumbnailPath(photo));
  model.releaseView('active'); model.reset();
});

test('refresh invalidates thumbnail generation and old media failure cannot affect the refreshed view or new account', async () => {
  const f = storeFixture(); const { model } = await pagedLibrary(f, 20);
  const oldPhoto = model.items[0]; const oldState = model.thumbnailState(oldPhoto);
  model.updateViewport('active', [oldPhoto], [], false, 20);
  await model.refresh();
  const nextPhoto = model.items[0]; const state = model.thumbnailState(nextPhoto);
  assert.notStrictEqual(state, oldState);
  model.updateViewport('active', [nextPhoto], [], false, 20);
  f.jobs[0].gate.reject(failure(K.SessionExpired)); await turn();
  assert.equal(state.errorText, ''); assert.equal(state.path, '');
  f.jobs[1].gate.resolve(8); await turn(); assert.ok(state.path);
  const nextAccount = { ...f.connector, async photos() { return { items: [item(9)], hasMore: false }; } };
  model.attach(nextAccount, { cacheDir: '/cache/bob' }, async () => { throw new Error('old account expiry'); });
  await model.open(S.Personal);
  model.updateViewport('new-account', model.items, [], false, 1);
  f.jobs.at(-1).gate.resolve(8); await turn();
  assert.ok(model.thumbnailPath(model.items[0]).startsWith('/cache/bob/'));
  assert.equal(f.disk.files.has(state.path), false);
  model.reset();
});

test('automatic paging locks append, keeps old content on failure, retries the same wire offset and stops on an empty page', async () => {
  const f = storeFixture(); const calls = []; const failureGate = deferred(); let fail = true;
  const connector = { ...f.connector, async photos(space, offset) {
    calls.push(offset);
    if (offset === 0) return { items: Array.from({ length: 20 }, (_, i) => item(i + 1)), hasMore: true };
    if (fail) { await failureGate.promise; throw failure(K.Http); }
    if (offset === 20) return { items: [item(20), item(21)], hasMore: true };
    return { items: [], hasMore: true };
  } };
  const model = realLibrary(f, connector); await model.open(S.Personal);
  const old = model.items;
  model.updateViewport('active', [], [], true, 20);
  model.updateViewport('active', [], [], true, 20);
  assert.equal(model.appending, true); assert.equal(model.busy, false); assert.deepEqual(calls, [0, 20]);
  failureGate.resolve(); await turn();
  assert.strictEqual(model.items, old); assert.equal(model.errorText, ''); assert.ok(model.appendError);
  for (let i = 0; i < 5; i++) model.updateViewport('active', [], [], true, 20);
  assert.deepEqual(calls, [0, 20], 'append errors cannot become an automatic retry storm');
  fail = false; await model.loadMore();
  assert.deepEqual(calls, [0, 20, 20]); assert.equal(model.items.length, 21); assert.equal(model.offset, 22);
  model.updateViewport('active', [], [], true, 21); await turn();
  assert.deepEqual(calls, [0, 20, 20, 22]); assert.equal(model.hasMore, false); assert.equal(model.appendError, '');
  await model.loadMore(); assert.equal(calls.length, 4);
  model.reset();
});

test('shared album lists and selected albums use the same automatic pagination path and raw duplicate counts', async () => {
  const f = storeFixture(); const calls = [];
  const album = id => ({ id, name: '相册' + id, itemCount: 2, space: S.WithMe, passphrase: 'private' });
  const connector = { ...f.connector, async photoAlbums(space, offset) {
    calls.push(['albums', offset]);
    return offset === 0 ? { items: Array.from({ length: 20 }, (_, i) => album(i + 1)), hasMore: true } :
      { items: [album(20), album(21)], hasMore: false };
  }, async albumPhotos(album, offset) {
    calls.push(['photos', offset]);
    return offset === 0 ? { items: [{ ...item(1), space: S.WithMe }], hasMore: true } :
      { items: [{ ...item(1), space: S.WithMe }, { ...item(2), space: S.WithMe }], hasMore: false };
  } };
  const model = realLibrary(f, connector); await model.open(S.WithMe, 'albums');
  model.updateViewport('shared', [], [], true, 20); await turn();
  assert.equal(model.albums.length, 21); assert.equal(model.offset, 22);
  await model.openAlbum(model.albums[0]);
  model.updateViewport('shared', [], [], true, 1); await turn();
  assert.equal(model.items.length, 2); assert.equal(model.offset, 3);
  assert.deepEqual(calls, [['albums', 0], ['albums', 20], ['photos', 0], ['photos', 1]]);
  assert.ok(model.albums.every(a => !Object.hasOwn(a, 'passphrase')));
  model.reset();
});

test('library owns and removes its existing application foreground event subscription', async () => {
  const f = storeFixture(); const { model } = await pagedLibrary(f, 20);
  const connector = model.connector; const listeners = new Map();
  model.attach(connector, { cacheDir: '/cache/alice', eventHub: {
    on(name, callback) { assert.equal(name, 'nas-foreground-change'); listeners.set(name, callback); },
    off(name, callback) { assert.strictEqual(listeners.get(name), callback); listeners.delete(name); },
  } }, async () => {});
  await model.open(S.Personal); model.updateViewport('active', model.items.slice(0, 1), [], false, 20);
  assert.equal(listeners.size, 1);
  listeners.get('nas-foreground-change')(false);
  assert.ok(f.jobs[0].transport.closed); assert.equal(f.store.visibleKeys.size, 0);
  f.jobs[0].gate.resolve(8); await turn();
  listeners.get('nas-foreground-change')(true);
  assert.equal(f.jobs.length, 2); f.jobs[1].gate.resolve(8); await turn();
  model.reset(); assert.equal(listeners.size, 0);
});

test('only visible references can exceed the byte budget and inflight prefetch cannot grow that protected set', async () => {
  const f = storeFixture(); const { model } = await pagedLibrary(f, 40); await model.loadMore();
  model.updateViewport('active', model.items.slice(0, 25), model.items.slice(25, 28), false, 40);
  await finishJobs(f, 0, 1024 * 1024);
  assert.equal(f.store.cache.length, 25);
  assert.equal(f.store.cache.reduce((sum, entry) => sum + entry.bytes, 0), 25 * 1024 * 1024);
  assert.ok(f.store.cache.every(entry => f.store.visibleKeys.has(entry.key)));
  for (const photo of model.items.slice(25, 28)) assert.equal(model.thumbnailPath(photo), '');
  assert.ok(f.jobs.length <= 26, 'once protected bytes consume the budget, queued prefetch is not dispatched');
  const before = f.jobs.length;
  model.updateViewport('active', model.items.slice(0, 25), model.items.slice(25, 28), false, 40);
  await turn(); assert.equal(f.jobs.length, before, 'repeated range notifications cannot restart over-budget prefetch');
  model.releaseView('active');
  assert.equal(f.store.cache.length, 24, 'releasing the viewport immediately restores the normal byte limit');
  assert.equal(f.disk.files.size, 24);
  model.reset();
});

test('prefetch cannot exceed the count budget when all 61 retained entries belong to the current viewport', async () => {
  const f = storeFixture(); const { model } = await pagedLibrary(f, 80);
  await model.loadMore(); await model.loadMore(); await model.loadMore();
  model.updateViewport('active', model.items.slice(0, 61), model.items.slice(61, 62), false, 80);
  await finishJobs(f);
  assert.equal(f.store.cache.length, 61);
  assert.ok(f.store.cache.every(entry => f.store.visibleKeys.has(entry.key)));
  assert.equal(model.thumbnailPath(model.items[61]), '');
  model.releaseView('active');
  assert.equal(f.store.cache.length, 60); assert.equal(f.disk.files.size, 60);
  model.reset();
});

test('a transport ignoring cancellation still cannot publish stale media or remove current visible files', async () => {
  const f = storeFixture(); f.ignoreCancellation(); const { model } = await pagedLibrary(f, 20);
  model.updateViewport('active', model.items.slice(0, 3), [], false, 20);
  const stale = f.jobs.slice();
  model.updateViewport('active', model.items.slice(8, 11), [], false, 20);
  stale[0].gate.resolve(8); stale[1].gate.resolve(8); await turn();
  assert.equal(f.jobs.length, 5);
  f.jobs[3].gate.resolve(8); f.jobs[4].gate.resolve(8); await turn();
  const currentPaths = [model.thumbnailPath(model.items[8]), model.thumbnailPath(model.items[9])];
  assert.ok(currentPaths.every(p => p && f.disk.files.has(p)));
  stale[2].gate.resolve(8); await turn();
  assert.ok(currentPaths.every(p => f.disk.files.has(p)));
  assert.ok(stale.every(job => !f.disk.files.has(job.destination)));
  assert.ok(f.store.cache.every(entry => f.store.visibleKeys.has(entry.key)));
  await finishJobs(f, 5); model.reset();
});

test('a real cancellation-close failure keeps its diagnostic but repeated offscreen notifications do not repeat close or logging', async () => {
  const timers = [];
  const f = storeFixture({ setTimeout(fn, delay) { assert.equal(delay, 1000); timers.push(fn); return timers.length; } });
  const { model } = await pagedLibrary(f, 20);
  model.updateViewport('active', model.items.slice(0, 1), [], false, 20);
  let closes = 0;
  f.jobs[0].transport.close = function () { this.closed = true; closes++; throw new Error('close failure'); };
  model.updateViewport('active', [], [], false, 20);
  for (let i = 0; i < 10; i++) model.updateViewport('active', [], [], false, 20);
  assert.equal(closes, 1); assert.equal(f.diagnostics.length, 0); assert.equal(timers.length, 1);
  timers[0]();
  assert.equal(f.diagnostics.length, 1);
  assert.ok(f.diagnostics[0].some(value => String(value).includes('thumbnail_cancel')));
  // finally 的关闭由传输完成处理；恢复关闭函数后结束测试中的真实失败场景。
  f.jobs[0].transport.close = function () { this.closed = true; };
  f.jobs[0].gate.resolve(8); await turn(); model.reset();
});

test('cache cleanup failures stop caching immediately and batch distinct paths without logging private filenames', async () => {
  const timers = [];
  const f = storeFixture({ setTimeout(fn, delay) { assert.equal(delay, 1000); timers.push(fn); return timers.length; } });
  const { model } = await pagedLibrary(f, 20);
  model.updateViewport('active', model.items.slice(0, 2), [], false, 20);
  await finishJobs(f);
  const unlink = f.disk.io.unlinkSync;
  f.disk.io.unlinkSync = () => { throw new Error('storage unavailable'); };
  f.store.invalidateThumbnail(model.items[0]); f.store.invalidateThumbnail(model.items[1]);
  assert.match(f.store.cleanupErrorText, /已停止继续缓存/);
  assert.equal(f.store.cleanupPaths.length, 2);
  assert.equal(f.diagnostics.length, 0); assert.equal(timers.length, 1);
  timers[0]();
  assert.equal(f.diagnostics.length, 1);
  assert.equal(f.diagnostics[0].at(-1), 2);
  assert.ok(!JSON.stringify(f.diagnostics).includes('/cache/alice'));
  f.disk.io.unlinkSync = unlink;
  model.reset();
});
