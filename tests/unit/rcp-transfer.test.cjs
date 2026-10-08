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
    require: id => {
      if (id === '../../platform/LocalSpaceBudget') { return mocks[id] || require('../helpers/load-space-budget.cjs')(mocks['../domain/DsmProtocol'] || mocks['../../core/domain/DsmProtocol']); } assert.ok(Object.hasOwn(mocks, id), 'unexpected dependency ' + id); return mocks[id]; } });
  return module.exports;
}

const dsm = load('core/domain/DsmProtocol.ts');
const utf8 = load('platform/Utf8Codec.ets', { '@kit.ArkTS': { util }, '../core/domain/DsmProtocol': dsm });
const photos = load('core/domain/PhotosProtocol.ts', { './DsmProtocol': dsm });
const contracts = load('core/network/NasTransferTransport.ts', { '../domain/DsmProtocol': dsm });
const { NasFailure, NasErrorKind: K } = dsm;
const encoder = new TextEncoder();
const isKind = kind => error => error instanceof NasFailure && error.kind === kind;
const deferred = () => { let resolve; const promise = new Promise(a => { resolve = a; }); return { promise, resolve }; };

function storage() {
  const files = new Map(); const dirs = new Set(); const handles = new Map(); const removed = [];
  let descriptor = 7; let syncs = 0;
  const rawWrite = (id, chunk) => {
    const entry = handles.get(id);
    assert.ok(entry, 'write to an unknown handle');
    const combined = new Uint8Array(entry.bytes.length + chunk.length);
    combined.set(entry.bytes); combined.set(chunk, entry.bytes.length); entry.bytes = combined;
    return chunk.length;
  };
  const io = {
    OpenMode: { CREATE: 64, READ_WRITE: 2, READ_ONLY: 0 },
    accessSync: name => files.has(name) || dirs.has(name),
    mkdirSync(name) { if (dirs.has(name) || files.has(name)) { throw new Error('already exists'); } dirs.add(name); },
    openSync(name, mode) {
      assert.equal(mode, io.OpenMode.CREATE | io.OpenMode.READ_WRITE);
      const handle = { fd: descriptor++ }; const entry = { name, bytes: new Uint8Array(0) };
      files.set(name, entry); handles.set(handle.fd, entry);
      return handle;
    },
    writeSync: (id, buffer) => rawWrite(id, new Uint8Array(buffer)),
    statSync(id) {
      if (typeof id === 'number') {
        const entry = handles.get(id); assert.ok(entry, 'stat of an unknown handle');
        return { size: entry.bytes.length, isFile: () => true, isDirectory: () => false };
      }
      if (dirs.has(id)) { return { size: 0, isFile: () => false, isDirectory: () => true }; }
      const entry = files.get(id); assert.ok(entry, 'stat of an unknown path ' + id);
      return { size: entry.bytes.length, isFile: () => true, isDirectory: () => false };
    },
    fsyncSync() { syncs++; },
    closeSync(id) { assert.ok(handles.delete(id), 'double close'); },
    unlinkSync(name) { if (!files.has(name)) { throw new Error('missing ' + name); } removed.push(name); files.delete(name); },
    rmdirSync(name) { if (!dirs.has(name)) { throw new Error('missing ' + name); } removed.push(name); dirs.delete(name);
      for (const key of Array.from(files.keys())) { if (key.startsWith(name + '/')) { files.delete(key); } } }
  };
  return { io, files, dirs, handles, removed, rawWrite, syncs: () => syncs };
}

function runtime(replies = []) {
  const disk = storage(); const requests = []; const sessions = []; const diagnostics = [];
  class MultipartForm { constructor(fields) { this.fields = fields; this.keys = undefined; } }
  class Request { constructor(url, method, headers, content) { this.url = url; this.method = method; this.headers = headers; this.content = content; } }
  const rcp = { MultipartForm, Request, createSession(configuration) {
    assert.equal(configuration.requestConfiguration.transfer.autoRedirect, false);
    const session = { cancelled: [], async fetch(request) {
      requests.push(request);
      const next = replies.shift();
      assert.ok(next, 'unexpected network request');
      if (typeof next === 'function') { return next(request, session); }
      for (const chunk of next.chunks) { await request.destination(chunk); }
      return { statusCode: next.status || 200, headers: next.headers || {} };
    }, cancel(request) { session.cancelled.push(request); }, close() { session.closed = true; } };
    sessions.push(session); return session;
  } };
  const transferTransport = load('core/network/RcpTransferTransport.ets', {
    '@kit.RemoteCommunicationKit': { rcp }, '@kit.CoreFileKit': { fileIo: disk.io },
    '@kit.PerformanceAnalysisKit': { hilog: { error(...args) { diagnostics.push(args); } } },
    '../domain/DsmProtocol': dsm, './NasTransferTransport': contracts, '../../platform/Utf8Codec': utf8 });
  const { RcpNasTransport } = load('core/network/RcpNasTransport.ets', {
    '@kit.RemoteCommunicationKit': { rcp }, '@kit.CoreFileKit': { fileIo: disk.io },
    '@kit.PerformanceAnalysisKit': { hilog: { error(...args) { diagnostics.push(args); } } },
    '../../platform/Utf8Codec': utf8, '../domain/DsmProtocol': dsm, '../domain/PhotosProtocol': photos,
    './NasTransferTransport': contracts, './RcpTransferTransport': transferTransport });
  return { RcpNasTransport, MultipartForm, disk, requests, sessions, diagnostics };
}

const uploadPlan = () => ({ address: 'https://nas.example.test:5001/webapi/entry.cgi', method: 'POST',
  fields: [ { name: 'api', content: 'SYNO.SynologyDrive.Files' }, { name: 'version', content: '2' },
    { name: 'method', content: 'upload' }, { name: 'path', content: 'id:829198498346875491/PLAN.md' },
    { name: 'type', content: 'file' }, { name: 'conflict_action', content: 'version' },
    { name: 'modified_time', content: '1790570123.335' } ],
  session: { sid: 'private-sid', synoToken: 'private-token' } });
const downloadPlan = () => ({ address: 'https://nas.example.test:5001/webapi/entry.cgi/SYNO.SynologyDrive.Files/PLAN.md',
  method: 'GET', fields: [ { name: 'api', content: 'SYNO.SynologyDrive.Files' }, { name: 'version', content: '2' },
    { name: 'method', content: 'download' }, { name: 'files', content: '["id:976700457026108129"]' },
    { name: 'force_download', content: 'true' }, { name: 'json_error', content: 'true' },
    { name: 'download_type', content: '"download"' }, { name: 'c2_offload', content: '"allow"' },
    { name: 'SynoToken', content: 'private-token' } ],
  session: { sid: 'private-sid', synoToken: 'private-token' } });
const control = onProgress => ({ cancellation: new contracts.NasTransferCancellation(), onProgress });
const uploadReply = uploaded => encoder.encode(JSON.stringify({ success: true, data: { tmp_newly_created: true, uploaded_size: uploaded } })).buffer;
const withSource = (disk, bytes) => { disk.files.set('/cache/src.bin', { name: '/cache/src.bin', bytes: new Uint8Array(bytes) }); return { path: '/cache/src.bin', bytes }; };

test('download ownership is announced only after exclusive creation, and callback failures discard only the new directory', async () => {
  const f = runtime([]), transport = new f.RcpNasTransport(); let created = 0;
  f.disk.dirs.add('/cache/existing');
  await assert.rejects(transport.transfers.download(downloadPlan(), { directory: '/cache/existing', maximumBytes: 10,
    onDirectoryCreated() { created++; } }, control(), () => {}));
  assert.equal(created, 0); assert.equal(f.disk.dirs.has('/cache/existing'), true);
  await assert.rejects(transport.transfers.download(downloadPlan(), { directory: '/cache/new', maximumBytes: 10,
    onDirectoryCreated() { created++; throw new NasFailure(K.Cancelled, 'closed'); } }, control(), () => {}));
  assert.equal(created, 1); assert.equal(f.disk.dirs.has('/cache/new'), false); assert.equal(f.requests.length, 0);
  transport.close();
});

test('the transfer capability reuses the connection session, uploads from the local path and never follows redirects', async () => {
  const f = runtime([{ chunks: [uploadReply(4)] }]);
  const transport = new f.RcpNasTransport();
  const source = withSource(f.disk, 4);
  const reply = await transport.transfers.upload(uploadPlan(), source, 'PLAN.md', control());
  assert.equal(reply.status, 200);
  assert.ok(reply.text.includes('uploaded_size'));
  assert.equal(f.sessions.length, 1);
  assert.equal(f.requests.length, 1);
  assert.equal(transport.transfers, transport.transfers);
  const request = f.requests[0];
  assert.equal(request.method, 'POST');
  assert.equal(request.url, uploadPlan().address);
  assert.equal(request.url.includes('private'), false);
  assert.equal(request.headers['X-SYNO-TOKEN'], 'private-token');
  assert.equal(request.cookies.id, 'private-sid');
  assert.equal(request.cacheControl.noStore, true);
  assert.equal(request.configuration.transfer.autoRedirect, false);
  const form = request.content;
  assert.ok(form instanceof f.MultipartForm);
  // file 必须最后：服务端依赖顺序解析其余标量。
  assert.deepEqual(Array.from(form.keys), ['api', 'version', 'method', 'path', 'type', 'conflict_action', 'modified_time', 'file']);
  assert.equal(form.fields.path, 'id:829198498346875491/PLAN.md');
  assert.equal(form.fields['file'].contentOrPath, '/cache/src.bin');
  assert.equal(form.fields['file'].remoteFileName, 'PLAN.md');
  assert.equal(form.fields['file'].contentType, 'application/octet-stream');
  // 整文件按路径交给 RCP，传输层没有读取它的能力。
  assert.equal(typeof form.fields['file'].contentOrPath, 'string');
  assert.equal(f.disk.io.readSync, undefined);
  transport.close();
});

test('the foreground slice transport forwards the original temporary-session headers without changing authentication', async () => {
  const f = runtime([{ chunks: [uploadReply(4)] }]);
  const transport = new f.RcpNasTransport();
  const plan = uploadPlan();
  plan.headers = { 'X-TMP-FILE': 'a'.repeat(32), 'X-TYPE-NAME': 'SLICEUPLOAD', 'X-FILE-CHUNK-END': 'true' };
  await transport.transfers.upload(plan, withSource(f.disk, 4), 'PLAN.md', control());
  assert.equal(f.requests[0].headers['X-TMP-FILE'], 'a'.repeat(32));
  assert.equal(f.requests[0].headers['X-FILE-CHUNK-END'], 'true');
  assert.equal(f.requests[0].headers['X-SYNO-TOKEN'], 'private-token');
  assert.equal(f.requests[0].cookies.id, 'private-sid');
  transport.close();
});

test('upload progress is transport progress only and stops the moment the caller cancels', async () => {
  const gate = deferred();
  const f = runtime([() => gate.promise.then(() => ({ statusCode: 200, headers: {} }))]);
  const transport = new f.RcpNasTransport();
  const source = withSource(f.disk, 4);
  const seen = [];
  const signal = control(progress => seen.push({ ...progress }));
  const pending = transport.transfers.upload(uploadPlan(), source, 'PLAN.md', signal);
  const request = f.requests[0];
  const handler = request.configuration.tracing.httpEventsHandler.onUploadProgress;
  handler(1024, 512);
  assert.deepEqual(seen, [{ direction: 'upload', processed: 512, total: 1024 }]);
  handler(0, 0);
  assert.deepEqual(seen[1], { direction: 'upload', processed: 0, total: undefined });
  signal.cancellation.cancel();
  assert.equal(f.sessions[0].cancelled.length, 1);
  assert.equal(f.sessions[0].cancelled[0], request);
  handler(2048, 1024);
  assert.equal(seen.length, 2);
  assert.equal(f.sessions[0].cancelled.length, 2);
  gate.resolve();
  await assert.rejects(pending, error => isKind(K.Cancelled)(error) &&
    error.message === '上传已停止，请检查目标文件以确认结果。');
  assert.equal(f.requests.length, 1);
  transport.close();
});

test('cancelling one transfer leaves a concurrent transfer untouched', async () => {
  const gates = [deferred(), deferred()];
  const f = runtime([() => gates[0].promise.then(() => ({ statusCode: 200, headers: {} })),
    () => gates[1].promise.then(() => ({ statusCode: 200, headers: {} }))]);
  const transport = new f.RcpNasTransport();
  f.disk.files.set('/cache/a.bin', { name: '/cache/a.bin', bytes: new Uint8Array(4) });
  f.disk.files.set('/cache/b.bin', { name: '/cache/b.bin', bytes: new Uint8Array(4) });
  const first = control(); const second = control();
  const a = transport.transfers.upload(uploadPlan(), { path: '/cache/a.bin', bytes: 4 }, 'a.bin', first);
  const b = transport.transfers.upload(uploadPlan(), { path: '/cache/b.bin', bytes: 4 }, 'b.bin', second);
  first.cancellation.cancel();
  assert.equal(f.sessions[0].cancelled.length, 1);
  assert.equal(f.sessions[0].cancelled[0], f.requests[0]);
  gates[1].resolve();
  assert.equal((await b).status, 200);
  gates[0].resolve();
  await assert.rejects(a, isKind(K.Cancelled));
  assert.equal(second.cancellation.cancelled, false);
  transport.close();
});

test('an oversized upload response is reported as unconfirmed, never as success', async () => {
  const f = runtime([{ chunks: [new ArrayBuffer(1024 * 1024), new ArrayBuffer(1)] }]);
  const transport = new f.RcpNasTransport();
  const source = withSource(f.disk, 4);
  await assert.rejects(transport.transfers.upload(uploadPlan(), source, 'PLAN.md', control()),
    error => isKind(K.Protocol)(error) && error.message === '上传结果未能确认，请检查目标文件。');
  assert.equal(f.sessions[0].cancelled.length, 1);
  assert.equal(f.requests.length, 1);
  transport.close();
});

test('the exact local file and byte count are verified before any upload request is sent', async () => {
  const f = runtime([{ chunks: [uploadReply(4)] }]);
  const transport = new f.RcpNasTransport();
  const source = withSource(f.disk, 4);
  await assert.rejects(transport.transfers.upload(uploadPlan(), { path: '/cache/src.bin', bytes: 5 }, 'PLAN.md', control()),
    error => isKind(K.InvalidInput)(error) && error.message === '上传文件已变化，请重新选择。');
  await assert.rejects(transport.transfers.upload(uploadPlan(), { path: '/cache/missing.bin', bytes: 4 }, 'PLAN.md', control()),
    isKind(K.InvalidInput));
  f.disk.dirs.add('/cache/adir');
  await assert.rejects(transport.transfers.upload(uploadPlan(), { path: '/cache/adir', bytes: 0 }, 'PLAN.md', control()),
    isKind(K.InvalidInput));
  await assert.rejects(transport.transfers.upload(uploadPlan(), source, 'a/b', control()), isKind(K.InvalidInput));
  await assert.rejects(transport.transfers.upload(uploadPlan(), { path: 'relative.bin', bytes: 4 }, 'PLAN.md', control()),
    isKind(K.InvalidInput));
  assert.equal(f.requests.length, 0);
  transport.close();
});

test('a download writes only into a directory it created and hands back a discard for its own content', async () => {
  const payload = encoder.encode('报告内容');
  const f = runtime([{ chunks: [payload.slice(0, 3).buffer, payload.slice(3).buffer],
    headers: { 'Content-Type': 'application/octet-stream', 'Content-Length': String(payload.length),
      'Content-Disposition': 'attachment; filename="other-name.bin"' } }]);
  const transport = new f.RcpNasTransport();
  const seen = [];
  const receipt = await transport.transfers.download(downloadPlan(),
    { directory: '/cache/drive-1', maximumBytes: 64, expectedBytes: payload.length }, control(), reply => seen.push(reply));
  assert.equal(receipt.path, '/cache/drive-1/content');
  assert.equal(receipt.bytes, payload.length);
  assert.deepEqual(Array.from(f.disk.files.get('/cache/drive-1/content').bytes), Array.from(payload));
  assert.equal(f.disk.syncs(), 1);
  assert.equal(f.disk.handles.size, 0);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].status, 200);
  assert.equal(seen[0].contentType, 'application/octet-stream');
  assert.equal(seen[0].contentLength, String(payload.length));
  assert.equal(seen[0].contentDisposition, 'attachment; filename="other-name.bin"');
  assert.equal(seen[0].bytes, payload.length);
  assert.equal(seen[0].prefixText, '报告内容');
  assert.deepEqual(Array.from(seen[0].prefix), Array.from(payload));
  const request = f.requests[0];
  assert.equal(request.method, 'GET');
  assert.equal(request.configuration.transfer.autoRedirect, false);
  assert.equal(request.cookies.id, 'private-sid');
  const query = new URLSearchParams(request.url.slice(request.url.indexOf('?') + 1));
  assert.equal(query.get('method'), 'download');
  assert.equal(query.get('files'), '["id:976700457026108129"]');
  assert.equal(query.get('SynoToken'), 'private-token');
  assert.equal(query.get('path'), null);
  // Content-Disposition 不参与本地路径选择，私有目录也不出现在请求里。
  assert.equal(request.url.startsWith(downloadPlan().address + '?'), true);
  assert.equal(request.url.includes('/cache/drive-1'), false);
  assert.equal(request.url.includes('other-name'), false);
  receipt.discard();
  assert.equal(f.disk.files.has('/cache/drive-1/content'), false);
  assert.equal(f.disk.dirs.has('/cache/drive-1'), false);
  receipt.discard();
  assert.deepEqual(f.disk.removed, ['/cache/drive-1/content', '/cache/drive-1']);
  transport.close();
});

test('a download never publishes an existing path or a redirect destination', async () => {
  const taken = runtime([]);
  const first = new taken.RcpNasTransport();
  taken.disk.dirs.add('/cache/taken');
  taken.disk.files.set('/cache/taken/keep.bin', { name: '/cache/taken/keep.bin', bytes: new Uint8Array([9]) });
  await assert.rejects(first.transfers.download(downloadPlan(), { directory: '/cache/taken', maximumBytes: 64 }, control(), () => {}),
    error => isKind(K.Protocol)(error) && error.message === '无法创建下载临时目录。');
  assert.equal(taken.requests.length, 0);
  assert.equal(taken.disk.files.has('/cache/taken/keep.bin'), true);
  assert.deepEqual(taken.disk.removed, []);
  first.close();

  const redirected = runtime([{ status: 302, chunks: [encoder.encode('moved').buffer],
    headers: { 'Location': 'https://evil.example/', 'Content-Type': 'text/html' } }]);
  const second = new redirected.RcpNasTransport();
  let validated = 0;
  await assert.rejects(second.transfers.download(downloadPlan(), { directory: '/cache/drive-2', maximumBytes: 64 },
    control(), () => { validated++; }), error => isKind(K.Http)(error) && error.code === 302);
  assert.equal(validated, 0);
  assert.equal(redirected.disk.files.size, 0);
  assert.equal(redirected.disk.dirs.size, 0);
  assert.equal(redirected.requests[0].configuration.transfer.autoRedirect, false);
  second.close();
});

test('streaming bounds, short writes and disk failures all fail closed and remove the private file', async () => {
  const cases = [
    { name: 'over the caller limit', chunks: [new Uint8Array(9).buffer], maximumBytes: 8,
      expected: '下载文件超过大小限制。', break_io: null },
    { name: 'a zero-byte write', chunks: [new Uint8Array([1, 2]).buffer], maximumBytes: 8,
      expected: '下载文件写入失败。', break_io: io => { io.writeSync = () => 0; } },
    { name: 'a disk write error', chunks: [new Uint8Array([1, 2]).buffer], maximumBytes: 8,
      expected: '下载文件写入失败。', break_io: io => { io.writeSync = () => { throw Object.assign(new Error('disk'), { code: 13900012 }); }; } },
    { name: 'a size mismatch after writing', chunks: [new Uint8Array([1, 2]).buffer], maximumBytes: 8,
      expected: '下载文件不完整，请重试。', break_io: io => { const read = io.statSync;
        io.statSync = id => Object.assign(read(id), typeof id === 'number' ? { size: 3 } : {}); } },
    { name: 'a failed flush', chunks: [new Uint8Array([1, 2]).buffer], maximumBytes: 8,
      expected: '下载文件保存失败，请重试。', break_io: io => { io.fsyncSync = () => { throw new Error('fsync'); }; } },
    { name: 'a failed close', chunks: [new Uint8Array([1, 2]).buffer], maximumBytes: 8,
      expected: '下载文件保存失败，请重试。', break_io: io => { io.closeSync = () => { throw new Error('close'); }; } }
  ];
  for (const scenario of cases) {
    const f = runtime([{ chunks: scenario.chunks }]);
    const transport = new f.RcpNasTransport();
    if (scenario.break_io !== null) { scenario.break_io(f.disk.io); }
    await assert.rejects(transport.transfers.download(downloadPlan(),
      { directory: '/cache/drive-3', maximumBytes: scenario.maximumBytes }, control(), () => {}),
      error => isKind(K.Protocol)(error) && error.message === scenario.expected, scenario.name);
    assert.equal(f.disk.files.size, 0, scenario.name);
    assert.equal(f.disk.dirs.size, 0, scenario.name);
    transport.close();
  }

  // 短写必须循环写完，不能把一次部分写入当作完成。
  const short = runtime([{ chunks: [new Uint8Array([1, 2, 3, 4, 5]).buffer] }]);
  const transport = new short.RcpNasTransport();
  short.disk.io.writeSync = (id, buffer) => short.disk.rawWrite(id, new Uint8Array(buffer).slice(0, 1));
  const receipt = await transport.transfers.download(downloadPlan(), { directory: '/cache/drive-4', maximumBytes: 8 }, control(), () => {});
  assert.equal(receipt.bytes, 5);
  assert.deepEqual(Array.from(short.disk.files.get('/cache/drive-4/content').bytes), [1, 2, 3, 4, 5]);
  transport.close();
});

test('a download keeps only a bounded prefix for protocol checks while streaming everything to disk', async () => {
  const chunk = new Uint8Array(32 * 1024).fill(65);
  const f = runtime([{ chunks: [chunk.buffer, chunk.buffer, chunk.buffer, chunk.buffer] }]);
  const transport = new f.RcpNasTransport();
  const seen = [];
  const receipt = await transport.transfers.download(downloadPlan(), { directory: '/cache/drive-5', maximumBytes: 256 * 1024 },
    control(), reply => seen.push(reply));
  assert.equal(receipt.bytes, 128 * 1024);
  assert.equal(seen[0].bytes, 128 * 1024);
  assert.equal(seen[0].prefix.length, 64 * 1024);
  assert.equal(f.disk.files.get('/cache/drive-5/content').bytes.length, 128 * 1024);
  transport.close();
});

test('a closed connection refuses both directions before sending anything', async () => {
  const f = runtime([]);
  const transport = new f.RcpNasTransport();
  const source = withSource(f.disk, 4);
  transport.close();
  await assert.rejects(transport.transfers.upload(uploadPlan(), source, 'PLAN.md', control()),
    error => isKind(K.Cancelled)(error) && error.message === '连接已关闭。');
  await assert.rejects(transport.transfers.download(downloadPlan(), { directory: '/cache/drive-6', maximumBytes: 8 }, control(), () => {}),
    error => isKind(K.Cancelled)(error) && error.message === '连接已关闭。');
  assert.equal(f.requests.length, 0);
  assert.equal(f.disk.dirs.size, 0);
  assert.equal(f.diagnostics.length, 0);
});

test('download close and cleanup failures preserve the original rejection and log no private data', async () => {
  const f = runtime([{ status: 302, chunks: [] }]);
  const transport = new f.RcpNasTransport();
  f.disk.io.closeSync = () => { throw new Error('close'); };
  f.disk.io.rmdirSync = () => { throw new Error('cleanup'); };
  await assert.rejects(transport.transfers.download(downloadPlan(), { directory: '/cache/private-result', maximumBytes: 8 },
    control(), () => assert.fail('redirect must not validate')), isKind(K.Http));
  assert.equal(f.diagnostics.length, 2);
  assert.ok(f.diagnostics.every(args => !/private-result|private-token|private-sid/.test(JSON.stringify(args))));
  transport.close();
});
