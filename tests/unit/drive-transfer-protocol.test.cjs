const { test } = require('node:test');
const assert = require('node:assert/strict');
const protocol = require('../../work/core-build/domain/DriveTransferProtocol.js');
const transport = require('../../work/core-build/network/NasTransferTransport.js');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');

const isKind = kind => error => error instanceof NasFailure && error.kind === kind;
const named = list => Object.fromEntries(list.map(field => [field.name, field.content]));
const encoder = new TextEncoder();
const json = data => JSON.stringify({ success: true, data });
const binary = over => Object.assign({ status: 200, contentType: 'application/octet-stream', contentLength: '',
  contentDisposition: '', bytes: 0, prefix: new Uint8Array(0), prefixText: '' }, over);
const body = (bytes, over = {}) => binary(Object.assign({ bytes: bytes.length, prefix: bytes,
  contentLength: String(bytes.length) }, over));
const text = (value, over = {}) => body(encoder.encode(value), Object.assign({ prefixText: value }, over));

test('Drive upload fields keep the captured raw scalar multipart encoding and reject every unusable input', () => {
  const input = { parentId: '829198498346875491', filename: 'PLAN.md', conflict: 'version', modifiedTime: 1790570123.335 };
  assert.deepEqual(protocol.driveUploadFields(input), [
    { name: 'path', content: 'id:829198498346875491/PLAN.md' },
    { name: 'type', content: 'file' },
    { name: 'conflict_action', content: 'version' },
    { name: 'modified_time', content: '1790570123.335' }
  ]);
  assert.equal(named(protocol.driveUploadFields({ ...input, conflict: 'autorename' })).conflict_action, 'autorename');
  // 长 ID 以字符串原样传递，不被转成数字。
  assert.equal(named(protocol.driveUploadFields(input)).path, 'id:829198498346875491/PLAN.md');
  for (const parentId of ['', 'abc', '1e5', '-1', ' 12', '123456789012345678901']) {
    assert.throws(() => protocol.driveUploadFields({ ...input, parentId }), isKind(K.InvalidInput));
  }
  for (const filename of ['', '.', '..', 'a/b', 'a\\b', 'a\u0000b', 'a\u007fb']) {
    assert.throws(() => protocol.driveUploadFields({ ...input, filename }), isKind(K.InvalidInput));
  }
  for (const conflict of ['overwrite', '', undefined, 1]) {
    assert.throws(() => protocol.driveUploadFields({ ...input, conflict }), isKind(K.InvalidInput));
  }
  for (const modifiedTime of [-1, NaN, Infinity, '1790570123'] ) {
    assert.throws(() => protocol.driveUploadFields({ ...input, modifiedTime }), isKind(K.InvalidInput));
  }
  // 调用方多带的字段不会进入 multipart，认证字段无法借业务参数注入。
  assert.equal(protocol.driveUploadFields({ ...input, api: 'SYNO.FileStation.Upload', _sid: 'x', SynoToken: 'x', file: 'x' }).length, 4);
  const encoded = JSON.stringify(protocol.driveUploadFields(input));
  assert.equal(encoded.includes('SYNO.'), false);
  assert.equal(encoded.toLowerCase().includes('sid'), false);
});

test('Drive download fields distinguish an ordinary download from a preview and stay user-safe', () => {
  const base = { fileId: '976700457026108129', filename: 'PLAN.md', preview: false };
  assert.deepEqual(named(protocol.driveDownloadFields(base)), { files: '["id:976700457026108129"]',
    force_download: 'true', json_error: 'true', download_type: '"download"', c2_offload: '"allow"' });
  assert.deepEqual(named(protocol.driveDownloadFields({ ...base, preview: true })),
    { files: '["id:976700457026108129"]', force_download: 'false', is_preview: 'true' });
  for (const fileId of ['id:1', '', '1.5']) {
    assert.throws(() => protocol.driveDownloadFields({ ...base, fileId }), isKind(K.InvalidInput));
  }
  for (const filename of ['../etc/passwd', 'a/b', '']) {
    assert.throws(() => protocol.driveDownloadFields({ ...base, filename }), isKind(K.InvalidInput));
  }
  assert.throws(() => protocol.driveDownloadFields({ ...base, preview: 'true' }), isKind(K.InvalidInput));
});

test('a Drive upload counts as accepted only for the reported byte count, in either captured success shape', () => {
  const accepted = [ { tmp_newly_created: true, uploaded_size: 8 }, { uploaded_size: 8, file: { file_id: '829198498346875491' } } ];
  for (const data of accepted) {
    assert.deepEqual(protocol.decodeDriveUpload(200, json(data), 8), { uploadedBytes: 8 });
  }
  const unconfirmed = [ { tmp_newly_created: true }, { uploaded_size: '8' }, { uploaded_size: -1 }, { uploaded_size: 1.5 },
    { uploaded_size: 7 }, { uploaded_size: 9 }, { uploaded_size: 9007199254740992 } ];
  for (const data of unconfirmed) {
    assert.throws(() => protocol.decodeDriveUpload(200, json(data), 8), error => {
      assert.ok(isKind(K.Protocol)(error));
      assert.equal(error.message, '上传结果未能确认，请检查目标文件后再试。');
      assert.doesNotMatch(error.message, /uploaded_size|multipart|SYNO\.|预期|字节/);
      return true;
    });
  }
  assert.throws(() => protocol.decodeDriveUpload(200, JSON.stringify({ success: false, error: { code: 119 } }), 8),
    isKind(K.SessionExpired));
  assert.throws(() => protocol.decodeDriveUpload(200, JSON.stringify({ success: false, error: { code: 105 } }), 8),
    error => error.kind === K.Server && error.code === 105 && error.message === '暂时无法读取 Drive 内容，请刷新重试。');
  assert.throws(() => protocol.decodeDriveUpload(302, json({ uploaded_size: 8 }), 8), isKind(K.Http));
});

test('a downloaded file is judged by its own bytes, so JSON and attached HTML content are still files', () => {
  const target = { directory: '/cache/drive', maximumBytes: 4096 };
  assert.doesNotThrow(() => protocol.validateDriveDownload(text('{"hello":[1,2,3]}', { contentType: 'application/json' }), target));
  assert.doesNotThrow(() => protocol.validateDriveDownload(text('{"success":true,"data":{"list":[]}}',
    { contentType: 'application/json' }), target));
  assert.doesNotThrow(() => protocol.validateDriveDownload(text('<html><body>报告</body></html>',
    { contentType: 'text/html', contentDisposition: 'attachment; filename="报告.html"' }), target));
  assert.doesNotThrow(() => protocol.validateDriveDownload(body(new Uint8Array([1, 2, 3, 4])),
    { directory: '/cache/drive', maximumBytes: 4096, expectedBytes: 4 }));
  assert.doesNotThrow(() => protocol.validateDriveDownload(body(new Uint8Array(0)), target));
  assert.doesNotThrow(() => protocol.validateDriveDownload(body(new Uint8Array([0, 255, 254, 1])), target));
});

test('a download refuses error envelopes, wrong lengths and non-200 responses without inventing content', () => {
  const target = { directory: '/cache/drive', maximumBytes: 4096 };
  // DSM 在 HTTP 200 上返回明确的错误信封：必须按 Drive 错误语义解释，不能当文件交付。
  assert.throws(() => protocol.validateDriveDownload(text('{"success":false,"error":{"code":119}}',
    { contentType: 'application/json' }), target), isKind(K.SessionExpired));
  assert.throws(() => protocol.validateDriveDownload(text('{"success":false,"error":{"code":105}}',
    { contentType: 'application/json' }), target), error => error.kind === K.Server && error.code === 105);
  assert.throws(() => protocol.validateDriveDownload(body(new Uint8Array(8), { status: 302 }), target), isKind(K.Http));
  assert.throws(() => protocol.validateDriveDownload(body(new Uint8Array(8), { status: 401 }), target), isKind(K.Http));
  for (const contentLength of ['9', '8 ', '0x8', '-8', '8.0']) {
    assert.throws(() => protocol.validateDriveDownload(body(new Uint8Array(8), { contentLength }), target),
      error => isKind(K.Protocol)(error) && error.message === '下载文件不完整，请重试。');
  }
  assert.throws(() => protocol.validateDriveDownload(body(new Uint8Array(5)), { directory: '/cache/drive', maximumBytes: 4 }),
    isKind(K.Protocol));
  assert.throws(() => protocol.validateDriveDownload(body(new Uint8Array(3)),
    { directory: '/cache/drive', maximumBytes: 4096, expectedBytes: 4 }), isKind(K.Protocol));
  assert.throws(() => protocol.validateDriveDownload(binary({ bytes: -1 }), target), isKind(K.Protocol));
  assert.throws(() => protocol.validateDriveDownload(text('<html>请登录</html>', { contentType: 'text/html' }), target),
    error => isKind(K.Protocol)(error) && error.message === '未能取得下载文件，请重新登录后重试。');
});

test('only a small body is sniffed for a Drive error envelope, so a large file is never misread as one', () => {
  const large = binary({ bytes: transport.NAS_TRANSFER_PREFIX_BYTES + 1, prefixText: '{"success":false,"error":{"code":119}}' });
  assert.doesNotThrow(() => protocol.validateDriveDownload(large, { directory: '/cache/drive', maximumBytes: large.bytes }));
  const small = binary({ bytes: 32, prefixText: '{"success":false,"error":{"code":119}}' });
  assert.throws(() => protocol.validateDriveDownload(small, { directory: '/cache/drive', maximumBytes: 32 }),
    isKind(K.SessionExpired));
});

test('transfer limits and local path/byte validation are shared by every transport implementation', () => {
  assert.equal(transport.NAS_TRANSFER_PREFIX_BYTES, 64 * 1024);
  assert.equal(transport.NAS_TRANSFER_UPLOAD_REPLY_BYTES, 1024 * 1024);
  assert.equal(transport.validateNasTransferFilename('报告 2026.md'), '报告 2026.md');
  for (const name of ['', '.', '..', 'a/b', 'a\\b', 'a\u0000b', 'a\u007fb']) {
    assert.throws(() => transport.validateNasTransferFilename(name), isKind(K.InvalidInput));
  }
  assert.doesNotThrow(() => transport.validateNasUploadSource({ path: '/cache/a.bin', bytes: 0 }));
  for (const path of ['', 'relative/file', '/dir/', '/dir/../other', '/dir/./x', 'C:/dir/x', '/dir\\x', '/dir\u0000']) {
    assert.throws(() => transport.validateNasUploadSource({ path, bytes: 1 }), isKind(K.InvalidInput));
  }
  for (const bytes of [-1, 1.5, NaN, Infinity, '8', undefined]) {
    assert.throws(() => transport.validateNasUploadSource({ path: '/cache/a.bin', bytes }), isKind(K.InvalidInput));
  }
  assert.doesNotThrow(() => transport.validateNasDownloadTarget({ directory: '/cache/d', maximumBytes: 4, expectedBytes: 4 }));
  for (const target of [ { directory: '/cache/d', maximumBytes: 0 }, { directory: '/cache/d', maximumBytes: -1 },
    { directory: '/cache/d', maximumBytes: 1.5 }, { directory: '/cache/d', maximumBytes: 4, expectedBytes: 5 },
    { directory: '/cache/d', maximumBytes: 4, expectedBytes: -1 }, { directory: '/cache/d', maximumBytes: 4, expectedBytes: 1.5 },
    { directory: '/cache/', maximumBytes: 4 } ]) {
    assert.throws(() => transport.validateNasDownloadTarget(target), isKind(K.InvalidInput));
  }
});

test('a transfer signal cancels only its own request and survives a failing listener', () => {
  const signal = new transport.NasTransferCancellation();
  assert.equal(signal.cancelled, false);
  assert.doesNotThrow(() => signal.check());
  signal.subscribe(() => { throw new Error('listener failed'); });
  let reached = 0;
  const unsubscribe = signal.subscribe(() => { reached++; });
  signal.cancel();
  assert.equal(signal.cancelled, true);
  assert.equal(reached, 1);
  assert.throws(() => signal.check(), error => isKind(K.Cancelled)(error) && error.message === '传输已取消。');
  signal.cancel();
  assert.equal(reached, 1);
  let immediate = 0;
  signal.subscribe(() => { immediate++; });
  assert.equal(immediate, 1);
  unsubscribe();
  assert.equal(reached, 1);
});
