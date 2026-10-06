const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const p = require('../../work/core-build/domain/DriveCollaborationProtocol.js');
const record = (account = 'alice', nasOrigin = 'https://nas.test') => ({ id: '11111111-1111-4111-8111-111111111111',
  nasOrigin, account, fileId: '900000000000000001', name: '资料.txt', createdAt: 1, state: 'unknown' });
const scope = (origin, account) => crypto.createHash('sha256').update(JSON.stringify([origin, account])).digest('hex');
const recordPath = (origin = 'https://nas.test', account = 'alice') => '/private/drive-file-links/' + scope(origin, account) + '/records.json';
function fixture() {
  const files = new Map(), writes = [], directories = [];
  const mocks = {
    '@kit.CoreFileKit': { fileIo: {
      async stat(name) { if (!files.has(name)) throw { code: 13900002 }; return { size: Buffer.byteLength(files.get(name)) }; },
      async readText(name) { return files.get(name); }
    } },
    '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(value) { return new Uint8Array(Buffer.from(value)); } } } },
    '../../platform/SdkDigest': { sha256: async bytes => crypto.createHash('sha256').update(bytes).digest('hex') },
    '../../platform/SdkFileIO': { writePrivateSnapshot: async (name, bytes) => { const text = Buffer.from(bytes).toString(); files.set(name, text); writes.push([name, text]); } },
    '../../core/domain/DsmProtocol': dsm, '../../core/domain/DriveCollaborationProtocol': p,
    '../transfers/TransferQueueFiles': { ensureTransferDirectory: async name => directories.push(name) }
  };
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/drive/DriveSharingStore.ets'), 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const mod = { exports: {} };
  vm.runInNewContext(compiled.outputText, { module: mod, exports: mod.exports,
    require(id) { assert.ok(Object.hasOwn(mocks, id), id); return mocks[id]; } });
  return { Store: mod.exports.DriveSharingStore, files, writes, directories, mocks };
}

test('private store isolates normalized NAS and account, validates scopes, and atomically persists uncertainty', async () => {
  const f = fixture(), store = new f.Store();
  assert.equal((await store.load({ filesDir: '/private' }, 'https://NAS.test:443/', ' alice ')).length, 0);
  await store.save([record()]); assert.equal(f.writes[0][0], recordPath());
  assert.equal(JSON.parse(f.files.get(recordPath())).records[0].state, 'unknown');
  assert.equal((await store.load({ filesDir: '/private' }, 'https://second.test', 'alice')).length, 0);
  await store.save([record('alice', 'https://second.test')]);
  assert.equal((await store.load({ filesDir: '/private' }, 'https://nas.test', 'bob')).length, 0);
  assert.equal((await store.load({ filesDir: '/private' }, 'https://nas.test', 'alice'))[0].fileId, record().fileId);
  await assert.rejects(() => store.save([record('bob')]), /无法读取/);
  assert.equal(f.writes.length, 2);
});

test('store refuses save before load and corrupt, wrong-scope or oversized snapshots cannot be overwritten', async () => {
  for (const text of ['malformed', JSON.stringify({ version: 1, scope: 'wrong', records: [] }), 'x'.repeat(1024 * 1024 + 1)]) {
    const f = fixture(), store = new f.Store(); f.files.set(recordPath(), text);
    await assert.rejects(() => store.save([]), /尚未加载/);
    await assert.rejects(() => store.load({ filesDir: '/private' }, 'https://nas.test', 'alice'));
    await assert.rejects(() => store.save([]), /尚未加载/);
    assert.equal(f.files.get(recordPath()), text); assert.equal(f.writes.length, 0);
  }
});

test('only missing-file error yields empty history; I/O failures remain failures', async () => {
  const f = fixture(), store = new f.Store();
  f.mocks['@kit.CoreFileKit'].fileIo.stat = async () => { throw { code: 13900013 }; };
  await assert.rejects(() => store.load({ filesDir: '/private' }, 'https://nas.test', 'alice'));
  await assert.rejects(() => store.save([]), /尚未加载/);
  assert.equal(f.writes.length, 0);
});
