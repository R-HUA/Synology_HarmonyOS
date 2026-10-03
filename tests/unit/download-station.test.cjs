const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdkRoot = process.env.HARMONY_SDK_ROOT || path.join(process.env.DEVECO_CLI_CLT_PATH || 'C:/Program Files/command-line-tools', 'sdk/default');
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const sourceRoot = path.join(__dirname, '../../entry/src/main/ets/features/downloadStation');
const plain = value => JSON.parse(JSON.stringify(value));
const isKind = kind => error => error instanceof dsm.NasFailure && error.kind === kind;
const invalidInput = isKind(dsm.NasErrorKind.InvalidInput);
const invalidResponse = isKind(dsm.NasErrorKind.Protocol);
const HASH = '0123456789abcdef'.repeat(2) + '01234567';
const MAGNET = `magnet:?xt=urn:btih:${HASH}`;

function loadSource(filename, mocks) {
  const output = ts.transpileModule(fs.readFileSync(path.join(sourceRoot, filename), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true,
  });
  assert.equal((output.diagnostics || []).filter(diagnostic => diagnostic.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  const noLog = () => { throw new Error('download parameters must not be logged'); };
  vm.runInNewContext(output.outputText, {
    module, exports: module.exports, Error, console: { log: noLog, warn: noLog, error: noLog, info: noLog, debug: noLog },
    require: id => { assert.ok(Object.hasOwn(mocks, id), `unexpected dependency ${id}`); return mocks[id]; },
  }, { filename });
  return module.exports;
}

const protocol = loadSource('DownloadStationProtocol.ts', { '../../core/domain/DsmProtocol': dsm });
const { DownloadStationRepository } = loadSource('DownloadStationRepository.ts', { './DownloadStationProtocol': protocol });
const syntheticTask = (overrides = {}) => ({
  id: 'dbid_001', type: 'bt', title: '合成 NAS 下载任务', size: '9427312332', status: 'downloading', status_extra: null,
  username: 'SYNTHETIC_PRIVATE_OWNER',
  additional: {
    detail: { destination: 'Download/测试目录', create_time: '1341210005', uri: 'https://example.test/file?token=SYNTHETIC_PRIVATE_TOKEN' },
    transfer: { size_downloaded: '123456', size_uploaded: '234567', speed_download: 345678, speed_upload: 456789 },
    file: [{ filename: '子目录/测试.bin', size: '100', size_downloaded: '30', priority: 'normal' }],
    tracker: [{ url: 'https://example.test/tracker?passkey=SYNTHETIC_TRACKER_SECRET' }],
    peer: [{ address: 'SYNTHETIC_PRIVATE_PEER' }],
  },
  ...overrides,
});

function repositoryWith(response) {
  const calls = [];
  const repository = new DownloadStationRepository(async (method, fields) => {
    calls.push({ method, fields: plain(fields) });
    return typeof response === 'function' ? response(method, fields) : response;
  });
  return { repository, calls };
}

test('download-station pure TS sources pass strict SDK type checking without emitted files', () => {
  const program = ts.createProgram(['DownloadStationProtocol.ts', 'DownloadStationRepository.ts'].map(filename => path.join(sourceRoot, filename)), {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS, strict: true, skipLibCheck: true, noEmit: true,
  });
  const diagnostics = ts.getPreEmitDiagnostics(program);
  assert.deepEqual(diagnostics.map(diagnostic => ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n')), []);
});

test('synthetic list requests one bounded page and only detail/transfer, retaining real byte and timestamp units', async () => {
  const fixture = repositoryWith({ total: 1, offset: 0, tasks: [syntheticTask()] });
  const page = plain(await fixture.repository.list());
  assert.deepEqual(fixture.calls, [{ method: 'list', fields: [
    { name: 'offset', content: '0' }, { name: 'limit', content: '50' }, { name: 'additional', content: 'detail,transfer' },
  ] }]);
  assert.equal(page.total, 1);
  assert.equal(page.offset, 0);
  assert.deepEqual(page.tasks[0], {
    id: 'dbid_001', title: '合成 NAS 下载任务', rawStatus: 'downloading', status: 'downloading', type: 'bt',
    totalBytes: 9427312332, downloadedBytes: 123456, uploadedBytes: 234567, downloadBytesPerSecond: 345678,
    uploadBytesPerSecond: 456789, destination: 'Download/测试目录', createdAt: 1341210005000,
  });
  assert.ok(!JSON.stringify(page).includes('SYNTHETIC_'));
  assert.equal(page.tasks[0].files, undefined);
  assert.equal(page.tasks[0].percentage, undefined);
});

test('synthetic pagination keeps the server offset and permits an empty page after concurrent task removal', async () => {
  const fixture = repositoryWith({ total: 1, offset: 5, tasks: [] });
  assert.deepEqual(plain(await fixture.repository.list(5, 2)), { total: 1, offset: 5, tasks: [] });
  assert.equal(fixture.calls[0].fields[0].content, '5');
  assert.equal(fixture.calls[0].fields[1].content, '2');
});

test('synthetic getinfo requests files on demand without requesting trackers or peers', async () => {
  const fixture = repositoryWith({ tasks: [syntheticTask()] });
  const task = plain(await fixture.repository.getInfo('dbid_001'));
  assert.deepEqual(fixture.calls, [{ method: 'getinfo', fields: [
    { name: 'id', content: 'dbid_001' }, { name: 'additional', content: 'detail,transfer,file' },
  ] }]);
  assert.deepEqual(task.files, [{ name: '子目录/测试.bin', totalBytes: 100, downloadedBytes: 30, priority: 'normal' }]);
  assert.ok(!JSON.stringify(task).includes('SYNTHETIC_'));
});

test('synthetic metadata absence, zero bytes and eMule null creation time remain truthful without percentages', () => {
  const minimal = plain(protocol.decodeDownloadTask({ id: '1', title: '未知大小', status: 'waiting' }));
  assert.deepEqual(minimal, { id: '1', title: '未知大小', rawStatus: 'waiting', status: 'waiting' });
  const emule = plain(protocol.decodeDownloadTask(syntheticTask({ size: 0, additional: {
    detail: { create_time: null }, transfer: { size_downloaded: '0', speed_download: 0, speed_upload: 0 },
  } })));
  assert.equal(emule.totalBytes, 0);
  assert.equal(emule.downloadedBytes, 0);
  assert.equal(emule.downloadBytesPerSecond, 0);
  assert.equal(emule.createdAt, undefined);
  assert.equal(emule.percentage, undefined);
});

for (const [rawStatus, status] of Object.entries({ waiting: 'waiting', filehosting_waiting: 'waiting', downloading: 'downloading',
  paused: 'paused', finishing: 'processing', hash_checking: 'processing', extracting: 'processing', finished: 'finished',
  seeding: 'seeding', error: 'error', future_state: 'unknown', DOWNLOADING: 'unknown' })) {
  test(`synthetic status ${rawStatus} retains the original and safely maps to ${status}`, () => {
    const task = protocol.decodeDownloadTask(syntheticTask({ status: rawStatus, size: '100', additional: {
      transfer: { size_downloaded: '100', speed_upload: 99 },
    } }));
    assert.equal(task.rawStatus, rawStatus);
    assert.equal(task.status, status);
    assert.equal(task.percentage, undefined);
  });
}

test('synthetic decimal string IDs beyond numeric precision survive exactly; numeric IDs are never repaired', () => {
  const id = '18446744073709551615';
  assert.equal(protocol.decodeDownloadTask(syntheticTask({ id })).id, id);
  for (const invalid of [Number.MAX_SAFE_INTEGER + 1, 1, null, undefined, '', 'dbid_1,dbid_2', 'bad\nID', {}, true]) {
    assert.throws(() => protocol.decodeDownloadTask(syntheticTask({ id: invalid })), invalidResponse);
  }
});

test('synthetic malformed task rows and nested metadata are rejected rather than coerced or defaulted', () => {
  const rows = [null, [], true, 1, 'task', {}, syntheticTask({ title: 10 }), syntheticTask({ title: 'bad\nname' }),
    syntheticTask({ title: 'x'.repeat(4097) }), syntheticTask({ status: 'state with spaces' }),
    syntheticTask({ additional: null }), syntheticTask({ additional: [] }),
    syntheticTask({ additional: { detail: [] } }), syntheticTask({ additional: { transfer: false } }),
    syntheticTask({ additional: { detail: { destination: '/volume1/Download' } } }),
    syntheticTask({ status_extra: { error_detail: {} } })];
  for (const row of rows) { assert.throws(() => protocol.decodeDownloadTask(row), invalidResponse); }
});

test('synthetic sizes, byte rates and file sizes reject inexact numbers and noncanonical quantities', () => {
  const invalidQuantities = [-1, 1.2, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, '9007199254740993',
    '-1', '1.5', '1e3', ' 4 ', '004', '', null, true, {}, []];
  for (const quantity of invalidQuantities) {
    assert.throws(() => protocol.decodeDownloadTask(syntheticTask({ size: quantity })), invalidResponse);
    for (const field of ['size_downloaded', 'size_uploaded', 'speed_download', 'speed_upload']) {
      assert.throws(() => protocol.decodeDownloadTask(syntheticTask({ additional: { transfer: { [field]: quantity } } })), invalidResponse);
    }
    assert.throws(() => protocol.decodeDownloadTask(syntheticTask({ additional: {
      file: [{ filename: 'test.bin', size: quantity }],
    } }), true), invalidResponse);
  }
  assert.equal(protocol.decodeDownloadTask(syntheticTask({ size: Number.MAX_SAFE_INTEGER.toString() })).totalBytes, Number.MAX_SAFE_INTEGER);
});

test('synthetic timestamps reject invalid units and Date overflow instead of inventing a creation date', () => {
  for (const create_time of [-1, 1.2, true, 'today', '1341210005.1', '8640000000001', Number.MAX_SAFE_INTEGER]) {
    assert.throws(() => protocol.decodeDownloadTask(syntheticTask({ additional: { detail: { create_time } } })), invalidResponse);
  }
  assert.equal(protocol.decodeDownloadTask(syntheticTask({ additional: { detail: { create_time: '0' } } })).createdAt, 0);
});

test('synthetic malformed pagination and duplicate remote identities never produce a successful page', () => {
  const task = syntheticTask();
  for (const data of [null, [], {}, { total: '1', offset: 0, tasks: [task] }, { total: 1, offset: 1, tasks: [task] },
    { total: 0, offset: 0, tasks: [task] }, { total: 1, offset: 0, tasks: {} },
    { total: 2, offset: 0, tasks: [task, task] }, { total: 60, offset: 0, tasks: Array(51).fill(task) }]) {
    assert.throws(() => protocol.decodeDownloadTaskPage(data, 0, 50), invalidResponse);
  }
});

test('synthetic getinfo distinguishes a disappeared task from malformed or mismatched detail data', () => {
  assert.throws(() => protocol.decodeDownloadTaskInfo({ tasks: [] }, 'dbid_001'), error =>
    error instanceof dsm.NasFailure && error.code === 404);
  for (const data of [{}, { tasks: null }, { tasks: [syntheticTask({ id: 'other' })] },
    { tasks: [syntheticTask(), syntheticTask()] }, { tasks: [syntheticTask({ additional: { file: {} } })] },
    { tasks: [syntheticTask({ additional: { file: [null] } })] }]) {
    assert.throws(() => protocol.decodeDownloadTaskInfo(data, 'dbid_001'), invalidResponse);
  }
});

test('synthetic task errors are mapped to user text and unknown details cannot leak server strings', () => {
  const permission = protocol.decodeDownloadTask(syntheticTask({ status: 'error', status_extra: { error_detail: 'destination_denied' } }));
  assert.match(permission.errorMessage, /权限/);
  const unknown = protocol.decodeDownloadTask(syntheticTask({ status: 'error', status_extra: { error_detail: 'SYNTHETIC_SECRET' } }));
  assert.ok(!unknown.errorMessage.includes('SYNTHETIC_SECRET'));
  assert.equal(protocol.downloadStationFailure(402).kind, dsm.NasErrorKind.Permission);
  assert.equal(protocol.downloadStationFailure(106).kind, dsm.NasErrorKind.SessionExpired);
  assert.equal(protocol.downloadStationFailure(104).kind, dsm.NasErrorKind.Unsupported);
});

test('synthetic URI admission accepts only public HTTP/HTTPS/FTP and valid BT magnets, retaining the exact input', () => {
  for (const uri of ['http://example.test/file', 'HTTPS://example.test:8443/a%20b.bin?download=1',
    'ftp://example.test:21/file', 'https://[2001:db8::1]:8443/file', 'https://example.test/%E4%B8%AD%E6%96%87',
    MAGNET, MAGNET + '&dn=测试%20文件&tr=udp%3A%2F%2Ftracker.example.test%3A6969',
    'magnet:?xt=urn:btih:' + 'A'.repeat(32)]) {
    assert.equal(protocol.validateDownloadUri(uri), uri);
  }
});

test('synthetic unsupported sources, local paths, multiple URLs and malformed links are rejected', () => {
  for (const uri of [null, undefined, 42, {}, '', 'https://', 'example.test/file', 'file:///sdcard/test.torrent',
    'C:\\Downloads\\test.torrent', '/storage/emulated/0/Download/test.torrent', 'Download/test.torrent',
    'ed2k://download/file', 'javascript:alert(1)', 'data:text/plain,test', 'smb://nas/share/file',
    ' https://example.test/file', 'https://example.test/a b', 'https://example.test/a\\b',
    'https://example.test:0/file', 'https://example.test:65536/file', 'https://bad..host/file',
    'https://[:::]/file', 'https://[a]/file', 'https://[12345::1]/file',
    'https://[1:2:3:4:5:6:7::8]/file', 'https://[1::2::3]/file',
    'https://example.test/one,https://example.test/two', 'https://example.test/%zz',
    'https://example.test/%C0%AF', 'https://example.test/' + 'a'.repeat(8192),
    'magnet:?dn=missing-hash', 'magnet:?xt=urn:btih:invalid', 'magnet:?xt=urn:btih:' + '1'.repeat(39)]) {
    assert.throws(() => protocol.validateDownloadUri(uri), invalidInput);
  }
});

test('synthetic raw and encoded control characters never cross the request boundary', () => {
  for (const control of ['\n', '\r', '\0', '\t', '\x7f', '\x85', '\u2028', '%0A', '%0D', '%00', '%7F', '%C2%85', '%250A']) {
    assert.throws(() => protocol.validateDownloadUri('https://example.test/file' + control), invalidInput);
  }
});

test('synthetic embedded credentials, bearer tokens and signed URL parameters are blocked even under nested encoding', () => {
  for (const uri of ['http://user:secret@example.test/file', 'ftp://user@example.test/file',
    'https://user%3Asecret%40example.test/file', 'https://example.test/file?token=secret',
    'https://example.test/file?access_token=secret', 'https://example.test/file?SynoToken=secret',
    'https://example.test/webapi/entry.cgi?_sid=secret', 'https://example.test/file?api-key=secret',
    'https://example.test/file?access_key=secret', 'https://example.test/file?PHPSESSID=secret',
    MAGNET + '&tr=https%3A%2F%2Ftracker.example.test%3Fpasskey%3Dsecret',
    'https://example.test/file?%74%6F%6B%65%6E=secret', 'https://example.test/file?%2574oken=secret',
    'https://example.test/file?X-Amz-Credential=secret', 'https://example.test/file?sig=secret',
    'https://example.test/file#auth=secret', 'https://example.test/token/secret/file',
    'https://example.test/file?url=https%3A%2F%2Fuser%3Asecret%40other.test%2Ffile',
    MAGNET + '&tr=https%3A%2F%2Ftracker.example.test%3Ftoken%3Dsecret']) {
    assert.throws(() => protocol.validateDownloadUri(uri), error => invalidInput(error) && !error.message.includes('secret'));
  }
});

test('synthetic magnet sources cannot embed local-file or executable schemes', () => {
  for (const suffix of ['&xs=file%3A%2F%2F%2Fprivate.torrent', '&as=smb%3A%2F%2Fhost%2Fshare',
    '&xs=javascript%3Aalert(1)', '&xs=data%3Atext%2Fplain%3Btest']) {
    assert.throws(() => protocol.validateDownloadUri(MAGNET + suffix), invalidInput);
  }
});

test('synthetic sparse request/response arrays cannot fabricate missing IDs or metadata entries', () => {
  assert.throws(() => protocol.validateDownloadTaskIds(Array(1)), invalidInput);
  assert.throws(() => protocol.decodeDownloadTaskPage({ total: 1, offset: 0, tasks: Array(1) }, 0, 50), invalidResponse);
  assert.throws(() => protocol.decodeDownloadTask(syntheticTask({ additional: { file: Array(1) } }), true), invalidResponse);
  assert.throws(() => protocol.decodeDownloadActionResults(Array(1), ['dbid_001']), invalidResponse);
});

test('synthetic destinations are NAS-relative shared paths and are never joined to an origin or phone path', () => {
  for (const destination of ['Download', 'Download/子目录', '共享目录/合法 空格']) {
    assert.equal(protocol.validateDownloadDestination(destination), destination);
  }
  for (const destination of [undefined, null, 42, {}, '', '/Download', '/volume1/Download', '/storage/emulated/0/Download',
    'C:\\Download', 'file:///data/storage', 'https://nas.example.test/share', 'Download\\file', 'Download//file',
    'Download/', 'Download/../other', 'Download/./file', '../Download', 'Download/%2e%2e', ' Download',
    'Download/ file', 'Download\nfile', 'Download\0file', 'a'.repeat(4097)]) {
    assert.throws(() => protocol.validateDownloadDestination(destination), invalidInput);
  }
});

test('synthetic create passes an exact single URI and relative NAS path, accepting no-ID success without a fake ID', async () => {
  const fixture = repositoryWith({});
  const result = plain(await fixture.repository.create('https://example.test/file.torrent', 'Download/测试目录'));
  assert.deepEqual(result, { state: 'accepted', awaitingConfirmation: true });
  assert.equal(Object.hasOwn(result, 'taskId'), false);
  assert.deepEqual(fixture.calls, [{ method: 'create', fields: [
    { name: 'uri', content: 'https://example.test/file.torrent' }, { name: 'destination', content: 'Download/测试目录' },
  ] }]);
  assert.deepEqual(Object.keys(fixture.repository), ['call']);
});

test('synthetic create can retain a genuine server string ID without declaring completed or matching a task locally', () => {
  assert.deepEqual(plain(protocol.decodeDownloadCreateResult({ id: '18446744073709551615' })), {
    state: 'accepted', awaitingConfirmation: true, taskId: '18446744073709551615',
  });
  for (const data of [null, [], true, '', { id: 1 }, { id: Number.MAX_SAFE_INTEGER + 1 }, { id: '' },
    { success: false }, { success: true }, { error: { code: '402' } }]) {
    assert.throws(() => protocol.decodeDownloadCreateResult(data), invalidResponse);
  }
  assert.throws(() => protocol.decodeDownloadCreateResult({ error: { code: 402 } }), isKind(dsm.NasErrorKind.Permission));
});

test('synthetic input validation occurs before any callback, including all read and write methods', async () => {
  const fixture = repositoryWith({});
  for (const [offset, limit] of [[-1, 50], [1.5, 50], [NaN, 50], [0, -1], [0, 0], [0, 201], [0, 2.5], ['0', 50], [Number.MAX_SAFE_INTEGER + 1, 1]]) {
    await assert.rejects(fixture.repository.list(offset, limit), invalidInput);
  }
  for (const id of [undefined, null, 1, Number.MAX_SAFE_INTEGER + 1, '', 'dbid_1,dbid_2', 'dbid_1\n', 'a'.repeat(257)]) {
    await assert.rejects(fixture.repository.getInfo(id), invalidInput);
  }
  for (const method of ['pause', 'resume', 'remove']) {
    for (const ids of [[], ['a', 'a'], [42], ['a,b'], null, 'a', Array.from({ length: 201 }, (unused, index) => `dbid_${index}`)]) {
      await assert.rejects(fixture.repository[method](ids), invalidInput);
    }
  }
  await assert.rejects(fixture.repository.create('file:///phone.torrent', 'Download'), invalidInput);
  await assert.rejects(fixture.repository.create('https://example.test/file', '/volume1/Download'), invalidInput);
  await assert.rejects(fixture.repository.create('https://example.test/file?token=secret', 'Download'), invalidInput);
  assert.deepEqual(fixture.calls, []);
});

for (const [method, rpcMethod] of [['pause', 'pause'], ['resume', 'resume'], ['remove', 'delete']]) {
  test(`synthetic ${method} decodes every task error despite envelope success and preserves caller ID ordering`, async () => {
    const fixture = repositoryWith([{ id: 'dbid_002', error: 405 }, { id: 'dbid_001', error: 0 }]);
    const ids = ['dbid_001', 'dbid_002'];
    const results = plain(await fixture.repository[method](ids));
    assert.deepEqual(ids, ['dbid_001', 'dbid_002']);
    assert.deepEqual(results[0], { id: 'dbid_001', success: true, errorCode: 0, message: '' });
    assert.equal(results[1].id, 'dbid_002');
    assert.equal(results[1].success, false);
    assert.equal(results[1].errorCode, 405);
    assert.match(results[1].message, /当前任务状态/);
    assert.equal(fixture.calls.length, 1);
    const fields = [{ name: 'id', content: 'dbid_001,dbid_002' }];
    if (method === 'remove') { fields.push({ name: 'force_complete', content: 'false' }); }
    assert.deepEqual(fixture.calls[0], { method: rpcMethod, fields });
  });
}

test('synthetic removal has no source-file API, deletion flag or force-complete behavior', async () => {
  const fixture = repositoryWith([{ id: 'dbid_001', error: 0 }]);
  await fixture.repository.remove(['dbid_001']);
  assert.deepEqual(fixture.calls, [{ method: 'delete', fields: [
    { name: 'id', content: 'dbid_001' }, { name: 'force_complete', content: 'false' },
  ] }]);
});

test('synthetic action results require exact, unique identities and integer error codes, never treating an empty reply as success', () => {
  const valid = { id: 'dbid_001', error: 0 };
  for (const data of [null, {}, { tasks: [valid] }, { success: true, data: [valid] }, [], [null],
    [{ id: 'different', error: 0 }], [{ id: 1, error: 0 }], [{ id: 'dbid_001' }],
    [{ ...valid, error: '0' }], [{ ...valid, error: -1 }], [{ ...valid, error: 1.2 }],
    [{ ...valid, error: NaN }], [{ ...valid, error: Number.MAX_SAFE_INTEGER + 1 }], [valid, valid]]) {
    assert.throws(() => protocol.decodeDownloadActionResults(data, ['dbid_001']), invalidResponse);
  }
  assert.throws(() => protocol.decodeDownloadActionResults([valid, valid], ['dbid_001', 'dbid_002']), invalidResponse);
  assert.throws(() => protocol.decodeDownloadActionResults([valid], ['dbid_001', 'dbid_002']), invalidResponse);
});

test('synthetic mutation snapshots IDs before awaiting rather than validating the caller mutable array twice', async () => {
  let complete;
  const fixture = repositoryWith(() => new Promise(resolve => { complete = resolve; }));
  const ids = ['dbid_001'];
  const pending = fixture.repository.pause(ids);
  ids[0] = 'other';
  complete([{ id: 'dbid_001', error: 0 }]);
  assert.equal((await pending)[0].id, 'dbid_001');
  assert.equal(fixture.calls[0].fields[0].content, 'dbid_001');
});

for (const method of ['create', 'pause', 'resume', 'remove']) {
  test(`synthetic ${method} never automatically retries a failed or uncertain write`, async () => {
    const failure = new dsm.NasFailure(dsm.NasErrorKind.Network, '合成网络错误');
    const fixture = repositoryWith(() => { throw failure; });
    const operation = method === 'create' ? fixture.repository.create('https://example.test/file', 'Download') : fixture.repository[method](['dbid_001']);
    await assert.rejects(operation, error => error === failure);
    assert.equal(fixture.calls.length, 1);
  });
  test(`synthetic ${method} malformed response also cannot trigger an automatic replay`, async () => {
    const fixture = repositoryWith(null);
    const operation = method === 'create' ? fixture.repository.create('https://example.test/file', 'Download') : fixture.repository[method](['dbid_001']);
    await assert.rejects(operation, invalidResponse);
    assert.equal(fixture.calls.length, 1);
  });
}
