const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdkRoot = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const protocol = require('../../work/core-build/domain/DsmProtocol.js');
const state = require('../../work/core-build/domain/ExtensionWriteState.js');
const pending = [{ feature: 'nasDownloads', operation: 'create', createdAt: 100 }];

function fixture() {
  const files = new Map();
  const faults = {};
  let writes = 0;
  const mocks = {
    '@kit.CoreFileKit': { fileIo: {
      async mkdir() {},
      async stat(file) {
        if (faults.stat) throw faults.stat;
        if (!files.has(file)) throw Object.assign(new Error('missing'), { code: 13900002 });
        return { size: files.get(file).length };
      },
      async readText(file) { if (faults.read) throw faults.read; return files.get(file); },
    } },
    '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } } },
    '../../platform/SdkDigest': { sha256: async bytes => Buffer.from(bytes).toString('hex') },
    '../../platform/SdkFileIO': { async writePrivateSnapshot(file, bytes) {
      if (faults.save) throw faults.save;
      writes++; files.set(file, Buffer.from(bytes).toString('utf8'));
    } },
    '../../core/domain/DsmProtocol': protocol,
    '../../core/domain/ExtensionWriteState': state,
  };
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/extensions/ExtensionWriteStore.ets'), 'utf8');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, Error, Uint8Array,
    require: id => { assert.ok(Object.hasOwn(mocks, id), id); return mocks[id]; } });
  return { store: new module.exports.ExtensionWriteStore(), files, faults, writes: () => writes };
}

test('extension pending records are restored only within the same origin and account', async () => {
  const { store, files } = fixture();
  const context = { filesDir: '/private' };
  await store.load(context, 'https://nas.example.test', 'alice');
  await store.save(pending);
  assert.deepEqual(JSON.parse(JSON.stringify(await store.load(context, 'https://nas.example.test', 'alice'))), pending);
  assert.equal((await store.load(context, 'https://nas.example.test', 'bob')).length, 0);
  assert.equal((await store.load(context, 'https://other.example.test', 'alice')).length, 0);
  assert.equal(files.size, 1);
});

test('failed reads and corrupt existing records never authorize an overwrite', async () => {
  for (const fault of ['read', 'stat', 'corrupt']) {
    const { store, files, faults, writes } = fixture();
    const context = { filesDir: '/private' };
    await store.load(context, 'https://nas.example.test', 'alice');
    await store.save(pending);
    const before = Array.from(files.values());
    if (fault === 'corrupt') files.set(Array.from(files.keys())[0], '{');
    else faults[fault] = new Error('injected failure');
    await assert.rejects(store.load(context, 'https://nas.example.test', 'alice'));
    await assert.rejects(store.save([]), error => error.kind === protocol.NasErrorKind.Protocol);
    assert.equal(writes(), 1);
    if (fault !== 'corrupt') assert.deepEqual(Array.from(files.values()), before);
  }
});

test('pending store rejects writes before load and propagates persistence failures', async () => {
  const { store, faults, writes } = fixture();
  await assert.rejects(store.save(pending));
  await store.load({ filesDir: '/private' }, 'https://nas.example.test', 'alice');
  faults.save = new Error('disk full');
  await assert.rejects(store.save(pending), /disk full/);
  assert.equal(writes(), 0);
});
