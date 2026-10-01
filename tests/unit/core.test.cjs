const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const protocol = require('../../work/core-build/domain/DsmProtocol.js');
const { NasConnector } = require('../../work/core-build/network/NasConnector.js');
const { NasFailure, NasErrorKind: K } = protocol;
const fixture = JSON.parse(fs.readFileSync('tests/contract_fixtures/nas-capabilities.json', 'utf8'));
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });
const fail = code => ({ status: 200, text: JSON.stringify({ success: false, error: { code } }) });
const isKind = kind => error => error instanceof NasFailure && error.kind === kind;

class FakeTransport {
  calls = [];
  replies = [];
  closed = false;
  async post(address, body, authorization) {
    this.calls.push({ address, body: new URLSearchParams(body), authorization });
    assert.ok(this.replies.length, 'unexpected network request');
    const reply = this.replies.shift();
    return typeof reply === 'function' ? reply() : reply;
  }
  close() { this.closed = true; }
}

async function connected() {
  const transport = new FakeTransport();
  transport.replies.push(ok(fixture.data));
  const connector = new NasConnector(transport);
  await connector.discover('https://nas.example.test:5001');
  return { connector, transport };
}

async function loggedIn() {
  const context = await connected();
  context.transport.replies.push(ok({ sid: 'test-sid', synotoken: 'test-token' }));
  await context.connector.login('reader', 'private &+=密码', '');
  return context;
}

test('HTTPS origin rejects credential, downgrade, path and URL escape inputs', () => {
  assert.equal(protocol.normalizeNasOrigin(' HTTPS://nas.test ' .toLowerCase()), 'https://nas.test');
  assert.equal(protocol.normalizeNasOrigin('https://NAS.test:443/'), 'https://nas.test');
  assert.equal(protocol.normalizeNasOrigin('https://[2001:db8::1]:5001'), 'https://[2001:db8::1]:5001');
  for (const input of ['http://nas.test', 'https://u:p@nas.test', 'https://nas.test/path',
    'https://nas.test?next=evil', 'https://nas.test#x', 'https://nas.test:0', 'https://nas.test:65536',
    'https://nas.test\\@evil.test', 'https://.nas.test', 'https://nas..test']) {
    assert.throws(() => protocol.normalizeNasOrigin(input), isKind(K.InvalidInput));
  }
});

test('discovered CGI paths cannot leave the trusted origin or webapi prefix', () => {
  assert.equal(protocol.validateApiPath('FileStation/file_share.cgi'), 'FileStation/file_share.cgi');
  for (const input of ['https://evil.test/a.cgi', '//evil.test/a.cgi', '../entry.cgi',
    'x/../entry.cgi', 'entry.cgi?next=x', '%2e%2e/entry.cgi', 'entry.cgi#x']) {
    assert.throws(() => protocol.validateApiPath(input), isKind(K.Protocol));
  }
});

test('HTTP status, malformed envelopes, HTML and business errors cannot become success', () => {
  assert.throws(() => protocol.decodeNasResponse('SYNO.API.Auth', 302, '{}'), isKind(K.Http));
  for (const body of ['<html>Login</html>', 'null', '[]', '{}', '{"success":"true"}',
    '{"success":false}', '{"success":true,"data":null}']) {
    assert.throws(() => protocol.decodeNasResponse('SYNO.API.Auth', 200, body), isKind(K.Protocol));
  }
  assert.throws(() => protocol.decodeNasResponse('SYNO.FileStation.List', 200, fail(105).text), isKind(K.Permission));
  assert.deepEqual(protocol.decodeNasResponse('SYNO.API.Auth', 200, '{"success":true}'), {});
});

test('authentication and file error namespaces preserve their different meanings', () => {
  assert.equal(protocol.dsmFailure('SYNO.API.Auth', 403).kind, K.OtpRequired);
  assert.equal(protocol.dsmFailure('SYNO.API.Auth', 406).kind, K.OtpRequired);
  assert.equal(protocol.dsmFailure('SYNO.API.Auth', 404).kind, K.OtpInvalid);
  assert.equal(protocol.dsmFailure('SYNO.FileStation.List', 403).kind, K.Permission);
  assert.equal(protocol.dsmFailure('SYNO.FileStation.List', 404).kind, K.Permission);
  assert.equal(protocol.dsmFailure('SYNO.FileStation.List', 402).kind, K.Server);
  assert.equal(protocol.dsmFailure('SYNO.FileStation.List', 150).kind, K.SessionExpired);
});

test('capability parsing validates ranges, paths and version intersection', () => {
  const capabilities = protocol.decodeCapabilities(fixture.data);
  assert.equal(protocol.selectNasApi(capabilities, 'SYNO.API.Auth', [6]).maxVersion, 7);
  assert.throws(() => protocol.selectNasApi(capabilities, 'SYNO.API.Auth', [8]), isKind(K.Unsupported));
  assert.throws(() => protocol.decodeCapabilities({ bad: { minVersion: 7, maxVersion: 6, path: 'entry.cgi' } }), isKind(K.Protocol));
  assert.throws(() => protocol.decodeCapabilities({ bad: null }), isKind(K.Protocol));
});

test('file parser validates identity, page bounds, missing isdir and zero-byte files', () => {
  const entry = { name: '中文 , &+.txt', path: '/共享/中文 , &+.txt', isdir: false, additional: { size: 0 } };
  assert.equal(protocol.decodeNasFilePage({ offset: 0, total: 1, files: [entry] }, false, 0, 100).entries[0].bytes, 0);
  assert.equal(protocol.decodeNasFilePage({ offset: 0, total: 1, shares: [{ name: '共享', path: '/共享' }] }, true, 0, 100).entries[0].isDirectory, true);
  for (const data of [
    { offset: 1, total: 1, files: [entry] }, { offset: 0, total: 0, files: [entry] },
    { offset: 0, total: 1, files: [] }, { offset: 0, total: 2, files: [entry, entry] },
    { offset: 0, total: 1, files: [{ name: 'x', path: '/x' }] },
    { offset: 0, total: 1, files: [{ ...entry, additional: { size: -1 } }] },
    { offset: 0, total: 1, files: [{ ...entry, path: '/共享/../x' }] }
  ]) assert.throws(() => protocol.decodeNasFilePage(data, false, 0, 100), isKind(K.Protocol));
});

test('login sends secrets only in POST body using Auth 6, and OTP can be retried explicitly', async () => {
  const { connector, transport } = await connected();
  transport.replies.push(fail(403), ok({ sid: 'test-sid' }));
  await assert.rejects(connector.login('reader', 'secret+&密码', ''), isKind(K.OtpRequired));
  await connector.login('reader', 'secret+&密码', '123456');
  const call = transport.calls.at(-1);
  assert.equal(call.address, 'https://nas.example.test:5001/webapi/entry.cgi');
  assert.equal(call.body.get('version'), '6');
  assert.equal(call.body.get('passwd'), 'secret+&密码');
  assert.equal(call.body.get('otp_code'), '123456');
  assert.equal(call.body.get('format'), 'sid');
  assert.ok(!call.address.includes('secret'));
});

test('JSON requestFormat quotes string parameters and preserves Unicode/comma/backslash paths', async () => {
  const { connector, transport } = await loggedIn();
  transport.replies.push(ok({ offset: 100, total: 100, files: [] }));
  await connector.list('/共享/中文 , &+\\目录', 100);
  const call = transport.calls.at(-1);
  assert.equal(JSON.parse(call.body.get('folder_path')), '/共享/中文 , &+\\目录');
  assert.equal(JSON.parse(call.body.get('sort_by')), 'name');
  assert.equal(call.body.get('offset'), '100');
  assert.deepEqual(call.authorization, { sid: 'test-sid', synoToken: 'test-token' });
  assert.equal(call.body.get('_sid'), null);
  assert.equal(call.body.get('SynoToken'), null);
  assert.deepEqual(JSON.parse(call.body.get('additional')), ['size']);
});

test('expired session clears local authorization and does not retry automatically', async () => {
  const { connector, transport } = await loggedIn();
  transport.replies.push(fail(106));
  await assert.rejects(connector.list(''), isKind(K.SessionExpired));
  const count = transport.calls.length;
  await assert.rejects(connector.list(''), isKind(K.SessionExpired));
  assert.equal(transport.calls.length, count);
});

test('reads and logout pass Cookie SID and CSRF credentials without putting them in URL or form', async () => {
  const { connector, transport } = await loggedIn();
  assert.equal(transport.calls[0].authorization, undefined);
  assert.equal(transport.calls[1].authorization, undefined);
  transport.replies.push(() => {
    const call = transport.calls.at(-1);
    // 回归真实 DSM 的 119：传输层同时取得 Cookie SID 与 CSRF 请求头凭证。
    return call.authorization?.sid === 'test-sid' && call.authorization?.synoToken === 'test-token' ? ok({ offset: 0, total: 0, shares: [] }) : fail(119);
  }, ok(undefined));
  await connector.list('');
  await connector.logout();
  for (const call of transport.calls.slice(2)) {
    assert.deepEqual(call.authorization, { sid: 'test-sid', synoToken: 'test-token' });
    assert.equal(call.body.get('_sid'), null);
    assert.equal(call.body.get('SynoToken'), null);
    assert.ok(!call.address.includes('test-sid'));
  }
  assert.ok(transport.closed);
});

test('session parsing rejects Cookie separators and header injection before using the SID', () => {
  for (const sid of ['sid; id=other', 'sid\r\nX-Injected: yes', 'sid,other', '"sid"', 'sid\\other', 'sid other']) {
    assert.throws(() => protocol.decodeNasSession({ sid }), isKind(K.Protocol));
  }
  assert.equal(protocol.decodeNasSession({ sid: 'valid_SID-0123.~' }).sid, 'valid_SID-0123.~');
  assert.throws(() => protocol.decodeNasSession({ sid: 'sid', synotoken: 'token\r\nInjected: yes' }), isKind(K.Protocol));
});

test('restored sessions must be discovered, are copied, and invalidation removes the snapshot', async () => {
  const unopened = new NasConnector(new FakeTransport());
  assert.throws(() => unopened.restoreSession({ sid: 'saved-sid', synoToken: 'saved-token' }), isKind(K.Unsupported));
  const { connector, transport } = await connected();
  const saved = { sid: 'saved-sid', synoToken: 'saved-token' };
  connector.restoreSession(saved);
  saved.sid = 'mutated';
  connector.sessionSnapshot().sid = 'also-mutated';
  assert.deepEqual(connector.sessionSnapshot(), { sid: 'saved-sid', synoToken: 'saved-token' });
  transport.replies.push(ok({ offset: 0, total: 0, shares: [] }), fail(119));
  await connector.list('');
  assert.equal(transport.calls.at(-1).authorization.sid, 'saved-sid');
  await assert.rejects(connector.list(''), isKind(K.SessionExpired));
  assert.equal(connector.sessionSnapshot(), undefined);
});

test('late login response after closing connection cannot create a new session', async () => {
  const { connector, transport } = await connected();
  let finish;
  transport.replies.push(() => new Promise(resolve => { finish = resolve; }));
  const pending = connector.login('reader', 'password', '');
  connector.close();
  finish(ok({ sid: 'late-sid' }));
  await assert.rejects(pending, isKind(K.Cancelled));
  assert.ok(transport.closed);
});

test('parallel login is rejected before sending duplicate authentication requests', async () => {
  const { connector, transport } = await connected();
  let finish;
  transport.replies.push(() => new Promise(resolve => { finish = resolve; }));
  const pending = connector.login('reader', 'password', '');
  await assert.rejects(connector.login('reader', 'password', ''), isKind(K.InvalidInput));
  finish(ok({ sid: 'sid' }));
  await pending;
  assert.equal(transport.calls.length, 2);
});

test('IP-bound session failure invalidates in-flight successful responses', async () => {
  const { connector, transport } = await loggedIn();
  let finish;
  transport.replies.push(() => new Promise(resolve => { finish = resolve; }), fail(150));
  const earlierRead = connector.list('');
  await assert.rejects(connector.list(''), isKind(K.SessionExpired));
  finish(ok({ offset: 0, total: 0, shares: [] }));
  await assert.rejects(earlierRead, isKind(K.Cancelled));
});

test('logout clears local authorization even when server result is not confirmed', async () => {
  const { connector, transport } = await loggedIn();
  transport.replies.push({ status: 503, text: '<html>unavailable</html>' });
  await assert.rejects(connector.logout(), isKind(K.Http));
  assert.ok(transport.closed);
  await assert.rejects(connector.list(''), isKind(K.Cancelled));
});

test('two connectors isolate origin, SID and token', async () => {
  const first = await loggedIn();
  const second = await connected();
  second.transport.replies.push(ok({ sid: 'second-sid' }), ok({ offset: 0, total: 0, shares: [] }));
  await second.connector.login('other', 'password', '');
  await second.connector.list('');
  assert.equal(second.transport.calls.at(-1).authorization.sid, 'second-sid');
  assert.equal(second.transport.calls.at(-1).body.get('SynoToken'), null);
  first.connector.close();
  assert.equal(second.transport.closed, false);
});

test('getinfo parser accepts only one exact identity with boolean type and required size', () => {
  const file = { path: '/Archive/Apps/test/probe.txt', name: 'probe.txt', isdir: false, additional: { size: 0 } };
  assert.deepEqual(protocol.decodeNasFileInfo({ files: [file] }, file.path), {
    path: file.path, name: file.name, isDirectory: false, bytes: 0
  });
  assert.equal(protocol.decodeNasFileInfo({ files: [{ ...file, isdir: true }] }, file.path).isDirectory, true);
  for (const data of [
    {}, { files: [] }, { files: [file, file] }, { files: [{ error: { code: 408 } }] },
    { files: [{ ...file, path: '/Archive/Apps/test/other.txt' }] },
    { files: [{ ...file, isdir: 'false' }] }, { files: [{ ...file, additional: undefined }] },
    { files: [{ ...file, additional: {} }] }, { files: [{ ...file, additional: { size: -1 } }] },
    { files: [{ ...file, additional: { size: '0' } }] }, { files: [{ ...file, error: { code: 408 } }] }
  ]) assert.throws(() => protocol.decodeNasFileInfo(data, file.path), isKind(K.Protocol));
});

test('getFileInfo requests exact JSON path and rejects a business or per-file failure', async () => {
  const { connector, transport } = await loggedIn();
  const path = '/共享/中文 " , &+\\probe.txt';
  transport.replies.push(ok({ files: [{ path, name: 'probe.txt', isdir: false, additional: { size: 42 } }] }),
    fail(105), ok({ files: [{ path, error: { code: 408 } }] }));
  assert.equal((await connector.getFileInfo(path)).bytes, 42);
  const call = transport.calls.at(-1);
  assert.equal(call.body.get('method'), 'getinfo');
  assert.equal(call.body.get('version'), '2');
  assert.deepEqual(JSON.parse(call.body.get('path')), [path]);
  assert.deepEqual(JSON.parse(call.body.get('additional')), ['size']);
  assert.deepEqual(call.authorization, { sid: 'test-sid', synoToken: 'test-token' });
  await assert.rejects(connector.getFileInfo(path), isKind(K.Permission));
  await assert.rejects(connector.getFileInfo(path), isKind(K.Protocol));
});

test('transfer plans preserve multipart and JSON special characters without overwrite or parent creation', async () => {
  const { connector, transport } = await loggedIn();
  const directory = '/共享/中文 " , &+\\目录';
  const file = directory + '/probe.txt';
  const upload = connector.transferUploadPlan(directory);
  const download = connector.transferDownloadPlan(file);
  const uploadFields = new Map(upload.fields.map(field => [field.name, field.content]));
  const downloadFields = new Map(download.fields.map(field => [field.name, field.content]));
  assert.equal(uploadFields.get('api'), 'SYNO.FileStation.Upload');
  assert.equal(uploadFields.get('version'), '2');
  assert.equal(uploadFields.get('method'), 'upload');
  assert.equal(uploadFields.get('path'), directory);
  assert.equal(uploadFields.get('create_parents'), 'false');
  assert.equal(uploadFields.has('overwrite'), false);
  assert.equal(uploadFields.has('file'), false);
  assert.equal(downloadFields.get('api'), 'SYNO.FileStation.Download');
  assert.equal(downloadFields.get('version'), '2');
  assert.equal(downloadFields.get('method'), 'download');
  assert.deepEqual(JSON.parse(downloadFields.get('path')), [file]);
  assert.equal(JSON.parse(downloadFields.get('mode')), 'download');
  for (const plan of [upload, download]) {
    assert.equal(plan.address, 'https://nas.example.test:5001/webapi/entry.cgi');
    assert.equal(plan.address.includes('?'), false);
    assert.deepEqual(plan.session, { sid: 'test-sid', synoToken: 'test-token' });
    assert.ok(plan.fields.every(field => typeof field.content === 'string'));
    assert.ok(plan.fields.every(field => !['_sid', 'SynoToken', 'passwd'].includes(field.name)));
  }
  upload.session.sid = 'mutated';
  assert.equal(connector.sessionSnapshot().sid, 'test-sid');
  assert.equal(transport.calls.length, 2, 'planning must not issue a network request');
});

test('transfer plans use plain scalar strings when the advertised format is not JSON', async () => {
  const capabilities = structuredClone(fixture.data);
  delete capabilities['SYNO.FileStation.Upload'].requestFormat;
  delete capabilities['SYNO.FileStation.Download'].requestFormat;
  const transport = new FakeTransport();
  transport.replies.push(ok(capabilities));
  const connector = new NasConnector(transport);
  await connector.discover('https://nas.example.test:5001');
  connector.restoreSession({ sid: 'saved-sid', synoToken: '' });
  const fields = plan => new Map(plan.fields.map(field => [field.name, field.content]));
  assert.equal(fields(connector.transferUploadPlan('/Archive/Apps/test')).get('path'), '/Archive/Apps/test');
  assert.equal(fields(connector.transferDownloadPlan('/Archive/Apps/test/a.txt')).get('mode'), 'download');
});

test('file validation and transfer plans require a live session and reject unsafe paths', async () => {
  const { connector, transport } = await connected();
  await assert.rejects(connector.getFileInfo('/Archive/Apps/test/a.txt'), isKind(K.SessionExpired));
  assert.throws(() => connector.transferUploadPlan('/Archive/Apps/test'), isKind(K.SessionExpired));
  assert.throws(() => connector.transferDownloadPlan('/Archive/Apps/test/a.txt'), isKind(K.SessionExpired));
  connector.restoreSession({ sid: 'saved-sid', synoToken: '' });
  for (const path of ['/', '/Archive/../private', '/Archive/Apps/test\u0000']) {
    await assert.rejects(connector.getFileInfo(path), isKind(K.Protocol));
    assert.throws(() => connector.transferUploadPlan(path), isKind(K.Protocol));
    assert.throws(() => connector.transferDownloadPlan(path), isKind(K.Protocol));
  }
  transport.replies.push(fail(119));
  await assert.rejects(connector.getFileInfo('/Archive/Apps/test/a.txt'), isKind(K.SessionExpired));
  assert.throws(() => connector.transferUploadPlan('/Archive/Apps/test'), isKind(K.SessionExpired));
  assert.throws(() => connector.transferDownloadPlan('/Archive/Apps/test/a.txt'), isKind(K.SessionExpired));
});

test('late getinfo responses cannot validate a file after the connection closes', async () => {
  const { connector, transport } = await loggedIn();
  const path = '/Archive/Apps/test/a.txt';
  let finish;
  transport.replies.push(() => new Promise(resolve => { finish = resolve; }));
  const pending = connector.getFileInfo(path);
  connector.close();
  finish(ok({ files: [{ path, name: 'a.txt', isdir: false, additional: { size: 10 } }] }));
  await assert.rejects(pending, isKind(K.Cancelled));
  assert.throws(() => connector.transferUploadPlan('/Archive/Apps/test'), isKind(K.Cancelled));
});
