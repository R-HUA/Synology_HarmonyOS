const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const state = require('../../work/core-build/domain/DriveTransferState.js');

function fixture(options = {}) {
  const writes = [];
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/drive/DriveTransferStore.ets'), 'utf8');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
  const mocks = {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {},
    '@kit.CoreFileKit': { fileIo: {
      async stat() { if (options.missing) throw { code: 13900002 }; if (options.statFailure) throw { code: 13900005 }; return { size: options.size || 3 }; },
      async readText() { if (options.readFailure) throw { code: 13900005 }; return options.text || '{"version":1,"scope":"testscope","records":[]}'; }
    } },
    '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } } },
    '../../platform/SdkDigest': { sha256: async () => 'testscope' },
    '../../platform/SdkFileIO': { writePrivateSnapshot: async (file, bytes) => writes.push([file, JSON.parse(Buffer.from(bytes).toString())]) },
    '../../core/domain/DsmProtocol': dsm, '../../core/domain/DriveTransferState': state,
    '../transfers/TransferQueueFiles': { async ensureTransferDirectory() {} }
  };
  const mod = { exports: {} };
  vm.runInNewContext(output.outputText, { module: mod, exports: mod.exports,
    require(id) { assert.ok(Object.hasOwn(mocks, id), id); return mocks[id]; } });
  const store = new mod.exports.DriveTransferStore();
  return { store, writes, load: () => store.load({ filesDir: '/private' }, 'https://nas.example.test:5001', 'alice') };
}

test('Drive history may start empty only after absence is confirmed, and saving requires a successful load', async () => {
  const f = fixture({ missing: true });
  await assert.rejects(f.store.save([]));
  assert.equal((await f.load()).length, 0);
  await f.store.save([]);
  assert.equal(f.writes.length, 1);
  assert.equal(f.writes[0][0], '/private/drive-transfers/testscope/records.json');
  assert.equal(f.writes[0][1].scope, 'testscope');
});

test('corrupt, unreadable and over-limit snapshots cannot be overwritten with empty history', async () => {
  for (const options of [{ text: '{' }, { text: '{"version":1,"scope":"wrong","records":[]}' },
    { statFailure: true }, { readFailure: true }, { size: 1024 * 1024 + 1 }]) {
    const f = fixture(options);
    await assert.rejects(f.load());
    await assert.rejects(f.store.save([]));
    assert.equal(f.writes.length, 0);
  }
});
