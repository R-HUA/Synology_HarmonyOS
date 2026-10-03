const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdkRoot = process.env.HARMONY_SDK_ROOT || path.join(process.env.DEVECO_CLI_CLT_PATH || 'C:/Program Files/command-line-tools', 'sdk/default');
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

function load(relative, mocks = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets', relative), 'utf8');
  const output = ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS,
  }, reportDiagnostics: true });
  assert.equal((output.diagnostics || []).filter(diagnostic => diagnostic.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, Error,
    require: name => { assert.ok(Object.hasOwn(mocks, name), 'unexpected dependency ' + name); return mocks[name]; },
  }, { filename: relative });
  return module.exports;
}

const dsm = load('core/domain/DsmProtocol.ts');
const protocol = load('features/fileSharing/FileSharingProtocol.ts', { '../../core/domain/DsmProtocol': dsm });
const { FileSharingRepository } = load('features/fileSharing/FileSharingRepository.ts', { './FileSharingProtocol': protocol });
const { NasFailure, NasErrorKind: Kind } = dsm;
const plain = value => JSON.parse(JSON.stringify(value));
const isKind = kind => error => error instanceof NasFailure && error.kind === kind;
const link = (id = 'opaque-A', overrides = {}) => ({ id, name: '中文文件.jpg', path: '/共享/中文文件.jpg',
  url: 'http://nas.lan:5000/fbsharing/' + id, isFolder: false, has_password: false,
  date_available: '0', date_expired: '0', status: 'valid', link_owner: 'reader', ...overrides });
const created = (filePath, id = 'opaque-A', error = 0) => error === 0
  ? { path: filePath, id, url: 'https://outside.example.test/fbsharing/' + id, error,
    qrcode: 'https://untrusted.example.test/never-fetch', password: 'never-return-this' }
  : { path: filePath, error };

function repository(replies = []) {
  const calls = [];
  const service = new FileSharingRepository(async (method, fields) => {
    calls.push({ method, fields: plain(fields), params: Object.fromEntries(fields.map(field => [field.name, field.content])) });
    assert.ok(replies.length, 'unexpected request');
    const reply = replies.shift();
    if (reply instanceof Error) { throw reply; }
    return typeof reply === 'function' ? reply() : reply;
  });
  return { service, calls };
}

test('Sharing constants match the officially verified version 3 and 16-character password contract', () => {
  assert.equal(protocol.FILE_SHARING_API, 'SYNO.FileStation.Sharing');
  assert.equal(protocol.FILE_SHARING_VERSION, 3);
  assert.equal(protocol.SHARE_PASSWORD_MAX_LENGTH, 16);
});

test('list uses one bounded default page and preserves unknown status without secrets', async () => {
  const input = link('opaque-A', { status: 'new-server-status', password: 'never-store', _sid: 'never-store',
    date_available: '2026-12-31', date_expired: '2027-01-01' });
  const { service, calls } = repository([{ success: true, data: { links: [input], offset: 0, total: 80 } }]);
  const page = await service.list();
  assert.deepEqual(calls.map(call => [call.method, call.params]), [['list', { offset: '0', limit: '50' }]]);
  assert.deepEqual(plain(page), { links: [{ id: 'opaque-A', name: input.name, path: input.path, url: input.url,
    isFolder: false, hasPassword: false, availableDate: '2026-12-31', expiredDate: '2027-01-01',
    status: 'new-server-status', owner: 'reader' }], offset: 0, total: 80 });
  assert.equal(JSON.stringify(page).includes('never-store'), false);
});

test('list accepts explicit offset and official zero-limit semantics without fetching more pages', async () => {
  const { service, calls } = repository([{ links: [link('opaque-A')], offset: 10, total: 11 },
    { links: [], offset: 20, total: 0 }]);
  await service.list(10, 0);
  await service.list(20, 1);
  assert.deepEqual(calls.map(call => call.params), [{ offset: '10', limit: '0' }, { offset: '20', limit: '1' }]);
});

test('getInfo uses getinfo and quoted opaque IDs, accepting documented boolean and string folder flags', async () => {
  const id = '09,中文"X';
  const input = link(id, { url: 'https://external.example.test/fbsharing/item', isFolder: 'true' });
  const { service, calls } = repository([input, link('second', { isFolder: 'false' })]);
  assert.equal((await service.getInfo(id)).isFolder, true);
  assert.equal((await service.getInfo('second')).isFolder, false);
  assert.equal(calls[0].method, 'getinfo');
  assert.equal(JSON.parse(calls[0].params.id), id);
});

test('create serializes Chinese, commas, quotes and backslashes as a JSON array and keeps per-path failures', async () => {
  const paths = ['/共享/中文,"\\名字 &+.jpg', '/共享/子目录'];
  const { service, calls } = repository([{ links: [created(paths[1], '', 2001), created(paths[0])] }]);
  const results = await service.create(paths, { password: { mode: 'set', value: '中文,"口令' },
    availableDate: '2026-10-03', expiredDate: '2026-12-31' });
  assert.deepEqual(JSON.parse(calls[0].params.path), paths);
  const encoded = new URLSearchParams(dsm.encodeNasForm(calls[0].fields));
  assert.deepEqual(JSON.parse(encoded.get('path')), paths);
  assert.equal(JSON.parse(encoded.get('password')), '中文,"口令');
  assert.equal(JSON.parse(calls[0].params.password), '中文,"口令');
  assert.equal(JSON.parse(calls[0].params.date_available), '2026-10-03');
  assert.equal(JSON.parse(calls[0].params.date_expired), '2026-12-31');
  assert.equal(results[0].path, paths[0]);
  assert.equal(results[0].id, 'opaque-A');
  assert.equal(results[0].failure, undefined);
  assert.equal(results[1].path, paths[1]);
  assert.equal(results[1].failure.code, 2001);
  assert.equal(results[1].id, undefined);
  assert.equal(JSON.stringify(results).includes('qrcode'), false);
  assert.equal(JSON.stringify(results).includes('never-return-this'), false);
  assert.ok(results.every(result => !Object.hasOwn(result, 'password') && !Object.hasOwn(result, 'qrcode')));
  assert.deepEqual(Object.keys(service), ['call']);
});

test('edit keeps, sets and explicitly removes passwords, using JSON-array IDs and no implicit clearing', async () => {
  const id = '0001,"opaque';
  const { service, calls } = repository([{}, { success: true }, { success: true, data: {} }]);
  await service.edit(id, { password: { mode: 'retain' }, expiredDate: '2028-02-29' });
  await service.edit(id, { password: { mode: 'set', value: '1234567890123456' } });
  await service.edit(id, { password: { mode: 'remove' }, availableDate: '0', expiredDate: '0' });
  assert.equal(Object.hasOwn(calls[0].params, 'password'), false);
  assert.equal(JSON.parse(calls[1].params.password), '1234567890123456');
  assert.equal(JSON.parse(calls[2].params.password), '');
  assert.equal(calls[2].params.date_available, '0');
  assert.equal(calls[2].params.date_expired, '0');
  assert.equal(Object.hasOwn(calls[1].params, 'date_available'), false);
  for (const call of calls) {
    assert.equal(call.method, 'edit');
    assert.deepEqual(JSON.parse(call.params.id), [id]);
  }
});

test('password length counts Unicode characters and accepts exactly sixteen', async () => {
  const paths = ['/共享/文件'];
  const { service, calls } = repository([{ links: [created(paths[0])] }]);
  await service.create(paths, { password: { mode: 'set', value: '🔐'.repeat(16) } });
  assert.equal(JSON.parse(calls[0].params.password), '🔐'.repeat(16));
});

test('dates remain literal NAS calendar dates regardless of phone timezone or current date', async () => {
  const paths = ['/共享/文件'];
  const { service, calls } = repository([{ links: [created(paths[0])] }, { links: [created(paths[0])] }]);
  const previous = process.env.TZ;
  try {
    process.env.TZ = 'Pacific/Kiritimati';
    await service.create(paths, { availableDate: '2000-02-29', expiredDate: '2000-03-01' });
    process.env.TZ = 'America/Adak';
    await service.create(paths, { availableDate: '2000-02-29', expiredDate: '2000-03-01' });
  } finally {
    if (previous === undefined) delete process.env.TZ; else process.env.TZ = previous;
  }
  assert.deepEqual(calls[0].params, calls[1].params);
  assert.equal(calls[0].params.date_available, '"2000-02-29"');
});

test('delete maps an empty success to each requested opaque ID without losing identities', async () => {
  const ids = ['abc', '00009', '中文,"id'];
  const { service, calls } = repository([{ success: true }]);
  assert.deepEqual(plain(await service.remove(ids)), ids.map(id => ({ id })));
  assert.equal(calls[0].method, 'delete');
  assert.deepEqual(JSON.parse(calls[0].params.id), ids);
});

test('delete preserves the official top-level error.errors array and marks only failed IDs', async () => {
  const { service } = repository([{ success: false, error: { code: 2002,
    errors: [{ id: 'missing', code: 2000 }, { id: 'blocked', code: 403 }] } }]);
  const results = await service.remove(['kept', 'missing', 'blocked']);
  assert.equal(results[0].id, 'kept');
  assert.equal(results[0].failure, undefined);
  assert.equal(results[1].failure.code, 2000);
  assert.match(results[1].failure.message, /不存在/);
  assert.equal(results[2].failure.kind, Kind.Permission);
});

test('edit and delete check detailed item errors in decoded responses even under success=true', async () => {
  const { service } = repository([{ success: true, data: { errors: [{ id: 'edit-id', code: 2000 }] } },
    { error: { code: 2002, errors: [{ id: 'delete-id', code: 403 }] } }]);
  assert.equal((await service.edit('edit-id', { password: { mode: 'remove' } })).failure.code, 2000);
  assert.equal((await service.remove(['delete-id']))[0].failure.kind, Kind.Permission);
});

test('all parameter errors are rejected before calling the injected transport', async () => {
  const { service, calls } = repository();
  const requests = [];
  for (const value of [-1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, '1', null]) {
    requests.push(() => service.list(value, 50), () => service.list(0, value));
  }
  for (const id of ['', ' ', null, 123, 'bad\nvalue']) requests.push(() => service.getInfo(id));
  for (const ids of [[], null, [1], [''], ['a', 'a'], new Array(1)]) requests.push(() => service.remove(ids));
  for (const paths of [[], null, [2], new Array(1), ['/'], ['/共享/../文件'], ['/共享//文件'], ['/共享/文件/'],
    ['/共享/\0文件'], ['/共享/文件', '/共享/文件']]) requests.push(() => service.create(paths));
  for (const password of [null, { mode: 'unknown' }, { mode: 'set' }, { mode: 'set', value: '' },
    { mode: 'set', value: 123 }, { mode: 'set', value: 'x'.repeat(17) }, { mode: 'set', value: '🔐'.repeat(17) },
    { mode: 'set', value: 'bad\npassword' }, { mode: 'retain', value: 'secret' }, { mode: 'remove', value: '' }]) {
    requests.push(() => service.create(['/共享/文件'], { password }));
  }
  for (const date of ['2026-02-29', '1900-02-29', '0000-01-01', '2026-04-31', '2026-13-01',
    '2026-01-00', '2026-1-01', '2026-01-01T00:00:00Z', '', 0, null]) {
    requests.push(() => service.create(['/共享/文件'], { availableDate: date }),
      () => service.edit('id', { expiredDate: date }));
  }
  requests.push(() => service.create(['/共享/文件'], { availableDate: '2026-12-31', expiredDate: '2026-01-01' }),
    () => service.create(['/共享/文件'], null), () => service.edit('id', {}),
    () => service.edit('id', { password: { mode: 'retain' } }), () => service.edit(1, { expiredDate: '0' }));
  for (const request of requests) await assert.rejects(request(), isKind(Kind.InvalidInput));
  assert.equal(calls.length, 0);
});

test('returned URLs remain unmodified for safe LAN HTTP, external HTTPS and encoded paths', async () => {
  const urls = ['http://192.168.50.150:5000/fbsharing/item', 'https://EXTERNAL.example.test:443/fbsharing/%E4%B8%AD%E6%96%87?dl=1',
    'http://[::1]:5000/fbsharing/item#preview', 'https://nas.lan/fbsharing/a%20b'];
  const { service, calls } = repository(urls.map(url => link('id', { url })));
  for (const url of urls) assert.equal((await service.getInfo('id')).url, url);
  assert.equal(calls.length, urls.length);
  assert.ok(calls.every(call => call.method === 'getinfo'));
});

test('unsafe returned URLs reject schemes, credentials, authentication parameters and raw or encoded controls', async () => {
  const urls = ['javascript:alert(1)', 'file:///secret', '//outside.example.test/item',
    'https://user:password@outside.example.test/item', 'https://user%40outside.example.test/item',
    'https://nas.lan\\@outside.example.test/item', 'https://nas.lan:65536/item',
    'https://nas.lan/item?SID=secret', 'https://nas.lan/item?%5Fsid=secret',
    'https://nas.lan/item?%255Fsid=secret', 'https://nas.lan/item?download=1;SynoToken=secret',
    'https://nas.lan/item#access_token=secret', 'https://nas.lan/item#/view?password=secret',
    'https://nas.lan/item?authorization=secret', 'https://nas.lan/item\n',
    'https://nas.lan/item%0a', 'https://nas.lan/item%00', 'https://nas.lan/item%C2%85',
    'https://nas.lan/item%5c', 'https://nas.lan/item%zz', 'https://nas.lan/item?token=secret'];
  const { service, calls } = repository(urls.map(url => link('id', { url })));
  for (const url of urls) await assert.rejects(service.getInfo('id'), isKind(Kind.Protocol), url);
  assert.equal(calls.length, urls.length);
});

test('unsafe URLs are checked on create and list as well as getinfo', async () => {
  const filePath = '/共享/文件';
  const { service } = repository([{ links: [{ ...created(filePath), url: 'https://user:pass@nas.lan/item' }] },
    { links: [link('id', { url: 'https://nas.lan/item?_sid=secret' })], offset: 0, total: 1 }]);
  await assert.rejects(service.create([filePath]), isKind(Kind.Protocol));
  await assert.rejects(service.list(), isKind(Kind.Protocol));
});

test('list rejects malformed pagination, duplicate IDs and invalid response fields rather than inventing defaults', async () => {
  const responses = [{}, { links: [], offset: '0', total: 0 }, { links: [], offset: 1, total: 1 },
    { links: [link('id')], offset: 0, total: 0 }, { links: [link('id'), link('id')], offset: 0, total: 2 },
    ...[{ id: 99 }, { has_password: 'false' }, { isFolder: 'unknown' }, { date_expired: '2026-02-29' },
      { path: '/共享/../文件' }, { status: '' }, { link_owner: null }, { error: 2000 }]
      .map(overrides => ({ links: [link('id', overrides)], offset: 0, total: 1 }))];
  const { service } = repository(responses.slice());
  for (const response of responses) await assert.rejects(service.list(), isKind(Kind.Protocol));
});

test('getInfo cannot confirm a different link identity', async () => {
  const { service } = repository([link('other')]);
  await assert.rejects(service.getInfo('requested'), isKind(Kind.Protocol));
});

test('create rejects missing, duplicate, mismatched or ambiguous item outcomes', async () => {
  const filePath = '/共享/文件';
  const responses = [{}, { links: [] }, { links: [created('/共享/other')] },
    { links: [{ path: filePath, id: 'id', url: 'https://nas.lan/item' }] },
    { links: [{ ...created(filePath), error: '0' }] }, { links: [{ ...created(filePath), id: 123 }] },
    { links: [{ ...created(filePath), error: -1 }] }];
  const { service } = repository(responses.slice());
  for (const response of responses) await assert.rejects(service.create([filePath]), isKind(Kind.Protocol));
  const duplicate = repository([{ links: [created(filePath), created(filePath)] },
    { links: [created(filePath, 'same'), created('/共享/other', 'same')] }]);
  await assert.rejects(duplicate.service.create([filePath, '/共享/other']), isKind(Kind.Protocol));
  await assert.rejects(duplicate.service.create([filePath, '/共享/other']), isKind(Kind.Protocol));
});

test('edit and delete reject malformed detailed failures and unexpected success payloads', async () => {
  const responses = [{ links: [] }, { errors: 'invalid' }, { errors: [{ id: 'other', code: 2000 }] },
    { errors: [{ id: 'id', code: 0 }] }, { errors: [{ id: 'id', code: '2000' }] },
    { errors: [{ id: 'id', code: 2000 }, { id: 'id', code: 403 }] },
    { success: false, error: { code: 2002, errors: [] } },
    { success: true, error: { code: 2000 } }, { success: 'true' }, null];
  for (const reply of responses) {
    const { service } = repository([reply, reply]);
    await assert.rejects(service.edit('id', { expiredDate: '0' }), isKind(Kind.Protocol));
    await assert.rejects(service.remove(['id']), isKind(Kind.Protocol));
  }
});

test('missing-link, permission and session errors stay distinct with original codes', async () => {
  for (const [code, kind] of [[2000, Kind.Server], [403, Kind.Permission], [106, Kind.SessionExpired], [9876, Kind.Server]]) {
    const { service } = repository([{ success: false, error: { code } }]);
    await assert.rejects(service.getInfo('id'), error => isKind(kind)(error) && error.code === code);
  }
  const { service } = repository([{ success: false, error: { code: 2002 } }]);
  await assert.rejects(service.remove(['id']), error => error.code === 2002);
});

test('transport failures propagate unchanged and no write is retried or followed by an automatic read', async () => {
  const failure = new NasFailure(Kind.Network, '结果待确认');
  const { service, calls } = repository([failure, failure, failure]);
  await assert.rejects(service.create(['/共享/文件']), error => error === failure);
  await assert.rejects(service.edit('id', { password: { mode: 'remove' } }), error => error === failure);
  await assert.rejects(service.remove(['id']), error => error === failure);
  assert.deepEqual(calls.map(call => call.method), ['create', 'edit', 'delete']);
});

test('caller mutations during a request do not alter captured paths or IDs', async () => {
  const paths = ['/共享/文件'];
  const ids = ['original'];
  const { service } = repository([() => { paths[0] = '/共享/other'; return { links: [created('/共享/文件')] }; },
    () => { ids[0] = 'changed'; return {}; }]);
  assert.equal((await service.create(paths))[0].path, '/共享/文件');
  assert.equal((await service.remove(ids))[0].id, 'original');
});

test('decoded global errors cannot be hidden by otherwise plausible read or create payloads', async () => {
  const filePath = '/共享/文件';
  const { service } = repository([{ ...link('id'), error: { code: 2000 } },
    { success: true, data: { links: [created(filePath)], error: { code: 2002 } } },
    { links: [link('id')], offset: 0, total: 1, errors: [{ id: 'id', code: 2000 }] }]);
  await assert.rejects(service.getInfo('id'), error => error.code === 2000);
  await assert.rejects(service.create([filePath]), error => error.code === 2002);
  await assert.rejects(service.list(), isKind(Kind.Protocol));
});
