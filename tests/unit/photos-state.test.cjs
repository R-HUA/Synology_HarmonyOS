const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { TextDecoder } = require('node:util');
const sdkRoot = process.env.HARMONY_SDK_ROOT || path.join(process.env.DEVECO_CLI_CLT_PATH || 'C:/Program Files/command-line-tools', 'sdk/default');
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(relative, mocks = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets', relative), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020,
    module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, Error, Date, Uint8Array, ArrayBuffer,
    require: id => { assert.ok(Object.hasOwn(mocks, id), 'unexpected dependency ' + id); return mocks[id]; } });
  return module.exports;
}
const dsm = load('core/domain/DsmProtocol.ts');
const photos = load('core/domain/PhotosProtocol.ts', { './DsmProtocol': dsm });
const operations = load('core/domain/FileOperations.ts', { './DsmProtocol': dsm });
const queueState = load('core/domain/TransferQueueState.ts', { './DsmProtocol': dsm });
const control = load('core/domain/SystemControl.ts', { './DsmProtocol': dsm });
const drive = load('core/domain/DriveProtocol.ts', { './DsmProtocol': dsm });
const transferContracts = load('core/network/NasTransferTransport.ts', { '../domain/DsmProtocol': dsm });
const driveTransfer = load('core/domain/DriveTransferProtocol.ts', { './DsmProtocol': dsm, './DriveProtocol': drive,
  '../network/NasTransferTransport': transferContracts });
const driveThumbnail = load('core/domain/DriveThumbnailProtocol.ts', { './DsmProtocol': dsm, './DriveProtocol': drive,
  './DriveTransferProtocol': driveTransfer });
const connectorModule = load('core/network/NasConnector.ts', { '../domain/DsmProtocol': dsm,
  '../domain/ReadOnlyProtocol': load('core/domain/ReadOnlyProtocol.ts', { './DsmProtocol': dsm }),
  '../domain/PhotoUpload': load('core/domain/PhotoUpload.ts', { './DsmProtocol': dsm }),
  '../domain/ExtensionProtocol': load('core/domain/ExtensionProtocol.ts', { './DsmProtocol': dsm }),
  './ApiVersionPolicy': load('core/network/ApiVersionPolicy.ts', { '../domain/DsmProtocol': dsm }),
  './SessionRegistry': load('core/network/SessionRegistry.ts', { '../domain/DsmProtocol': dsm }),
  '../capabilities/CapabilityRegistry': load('core/capabilities/CapabilityRegistry.ts', { '../domain/DsmProtocol': dsm,
    '../network/ApiVersionPolicy': load('core/network/ApiVersionPolicy.ts', { '../domain/DsmProtocol': dsm }) }),
  './DsmRpcClient': load('core/network/DsmRpcClient.ts', { '../domain/DsmProtocol': dsm,
    './ApiVersionPolicy': load('core/network/ApiVersionPolicy.ts', { '../domain/DsmProtocol': dsm }) }),
  '../domain/PhotoActions': load('core/domain/PhotoActions.ts', { './DsmProtocol': dsm, './PhotosProtocol': photos }), '../domain/PhotosProtocol': photos, '../domain/FileOperations': operations, '../domain/TransferQueueState': queueState,
  '../domain/DriveProtocol': drive, '../domain/DriveTransferProtocol': driveTransfer,
  '../domain/DriveThumbnailProtocol': driveThumbnail,
  './NasTransferTransport': transferContracts,
  '../domain/SystemControl': control });
const { NasFailure, NasErrorKind: K } = dsm;
const { PhotosSpace: S } = photos;
const isKind = kind => error => error instanceof NasFailure && error.kind === kind;
const failure = kind => new NasFailure(kind, '测试失败');
const plain = value => JSON.parse(JSON.stringify(value));
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });
const bad = code => ({ status: 200, text: JSON.stringify({ success: false, error: { code } }) });
const item = (id, space = S.Personal) => ({ id, space, filename: 'image-' + id + '.jpg', bytes: 8, mediaType: 'photo' });
// 除 documentedItem 原文节选外，wire/item 与媒体响应均为合成合同样本。
const wire = id => ({ id, filename: 'image-' + id + '.jpg', filesize: 8, type: 'photo' });
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const turn = () => new Promise(resolve => setImmediate(resolve));
const log = { hilog: { error() {}, info() {} } };

async function connected(albumVersion = 1) {
  const calls = [];
  const replies = [];
  const capabilities = {};
  for (const name of connectorModule.NAS_DISCOVERY_QUERY.split(',')) capabilities[name] = {
    path: 'entry.cgi', minVersion: 1, maxVersion: name === 'SYNO.API.Auth' ? 6 : name === 'SYNO.FileStation.List' ? 2 :
      name === 'SYNO.Foto.Browse.Album' ? albumVersion : 1,
    requestFormat: 'JSON',
  };
  const connector = new connectorModule.NasConnector({ async post(address, body, session) {
    calls.push({ address, body: new URLSearchParams(body), session });
    assert.ok(replies.length); return replies.shift();
  }, close() {} });
  replies.push(ok(capabilities));
  await connector.discover('https://nas.example.test:5001');
  connector.restoreSession([{ name: 'FileStation', sid: 'private-sid', synoToken: 'private-token' }]);
  return { connector, calls, replies };
}

// 真实社区文档响应节选，仅字段样本；不代表当前 NAS 的实际响应。
// https://github.com/N4S4/synology-photos-api/blob/master/API/SYNO.Foto/SYNO.Foto.Browse.Item.list.md
const documentedItem = { id: 80716, filename: 'IMG_20210723_201314.JPG', filesize: 13078975, type: 'photo', time: 1627071194,
  additional: { orientation: 1, resolution: { height: 4000, width: 6000 },
    thumbnail: { cache_key: '80716_1633859830', m: 'ready', preview: 'broken', sm: 'ready', unit_id: 80716, xl: 'ready' } } };

test('documented fields preserve seconds, dimensions and distinct thumbnail identity; unknown availability is ignored', () => {
  const parsed = photos.decodePhotosPage({ list: [documentedItem] }, S.Personal, 0, 20).items[0];
  assert.equal(parsed.takenAt, 1627071194);
  assert.equal(parsed.width, 6000);
  assert.equal(parsed.height, 4000);
  assert.deepEqual(plain(parsed.thumbnail), { unitId: 80716, cacheKey: '80716_1633859830' });
  const bare = photos.decodePhotosPage({ list: [wire(1)] }, S.Shared, 0, 20).items[0];
  assert.equal(bare.takenAt, undefined);
  assert.equal(bare.thumbnail, undefined);
  for (const changed of [{ time: '1627071194' }, { time: -1 }, { additional: { resolution: { width: '6000' } } },
    { additional: { thumbnail: { unit_id: '80716' } } }, { additional: { thumbnail: { unit_id: 1, cache_key: {} } } }]) {
    assert.throws(() => photos.decodePhotosPage({ list: [{ ...documentedItem, ...changed }] }, S.Personal, 0, 20), isKind(K.Protocol));
  }
});

test('detail and pagination reject identity confusion, duplicate pages and cross-space media requests', () => {
  assert.throws(() => photos.decodePhotoDetail({ list: [wire(2)] }, item(1)), isKind(K.Protocol));
  assert.throws(() => photos.decodePhotoDetail({ list: [] }, item(1)), isKind(K.Protocol));
  assert.throws(() => photos.decodePhotoDetail({ list: [wire(1), wire(2)] }, item(1)), isKind(K.Protocol));
  assert.throws(() => photos.decodePhotoDetail({ list: [wire(1)] }, item(1, S.WithMe)), isKind(K.Unsupported));
  assert.deepEqual(plain(photos.mergePhotoItems([item(1)], [item(1), item(2)], S.Personal)).map(x => x.id), [1, 2]);
  assert.throws(() => photos.mergePhotoItems([], [item(1, S.Shared)], S.Personal), isKind(K.Protocol));
  assert.throws(() => photos.decodePhotoAlbumPage({}, S.Personal, 0, 20), isKind(K.Protocol));
  assert.throws(() => photos.decodePhotoAlbumPage({ list: [] }, S.Personal, Number.MAX_SAFE_INTEGER, 20), isKind(K.InvalidInput));
});

test('connector selects optional independent namespaces and exact album, get and media fields without URL credentials', async () => {
  const { connector, calls, replies } = await connected();
  for (const space of [S.Personal, S.Shared]) {
    const prefix = space === S.Personal ? 'SYNO.Foto.' : 'SYNO.FotoTeam.';
    replies.push(ok({ list: [wire(1)] }));
    await connector.photos(space, 20);
    assert.equal(calls.at(-1).body.get('api'), prefix + 'Browse.Item');
    assert.equal(calls.at(-1).body.get('sort_by'), 'takentime');
    assert.equal(calls.at(-1).body.get('sort_direction'), 'desc');
    assert.deepEqual(JSON.parse(calls.at(-1).body.get('additional')), ['thumbnail', 'resolution', 'orientation']);
    replies.push(ok({ list: [{ id: 5, name: 'My Album Name', item_count: 3, unknown: true }] }));
    const album = (await connector.photoAlbums(space)).items[0];
    assert.equal(album.space, space);
    assert.equal(calls.at(-1).body.get('api'), prefix + 'Browse.Album');
    replies.push(ok({ list: [wire(1)] }));
    await connector.albumPhotos(album);
    assert.equal(calls.at(-1).body.get('id'), '5');
    assert.equal(calls.at(-1).body.has('album_id'), false);
    assert.equal(calls.at(-1).body.has('passphrase'), false);
    replies.push(ok({ list: [wire(1)] }));
    await connector.photoDetail(item(1, space));
    assert.deepEqual(JSON.parse(calls.at(-1).body.get('id')), [1]);
    const sample = { ...item(1, space), thumbnail: { unitId: 77, cacheKey: 'cache' } };
    const thumb = connector.photoThumbnailPlan(sample, 'xl');
    const form = new URLSearchParams(dsm.encodeNasForm(thumb.fields));
    assert.equal(form.get('api'), prefix + 'Thumbnail');
    assert.equal(form.get('id'), '77');
    assert.equal(JSON.parse(form.get('size')), 'xl');
    assert.equal(JSON.parse(form.get('type')), 'unit');
    assert.equal(JSON.parse(form.get('cache_key')), 'cache');
    const original = connector.photoOriginalPlan(sample);
    assert.equal(new URLSearchParams(dsm.encodeNasForm(original.fields)).get('unit_id'), '[1]');
    for (const plan of [thumb, original]) {
      assert.ok(plan.address.startsWith('https://nas.example.test:5001/webapi/'));
      assert.ok(!plan.address.includes('private'));
      assert.ok(!dsm.encodeNasForm(plan.fields).includes('private'));
      assert.equal(plan.session.sid, 'private-sid');
    }
  }
  assert.throws(() => connector.photoOriginalPlan(item(1, S.WithMe)), isKind(K.Unsupported));
});

test('my shared albums use the official v4 shared category and preserve album identity', async () => {
  const { connector, calls, replies } = await connected(4);
  replies.push(ok({ list: [{ id: 17, name: '我的共享相册', item_count: 3 }] }));
  const result = await connector.photoSharedByMeAlbums(20);
  const request = calls.at(-1).body;
  assert.equal(request.get('api'), 'SYNO.Foto.Browse.Album');
  assert.equal(request.get('version'), '4');
  assert.equal(JSON.parse(request.get('category')), 'shared');
  assert.deepEqual(JSON.parse(request.get('additional')), ['thumbnail', 'sharing_info']);
  assert.equal(request.get('offset'), '20');
  assert.equal(request.get('limit'), '20');
  assert.deepEqual(plain(result), { items: [{ id: 17, name: '我的共享相册', itemCount: 3, space: S.Personal }], offset: 20, hasMore: false });
});

test('Photos detail and media expiry first verify the base session and distinguish package rejection from logout', async () => {
  const { connector, replies } = await connected();
  replies.push(bad(119), ok({ shares: [], offset: 0, total: 0 }));
  await assert.rejects(connector.photoDetail(item(1)), isKind(K.Unsupported));
  assert.equal(connector.sessionSnapshot()[0].sid, 'private-sid');
  replies.push(ok({ shares: [], offset: 0, total: 0 }));
  await assert.rejects(connector.photoMediaFailure(failure(K.SessionExpired)), isKind(K.Unsupported));
  replies.push(bad(119));
  await assert.rejects(connector.photoMediaFailure(failure(K.SessionExpired)), isKind(K.SessionExpired));
  assert.equal(connector.sessionSnapshot().length, 0);
});

class MockMedia {
  cleanupErrorText = '';
  attach() {} reset() {} setAccess() {} pinPreview() { return ''; } closeDetail() {} cancelOriginal() {} thumbnailPath() { return ''; }
  async thumbnail() { return '/private/preview'; }
  async original() { return '/private/original'; }
  async exportOriginal() { return false; }
}
let nextScope = 1;
const { PhotoLibrary } = load('features/photos/PhotoLibrary.ets', { '@kit.ArkTS': { util: { generateRandomUUID: () => '11111111-1111-4111-8111-' + String(nextScope++).padStart(12, '0') } }, '@kit.PerformanceAnalysisKit': log,
  '../../core/domain/DsmProtocol': dsm, '../../core/domain/PhotosProtocol': photos, '../../platform/PhotoExif': { readPhotoExif: async () => ({}) }, './PhotoMediaStore': { PhotoMediaStore: MockMedia } });
function library(connector, expired = async () => {}) { connector.supportsPhotoAction ??= () => false; const model = new PhotoLibrary(); model.attach(connector, undefined, expired); return model; }

test('photo selection retains selected identities while paging and clears on space navigation and account reset', async () => {
  const model = library({ async photos(space, offset) { return { items: [item(offset === 0 ? 1 : 2, space)], hasMore: offset === 0 }; } });
  await model.open(S.Personal, 'timeline'); model.beginSelection(); model.toggleSelection(model.items[0]);
  await model.loadMore(); assert.deepEqual(Array.from(model.selectedItems(), entry => entry.id), [1]);
  model.toggleSelection(model.items[1]); assert.deepEqual(Array.from(model.selectedItems(), entry => entry.id), [1, 2]);
  await model.open(S.Shared, 'timeline'); assert.equal(model.selecting, false); assert.equal(model.selectedKeys.length, 0);
  model.beginSelection(); model.toggleSelection(model.items[0]); model.reset(); assert.equal(model.selectedKeys.length, 0);
});

test('photo tabs retain pagination and selected albums without mixing a late response into another tab', async () => {
  const late = deferred(); let delayed = false;
  const model = library({
    async photos(space, offset) { return { items: [item(offset + 1, space)], offset, hasMore: offset === 0 }; },
    async photoAlbums(space, offset) { return delayed ? late.promise : { items: [{ id: 7, name: '相册', itemCount: 1, space }], offset, hasMore: false }; },
    async albumPhotos(album, offset) { return { items: [item(99, album.space)], offset, hasMore: false }; }
  });
  await model.activateTab('photos', S.Personal, 'timeline'); await model.loadMore();
  await model.activateTab('albums', S.Personal, 'albums'); await model.openAlbum(model.albums[0]);
  await model.activateTab('photos', S.Personal, 'timeline'); assert.equal(model.items.length, 2);
  await model.activateTab('albums', S.Personal, 'albums'); assert.equal(model.selectedAlbum.id, 7); assert.equal(model.items[0].id, 99);
  delayed = true;
  const pending = model.activateTab('shared', S.Shared, 'albums');
  await model.activateTab('photos', S.Personal, 'timeline');
  late.resolve({ items: [], offset: 0, hasMore: false }); await pending;
  assert.equal(model.space, S.Personal); assert.equal(model.items.length, 2);
  model.reset(); assert.equal(model.tabContexts.size, 0);
});

test('my shared albums keep their filter through pagination, album contents and return', async () => {
  const calls = [];
  const model = library({
    async photoSharedByMeAlbums(offset) {
      calls.push(['shared', offset]);
      return { items: Array.from({ length: offset === 0 ? 20 : 1 }, (_, i) =>
        ({ id: offset + i, name: '共享相册', itemCount: 1, space: S.Personal })), offset, hasMore: offset === 0 };
    },
    async albumPhotos(album, offset) {
      calls.push(['items', album.id, offset]); return { items: [item(99)], offset, hasMore: false };
    }
  });
  await model.activateTab('shared', S.Personal, 'sharedByMe');
  await model.loadMore();
  assert.equal(model.albums.length, 21);
  await model.openAlbum(model.albums[5]);
  assert.equal(model.items[0].id, 99);
  await model.backToLibrary();
  assert.equal(model.section, 'sharedByMe');
  assert.equal(model.selectedAlbum, undefined);
  assert.equal(model.albums.length, 20);
  assert.deepEqual(calls, [['shared', 0], ['shared', 20], ['items', 5, 0], ['shared', 0]]);
  assert.equal(model.errorText, '');
});

test('timeline pagination appends and deduplicates while advancing by wire row count', async () => {
  const calls = [];
  const model = library({ async photos(space, offset) {
    calls.push(offset);
    return offset === 0 ? { items: Array.from({ length: 20 }, (_, i) => item(i + 1, space)), offset, hasMore: true } :
      { items: [item(20, space), item(21, space)], offset, hasMore: false };
  } });
  await model.open(S.Personal, 'timeline');
  await model.loadMore();
  await model.loadMore();
  assert.deepEqual(calls, [0, 20]);
  assert.equal(model.items.length, 21);
  assert.equal(model.hasMore, false);
  assert.equal(model.busy, false);
  await model.refresh();
  assert.equal(model.items.length, 20);
});

test('album pagination and selecting an album keep its space; WithMe stays in albums', async () => {
  const calls = [];
  const model = library({ async photoAlbums(space, offset) {
    calls.push(['albums', space, offset]); return { items: [{ id: 7, name: '相册', itemCount: 2, space }], offset, hasMore: false };
  }, async albumPhotos(album, offset) {
    calls.push(['items', album.space, offset]); return { items: [item(1, album.space)], offset, hasMore: false };
  } });
  await model.open(S.WithMe, 'timeline');
  assert.equal(model.section, 'albums');
  await model.openAlbum({ ...model.albums[0], space: S.Personal });
  assert.equal(calls.length, 1);
  assert.ok(model.errorText);
  await model.openAlbum(model.albums[0]);
  assert.equal(model.items[0].space, S.WithMe);
  await model.backToLibrary();
  assert.equal(model.selectedAlbum, undefined);
  assert.equal(calls.at(-1)[0], 'albums');
});

test('switching view or account rejects late lists, thumbnails and details; old session errors cannot clear the next account', async () => {
  const late = deferred();
  let expired = 0;
  const model = library({ photos: () => late.promise }, async () => { expired++; });
  const old = model.open(S.Personal);
  model.attach({ async photos() { return { items: [item(2, S.Shared)], offset: 0, hasMore: false }; } }, undefined, async () => { expired++; });
  await model.open(S.Shared);
  late.reject(failure(K.SessionExpired));
  await old;
  assert.equal(expired, 0);
  assert.equal(model.items[0].space, S.Shared);
  assert.equal(model.errorText, '');
  const detail = deferred();
  model.connector = { photoDetail: () => detail.promise };
  const opening = model.openDetail(model.items[0]);
  model.closeDetail();
  detail.resolve(item(2, S.Shared));
  await opening;
  assert.equal(model.detail, undefined);
  assert.equal(model.previewPath, '');
  assert.equal(model.loadingMedia, false);
});

test('a view switch ignores earlier pagination and genuine global expiry invokes the owning VM', async () => {
  const late = deferred();
  let expired = 0;
  const model = library({ photos: () => late.promise,
    async photoAlbums(space) { return { items: [{ id: 3, name: '相册', itemCount: 0, space }], offset: 0, hasMore: false }; }
  }, async () => { expired++; });
  const pending = model.open(S.Personal, 'timeline');
  await model.open(S.Shared, 'albums');
  late.resolve({ items: [item(1)], offset: 0, hasMore: false });
  await pending;
  assert.equal(model.items.length, 0);
  assert.equal(model.albums[0].space, S.Shared);
  model.connector = { async photoAlbums() { throw failure(K.SessionExpired); } };
  await model.refresh();
  assert.equal(expired, 1);
  assert.ok(model.errorText);
});

test('detail and original failures preserve entry points and export cancellation never reports completion', async () => {
  const model = library({ async photos() { return { items: [item(1)], offset: 0, hasMore: false }; },
    async photoDetail() { throw failure(K.Protocol); } });
  await model.open(S.Personal);
  await model.openDetail(model.items[0]);
  assert.equal(model.detail.id, 1);
  assert.ok(model.mediaErrorText);
  assert.equal(model.loadingMedia, false);
  model.media.original = async () => { throw failure(K.Http); };
  await model.loadOriginal();
  assert.equal(model.originalPath, '');
  assert.ok(model.mediaErrorText);
  assert.equal(await model.exportOriginal(), false);
  assert.equal(model.exportNotice, '');
});

test('favorite state is available while the large preview is still loading', async () => {
  const preview = deferred();
  const photo = { ...item(1), favorite: false, thumbnail: { cacheKey: '1', unitId: 1 } };
  const model = library({ async photos() { return { items: [photo], offset: 0, hasMore: false }; },
    async photoDetail() { return photo; } });
  model.media.thumbnail = () => preview.promise;
  await model.open(S.Personal);
  const opening = model.openDetail(model.items[0]);
  await turn();
  assert.equal(model.detail.favorite, false);
  assert.equal(model.loadingMedia, true);
  preview.resolve('/private/preview');
  await opening;
  assert.equal(model.loadingMedia, false);
});

test('swiping follows loaded order, stops at boundaries and ignores a late previous detail', async () => {
  const late = deferred();
  const model = library({ async photos() { return { items: [item(1), item(2), item(3)], offset: 0, hasMore: false }; },
    async photoDetail(photo) { return photo.id === 1 ? late.promise : photo; } });
  await model.open(S.Personal);
  const opening = model.openDetail(model.items[0]);
  await model.switchDetail(-1);
  assert.equal(model.detail.id, 1);
  await model.switchDetail(1);
  late.resolve(item(1));
  await opening;
  assert.equal(model.detail.id, 2);
  await model.switchDetail(1);
  await model.switchDetail(1);
  assert.equal(model.detail.id, 3);
  await model.switchDetail(-1);
  assert.equal(model.detail.id, 2);
});

test('confirmed favorite changes preserve media and cannot modify a different photo', async () => {
  const photo = { ...item(1), favorite: false };
  const model = library({ async photos() { return { items: [photo], offset: 0, hasMore: false }; },
    async photoDetail() { return photo; } });
  await model.open(S.Personal);
  await model.openDetail(model.items[0]);
  model.originalPath = '/private/original';
  model.previewPath = '/private/preview';
  model.confirmFavorite(model.detail, true);
  assert.equal(model.detail.favorite, true);
  assert.equal(model.items[0].favorite, true);
  assert.equal(model.originalPath, '/private/original');
  assert.equal(model.previewPath, '/private/preview');
  const previous = model.detail;
  model.confirmFavorite(previous, false);
  assert.equal(model.detail.favorite, false);
  model.confirmFavorite(previous, true);
  assert.equal(model.detail.favorite, false);
});

test('swiping loads the next page and leaving detail cancels a pending page transition', async () => {
  const page = deferred();
  const model = library({ async photos(space, offset) {
    return offset === 0 ? { items: [item(1)], offset, hasMore: true } : page.promise;
  }, async photoDetail(photo) { return photo; } });
  await model.open(S.Personal);
  await model.openDetail(model.items[0]);
  const switching = model.switchDetail(1);
  model.closeDetail();
  page.resolve({ items: [item(2)], offset: 1, hasMore: false });
  await switching;
  assert.equal(model.detail, undefined);
  await model.openDetail(model.items[0]);
  await model.switchDetail(1);
  assert.equal(model.detail.id, 2);
});

const jpeg = new Uint8Array([255, 216, 255, 224, 0, 0, 0, 0]);
function mediaCheck(overrides = {}) {
  const values = { status: 200, type: 'image/jpeg', length: '8', received: 8, prefix: jpeg, text: '', thumbnail: true, expected: undefined, ...overrides };
  return photos.validatePhotoMediaResponse('SYNO.Foto.Thumbnail', values.status, values.type, values.length,
    values.received, values.prefix, values.text, values.thumbnail, values.expected);
}

test('binary validation rejects HTTP/redirect, JSON business errors, HTML, short/oversized data and incompatible content', () => {
  mediaCheck();
  for (const status of [206, 302, 401, 403, 500]) assert.throws(() => mediaCheck({ status }), isKind(K.Http));
  for (const input of [{ received: 0 }, { received: photos.PHOTO_THUMBNAIL_MAX_BYTES + 1 }, { length: '7' },
    { length: '8x' }, { type: 'text/html', text: '<html>' }, { type: 'application/zip' },
    { type: 'image/jpeg', prefix: new Uint8Array(8) }]) assert.throws(() => mediaCheck(input), isKind(K.Protocol));
  assert.throws(() => mediaCheck({ type: 'application/json', text: JSON.stringify({ success: false, error: { code: 119 } }) }), isKind(K.SessionExpired));
  assert.throws(() => mediaCheck({ text: JSON.stringify({ success: false, error: { code: 105 } }) }), isKind(K.Permission));
  assert.throws(() => mediaCheck({ type: 'application/json', text: JSON.stringify({ success: true, data: {} }) }), isKind(K.Protocol));
  assert.throws(() => mediaCheck({ thumbnail: false, expected: 9 }), isKind(K.Protocol));
  assert.throws(() => mediaCheck({ thumbnail: false, received: photos.PHOTO_ORIGINAL_MAX_BYTES + 1 }), isKind(K.Protocol));
});


test('shared owner metadata selects FotoTeam only for integer zero and otherwise Foto; missing metadata never guesses', async () => {
  const { connector } = await connected();
  const access = { albumId: 3, scope: 'shared-scope', passphrase: 'memory-only-passphrase' };
  for (const owner of [0, 7]) {
    const parsed = photos.decodePhotosPage({ list: [{ ...wire(1), owner_user_id: owner,
      additional: { thumbnail: { unit_id: 88, cache_key: 'shared-cache', xl: 'future-status' } } }] }, S.WithMe, 0, 20).items[0];
    assert.equal(parsed.sourceSpace, owner === 0 ? S.Shared : S.Personal);
    assert.equal(parsed.space, S.WithMe);
    assert.equal(Object.hasOwn(parsed, 'passphrase'), false);
    const thumbnail = connector.photoThumbnailPlan(parsed, 'xl', access);
    const original = connector.photoOriginalPlan(parsed, access);
    const prefix = owner === 0 ? 'SYNO.FotoTeam.' : 'SYNO.Foto.';
    for (const [plan, suffix] of [[thumbnail, 'Thumbnail'], [original, 'Download']]) {
      const body = new URLSearchParams(dsm.encodeNasForm(plan.fields));
      assert.equal(body.get('api'), prefix + suffix);
      assert.equal(JSON.parse(body.get('cache_key')), 'shared-cache');
      assert.equal(JSON.parse(body.get('passphrase')), access.passphrase);
      assert.ok(!plan.address.includes(access.passphrase));
      assert.ok(!plan.address.includes('private-sid'));
    }
    assert.equal(new URLSearchParams(dsm.encodeNasForm(thumbnail.fields)).get('id'), '1');
    assert.equal(new URLSearchParams(dsm.encodeNasForm(original.fields)).get('unit_id'), '[1]');
    const without = connector.photoOriginalPlan(parsed, { ...access, passphrase: '' });
    assert.equal(new URLSearchParams(dsm.encodeNasForm(without.fields)).has('passphrase'), false);
  }
  for (const owner of [-1, 0.5, '0', null, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => photos.decodePhotosPage({ list: [{ ...wire(1), owner_user_id: owner }] }, S.WithMe, 0, 20), isKind(K.Protocol));
  }
  const unknown = photos.decodePhotosPage({ list: [{ ...wire(1), additional: { thumbnail: { cache_key: 'cache' } } }] }, S.WithMe, 0, 20).items[0];
  assert.equal(unknown.sourceSpace, undefined);
  assert.throws(() => connector.photoOriginalPlan(unknown, access), isKind(K.Unsupported));
  assert.throws(() => connector.photoThumbnailPlan(unknown, 'm', access), isKind(K.Unsupported));
  assert.throws(() => connector.photoOriginalPlan({ ...item(1), sourceSpace: S.Shared }), isKind(K.Protocol));
  assert.throws(() => photos.decodePhotoDetail({ list: [{ ...wire(1), owner_user_id: 0 }] }, item(1)), isKind(K.Protocol));
});

test('shared media credential strings follow discovered scalar format without changing array/numeric fields', async () => {
  const { connector } = await connected();
  const access = { albumId: 3, scope: 'scope-album3', passphrase: 'secret with &+=中文' };
  const shared = { ...item(1, S.WithMe), sourceSpace: S.Personal, thumbnail: { unitId: 1, cacheKey: 'cache with &' } };
  for (const capability of connector.capabilities) capability.jsonParameters = false;
  const thumbnail = connector.photoThumbnailPlan(shared, 'm', access);
  const form = new URLSearchParams(dsm.encodeNasForm(thumbnail.fields));
  assert.equal(form.get('passphrase'), access.passphrase);
  assert.equal(form.get('cache_key'), shared.thumbnail.cacheKey);
  assert.equal(form.get('type'), 'unit');
  assert.equal(form.get('size'), 'm');
  assert.equal(form.get('id'), '1');
  assert.equal(new URLSearchParams(dsm.encodeNasForm(connector.photoOriginalPlan(shared, access).fields)).get('unit_id'), '[1]');
});

test('shared media HTTP401 and package119 recheck base login; permission refusal keeps the verified base session', async () => {
  const { connector, replies, calls } = await connected();
  for (const error of [new NasFailure(K.Http, 'shared HTTP401', 401), new NasFailure(K.SessionExpired, 'shared119', 119)]) {
    replies.push(ok({ shares: [], offset: 0, total: 0 }));
    await assert.rejects(connector.photoMediaFailure(error), isKind(error.kind === K.Http ? K.Permission : K.Unsupported));
    assert.equal(calls.at(-1).body.get('api'), 'SYNO.FileStation.List');
    assert.equal(connector.sessionSnapshot()[0].sid, 'private-sid');
  }
  const count = calls.length;
  await assert.rejects(connector.photoMediaFailure(new NasFailure(K.Http, 'denied', 403)), isKind(K.Permission));
  assert.equal(calls.length, count);
  assert.equal(connector.sessionSnapshot()[0].sid, 'private-sid');
});

test('shared library details use trusted list metadata, isolate album credential contexts and clear them on close', async () => {
  let gets = 0;
  const credential = 'never-in-ui-or-path';
  const connector = { async photoAlbums(space) { return { items: [
    { id: 3, name: '共享相册3', itemCount: 1, space, passphrase: credential },
    { id: 4, name: '共享相册4', itemCount: 1, space, passphrase: 'other-passphrase' } ], offset: 0, hasMore: false }; },
    async albumPhotos() { return { items: [{ ...item(1, S.WithMe), sourceSpace: S.Shared,
      thumbnail: { unitId: 1, cacheKey: 'shared-cache' } }], offset: 0, hasMore: false }; },
    async photoDetail() { gets++; throw new Error('shared get must not be called'); } };
  const model = library(connector);
  const accesses = [];
  model.media.setAccess = access => { if (access) accesses.push(access); };
  await model.open(S.WithMe);
  assert.ok(model.albums.every(album => album.passphrase === undefined));
  await model.openAlbum(model.albums[0]);
  await model.openDetail(model.items[0]);
  assert.equal(gets, 0);
  assert.equal(model.detail.id, 1);
  assert.equal(model.detail.passphrase, undefined);
  assert.equal(model.detailAccess.passphrase, credential);
  model.closeDetail();
  assert.equal(model.detailAccess, undefined);
  await model.backToLibrary();
  assert.equal(model.selectedAlbum, undefined);
  assert.equal(model.selectedAccess, undefined);
  assert.equal(model.detailAccess, undefined);
  await model.openAlbum(model.albums[1]);
  assert.equal(accesses[1].albumId, 4);
  assert.notEqual(accesses[1].scope, accesses[0].scope);
  assert.equal(accesses[1].passphrase, 'other-passphrase');
  model.reset();
  assert.equal(model.selectedAccess, undefined);
  assert.equal(model.albumPassphrases.size, 0);
});

test('external taken time must be representable by Date without substituting missing time', () => {
  assert.throws(() => photos.decodePhotosPage({ list: [{ ...wire(1), time: Number.MAX_SAFE_INTEGER }] }, S.Personal, 0, 20), isKind(K.Protocol));
  assert.throws(() => photos.decodePhotosPage({ list: [{ ...wire(1), time: 8640000000001 }] }, S.Personal, 0, 20), isKind(K.Protocol));
  assert.equal(photos.decodePhotosPage({ list: [{ ...wire(1), time: 8640000000000 }] }, S.Personal, 0, 20).items[0].takenAt, 8640000000000);
  assert.equal(photos.decodePhotosPage({ list: [wire(1)] }, S.Personal, 0, 20).items[0].takenAt, undefined);
});
