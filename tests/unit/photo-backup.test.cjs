const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'D:/Program Files/DevEco Studio/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const policy = require('../../work/core-build/domain/PhotoBackupPolicy.js');
const protocol = require('../../work/core-build/domain/DsmProtocol.js');
const upload = require('../../work/core-build/domain/PhotoUpload.js');
const asset = { uri: 'media:one', name: '照片.jpg', bytes: 8, modifiedAt: 1704067200, takenAt: 0, addedAt: 1704067200, album: '相机' };

test('backup defaults, date fallback, source album and exact target determine deduplication', () => {
  const settings = new policy.PhotoBackupSettings();
  assert.equal(settings.enabled, false); assert.equal(settings.wifiOnly, true);
  assert.equal(policy.backupDirectory(settings, 'Phone', asset), 'MobileBackup/Phone/2024/01');
  assert.throws(() => upload.photoDateDirectory(0, 0));
  settings.layout = 'album';
  assert.equal(policy.backupDirectory(settings, 'Phone', asset), 'MobileBackup/Phone/相机');
  assert.throws(() => policy.backupDirectory(settings, 'Phone', { ...asset, album: '' }));
  settings.layout = 'flat'; settings.custom = true; settings.directory = '自选/目录';
  assert.equal(policy.backupDirectory(settings, 'Phone', asset), '自选/目录');
  const key = policy.backupAssetKey(asset, '自选/目录', 'content-one');
  assert.notEqual(key, policy.backupAssetKey({ ...asset, modifiedAt: asset.modifiedAt + 1 }, '自选/目录', 'content-one'));
  assert.notEqual(key, policy.backupAssetKey(asset, '另一目录', 'content-one'));
  assert.notEqual(key, policy.backupAssetKey(asset, '自选/目录', 'content-two'));
  const snapshot = { version: 1, scope: 'one', settings, completed: [key] };
  assert.deepEqual(policy.decodePhotoBackup(JSON.stringify(snapshot), 'one'), snapshot);
  assert.throws(() => policy.decodePhotoBackup(JSON.stringify(snapshot), 'two'));
  assert.throws(() => policy.decodePhotoBackup(JSON.stringify({ ...snapshot, settings: { ...settings, enabled: 'yes' } }), 'one'));
});

async function fixture(count = 1) {
  const records = new Map(), uploads = [], queries = [], saves = [], allowed = [], events = new Map(), hashes = [];
  const state = { wifi: true, charging: 1, permission: true, fail: false, unknown: false, denied: false };
  const assets = Array.from({ length: count }, (_, i) => ({ ...asset, uri: 'media:' + i, name: i + '.jpg', owner: 1, type: 1 }));
  class Predicates {
    constructor() { this.offset = 0; this.count = 50; this.only = false; this.since = 0; }
    equalTo(_key, _value) { this.only = true; return this; }
    greaterThanOrEqualTo(_key, value) { this.since = value; return this; }
    orderByAsc() { return this; }
    limit(count, offset) { this.offset = offset; this.count = count; return this; }
  }
  const helper = {
    registerChange(_uri, _children, callback) { events.set('media', callback); },
    unRegisterChange() { events.delete('media'); }, async release() {},
    async getAssets(options) {
      queries.push(options);
      const p = options.predicates;
      const selected = assets.filter(a => (!p.only || a.type === 1) && a.addedAt >= p.since).slice(p.offset, p.offset + p.count);
      return { async getAllObjects() { return selected.map(a => ({ uri: a.uri, displayName: a.name,
        get(key) { return ({ size: a.bytes, date_taken: a.takenAt, date_modified: a.modifiedAt, date_added: a.addedAt, owner_album_id: a.owner })[key]; } })); }, close() {} };
    },
    async getAlbums(type) { return { async getAllObjects() { return type === 2048 ? [{ lpath: '/DCIM/Camera', albumName: '相机' }] : []; }, close() {} }; },
    async getAlbumIdByLpath() { return 1; },
  };
  const queue = { items: [], backupCompleted: undefined,
    async setBackupAllowed(value) { allowed.push(value); },
    async uploadPhotos(directory, sources, automatic) {
      uploads.push({ directory, sources, automatic });
      const key = sources[0].backupKey;
      if (state.fail) { throw new Error('upload unavailable'); }
      this.items.push({ id: 'task-' + uploads.length, direction: 'upload', source: 'photoBackup', backupKey: key,
        state: state.unknown ? 'unknown' : 'completed', errorText: state.unknown ? '结果待确认' : '' });
      if (!state.unknown) { await this.backupCompleted(key); }
      return { acceptedIndices: [0], issues: [] };
    },
    async removeRecord(id) {
      const item = this.items.find(item => item.id === id);
      assert.ok(saves.some(snapshot => snapshot.completed.includes(item.backupKey)), 'ledger must precede history cleanup');
      this.items = this.items.filter(item => item.id !== id);
    },
  };
  const connector = { async ensurePhotoDirectory(segments) { return segments.length; } };
  const context = { filesDir: '/private', eventHub: { on(key, callback) { events.set(key, callback); }, off(key) { events.delete(key); } } };
  const mocks = {
    '@kit.AbilityKit': { abilityAccessCtrl: { GrantStatus: { PERMISSION_GRANTED: 0 }, createAtManager() { return {
      async requestPermissionsFromUser() { return { authResults: [state.denied ? -1 : 0] }; },
      verifyAccessTokenSync() { return state.permission ? 0 : -1; },
    }; } }, bundleManager: { BundleFlag: { GET_BUNDLE_INFO_WITH_APPLICATION: 1 }, async getBundleInfoForSelf() { return { appInfo: { accessTokenId: 1 } }; } } },
    '@kit.BasicServicesKit': { deviceInfo: { productModel: 'Phone' }, batteryInfo: { BatteryChargeState: { ENABLE: 1, FULL: 2 }, get chargingStatus() { return state.charging; } } },
    '@kit.CoreFileKit': { fileIo: { async readText(name) { if (!records.has(name)) throw { code: 13900002 }; return records.get(name); } } },
    '@kit.MediaLibraryKit': { photoAccessHelper: { PhotoKeys: { SIZE: 'size', DATE_TAKEN: 'date_taken', DATE_MODIFIED: 'date_modified', DATE_ADDED: 'date_added', OWNER_ALBUM_ID: 'owner_album_id', PHOTO_TYPE: 'type' },
      PhotoType: { IMAGE: 1 }, AlbumType: { SOURCE: 2048, USER: 0 }, AlbumSubtype: { ANY: 2147483647 },
      DefaultChangeUri: { DEFAULT_PHOTO_URI: 'media:change' }, getPhotoAccessHelper() { return helper; } } },
    '@kit.ArkData': { dataSharePredicates: { DataSharePredicates: Predicates } },
    '@kit.NetworkKit': { connection: { NetBearType: { BEARER_WIFI: 1 }, async getDefaultNet() { return { netId: 1 }; }, async getNetCapabilities() { return { bearerTypes: state.wifi ? [1] : [0] }; } } },
    '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } } }, '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
    '../../core/domain/DsmProtocol': protocol, '../../core/domain/PhotoBackupPolicy': policy,
    '../../platform/SdkDigest': { async sha256(bytes) { return Buffer.from(bytes).toString('hex'); } },
    '../../platform/SdkFileIO': { async writePrivateSnapshot(name, bytes) { const text = Buffer.from(bytes).toString(); records.set(name, text); saves.push(JSON.parse(text)); } },
    '../transfers/TransferQueueFiles': { async ensureTransferDirectory() {}, async hashTransferFile(uri, _bytes, current) {
      current(); hashes.push(uri); return assets.find(a => a.uri === uri).content || uri;
    } },
  };
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/backup/AutomaticPhotoBackup.ets'), 'utf8').replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const module = { exports: {} };
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText,
    { module, exports: module.exports, TextEncoder, Date, Error, setInterval() { return 1; }, clearInterval() {}, setTimeout(callback) { queueMicrotask(callback); return 1; },
      require(id) { assert.ok(Object.hasOwn(mocks, id), id); return mocks[id]; } });
  const backup = new module.exports.AutomaticPhotoBackup();
  const settle = async () => { for (let i = 0; i < 10 || backup.scanning; i++) { await new Promise(resolve => setImmediate(resolve)); } };
  await backup.attach(context, connector, queue, 'https://nas.test', 'one'); await settle();
  return { backup, queue, state, records, uploads, queries, saves, events, assets, allowed, settle, context, connector, hashes };
}

test('automatic backup pages a large library, stages one item, persists success before cleanup and resumes without duplicates', async () => {
  const f = await fixture(1051);
  await f.backup.setEnabled(true); await f.settle();
  assert.equal(f.uploads.length, 1051); assert.equal(f.backup.completedCount, 1051); assert.equal(f.queue.items.length, 0);
  assert.ok(f.uploads.every(call => call.sources.length === 1 && call.automatic));
  assert.ok(f.queries.some(query => query.predicates.offset === 1000));
  await f.backup.attach(f.context, f.connector, f.queue, 'https://nas.test', 'one'); await f.settle();
  assert.equal(f.uploads.length, 1051);
  f.assets[0].modifiedAt++; f.backup.scan(); await f.settle(); assert.equal(f.uploads.length, 1052);
  f.backup.detach();
});

test('new mode preserves its anchor across disabling and continue; all reuses success ledger', async () => {
  const f = await fixture();
  await f.backup.configure('new'); await f.settle();
  assert.equal(f.backup.settings.enabled, false);
  assert.equal(f.uploads.length, 0);
  assert.equal(f.saves.at(-1).settings.mode, 'new');
  const anchor = f.backup.settings.since;
  await f.backup.setEnabled(true); await f.settle(); assert.equal(f.uploads.length, 0);
  await f.backup.setEnabled(false); await f.settle();
  await f.backup.configure('continue'); await f.settle(); assert.equal(f.backup.settings.since, anchor);
  await f.backup.configure('all'); await f.backup.setEnabled(true); await f.settle(); assert.equal(f.uploads.length, 1);
  f.backup.scan(); await f.settle(); assert.equal(f.uploads.length, 1); f.backup.detach();
});

test('same-size same-second edits are backed up, while condition polling does not reread an unchanged library', async () => {
  const f = await fixture();
  await f.backup.setEnabled(true); await f.settle();
  const reads = f.hashes.length;
  f.backup.scan(false); await f.settle();
  assert.equal(f.hashes.length, reads);
  f.assets[0].content = 'edited-same-size'; f.events.get('media')({}); await f.settle();
  assert.equal(f.uploads.length, 2);
  assert.equal(f.backup.completedCount, 2);
  f.backup.detach();
});

test('network, charging, image filter and denied media authorization gate backup', async () => {
  const f = await fixture(2);
  f.state.wifi = false; await f.backup.setEnabled(true); await f.settle(); assert.equal(f.uploads.length, 0);
  f.state.wifi = true; f.state.charging = 0;
  await f.backup.configure('all', false, '', 'date', true, true, true); await f.settle(); assert.equal(f.uploads.length, 0);
  f.assets[1].type = 2; f.state.charging = 1; f.backup.scan(); await f.settle(); assert.equal(f.uploads.length, 1);
  await f.backup.setEnabled(false); f.state.denied = true; await f.backup.setEnabled(true); await f.settle();
  assert.equal(f.backup.settings.enabled, false); assert.match(f.backup.errorText, /授权/); f.backup.detach();
});

test('album layout uses one owning source and reports missing owners; unknown results are never replayed', async () => {
  const f = await fixture(2);
  f.assets[1].owner = 0;
  await f.backup.configure('all', false, '', 'album'); await f.backup.setEnabled(true); await f.settle();
  assert.equal(f.uploads.length, 1); assert.equal(f.uploads[0].directory, '/home/Photos/MobileBackup/Phone/相机');
  assert.match(f.backup.errorText, /来源相册/);
  f.backup.detach();
  const g = await fixture(); g.state.unknown = true;
  await g.backup.setEnabled(true); await g.settle(); assert.equal(g.backup.completedCount, 0);
  g.backup.scan(); await g.settle(); assert.equal(g.uploads.length, 1); g.backup.detach();
});
