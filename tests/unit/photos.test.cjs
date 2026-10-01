const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { decodePhotosPage, decodeSharedAlbumPage, PhotosSpace } = require('../../work/core-build/domain/PhotosProtocol.js');
const { decodeNasResponse, NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');
const fixture = JSON.parse(fs.readFileSync('tests/contract_fixtures/photos-items.json', 'utf8'));
const valid = () => ({ id: 1, filename: '测试照片.jpg', filesize: 0, type: 'photo' });
const isKind = kind => error => error instanceof NasFailure && error.kind === kind;
const page = (rows, space = PhotosSpace.Personal, offset = 0, limit = 20) =>
  decodePhotosPage({ list: rows }, space, offset, limit);

test('Photos contract fixture is synthetic and maps all three original string media types', () => {
  assert.equal(fixture.provenance.kind, 'synthetic-contract-example');
  const data = decodeNasResponse('SYNO.Foto.Browse.Item', 200, JSON.stringify(fixture.response));
  assert.deepEqual(decodePhotosPage(data, PhotosSpace.Personal, 0, 20), {
    items: [
      { id: 101, filename: '示例照片.jpg', bytes: 2048, space: PhotosSpace.Personal, mediaType: 'photo' },
      { id: 102, filename: '示例视频.mp4', bytes: 4096, space: PhotosSpace.Personal, mediaType: 'video' },
      { id: 103, filename: '示例实况照片.heic', bytes: 0, space: PhotosSpace.Personal, mediaType: 'live' }
    ], offset: 0, hasMore: false
  });
});

test('the same item ID in personal and shared spaces preserves separate identities', () => {
  const personal = page([valid()], PhotosSpace.Personal).items[0];
  const shared = page([valid()], PhotosSpace.Shared).items[0];
  assert.equal(personal.id, shared.id);
  assert.equal(personal.space, PhotosSpace.Personal);
  assert.equal(shared.space, PhotosSpace.Shared);
  assert.notDeepEqual(personal, shared);
});

test('an explicit empty visible list is valid without total or server offset', () => {
  assert.deepEqual(page([], PhotosSpace.Shared, 20), { items: [], offset: 20, hasMore: false });
  assert.equal(page([valid()]).items[0].bytes, 0);
});

test('invalid envelopes and missing lists cannot silently become empty libraries', () => {
  for (const data of [null, undefined, '', '<html>login</html>', [], {}, { files: [] },
    { list: null }, { list: {} }, { list: '' }, { success: false, error: { code: 105 } },
    { success: true, data: { list: [] } }]) {
    assert.throws(() => decodePhotosPage(data, PhotosSpace.Personal, 0, 20), isKind(K.Protocol));
  }
});

test('required identity, filename, size and media type are checked without default values', () => {
  for (const field of ['id', 'filename', 'filesize', 'type']) {
    const row = valid();
    delete row[field];
    assert.throws(() => page([row]), isKind(K.Protocol));
  }
  const invalidRows = [null, [], 'photo',
    ...[-1, 1.5, '1', null, Number.MAX_SAFE_INTEGER + 1].map(id => ({ ...valid(), id })),
    ...['', 7, null].map(filename => ({ ...valid(), filename })),
    ...[-1, 1.5, '0', null, Number.MAX_SAFE_INTEGER + 1].map(filesize => ({ ...valid(), filesize })),
    ...['', 'image', 'Photo', 'unknown', 0, 1, null].map(type => ({ ...valid(), type }))];
  for (const row of invalidRows) assert.throws(() => page([row]), isKind(K.Protocol));
});

test('duplicate item IDs and oversized pages are rejected', () => {
  assert.throws(() => page([valid(), { ...valid(), filename: '另一照片.jpg' }]), isKind(K.Protocol));
  assert.throws(() => page(Array.from({ length: 21 }, (_, index) => ({ ...valid(), id: index + 1 }))), isKind(K.Protocol));
});

test('space and pagination boundaries cannot produce invalid or overflowing next offsets', () => {
  for (const offset of [-1, 0.5, '0', NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => page([], PhotosSpace.Personal, offset), isKind(K.InvalidInput));
  }
  for (const limit of [-1, 0, 0.5, '20', NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => page([], PhotosSpace.Personal, 0, limit), isKind(K.InvalidInput));
  }
  assert.throws(() => page([], PhotosSpace.Personal, Number.MAX_SAFE_INTEGER, 1), isKind(K.InvalidInput));
  for (const space of [-1, 3, 'Personal', undefined]) {
    assert.throws(() => decodePhotosPage({ list: [] }, space, 0, 20), isKind(K.InvalidInput));
  }
});

// 请求与字段来源：TREK 的原始实现及其测试样本，非本项目真机抓包。
// https://github.com/liketrek/TREK/blob/main/server/src/nest/memories/synology.service.ts#L419
// https://github.com/liketrek/TREK/blob/main/server/tests/unit/nest/synology.service.test.ts#L219
const album = () => ({ id: 3, name: '共享相册', item_count: 3 });
const albumPage = (rows, offset = 0, limit = 20) => decodeSharedAlbumPage({ list: rows }, offset, limit);

test('shared-with-me album fields and both original passphrase locations are preserved', () => {
  assert.deepEqual(albumPage([
    { ...album(), id: 1, passphrase: 'direct' },
    { ...album(), id: 2, sharing_info: { passphrase: 'nested' } },
    { ...album(), id: 3, passphrase: '', sharing_info: { passphrase: 'fallback' } },
    { ...album(), id: 4, passphrase: 'preferred', sharing_info: { passphrase: 'other' } }
  ]).items, [
    { id: 1, name: '共享相册', itemCount: 3, passphrase: 'direct' },
    { id: 2, name: '共享相册', itemCount: 3, passphrase: 'nested' },
    { id: 3, name: '共享相册', itemCount: 3, passphrase: 'fallback' },
    { id: 4, name: '共享相册', itemCount: 3, passphrase: 'preferred' }
  ]);
});

test('absent or empty sharing credentials are valid without invented values', () => {
  for (const row of [album(), { ...album(), passphrase: '' },
    { ...album(), sharing_info: {} }, { ...album(), sharing_info: { passphrase: '' } }]) {
    assert.deepEqual(albumPage([row]).items, [{ id: 3, name: '共享相册', itemCount: 3 }]);
  }
  assert.deepEqual(albumPage([], 20), { items: [], offset: 20, hasMore: false });
  assert.equal(albumPage([{ ...album(), item_count: 0 }]).items[0].itemCount, 0);
});

test('album identity, name and item count are required and strictly typed', () => {
  for (const field of ['id', 'name', 'item_count']) {
    const row = album();
    delete row[field];
    assert.throws(() => albumPage([row]), isKind(K.Protocol));
  }
  for (const row of [null, [], 'album',
    ...[-1, 1.5, '3', null, Number.MAX_SAFE_INTEGER + 1].map(id => ({ ...album(), id })),
    ...['', 3, null].map(name => ({ ...album(), name })),
    ...[-1, 1.5, '3', null, Number.MAX_SAFE_INTEGER + 1].map(item_count => ({ ...album(), item_count }))]) {
    assert.throws(() => albumPage([row]), isKind(K.Protocol));
  }
});

test('malformed optional sharing fields are errors instead of discarded credentials', () => {
  for (const row of [
    ...[null, 3, {}, []].map(passphrase => ({ ...album(), passphrase })),
    ...[null, '', 3, []].map(sharing_info => ({ ...album(), sharing_info })),
    ...[null, 3, {}, []].map(passphrase => ({ ...album(), sharing_info: { passphrase } }))
  ]) assert.throws(() => albumPage([row]), isKind(K.Protocol));
});

test('invalid album envelopes, duplicate identities and oversized pages cannot look empty', () => {
  for (const data of [null, '<html>login</html>', [], {}, { list: null }, { list: {} },
    { success: false, error: { code: 105 } }, { success: true, data: { list: [] } }]) {
    assert.throws(() => decodeSharedAlbumPage(data, 0, 20), isKind(K.Protocol));
  }
  assert.throws(() => albumPage([album(), { ...album(), name: '同一身份' }]), isKind(K.Protocol));
  assert.throws(() => albumPage(Array.from({ length: 21 }, (_, id) => ({ ...album(), id }))), isKind(K.Protocol));
});

test('shared album pagination validates boundaries and full pages only suggest more', () => {
  for (const offset of [-1, 0.5, '0', NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => albumPage([], offset), isKind(K.InvalidInput));
  }
  for (const limit of [-1, 0, 0.5, '20', NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => albumPage([], 0, limit), isKind(K.InvalidInput));
  }
  assert.throws(() => albumPage([], Number.MAX_SAFE_INTEGER, 1), isKind(K.InvalidInput));
  const rows = Array.from({ length: 20 }, (_, id) => ({ ...album(), id }));
  assert.equal(albumPage(rows).hasMore, true);
  assert.equal(albumPage(rows.slice(0, 19), 20).hasMore, false);
});

test('new shared-album fields are ignored and received photos retain their own source', () => {
  assert.deepEqual(decodeSharedAlbumPage({ list: [{ ...album(), owner_user_id: 7,
    shared: false, new_field: true, sharing_info: { future_field: 1 } }], future_page: true }, 0, 20).items,
  [{ id: 3, name: '共享相册', itemCount: 3 }]);
  const received = page([valid()], PhotosSpace.WithMe).items[0];
  const personal = page([valid()], PhotosSpace.Personal).items[0];
  assert.equal(received.space, PhotosSpace.WithMe);
  assert.notDeepEqual(received, personal);
});

test('sharing list business failures remain failures before album decoding', () => {
  for (const [code, kind] of [[105, K.Permission], [119, K.SessionExpired]]) {
    assert.throws(() => decodeSharedAlbumPage(decodeNasResponse('SYNO.Foto.Sharing.Misc', 200,
      JSON.stringify({ success: false, error: { code }, data: { list: [] } })), 0, 20), isKind(kind));
  }
});

test('new JSON fields and unavailable thumbnails do not break the minimal read contract', () => {
  const row = { ...valid(), new_server_field: { value: true }, additional: { thumbnail: { sm: 'notready', preview: 'broken' } } };
  const result = decodePhotosPage({ list: [row], new_page_field: 'future' }, PhotosSpace.Personal, 0, 20);
  assert.deepEqual(result.items, [{ id: 1, filename: '测试照片.jpg', bytes: 0, space: PhotosSpace.Personal, mediaType: 'photo' }]);
});

test('a full first batch of 20 suggests another page, while short and empty batches stop', () => {
  const rows = Array.from({ length: 20 }, (_, index) => ({ ...valid(), id: index + 1 }));
  assert.equal(page(rows).hasMore, true);
  assert.deepEqual(page(rows.slice(0, 19), PhotosSpace.Personal, 20), {
    items: page(rows.slice(0, 19)).items, offset: 20, hasMore: false
  });
  assert.equal(page([], PhotosSpace.Personal, 40).hasMore, false);
});

test('HTTP, business permission and session failures remain failures before page decoding', () => {
  for (const api of ['SYNO.Foto.Browse.Item', 'SYNO.FotoTeam.Browse.Item']) {
    for (const [code, kind] of [[105, K.Permission], [119, K.SessionExpired]]) {
      const response = JSON.stringify({ success: false, error: { code }, data: { list: [] } });
      assert.throws(() => decodePhotosPage(decodeNasResponse(api, 200, response), PhotosSpace.Personal, 0, 20), isKind(kind));
    }
    assert.throws(() => decodeNasResponse(api, 403, '{}'), isKind(K.Http));
    assert.throws(() => decodeNasResponse(api, 200, '<html>login</html>'), isKind(K.Protocol));
  }
});
