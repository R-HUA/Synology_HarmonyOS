const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { TextEncoder, TextDecoder } = require('node:util');
const sdkRoot = process.env.HARMONY_SDK_ROOT || path.join(process.env.DEVECO_CLI_CLT_PATH || 'C:/Program Files/command-line-tools', 'sdk/default');
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

const protocol = require('../../work/core-build/domain/DsmProtocol.js');
const registryModule = require('../../work/core-build/network/SessionRegistry.js');

/** 与 connection-switch 相同的源码加载方式：剥离装饰器后按 CommonJS 转译执行。 */
function loadSource(relative, mocks = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets', relative), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true,
  });
  assert.equal((output.diagnostics || []).filter(diagnostic => diagnostic.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, {
    module, exports: module.exports, Error, Date, Uint8Array, ArrayBuffer,
    require: id => {
      assert.ok(Object.hasOwn(mocks, id), `unexpected dependency ${id}`);
      return mocks[id];
    },
  }, { filename: relative });
  return module.exports;
}

const secretTag = 'secret';
const aliasTag = 'alias';
/** 与 connection-switch 相同的跨 Realm 序列化：源码模块在 vm 上下文里执行，对象原型不同于主上下文。 */
const plain = value => JSON.parse(JSON.stringify(value));
/** alias 在真实 Asset 存档里按内容匹配；mock 统一把 Uint8Array 别名解码回字符串作为存储键。 */
const aliasKey = value => (typeof value === 'string' ? value : new TextDecoder().decode(value));
/** 内存版 Asset 存档：仅覆盖保存/读取/清除三条路径，不模拟设备锁定等状态。 */
function assetStore() {
  const stored = new Map();
  const business = code => { const error = new Error('asset'); error.code = code; return error; };
  return {
    stored,
    Tag: { ALIAS: aliasTag, SECRET: secretTag, RETURN_TYPE: 'return-type', ACCESSIBILITY: 'accessibility',
      AUTH_TYPE: 'auth-type', SYNC_TYPE: 'sync-type', CONFLICT_RESOLUTION: 'conflict-resolution' },
    Accessibility: { DEVICE_UNLOCKED: 1 }, AuthType: { NONE: 1 }, SyncType: { NEVER: 1 },
    ConflictResolution: { OVERWRITE: 1 }, ReturnType: { ALL: 1 },
    ErrorCode: { NOT_FOUND: 1001, STATUS_MISMATCH: 1002 },
    async add(attributes) { stored.set(aliasKey(attributes.get(aliasTag)), new Uint8Array(attributes.get(secretTag))); },
    async query(query) {
      const key = aliasKey(query.get(aliasTag));
      if (!stored.has(key)) { throw business(1001); }
      const row = new Map();
      row.set(secretTag, new Uint8Array(stored.get(key)));
      return [row];
    },
    async remove(query) {
      const key = aliasKey(query.get(aliasTag));
      if (!stored.has(key)) { throw business(1001); }
      stored.delete(key);
    },
  };
}

const asset = assetStore();
const { NasSessionStore } = loadSource('features/connection/NasSessionStore.ets', {
  '@kit.AssetStoreKit': { asset },
  '@kit.ArkTS': { util: {
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
    TextDecoder: { create: () => ({ decodeToString: bytes => new TextDecoder('utf-8', { fatal: true }).decode(bytes) }) },
  } },
  '@kit.BasicServicesKit': { BusinessError: class extends Error {} },
  '../../core/domain/DsmProtocol': protocol,
  '../../core/network/SessionRegistry': registryModule,
});

const httpsOrigin = 'https://nas.example.test:5001';
const sessions = [
  { name: 'FileStation', sid: 'file-station-sid', synoToken: 'file-station-token' },
  { name: 'DownloadStation', sid: 'download-sid', synoToken: 'download-token' },
];

test('v2 sessions round-trip through the asset store without credentials beyond SIDs', async () => {
  const store = new NasSessionStore();
  await store.save({ origin: httpsOrigin, account: 'alice', insecureTls: false, sessions });
  const loaded = await store.load();
  assert.deepEqual(plain(loaded), { origin: httpsOrigin, account: 'alice', insecureTls: false, sessions });
  const raw = new TextDecoder().decode(asset.stored.get('synology-harmonyos.nas-session.v1'));
  const payload = JSON.parse(raw);
  assert.equal(payload.version, 2);
  assert.deepEqual(payload.sessions, sessions);
  assert.deepEqual(Object.keys(payload).sort(), ['account', 'insecureTls', 'origin', 'sessions', 'version']);
  await store.clear();
  assert.equal(await store.load(), undefined);
});

test('legacy v1 payloads restore as the File Station primary session only', async () => {
  const legacy = new TextEncoder().encode(JSON.stringify(
    { origin: httpsOrigin, account: 'alice', sid: 'legacy-sid', synoToken: 'legacy-token', insecureTls: true }));
  asset.stored.set('synology-harmonyos.nas-session.v1', legacy);
  const loaded = await new NasSessionStore().load();
  assert.deepEqual(plain(loaded), { origin: httpsOrigin, account: 'alice', insecureTls: true,
    sessions: [{ name: 'FileStation', sid: 'legacy-sid', synoToken: 'legacy-token' }] });
});

test('a plain http origin never keeps the insecure-certificate policy', async () => {
  const store = new NasSessionStore();
  await store.save({ origin: 'http://nas.example.test:5000', account: 'alice', insecureTls: true,
    sessions: [sessions[0]] });
  assert.equal((await store.load()).insecureTls, false);
});

test('invalid payloads are rejected instead of partially restoring sessions', async () => {
  const store = new NasSessionStore();
  const base = { origin: httpsOrigin, account: 'alice', insecureTls: false };
  const cases = [
    { ...base, sessions: [] },
    { ...base, sessions: [{ name: 'FileStation', sid: '', synoToken: '' }] },
    { ...base, sessions: [{ name: 'UnknownSuite', sid: 'sid', synoToken: '' }] },
    { ...base, sessions: [sessions[0], { name: 'FileStation', sid: 'other', synoToken: '' }] },
    { ...base, sessions: [{ name: 'FileStation', sid: 'sid; inject', synoToken: '' }] },
    { ...base, origin: 'ftp://nas.example.test' },
    { ...base, account: '' },
    { ...base, sessions: 'not-an-array' },
  ];
  const before = asset.stored.size;
  for (const session of cases) {
    await assert.rejects(() => store.save(session));
  }
  assert.equal(asset.stored.size, before, '拒绝的负载不得写入存档');
});
