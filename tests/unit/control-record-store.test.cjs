const test = require('node:test').test;
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const TextEncoder = require('node:util').TextEncoder;
const sdkRoot = process.env.HARMONY_SDK_ROOT || path.join(process.env.DEVECO_CLI_CLT_PATH || 'C:/Program Files/command-line-tools', 'sdk/default');
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const protocol = require('../../work/core-build/domain/DsmProtocol.js');
const control = require('../../work/core-build/domain/SystemControl.js');
const context = { filesDir: '/synthetic-private' };
const recordPath = context.filesDir + '/nas-control.json';
const SYNTHETIC_RECORD = {
  id: '0123456789abcdef'.repeat(2), origin: 'https://nas.example.test:5001',
  account: '合成账号', model: 'Synthetic NAS', fingerprint: 'ab'.repeat(32),
  action: 'shutdown', state: 'pending', createdAt: 100, updatedAt: 100,
};
const plain = value => JSON.parse(JSON.stringify(value));
const isKind = kind => error => error instanceof protocol.NasFailure && error.kind === kind;
const failure = code => Object.assign(new Error('synthetic platform failure: do-not-expose-secret'), { code });

function loadStore(mocks) {
  const relative = 'features/control/NasControlRecordStore.ets';
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
  return module.exports.NasControlRecordStore;
}

function storeFixture() {
  const files = new Map();
  const handles = new Map();
  const events = [];
  const faults = {};
  let nextFd = 1;
  const fail = operation => { if (faults[operation]) throw faults[operation]; };
  const event = (operation, details = {}) => {
    events.push({ operation, original: files.has(recordPath) ? files.get(recordPath).toString('utf8') : undefined, ...details });
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
      assert.equal(file, recordPath + '.tmp');
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
      const count = Object.hasOwn(faults, 'writeCount') ? faults.writeCount : Math.min(7, bytes.length);
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
      assert.equal(oldPath, recordPath + '.tmp');
      assert.equal(newPath, recordPath);
      assert.equal(handles.size, 0);
      files.set(newPath, Buffer.from(files.get(oldPath)));
      files.delete(oldPath);
    },
  };
  const NasControlRecordStore = loadStore({
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {}, '@kit.CoreFileKit': { fileIo: io },
    '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } } },
    '../../core/domain/DsmProtocol': protocol, '../../core/domain/SystemControl': control,
  });
  return { NasControlRecordStore, files, events, faults, handles };
}

test('SYNTHETIC actual ETS store blocks saving before load and accepts only initial stat ENOENT as empty', async () => {
  const fixture = storeFixture();
  const store = new fixture.NasControlRecordStore();
  await assert.rejects(store.save(SYNTHETIC_RECORD), isKind(protocol.NasErrorKind.Protocol));
  assert.equal(fixture.events.length, 0);
  assert.equal(await store.load(context), undefined);
  assert.deepEqual(fixture.events.map(event => event.operation), ['stat']);
  assert.equal(fixture.events[0].file, recordPath);
  assert.equal(fixture.files.size, 0);
  await store.save(SYNTHETIC_RECORD);
  assert.deepEqual(JSON.parse(fixture.files.get(recordPath)), { version: 1, record: SYNTHETIC_RECORD });
  assert.deepEqual([...fixture.files.keys()], [recordPath]);
});

test('SYNTHETIC partial UTF8 writes commit only after fsync/close/rename and retain only the latest record', async () => {
  const fixture = storeFixture();
  const store = new fixture.NasControlRecordStore();
  await store.load(context);
  await store.save(SYNTHETIC_RECORD);
  const original = fixture.files.get(recordPath).toString('utf8');
  fixture.files.set(recordPath + '.tmp', Buffer.from('stale-synthetic-secret'));
  fixture.events.length = 0;
  const updated = { ...SYNTHETIC_RECORD, id: 'fedcba9876543210'.repeat(2), account: '  合成新账号  ', state: 'accepted', updatedAt: 200 };
  await store.save(updated);
  const expected = control.validateNasControlRecord(updated);
  assert.deepEqual(JSON.parse(fixture.files.get(recordPath)), { version: 1, record: expected });
  const writes = fixture.events.filter(event => event.operation === 'write');
  assert.ok(writes.length > 1);
  let offset = 0;
  for (const write of writes) { assert.equal(write.offset, offset); offset += write.count; }
  assert.equal(offset, fixture.files.get(recordPath).length);
  assert.deepEqual(fixture.events.slice(-3).map(event => event.operation), ['fsync', 'close', 'rename']);
  for (const event of fixture.events) assert.equal(event.original, original);
  assert.deepEqual([...fixture.files.keys()], [recordPath]);
  assert.equal(fixture.handles.size, 0);
  const loaded = await new fixture.NasControlRecordStore().load(context);
  assert.deepEqual(plain(loaded), expected);
  assert.equal(control.nasControlUnresolved(loaded), true);
  assert.doesNotMatch(fixture.files.get(recordPath).toString('utf8'), /stale-synthetic-secret|password|sid|token|serial/i);
});

test('SYNTHETIC stat failures other than numeric ENOENT preserve existing bytes and keep saves blocked', async () => {
  for (const code of [13900001, 13900005, 13900012, '13900002', undefined]) {
    const fixture = storeFixture();
    const original = control.encodeNasControlRecord(SYNTHETIC_RECORD);
    fixture.files.set(recordPath, Buffer.from(original));
    fixture.faults.stat = failure(code);
    const store = new fixture.NasControlRecordStore();
    await assert.rejects(store.load(context), error => isKind(protocol.NasErrorKind.Protocol)(error) && /无法检查/.test(error.message));
    await assert.rejects(store.save(SYNTHETIC_RECORD), isKind(protocol.NasErrorKind.Protocol));
    assert.deepEqual(fixture.events.map(event => event.operation), ['stat']);
    assert.equal(fixture.files.get(recordPath).toString('utf8'), original);
  }
});

test('SYNTHETIC read errors after successful stat, including ENOENT races, cannot authorize overwriting', async () => {
  for (const code of [13900002, 13900012, 13900005]) {
    const fixture = storeFixture();
    const original = control.encodeNasControlRecord(SYNTHETIC_RECORD);
    fixture.files.set(recordPath, Buffer.from(original));
    fixture.faults.readText = failure(code);
    const store = new fixture.NasControlRecordStore();
    await assert.rejects(store.load(context), error => isKind(protocol.NasErrorKind.Protocol)(error) &&
      error.code === code && /无法读取/.test(error.message) && !error.message.includes('do-not-expose-secret'));
    await assert.rejects(store.save(SYNTHETIC_RECORD), isKind(protocol.NasErrorKind.Protocol));
    assert.deepEqual(fixture.events.map(event => event.operation), ['stat', 'readText']);
    assert.equal(fixture.files.get(recordPath).toString('utf8'), original);
  }
});

test('SYNTHETIC corrupt or credential-bearing snapshots revoke an earlier successful load', async () => {
  for (const corrupt of ['', '{broken', JSON.stringify({ version: 2, record: SYNTHETIC_RECORD }),
    JSON.stringify({ version: 1, record: { ...SYNTHETIC_RECORD, state: 'completed' } }),
    JSON.stringify({ version: 1, record: { ...SYNTHETIC_RECORD, action: 'restart' } }),
    JSON.stringify({ version: 1, record: { ...SYNTHETIC_RECORD, password: 'synthetic-secret' } }),
    JSON.stringify({ version: 1, record: SYNTHETIC_RECORD, serial: 'synthetic-secret' })]) {
    const fixture = storeFixture();
    const store = new fixture.NasControlRecordStore();
    await store.load(context);
    await store.save(SYNTHETIC_RECORD);
    fixture.files.set(recordPath, Buffer.from(corrupt));
    await assert.rejects(store.load(context), isKind(protocol.NasErrorKind.Protocol));
    const eventCount = fixture.events.length;
    await assert.rejects(store.save(SYNTHETIC_RECORD), isKind(protocol.NasErrorKind.Protocol));
    assert.equal(fixture.events.length, eventCount);
    assert.equal(fixture.files.get(recordPath).toString('utf8'), corrupt);
  }
});

test('SYNTHETIC 16KiB UTF8 limit is enforced both before and after read', async () => {
  const encoded = control.encodeNasControlRecord(SYNTHETIC_RECORD);
  const exact = encoded + ' '.repeat(16 * 1024 - Buffer.byteLength(encoded));
  const valid = storeFixture();
  valid.files.set(recordPath, Buffer.from(exact));
  assert.deepEqual(plain(await new valid.NasControlRecordStore().load(context)), SYNTHETIC_RECORD);
  for (const race of [false, true]) {
    const fixture = storeFixture();
    fixture.files.set(recordPath, Buffer.from(exact + ' '));
    if (race) fixture.faults.statSize = 1;
    const store = new fixture.NasControlRecordStore();
    await assert.rejects(store.load(context), error => isKind(protocol.NasErrorKind.Protocol)(error) && /过大/.test(error.message));
    await assert.rejects(store.save(SYNTHETIC_RECORD));
    assert.equal(fixture.files.get(recordPath).toString('utf8'), exact + ' ');
    assert.equal(fixture.events.some(event => event.operation === 'readText'), race);
    assert.equal(fixture.events.some(event => event.operation === 'open'), false);
  }
});

test('SYNTHETIC save validates metadata and UTF8 size before touching any temporary file', async () => {
  const fixture = storeFixture();
  const store = new fixture.NasControlRecordStore();
  await store.load(context);
  await store.save(SYNTHETIC_RECORD);
  const original = fixture.files.get(recordPath).toString('utf8');
  fixture.events.length = 0;
  for (const field of ['password', 'sid', 'token', 'serial']) {
    await assert.rejects(store.save({ ...SYNTHETIC_RECORD, [field]: 'synthetic-secret' }), isKind(protocol.NasErrorKind.InvalidInput));
  }
  for (const invalid of [{ ...SYNTHETIC_RECORD, action: 'restart' }, { ...SYNTHETIC_RECORD, state: 'completed' }, undefined, []]) {
    await assert.rejects(store.save(invalid), isKind(protocol.NasErrorKind.InvalidInput));
  }
  const huge = { ...SYNTHETIC_RECORD, origin: 'https://' + 'a.'.repeat(8300) + 'example.test' };
  await assert.rejects(store.save(huge), error => isKind(protocol.NasErrorKind.Protocol)(error) && /过大/.test(error.message));
  assert.equal(fixture.events.length, 0);
  assert.equal(fixture.files.get(recordPath).toString('utf8'), original);
});

test('SYNTHETIC every write-stage failure preserves original bytes and never creates a backup', async () => {
  for (const operation of ['open', 'write', 'fsync', 'close', 'rename']) {
    const fixture = storeFixture();
    const store = new fixture.NasControlRecordStore();
    await store.load(context);
    await store.save(SYNTHETIC_RECORD);
    const original = fixture.files.get(recordPath).toString('utf8');
    fixture.events.length = 0;
    fixture.faults[operation] = failure(13900005);
    await assert.rejects(store.save({ ...SYNTHETIC_RECORD, state: 'accepted', updatedAt: 200 }), error =>
      isKind(protocol.NasErrorKind.Protocol)(error) && error.code === 13900005 &&
      /无法保存/.test(error.message) && !error.message.includes('do-not-expose-secret'));
    assert.equal(fixture.files.get(recordPath).toString('utf8'), original);
    assert.equal(fixture.events.some(event => event.operation === 'rename'), operation === 'rename');
    if (operation !== 'open') assert.ok(fixture.events.some(event => event.operation === 'close'));
    assert.ok([...fixture.files.keys()].every(file => file === recordPath || file === recordPath + '.tmp'));
  }
});

test('SYNTHETIC invalid write progress stops before fsync/rename instead of reporting a false commit', async () => {
  for (const count of [0, -1, 1.5, NaN, Infinity, 1000000, undefined, null, true, '7']) {
    const fixture = storeFixture();
    const store = new fixture.NasControlRecordStore();
    await store.load(context);
    await store.save(SYNTHETIC_RECORD);
    const original = fixture.files.get(recordPath).toString('utf8');
    fixture.events.length = 0;
    fixture.faults.writeCount = count;
    await assert.rejects(store.save({ ...SYNTHETIC_RECORD, state: 'accepted' }), error =>
      isKind(protocol.NasErrorKind.Protocol)(error) && /无法完整保存/.test(error.message));
    assert.equal(fixture.files.get(recordPath).toString('utf8'), original);
    assert.deepEqual(fixture.events.map(event => event.operation), ['open', 'write', 'close']);
  }
});

test('SYNTHETIC serial persistence retry truncates a failed temporary write without executing any NAS operation', async () => {
  const fixture = storeFixture();
  const store = new fixture.NasControlRecordStore();
  await store.load(context);
  await store.save(SYNTHETIC_RECORD);
  const updated = { ...SYNTHETIC_RECORD, state: 'rejected', updatedAt: 200 };
  fixture.faults.rename = failure(13900005);
  await assert.rejects(store.save(updated));
  delete fixture.faults.rename;
  await store.save(updated);
  assert.deepEqual(JSON.parse(fixture.files.get(recordPath)), { version: 1, record: updated });
  assert.deepEqual([...fixture.files.keys()], [recordPath]);
  assert.equal(control.nasControlUnresolved(await store.load(context)), false);
});

test('SYNTHETIC orphan temporary files never replace the authoritative record during recovery', async () => {
  for (const originalExists of [false, true]) {
    const fixture = storeFixture();
    fixture.files.set(recordPath + '.tmp', Buffer.from('{synthetic interrupted write'));
    if (originalExists) fixture.files.set(recordPath, Buffer.from(control.encodeNasControlRecord(SYNTHETIC_RECORD)));
    const loaded = await new fixture.NasControlRecordStore().load(context);
    assert.deepEqual(loaded === undefined ? undefined : plain(loaded), originalExists ? SYNTHETIC_RECORD : undefined);
    assert.ok(fixture.events.every(event => event.file === recordPath));
    assert.equal(fixture.files.get(recordPath + '.tmp').toString('utf8'), '{synthetic interrupted write');
  }
});
