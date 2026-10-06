const { test } = require('node:test');
const assert = require('node:assert/strict');
const { NasConnector } = require('../../work/core-build/network/NasConnector.js');
const { DriveTransferAdapter } = require('../../work/core-build/network/DriveTransferAdapter.js');
const { DriveEntryKind } = require('../../work/core-build/domain/DriveProtocol.js');
const contracts = require('../../work/core-build/network/NasTransferTransport.js');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');

const isKind = kind => error => error instanceof NasFailure && error.kind === kind;
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });
const errorReply = code => ({ status: 200, text: JSON.stringify({ success: false, error: { code } }) });
const driveUnavailable = '此 NAS 不可通过 Drive 访问：SYNO.SynologyDrive.Files 未安装、被停用或当前账号无权使用 Synology Drive。';
const control = onProgress => ({ cancellation: new contracts.NasTransferCancellation(), onProgress });
const upload = (over = {}) => Object.assign({ parentId: '829198498346875491', filename: '报告 2026.md',
  conflict: 'version', modifiedTime: 1790570123.335 }, over);
const download = (over = {}) => Object.assign({ fileId: '976700457026108129', filename: '报告 2026.md', preview: false }, over);
const source = () => ({ path: '/cache/src.bin', bytes: 4 });
const capabilitiesOf = over => Object.assign({ canRead: true, canDownload: true, canPreview: true, canWrite: true }, over);
const entry = (over = {}) => Object.assign({ fileId: '976700457026108129', name: 'PLAN.md', kind: DriveEntryKind.File,
  starred: false, shared: false, revisionCount: 0, capabilities: capabilitiesOf() }, over);
const folder = (over = {}) => entry(Object.assign({ name: '文档', kind: DriveEntryKind.Folder }, over));

async function fixture(options = {}) {
  const bytes = options.bytes === undefined ? 8 : options.bytes;
  const capabilities = {
    'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 6 },
    'SYNO.SynologyDrive.Files': { path: 'entry.cgi', minVersion: options.minVersion || 1, maxVersion: options.maxVersion || 10 }
  };
  if (options.withoutFiles) { delete capabilities['SYNO.SynologyDrive.Files']; }
  const discovery = []; const calls = [];
  const transport = {
    async post(address, body) { discovery.push({ address, body }); return ok(capabilities); },
    close() {},
    transfers: options.withoutTransfers ? undefined : {
      async upload(request, uploadSource, filename, uploadControl) {
        const context = { request, source: uploadSource, filename, control: uploadControl, connector };
        calls.push(context);
        if (options.onUpload !== undefined) { return options.onUpload(context); }
        return ok({ tmp_newly_created: true, uploaded_size: uploadSource.bytes });
      },
      async download(request, target, downloadControl, validate) {
        const reply = options.binary || { status: 200, contentType: 'application/octet-stream',
          contentLength: String(bytes), contentDisposition: '', bytes, prefix: new Uint8Array(0), prefixText: '' };
        const context = { request, target, control: downloadControl, validate, reply, connector };
        calls.push(context);
        validate(reply);
        if (options.onDownload !== undefined) { options.onDownload(context); }
        return { path: target.directory + '/content', bytes: reply.bytes, discard: () => { context.discarded = true; } };
      }
    }
  };
  const connector = new NasConnector(transport);
  await connector.discover('https://nas.example.test:5001');
  connector.restoreSession([{ name: 'FileStation', sid: 'SYNTHETIC-SID', synoToken: 'SYNTHETIC-TOKEN' }]);
  return { connector, transport, calls, discovery };
}

test('kernel preserves the background network guard and exclusive-directory ownership notification', async () => {
  let checked = 0, created = 0;
  const checkNetwork = () => checked++, onDirectoryCreated = () => created++;
  const f = await fixture({ onUpload: async ({ control }) => { control.checkNetwork(); return ok({ uploaded_size: 4 }); },
    onDownload: ({ target, control }) => { target.onDirectoryCreated(); control.checkNetwork(); } });
  await f.connector.uploadDrive(upload(), source(), { ...control(), background: true, checkNetwork });
  assert.equal(f.calls[0].control.background, true); assert.equal(f.calls[0].control.checkNetwork, checkNetwork);
  await f.connector.downloadDrive(download(), { directory: '/cache/owned', maximumBytes: 8, onDirectoryCreated },
    { ...control(), background: true, checkNetwork });
  assert.equal(f.calls[1].control.background, true); assert.equal(checked, 2); assert.equal(created, 1);
});

test('thumbnail uses authenticated GET, bounded binary transport and the current revision', async () => {
  const prefix = new Uint8Array([137,80,78,71,13,10,26,10,0]);
  const f = await fixture({ binary: { status: 200, contentType: 'image/png', contentLength: '9',
    contentDisposition: '', bytes: 9, prefix, prefixText: '' } });
  const result = await f.connector.thumbnailDrive({ fileId: '976700457026108129', versionId: '999999999999999999' },
    '/cache/thumbnail-1', control());
  assert.deepEqual(result, { path: '/cache/thumbnail-1/content', bytes: 9 });
  const call = f.calls[0];
  assert.equal(call.request.method, 'GET');
  assert.equal(call.request.address, 'https://nas.example.test:5001/webapi/entry.cgi');
  assert.deepEqual(Object.fromEntries(call.request.fields.map(f => [f.name, f.content])), {
    api: 'SYNO.SynologyDrive.Files', version: '2', method: 'get_thumbnail',
    path: '"id:976700457026108129"', size: '"small"', version_id: '"999999999999999999"', SynoToken: 'SYNTHETIC-TOKEN'
  });
  assert.equal(call.target.maximumBytes, 4 * 1024 * 1024);
  assert.equal(JSON.stringify(result).includes('SYNTHETIC'), false);
});

test('thumbnail discards a result when the connection closes after validation', async () => {
  const prefix = new Uint8Array([137,80,78,71,13,10,26,10,0]);
  const f = await fixture({ binary: { status: 200, contentType: 'image/png', contentLength: '9',
    contentDisposition: '', bytes: 9, prefix, prefixText: '' },
    onDownload: ({ connector }) => connector.close() });
  await assert.rejects(f.connector.thumbnailDrive({ fileId: '1' }, '/cache/thumbnail-2', control()), isKind(K.Cancelled));
  assert.equal(f.calls[0].discarded, true);
});

test('Drive upload is an authenticated POST the kernel builds, and the caller never holds a credential', async () => {
  const f = await fixture();
  const input = source();
  const result = await f.connector.uploadDrive(upload(), input, control());
  assert.deepEqual(result, { uploadedBytes: 4 });
  assert.deepEqual(Object.keys(result), ['uploadedBytes']);
  assert.equal(f.calls.length, 1);
  const call = f.calls[0];
  assert.equal(call.request.address, 'https://nas.example.test:5001/webapi/entry.cgi');
  assert.equal(call.request.method, 'POST');
  assert.deepEqual(call.request.fields.map(field => field.name),
    ['api', 'version', 'method', 'path', 'type', 'conflict_action', 'modified_time']);
  assert.deepEqual(call.request.fields.map(field => field.content),
    ['SYNO.SynologyDrive.Files', '2', 'upload', 'id:829198498346875491/报告 2026.md', 'file', 'version', '1790570123.335']);
  assert.deepEqual(call.request.session, { sid: 'SYNTHETIC-SID', synoToken: 'SYNTHETIC-TOKEN' });
  // 认证只存在于内核构造的这次请求里，不进地址、不进业务表单。
  assert.equal(call.request.address.includes('SYNTHETIC'), false);
  assert.equal(call.request.fields.some(field => field.content.includes('SYNTHETIC')), false);
  assert.equal(call.request.fields.some(field => field.name === '_sid' || field.name === 'SynoToken'), false);
  assert.equal(call.filename, '报告 2026.md');
  assert.deepEqual(call.source, { path: '/cache/src.bin', bytes: 4 });
  // 源对象被复制：调用方随后改动不会再影响已发出的请求。
  input.bytes = 99;
  assert.equal(call.source.bytes, 4);
  // 调用方多带的字段不会被转发。
  await f.connector.uploadDrive(upload({ version: '9', api: 'SYNO.FileStation.Upload', temp: 'x' }), source(), control());
  assert.equal(f.calls[1].request.fields.length, 7);
});

test('slice upload uses an empty probe and the same final token, confirming total rather than remainder bytes', async () => {
  const token = 'a'.repeat(32);
  const f = await fixture({ onUpload: async context => context.request.headers['X-FILE-CHUNK-END'] === 'false' ?
    ok({ uploaded_size: 3, tmp_newly_created: false }) : ok({ uploaded_size: 8 }) });
  const probe = await f.connector.probeDriveUpload(upload(), token, { path: '/cache/empty', bytes: 0 }, 8, true, control());
  assert.equal(probe.uploadedBytes, 3);
  const result = await f.connector.uploadDriveSlice(upload(), token, { path: '/cache/remainder', bytes: 5 }, 8, control());
  assert.equal(result.uploadedBytes, 8);
  assert.equal(f.calls[0].source.bytes, 0); assert.equal(f.calls[1].source.bytes, 5);
  assert.equal(f.calls[0].request.headers['X-TMP-FILE'], token); assert.equal(f.calls[1].request.headers['X-TMP-FILE'], token);
  assert.equal(f.calls[0].request.headers['X-FILE-CHUNK-END'], 'false'); assert.equal(f.calls[1].request.headers['X-FILE-CHUNK-END'], 'true');
  await assert.rejects(f.connector.probeDriveUpload(upload(), token, source(), 8, true, control()), isKind(K.InvalidInput));
  assert.throws(() => f.connector.driveUploadPlan(upload({ conflict: 'autorename' }), token), isKind(K.InvalidInput));
  assert.equal(f.calls.length, 2);
  const expired = await fixture({ onUpload: async () => errorReply(119) });
  await assert.rejects(expired.connector.probeDriveUpload(upload(), token, { path: '/cache/empty', bytes: 0 }, 8, true, control()), isKind(K.SessionExpired));
  assert.equal(expired.connector.hasBusinessSession('FileStation'), false);
});

test('Drive download builds a GET with the kernel-injected token and an encoded single-file name', async () => {
  const f = await fixture({ bytes: 8 });
  const result = await f.connector.downloadDrive(download(),
    { directory: '/cache/drive-1', maximumBytes: 64, expectedBytes: 8 }, control());
  assert.deepEqual(result, { path: '/cache/drive-1/content', bytes: 8 });
  assert.deepEqual(Object.keys(result), ['path', 'bytes']);
  const call = f.calls[0];
  assert.equal(call.request.method, 'GET');
  assert.equal(call.request.address, 'https://nas.example.test:5001/webapi/entry.cgi/SYNO.SynologyDrive.Files/' +
    encodeURIComponent('报告 2026.md'));
  assert.equal(call.request.address.includes('SYNTHETIC-TOKEN'), false);
  assert.equal(call.request.address.includes('报告'), false);
  assert.equal(call.request.address.includes('/cache/'), false);
  const fields = Object.fromEntries(call.request.fields.map(field => [field.name, field.content]));
  assert.equal(fields.method, 'download');
  assert.equal(fields.files, '["id:976700457026108129"]');
  assert.equal(fields.force_download, 'true');
  assert.equal(fields.SynoToken, 'SYNTHETIC-TOKEN');
  assert.equal(fields.version, '2');
  assert.deepEqual(call.target, { directory: '/cache/drive-1', maximumBytes: 64, expectedBytes: 8 });
  assert.equal(call.discarded, undefined);

  await f.connector.downloadDrive(download({ preview: true }), { directory: '/cache/drive-2', maximumBytes: 64 }, control());
  const preview = f.calls[1];
  assert.equal(preview.request.address, 'https://nas.example.test:5001/webapi/entry.cgi/' + encodeURIComponent('报告 2026.md'));
  const previewFields = Object.fromEntries(preview.request.fields.map(field => [field.name, field.content]));
  assert.equal(previewFields.force_download, 'false');
  assert.equal(previewFields.is_preview, 'true');
  assert.equal(previewFields.json_error, undefined);
  assert.equal(previewFields.SynoToken, 'SYNTHETIC-TOKEN');
});

test('Drive transfer failures keep Drive semantics and a rejected session is invalidated exactly once', async () => {
  const expired = await fixture({ onUpload: async () => errorReply(119) });
  await assert.rejects(expired.connector.uploadDrive(upload(), source(), control()), isKind(K.SessionExpired));
  assert.equal(expired.connector.hasBusinessSession('FileStation'), false);
  // 会话确实失效：下一次调用要求重新登录，而不是带旧会话重试。
  await assert.rejects(expired.connector.uploadDrive(upload(), source(), control()),
    error => isKind(K.SessionExpired)(error) && error.message === '请先登录 NAS。');
  assert.equal(expired.calls.length, 1);

  const server = await fixture({ onUpload: async () => errorReply(105) });
  await assert.rejects(server.connector.uploadDrive(upload(), source(), control()),
    error => error.kind === K.Server && error.code === 105 && error.message === '暂时无法读取 Drive 内容，请刷新重试。');
  assert.equal(server.connector.hasBusinessSession('FileStation'), true);

  const mismatch = await fixture({ onUpload: async () => ok({ tmp_newly_created: true, uploaded_size: 3 }) });
  await assert.rejects(mismatch.connector.uploadDrive(upload(), source(), control()),
    error => isKind(K.Protocol)(error) && error.message === '上传结果未能确认，请检查目标文件后再试。');
  assert.equal(mismatch.connector.hasBusinessSession('FileStation'), true);
});

test('a Drive transfer without capability, session or a usable location never reaches the transfer layer', async () => {
  const noTransfer = await fixture({ withoutTransfers: true });
  await assert.rejects(noTransfer.connector.uploadDrive(upload(), source(), control()),
    error => isKind(K.Unsupported)(error) && error.message === '当前连接不支持文件传输。');
  await assert.rejects(noTransfer.connector.downloadDrive(download(), { directory: '/cache/d', maximumBytes: 8 }, control()),
    error => isKind(K.Unsupported)(error) && error.message === '当前连接不支持文件传输。');
  assert.equal(noTransfer.calls.length, 0);

  const noFiles = await fixture({ withoutFiles: true });
  await assert.rejects(noFiles.connector.uploadDrive(upload(), source(), control()),
    error => isKind(K.Unsupported)(error) && error.message === driveUnavailable);
  await assert.rejects(noFiles.connector.downloadDrive(download(), { directory: '/cache/d', maximumBytes: 8 }, control()),
    error => isKind(K.Unsupported)(error) && error.message === driveUnavailable);

  const oldFiles = await fixture({ minVersion: 1, maxVersion: 1 });
  await assert.rejects(oldFiles.connector.downloadDrive(download(), { directory: '/cache/d', maximumBytes: 8 }, control()),
    error => isKind(K.Unsupported)(error) && error.message === driveUnavailable);

  const badInput = await fixture();
  await assert.rejects(badInput.connector.uploadDrive(upload({ parentId: 'id:1' }), source(), control()), isKind(K.InvalidInput));
  await assert.rejects(badInput.connector.uploadDrive(upload({ filename: '../x' }), source(), control()), isKind(K.InvalidInput));
  await assert.rejects(badInput.connector.uploadDrive(upload(), { path: 'relative.bin', bytes: 4 }, control()), isKind(K.InvalidInput));
  await assert.rejects(badInput.connector.uploadDrive(upload(), { path: '/cache/src.bin', bytes: -1 }, control()), isKind(K.InvalidInput));
  await assert.rejects(badInput.connector.downloadDrive(download(), { directory: '/cache/d', maximumBytes: 0 }, control()), isKind(K.InvalidInput));
  await assert.rejects(badInput.connector.downloadDrive(download({ fileId: '97670045702610812a' }),
    { directory: '/cache/d', maximumBytes: 8 }, control()), isKind(K.InvalidInput));

  const stopped = await fixture();
  const signal = control();
  signal.cancellation.cancel();
  await assert.rejects(stopped.connector.uploadDrive(upload(), source(), signal),
    error => isKind(K.Cancelled)(error) && error.message === '传输已取消。');
  assert.equal(stopped.calls.length, 0);
});

test('a download result that becomes stale is discarded instead of handed out', async () => {
  const f = await fixture({ bytes: 8, onDownload: context => { context.connector.close(); } });
  await assert.rejects(f.connector.downloadDrive(download(), { directory: '/cache/drive-3', maximumBytes: 64, expectedBytes: 8 }, control()),
    error => isKind(K.Cancelled)(error) && error.message === '连接已关闭。');
  assert.equal(f.calls[0].discarded, true);
});

test('an upload that resolves after the connection changed never reports success', async () => {
  const f = await fixture({ onUpload: async context => { context.connector.close(); return ok({ tmp_newly_created: true, uploaded_size: 4 }); } });
  await assert.rejects(f.connector.uploadDrive(upload(), source(), control()),
    error => isKind(K.Cancelled)(error) && error.message === '连接已关闭。');
});

test('a stop reason from the transfer layer survives to the caller, and stale progress is refused', async () => {
  const stopped = await fixture({ onUpload: async () => {
    throw new NasFailure(K.Cancelled, '上传已停止，请检查目标文件以确认结果。'); } });
  await assert.rejects(stopped.connector.uploadDrive(upload(), source(), control()),
    error => isKind(K.Cancelled)(error) && error.message === '上传已停止，请检查目标文件以确认结果。');
  assert.equal(stopped.connector.hasBusinessSession('FileStation'), true);

  const seen = [];
  const progress = await fixture({ onUpload: async () => ok({ tmp_newly_created: true, uploaded_size: 4 }) });
  await progress.connector.uploadDrive(upload(), source(), control(value => seen.push({ ...value })));
  const forwarded = progress.calls[0].control;
  forwarded.onProgress({ direction: 'upload', processed: 1, total: 2 });
  assert.deepEqual(seen, [{ direction: 'upload', processed: 1, total: 2 }]);
  progress.connector.close();
  assert.throws(() => forwarded.onProgress({ direction: 'upload', processed: 2, total: 2 }),
    error => isKind(K.Cancelled)(error) && error.message === '连接已关闭。');
  assert.equal(seen.length, 1);

  const stale = await fixture({ onUpload: async () => errorReply(119) });
  await assert.rejects(stale.connector.uploadDrive(upload(), source(), control(value => seen.push({ ...value }))), isKind(K.SessionExpired));
  assert.throws(() => stale.calls[0].control.onProgress({ direction: 'upload', processed: 1, total: 2 }),
    error => isKind(K.Cancelled)(error) && error.message === '连接已切换。');
  assert.equal(seen.length, 1);
});

test('a download whose content fails Drive validation is discarded before it becomes a result', async () => {
  const cases = [
    { binary: { status: 302, contentType: 'text/html', contentLength: '', contentDisposition: '', bytes: 0,
      prefix: new Uint8Array(0), prefixText: '' }, kind: K.Http },
    { binary: { status: 200, contentType: 'application/json', contentLength: '32', contentDisposition: '', bytes: 32,
      prefix: new Uint8Array(0), prefixText: '{"success":false,"error":{"code":119}}' }, kind: K.SessionExpired },
    { binary: { status: 200, contentType: 'text/html', contentLength: '5', contentDisposition: '', bytes: 5,
      prefix: new Uint8Array(0), prefixText: '<html>' }, kind: K.Protocol },
    { binary: { status: 200, contentType: 'application/octet-stream', contentLength: '7', contentDisposition: '', bytes: 8,
      prefix: new Uint8Array(0), prefixText: '' }, kind: K.Protocol }
  ];
  for (const scenario of cases) {
    const f = await fixture({ bytes: scenario.bytes === undefined ? scenario.binary.bytes : scenario.bytes, binary: scenario.binary });
    await assert.rejects(f.connector.downloadDrive(download(), { directory: '/cache/drive-4', maximumBytes: 64 }, control()),
      isKind(scenario.kind));
    assert.equal(f.calls[0].discarded, undefined);
  }
});

test('the Drive transfer adapter refuses what an entry cannot do and forwards only typed requests', async () => {
  const f = await fixture({ bytes: 8 });
  const adapter = new DriveTransferAdapter(f.connector);
  assert.equal(adapter.available(), true);
  assert.equal((await fixture({ withoutFiles: true })).connector.supportsDriveApi('SYNO.SynologyDrive.Files', 2), false);

  for (const unusable of [entry({ capabilities: capabilitiesOf({ canRead: false, canDownload: false }) }),
    entry({ capabilities: capabilitiesOf({ canDownload: false }) }), folder({ capabilities: capabilitiesOf({ canRead: false }) })]) {
    assert.throws(() => adapter.download(unusable, { directory: '/cache/d', maximumBytes: 8 }, control()),
      error => isKind(K.Permission)(error) && error.message === '无法下载此文件。');
  }
  assert.throws(() => adapter.download(entry({ capabilities: capabilitiesOf({ canPreview: false }) }),
    { directory: '/cache/d', maximumBytes: 8 }, control(), true),
    error => isKind(K.Permission)(error) && error.message === '无法预览此文件。');
  assert.throws(() => adapter.upload(entry(), 'a.bin', 'version', 0, source(), control()),
    error => isKind(K.Permission)(error) && error.message === '无法向此文件夹上传文件。');
  assert.throws(() => adapter.upload(folder({ capabilities: capabilitiesOf({ canWrite: false }) }), 'a.bin', 'version', 0, source(), control()),
    isKind(K.Permission));
  assert.equal(f.calls.length, 0);

  assert.deepEqual(await adapter.download(entry(), { directory: '/cache/drive-5', maximumBytes: 64 }, control()),
    { path: '/cache/drive-5/content', bytes: 8 });
  assert.deepEqual(await adapter.upload(folder(), 'a.bin', 'version', 1790570123.335, source(), control()),
    { uploadedBytes: 4 });
  const fields = Object.fromEntries(f.calls[1].request.fields.map(field => [field.name, field.content]));
  assert.equal(fields.path, 'id:' + folder().fileId + '/a.bin');
  assert.equal(fields.conflict_action, 'version');
  assert.equal(fields.modified_time, '1790570123.335');
});
