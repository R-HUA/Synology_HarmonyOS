const test = require('node:test').test;
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const TextEncoder = require('node:util').TextEncoder;
const sdkRoot = process.env.HARMONY_SDK_ROOT || path.join(process.env.DEVECO_CLI_CLT_PATH || 'C:/Program Files/command-line-tools', 'sdk/default');
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const protocol = require('../../work/core-build/domain/DsmProtocol.js');
const routes = require('../../work/core-build/domain/ConnectionRoutes.js');
const context = { filesDir: '/synthetic-private' };
const bookPath = context.filesDir + '/nas-addresses.json';
const address = { origin: 'https://nas.example.test:5001', name: '家中 NAS', kind: 'lan' };
const binding = { account: 'alice', fingerprint: 'ab'.repeat(32), model: 'DS920+' };
const plain = value => JSON.parse(JSON.stringify(value));
const isKind = kind => error => error instanceof protocol.NasFailure && error.kind === kind;
const failure = code => Object.assign(new Error('synthetic platform failure: do-not-expose-serial'), { code });

function loadStore(mocks) {
  const relative = 'features/connection/NasAddressBookStore.ets';
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets', relative), 'utf8');
  const output = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true,
  });
  assert.equal((output.diagnostics || []).filter(diagnostic => diagnostic.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, {
    module, exports: module.exports, Error, Uint8Array, ArrayBuffer,
    require: id => { assert.ok(Object.hasOwn(mocks, id), `unexpected dependency ${id}`); return mocks[id]; },
  }, { filename: relative });
  return module.exports;
}

function storeFixture() {
  const files = new Map();
  const handles = new Map();
  const events = [];
  const cryptoInputs = [];
  const faults = {};
  let nextFd = 1;
  const fail = operation => { if (faults[operation]) throw faults[operation]; };
  const event = (operation, details = {}) => {
    events.push({ operation, original: files.has(bookPath) ? files.get(bookPath).toString('utf8') : undefined, ...details });
  };
  const io = {
    OpenMode: { READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
    async stat(file) {
      event('stat', { file });
      fail('stat');
      if (!files.has(file)) throw failure(13900002);
      return { size: faults.statSize === undefined ? files.get(file).length : faults.statSize };
    },
    async readText(file) {
      event('readText', { file });
      fail('readText');
      if (!files.has(file)) throw failure(13900002);
      return files.get(file).toString('utf8');
    },
    async open(file, mode) {
      event('open', { file, mode });
      fail('open');
      assert.equal(file, bookPath + '.tmp');
      assert.equal(mode, io.OpenMode.READ_WRITE | io.OpenMode.CREATE | io.OpenMode.TRUNC);
      const fd = nextFd++;
      handles.set(fd, { file, offset: 0 });
      files.set(file, Buffer.alloc(0));
      return { fd };
    },
    async write(fd, data) {
      const handle = handles.get(fd);
      assert.ok(handle);
      const bytes = Buffer.from(data);
      const count = faults.writeCount === undefined ? Math.min(7, bytes.length) : faults.writeCount;
      event('write', { file: handle.file, offset: handle.offset, count });
      fail('write');
      if (Number.isSafeInteger(count) && count > 0 && count <= bytes.length) {
        files.set(handle.file, Buffer.concat([files.get(handle.file), bytes.subarray(0, count)]));
        handle.offset += count;
      }
      return count;
    },
    async fsync(fd) {
      assert.ok(handles.has(fd));
      event('fsync');
      fail('fsync');
    },
    async close(file) {
      assert.ok(handles.has(file.fd));
      event('close');
      fail('close');
      handles.delete(file.fd);
    },
    async rename(oldPath, newPath) {
      event('rename', { oldPath, newPath });
      fail('rename');
      assert.equal(oldPath, bookPath + '.tmp');
      assert.equal(newPath, bookPath);
      assert.equal(handles.size, 0);
      files.set(newPath, Buffer.from(files.get(oldPath)));
      files.delete(oldPath);
    },
  };
  const exports = loadStore({
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {}, '@kit.CoreFileKit': { fileIo: io },
    '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd(algorithm) {
      assert.equal(algorithm, 'SHA256');
      fail('cryptoCreate');
      const digest = crypto.createHash('sha256');
      return {
        async update(input) { fail('cryptoUpdate'); cryptoInputs.push(Buffer.from(input.data).toString('utf8')); digest.update(input.data); },
        async digest() { fail('cryptoDigest'); return { data: faults.digestBytes || new Uint8Array(digest.digest()) }; },
      };
    } } },
    '../../core/domain/DsmProtocol': protocol,
    '../../core/domain/ConnectionRoutes': routes,
  });
  return { NasAddressBookStore: exports.NasAddressBookStore, nasDeviceFingerprint: exports.nasDeviceFingerprint,
    files, events, faults, cryptoInputs, handles };
}

test('synthetic actual store requires a successful load and only first-stat ENOENT permits migration', async () => {
  const fixture = storeFixture();
  const store = new fixture.NasAddressBookStore();
  await assert.rejects(store.save([]), isKind(protocol.NasErrorKind.Protocol));
  assert.equal(fixture.events.length, 0);
  assert.deepEqual(plain(await store.load(context)), []);
  assert.deepEqual(fixture.events.map(event => event.operation), ['stat']);
  assert.equal(fixture.files.size, 0);
  await store.save([]);
  assert.deepEqual(JSON.parse(fixture.files.get(bookPath)), { version: 1, addresses: [] });
  assert.deepEqual([...fixture.files.keys()], [bookPath]);
});

test('actual store round-trips UTF8 metadata through partial writes before fsync, close and atomic rename', async () => {
  const fixture = storeFixture();
  const store = new fixture.NasAddressBookStore();
  await store.load(context);
  await store.save([address]);
  const original = fixture.files.get(bookPath).toString('utf8');
  fixture.files.set(bookPath + '.tmp', Buffer.from('stale-synthetic-secret'));
  fixture.events.length = 0;
  const entries = [{ ...address, name: '新连接 📁', device: binding },
    { ...address, origin: 'https://[2001:DB8::1]:5001/', kind: 'private' }];
  await store.save(entries);
  const expected = routes.decodeConnectionAddressBook(routes.encodeConnectionAddressBook(entries));
  const writes = fixture.events.filter(event => event.operation === 'write');
  assert.ok(writes.length > 1);
  let offset = 0;
  for (const write of writes) { assert.equal(write.offset, offset); offset += write.count; }
  assert.equal(offset, fixture.files.get(bookPath).length);
  assert.deepEqual(fixture.events.slice(-3).map(event => event.operation), ['fsync', 'close', 'rename']);
  for (const event of fixture.events) assert.equal(event.original, original);
  assert.deepEqual([...fixture.files.keys()], [bookPath]);
  assert.equal(fixture.handles.size, 0);
  assert.deepEqual(plain(await new fixture.NasAddressBookStore().load(context)), expected);
  assert.equal(fixture.cryptoInputs.length, 0);
  assert.doesNotMatch(fixture.files.get(bookPath).toString('utf8'), /stale-synthetic-secret|password|sid|token|otp|serial/i);
});

test('corrupt or secret-bearing existing books cannot be overwritten, including after a prior successful load', async () => {
  for (const corrupt of ['{broken', JSON.stringify({ version: 2, addresses: [] }),
    JSON.stringify({ version: 1, addresses: [address, address] }),
    JSON.stringify({ version: 1, addresses: [{ ...address, password: 'synthetic-secret' }] })]) {
    const fixture = storeFixture();
    const store = new fixture.NasAddressBookStore();
    await store.load(context);
    await store.save([address]);
    fixture.files.set(bookPath, Buffer.from(corrupt));
    await assert.rejects(store.load(context), isKind(protocol.NasErrorKind.Protocol));
    const count = fixture.events.length;
    await assert.rejects(store.save([]), isKind(protocol.NasErrorKind.Protocol));
    assert.equal(fixture.events.length, count);
    assert.equal(fixture.files.get(bookPath).toString('utf8'), corrupt);
  }
});

test('read errors after a successful stat, even ENOENT, reject recovery instead of enabling an empty overwrite', async () => {
  for (const code of [13900002, 13900012, 13900005]) {
    const fixture = storeFixture();
    fixture.files.set(bookPath, Buffer.from(routes.encodeConnectionAddressBook([address])));
    fixture.faults.readText = failure(code);
    const store = new fixture.NasAddressBookStore();
    await assert.rejects(store.load(context), error => isKind(protocol.NasErrorKind.Protocol)(error) &&
      error.code === code && /无法读取连接地址记录/.test(error.message));
    const count = fixture.events.length;
    await assert.rejects(store.save([]));
    assert.equal(fixture.events.length, count);
    assert.deepEqual(JSON.parse(fixture.files.get(bookPath)).addresses, [address]);
  }
});

test('stat permission and IO failures are not treated as a fresh installation', async () => {
  for (const code of [13900001, 13900005, 13900012, 2]) {
    const fixture = storeFixture();
    fixture.faults.stat = failure(code);
    const store = new fixture.NasAddressBookStore();
    await assert.rejects(store.load(context), error => isKind(protocol.NasErrorKind.Protocol)(error) &&
      error.code === code && /无法检查连接地址记录/.test(error.message));
    await assert.rejects(store.save([]));
    assert.deepEqual(fixture.events.map(event => event.operation), ['stat']);
    assert.equal(fixture.files.size, 0);
  }
});

test('existing books at 64KiB load but larger books and growth between stat and read cannot be overwritten', async () => {
  const encoded = routes.encodeConnectionAddressBook([address]);
  const exact = encoded + ' '.repeat(64 * 1024 - Buffer.byteLength(encoded));
  const validFixture = storeFixture();
  validFixture.files.set(bookPath, Buffer.from(exact));
  assert.deepEqual(plain(await new validFixture.NasAddressBookStore().load(context)), [address]);
  for (const race of [false, true]) {
    const fixture = storeFixture();
    fixture.files.set(bookPath, Buffer.from(exact + ' '));
    if (race) fixture.faults.statSize = 1;
    const store = new fixture.NasAddressBookStore();
    await assert.rejects(store.load(context), error => isKind(protocol.NasErrorKind.Protocol)(error) && /过大/.test(error.message));
    await assert.rejects(store.save([]));
    assert.equal(fixture.files.get(bookPath).toString('utf8'), exact + ' ');
    assert.equal(fixture.events.some(event => event.operation === 'readText'), race);
    assert.equal(fixture.events.some(event => event.operation === 'open'), false);
  }
});

test('save validates metadata and its UTF8 byte size before opening a temporary file', async () => {
  const fixture = storeFixture();
  const store = new fixture.NasAddressBookStore();
  await store.load(context);
  await store.save([address]);
  const original = fixture.files.get(bookPath).toString('utf8');
  fixture.events.length = 0;
  for (const invalid of [{ ...address, password: 'synthetic-secret' },
    { ...address, device: { ...binding, serial: 'synthetic-serial' } }]) {
    await assert.rejects(store.save([invalid]), isKind(protocol.NasErrorKind.InvalidInput));
  }
  const huge = { ...address, origin: 'https://' + 'a.'.repeat(33000) + 'example.test' };
  await assert.rejects(store.save([huge]), error => isKind(protocol.NasErrorKind.Protocol)(error) && /过大/.test(error.message));
  assert.equal(fixture.events.length, 0);
  assert.equal(fixture.files.get(bookPath).toString('utf8'), original);
});

test('open, write, fsync, close and rename failures propagate Chinese errors and preserve the original book', async () => {
  for (const operation of ['open', 'write', 'fsync', 'close', 'rename']) {
    const fixture = storeFixture();
    const store = new fixture.NasAddressBookStore();
    await store.load(context);
    await store.save([address]);
    const original = fixture.files.get(bookPath).toString('utf8');
    fixture.events.length = 0;
    fixture.faults[operation] = failure(13900005);
    await assert.rejects(store.save([{ ...address, name: '新连接' }]), error =>
      isKind(protocol.NasErrorKind.Protocol)(error) && error.code === 13900005 &&
      /无法保存连接地址记录/.test(error.message) && !error.message.includes('do-not-expose-serial'));
    assert.equal(fixture.files.get(bookPath).toString('utf8'), original);
    assert.equal(fixture.events.some(event => event.operation === 'rename'), operation === 'rename');
    if (operation !== 'open') assert.ok(fixture.events.some(event => event.operation === 'close'));
    assert.ok([...fixture.files.keys()].every(file => file === bookPath || file === bookPath + '.tmp'));
  }
});

test('zero, negative, fractional, oversized and nonnumeric write progress never causes a false atomic commit', async () => {
  for (const count of [0, -1, 1.5, NaN, Infinity, 1000000]) {
    const fixture = storeFixture();
    const store = new fixture.NasAddressBookStore();
    await store.load(context);
    await store.save([address]);
    const original = fixture.files.get(bookPath).toString('utf8');
    fixture.events.length = 0;
    fixture.faults.writeCount = count;
    await assert.rejects(store.save([{ ...address, name: '新连接' }]), error =>
      isKind(protocol.NasErrorKind.Protocol)(error) && /无法完整保存/.test(error.message));
    assert.equal(fixture.files.get(bookPath).toString('utf8'), original);
    assert.deepEqual(fixture.events.map(event => event.operation), ['open', 'write', 'close']);
  }
});

test('an atomic save can be retried serially after a failed rename without replaying unrelated state', async () => {
  const fixture = storeFixture();
  const store = new fixture.NasAddressBookStore();
  await store.load(context);
  await store.save([address]);
  fixture.faults.rename = failure(13900005);
  await assert.rejects(store.save([{ ...address, name: '新连接' }]));
  delete fixture.faults.rename;
  await store.save([{ ...address, name: '新连接' }]);
  assert.deepEqual(plain(await new fixture.NasAddressBookStore().load(context)), [{ ...address, name: '新连接' }]);
  assert.deepEqual([...fixture.files.keys()], [bookPath]);
});

test('SHA256 uses only serialized raw model and serial, so distinct origins of the same real identity share a hash', async () => {
  const fixture = storeFixture();
  const identity = { model: 'DS920+', serial: 'synthetic-serial-001' };
  const first = await fixture.nasDeviceFingerprint({ ...identity, origin: 'https://192.0.2.1:5001', password: 'synthetic-secret' });
  const second = await fixture.nasDeviceFingerprint({ ...identity, origin: 'https://remote.example.test' });
  const expected = crypto.createHash('sha256').update(JSON.stringify([identity.model, identity.serial])).digest('hex');
  assert.equal(first, expected);
  assert.equal(second, expected);
  assert.match(first, /^[0-9a-f]{64}$/);
  assert.deepEqual(fixture.cryptoInputs, [JSON.stringify([identity.model, identity.serial]), JSON.stringify([identity.model, identity.serial])]);
  const differentSerial = await fixture.nasDeviceFingerprint({ ...identity, serial: 'synthetic-serial-002' });
  const differentModel = await fixture.nasDeviceFingerprint({ ...identity, model: 'DS923+' });
  assert.notEqual(differentSerial, expected);
  assert.notEqual(differentModel, expected);
  assert.equal(fixture.events.length, 0);
  assert.equal(fixture.files.size, 0);
  const store = new fixture.NasAddressBookStore();
  await store.load(context);
  await store.save([{ ...address, device: { ...binding, fingerprint: first } }]);
  assert.doesNotMatch(fixture.files.get(bookPath).toString('utf8'), /synthetic-serial|serial|password|synthetic-secret/);
});

test('identity failures prevent crypto use and neither trim nor fabricate identifiers', async () => {
  const fixture = storeFixture();
  for (const identity of [{ model: 'DS920+' }, { serial: 'synthetic-serial' }, {}]) {
    await assert.rejects(fixture.nasDeviceFingerprint(identity), isKind(protocol.NasErrorKind.Unsupported));
  }
  for (const identity of [null, [], { model: 'DS920+', serial: '' }, { model: 'DS920+', serial: 'bad\nserial' },
    { model: 123, serial: 'synthetic-serial' }, { model: 'DS920+', serial: 'x'.repeat(129) }]) {
    await assert.rejects(fixture.nasDeviceFingerprint(identity), isKind(protocol.NasErrorKind.Protocol));
  }
  assert.equal(fixture.cryptoInputs.length, 0);
  const raw = { model: ' DS920+ ', serial: ' synthetic-serial ' };
  const expected = crypto.createHash('sha256').update(JSON.stringify([raw.model, raw.serial])).digest('hex');
  assert.equal(await fixture.nasDeviceFingerprint(raw), expected);
  assert.equal(fixture.files.size, 0);
});

test('crypto creation, update, digest and truncated results fail explicitly without exposing raw identifiers', async () => {
  for (const operation of ['cryptoCreate', 'cryptoUpdate', 'cryptoDigest', 'digestBytes']) {
    const fixture = storeFixture();
    fixture.faults[operation] = operation === 'digestBytes' ? new Uint8Array([1, 2]) : failure(17630001);
    await assert.rejects(fixture.nasDeviceFingerprint({ model: 'DS920+', serial: 'synthetic-serial' }), error =>
      isKind(protocol.NasErrorKind.Protocol)(error) && /设备指纹/.test(error.message) &&
      !/synthetic-serial|do-not-expose-serial/.test(error.message));
    assert.equal(fixture.files.size, 0);
    assert.equal(fixture.events.length, 0);
  }
});
