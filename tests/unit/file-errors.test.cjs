const { test } = require('node:test');
const assert = require('node:assert/strict');
const { dsmFailure, decodeNasResponse, NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');

const fileApi = suffix => 'SYNO.FileStation.' + suffix;
const decodeFailure = (api, code, errors) => {
  const response = { success: false, error: { code, errors } };
  try { decodeNasResponse(api, 200, JSON.stringify(response)); }
  catch (error) { return error; }
  assert.fail('a failed envelope must not become a success');
};

test('known file conflicts explain the cause while retaining the existing Server kind and numeric code', () => {
  for (const [api, code, message] of [
    [fileApi('Rename'), 414, /同名文件或文件夹/],
    [fileApi('CopyMove'), 1003, /目标目录已存在同名/],
    [fileApi('CopyMove'), 1004, /同名但类型不同/]
  ]) {
    const error = dsmFailure(api, code);
    assert.ok(error instanceof NasFailure);
    assert.equal(error.kind, K.Server);
    assert.equal(error.code, code);
    assert.match(error.message, message);
    assert.doesNotMatch(error.message, /错误码/);
  }
});

test('documented storage, path, name and task failures receive specific Chinese explanations', () => {
  for (const [code, message] of [
    [400, /参数不正确/], [401, /未知错误/], [402, /NAS 当前繁忙/], [406, /账号或用户组信息/],
    [408, /文件或文件夹不存在/], [409, /文件系统不支持/], [410, /远程文件系统/],
    [412, /名称过长/], [413, /加密文件系统的长度限制/], [415, /磁盘配额/],
    [416, /存储空间不足/], [417, /读写文件失败/], [418, /名称或路径/], [419, /文件名称不符合/],
    [420, /FAT 文件系统/], [421, /正在使用中/], [599, /任务不存在/]
  ]) {
    const error = dsmFailure(fileApi('Delete'), code);
    assert.equal(error.kind, K.Server);
    assert.equal(error.code, code);
    assert.match(error.message, message);
  }
  const readOnly = dsmFailure(fileApi('Rename'), 411);
  assert.equal(readOnly.kind, K.Permission);
  assert.equal(readOnly.code, 411);
  assert.match(readOnly.message, /只读/);
  for (const code of [105, 403, 404, 405, 407]) {
    const error = dsmFailure(fileApi('Delete'), code);
    assert.equal(error.kind, K.Permission);
    assert.equal(error.code, code);
  }
});

test('operation aggregate errors explain failure without claiming that any particular file succeeded', () => {
  for (const [api, code, message] of [
    [fileApi('Delete'), 900, /删除未全部完成/],
    [fileApi('CopyMove'), 1000, /复制未全部完成/],
    [fileApi('CopyMove'), 1001, /移动未全部完成/],
    [fileApi('CopyMove'), 1002, /目标目录发生错误/],
    [fileApi('CreateFolder'), 1100, /文件夹创建失败/],
    [fileApi('CreateFolder'), 1101, /文件夹数量将超过系统限制/],
    [fileApi('Rename'), 1200, /重命名失败/],
    [fileApi('CopyMove'), 1006, /FAT32.*名称中的字符/],
    [fileApi('CopyMove'), 1007, /FAT32.*超过 4 GB/]
  ]) {
    const error = dsmFailure(api, code);
    assert.equal(error.kind, K.Server);
    assert.equal(error.code, code);
    assert.match(error.message, message);
    assert.doesNotMatch(error.message, /部分成功|全部失败|已回滚/);
  }
});

test('official error.errors gives the first known reason while preserving the aggregate kind and code', () => {
  const error = decodeFailure(fileApi('CopyMove'), 1000, [
    { code: 9999, path: '/secret/unknown', message: 'untrusted server message' },
    { code: 416, path: '/secret/private', name: 'private name' }, { code: 414, path: '/secret/later' }
  ]);
  assert.equal(error.kind, K.Server);
  assert.equal(error.code, 1000);
  assert.match(error.message, /复制未全部完成/);
  assert.match(error.message, /原因：存储空间不足/);
  assert.doesNotMatch(error.message, /同名|secret|private|untrusted/);
  for (const [api, aggregate, reason, message] of [
    [fileApi('Delete'), 900, 407, /没有执行此操作的权限/],
    [fileApi('CreateFolder'), 1100, 418, /名称或路径/],
    [fileApi('Rename'), 1200, 414, /同名/],
    [fileApi('CopyMove'), 1001, 408, /文件或文件夹不存在/]
  ]) {
    const failure = decodeFailure(api, aggregate, [{ code: reason, path: '/secret/file' }]);
    assert.equal(failure.kind, K.Server, 'nested permissions must not alter the established aggregate kind');
    assert.equal(failure.code, aggregate);
    assert.match(failure.message, message);
    assert.doesNotMatch(failure.message, /secret/);
  }
});

test('missing, unknown and malformed optional detail cannot hide a confirmed aggregate failure', () => {
  const expected = dsmFailure(fileApi('Delete'), 900);
  for (const errors of [undefined, null, {}, 'bad', [], [{ code: 9999 }],
    [null, false, [], { code: '416' }, { code: -1 }, { code: 416.5 }]]) {
    const failure = decodeFailure(fileApi('Delete'), 900, errors);
    assert.ok(failure instanceof NasFailure);
    assert.equal(failure.kind, expected.kind);
    assert.equal(failure.code, expected.code);
    assert.equal(failure.message, expected.message);
  }
});

test('Auth and OTP messages, session invalidation and other API namespaces keep their existing contracts', () => {
  for (const [code, kind, message] of [
    [400, K.Credentials, '账号或密码不正确。'], [401, K.Permission, '该账号已停用。'],
    [403, K.OtpRequired, '请输入双重验证动态码。'], [406, K.OtpRequired, '请输入双重验证动态码。'],
    [404, K.OtpInvalid, '动态码验证失败，请输入新的动态码。'],
    [407, K.Permission, '当前网络地址已被 DSM 封锁，请在 DSM 检查。'],
    [408, K.Credentials, '密码已到期或需要修改，请先在 DSM 网页处理。']
  ]) {
    const failure = decodeFailure('SYNO.API.Auth', code, [{ code: 414 }]);
    assert.equal(failure.kind, kind);
    assert.equal(failure.code, code);
    assert.equal(failure.message, message);
  }
  for (const api of [fileApi('Delete'), 'SYNO.API.Auth', 'SYNO.Foto.Browse.Item']) {
    for (const code of [106, 107, 119, 150]) {
      const failure = decodeFailure(api, code, [{ code: 416 }]);
      assert.equal(failure.kind, K.SessionExpired);
      assert.equal(failure.code, code);
      assert.equal(failure.message, dsmFailure(api, code).message);
    }
  }
  for (const code of [900, 1000, 1100, 1200, 414, 416]) {
    assert.equal(dsmFailure('SYNO.Foto.Browse.Item', code).message, `DSM 未完成请求（错误码 ${code}）。`);
  }
});

test('unknown or mismatched operation codes retain the existing generic message and code', () => {
  for (const [api, code] of [[fileApi('List'), 1003], [fileApi('Rename'), 1100],
    [fileApi('Delete'), 1005], [fileApi('CreateFolder'), 9999]]) {
    const failure = decodeFailure(api, code, [{ code: 99999 }]);
    assert.equal(failure.kind, K.Server);
    assert.equal(failure.code, code);
    assert.equal(failure.message, `DSM 未完成请求（错误码 ${code}）。`);
  }
  const direct = decodeFailure(fileApi('Rename'), 414, [{ code: 416 }]);
  assert.match(direct.message, /同名/);
  assert.doesNotMatch(direct.message, /存储空间|原因/);
});
