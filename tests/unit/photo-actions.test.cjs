const { test } = require('node:test');
const assert = require('node:assert/strict');
const { photoActionRequest, decodePhotoActionResult } = require('../../work/core-build/domain/PhotoActions.js');
const { decodePhotosPage, PhotosSpace: S } = require('../../work/core-build/domain/PhotosProtocol.js');
const { decodeExtensionWrites } = require('../../work/core-build/domain/ExtensionWriteState.js');
const { NasConnector } = require('../../work/core-build/network/NasConnector.js');
const { NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');
const { NasTransferCancellation } = require('../../work/core-build/network/NasTransferTransport.js');
const item = { id: 42, space: S.Personal, filename: '照片.jpg', bytes: 8, mediaType: 'photo' };
const fields = request => Object.fromEntries(request.fields.map(field => [field.name, field.content]));
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });

test('Photos uses source-specific mutation contracts and never treats received album items as writable', () => {
  const favorite = photoActionRequest({ action: 'favorite', item, favorite: true });
  assert.equal(favorite.api, 'SYNO.Foto.Browse.Item'); assert.equal(favorite.version, 7);
  assert.deepEqual(fields(favorite), { id: '[42]', favorite: 'true' });
  const copy = photoActionRequest({ action: 'copy', item: { ...item, space: S.Shared }, targetId: 10 });
  assert.equal(copy.api, 'SYNO.FotoTeam.BackgroundTask.File'); assert.equal(copy.method, 'copy');
  assert.deepEqual(fields(copy), { item_id: '[42]', folder_id: '[]', target_folder_id: '10', action: '"skip"' });
  const album = photoActionRequest({ action: 'album', item, targetId: 9 });
  assert.deepEqual(fields(album), { id: '9', item: '[42]' });
  for (const action of ['favorite', 'delete', 'album', 'share', 'copy']) {
    assert.throws(() => photoActionRequest({ action, item: { ...item, space: S.WithMe }, favorite: true, targetId: 10 }), error => error.kind === K.Unsupported);
  }
  assert.throws(() => photoActionRequest({ action: 'copy', item, targetId: -1 }));
});

test('background receipt is accepted rather than completed; an uncorrelated result is rejected', () => {
  const input = { action: 'delete', item };
  assert.deepEqual(decodePhotoActionResult(input, { task_info: { id: 12 } }), { completed: false, taskId: 12 });
  assert.throws(() => decodePhotoActionResult(input, {}));
  assert.throws(() => decodePhotoActionResult(input, { task_info: { id: '12' } }));
});

test('photo metadata accepts optional EXIF values and rejects malformed favorite flags', () => {
  const row = { id: 42, filename: item.filename, filesize: 8, type: 'photo', is_favorite: true,
    additional: { exif: { camera: '相机', iso: 500 }, description: '日落',
      address: { country: '中国', state: '江苏', city: '南京', county: '南京', route: '' }, tag: [{ id: 2, name: '旅行' }] } };
  const detail = decodePhotosPage({ list: [row] }, S.Personal, 0, 20).items[0];
  assert.equal(detail.favorite, true); assert.equal(detail.exif.iso, '500'); assert.equal(detail.description, '日落');
  assert.equal(detail.address, '中国，江苏，南京'); assert.deepEqual(detail.tags, ['旅行']);
  assert.equal(decodePhotosPage({ list: [{ ...row, additional: { description: '' } }] }, S.Personal, 0, 20).items[0].description, '');
  assert.throws(() => decodePhotosPage({ list: [{ ...row, is_favorite: 'true' }] }, S.Personal, 0, 20));
});

test('pending photo identity and task survive account-scoped persistence; invalid sources cannot replay', () => {
  const pending = [{ feature: 'photos', operation: 'copy', createdAt: 1, photoId: 42, photoSpace: S.Shared, taskId: 12 }];
  const text = value => JSON.stringify({ version: 1, scope: 'account', pending: value });
  assert.deepEqual(decodeExtensionWrites(text(pending), 'account'), pending);
  assert.throws(() => decodeExtensionWrites(text([{ ...pending[0], photoSpace: S.WithMe }]), 'account'));
  assert.throws(() => decodeExtensionWrites(text(pending), 'another-account'));
});

test('favorite is read from item additional metadata, including an explicit false', () => {
  const row = { id: 42, filename: item.filename, filesize: 8, type: 'photo' };
  for (const favorite of [true, false]) {
    assert.equal(decodePhotosPage({ list: [{ ...row, additional: { favorite } }] }, S.Personal, 0, 1).items[0].favorite, favorite);
  }
  assert.equal(decodePhotosPage({ list: [row] }, S.Personal, 0, 1).items[0].favorite, undefined);
  assert.throws(() => decodePhotosPage({ list: [{ ...row, additional: { favorite: 'false' } }] }, S.Personal, 0, 1),
    error => error.kind === K.Protocol);
});

async function fixture() {
  const calls = [], replies = [];
  const capabilities = { 'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 6 } };
  for (const name of ['SYNO.Foto.BackgroundTask.Info', 'SYNO.Foto.Browse.Item', 'SYNO.Foto.Browse.NormalAlbum',
    'SYNO.Foto.Sharing.Passphrase', 'SYNO.FileStation.Download', 'SYNO.FileStation.Thumb']) {
    capabilities[name] = { path: 'entry.cgi', minVersion: 1, maxVersion: name === 'SYNO.Foto.Browse.Item' ? 7 : 2, requestFormat: 'JSON' };
  }
  const connector = new NasConnector({ async post(address, body) { calls.push({ address, body: new URLSearchParams(body) }); return replies.shift(); },
    close() {}, transfers: { async download(request, target, control, validate) {
      calls.push({ request, target, control });
      validate({ status: 200, contentType: 'image/png', contentLength: '8', contentDisposition: '', bytes: 8,
        prefix: Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10]), prefixText: '' });
      return { path: target.directory + '/image', bytes: 8, discard() {} };
    } } });
  replies.push(ok(capabilities)); await connector.discover('https://nas.example.test');
  connector.restoreSession([{ name: 'FileStation', sid: 'synthetic-sid', synoToken: 'synthetic-token' }]);
  return { connector, calls, replies };
}

test('Photos task completion must match the persisted task; empty or wrong results remain uncertain', async () => {
  const f = await fixture();
  for (const data of [{ list: [] }, { list: [{ id: 13, status: 'done' }] }]) {
    f.replies.push(ok(data)); await assert.rejects(f.connector.photoTaskDone(12));
  }
  f.replies.push(ok({ list: [{ id: 12, status: 'processing' }] })); assert.equal(await f.connector.photoTaskDone(12), false);
  f.replies.push(ok({ list: [{ id: 12, status: 'done' }] })); assert.equal(await f.connector.photoTaskDone(12), true);
  f.replies.push(ok({ list: [{ id: 12, status: 'done', total: 1, completion: 0 }] }));
  await assert.rejects(f.connector.photoTaskDone(12), error => error.kind === K.Server);
});

test('Photos shares a new album only after its public view permission is confirmed; partial writes remain uncertain', async () => {
  const f = await fixture();
  f.replies.push(ok({ album: { id: 10, passphrase: 'synthetic-share' } }), ok({}));
  const result = await f.connector.photoAction({ action: 'share', item });
  assert.equal(result.completed, true); assert.equal(result.sharePassphrase, 'synthetic-share');
  const body = f.calls.at(-1).body;
  assert.equal(body.get('api'), 'SYNO.Foto.Sharing.Passphrase'); assert.equal(body.get('method'), 'update');
  assert.equal(body.get('passphrase'), '"synthetic-share"');
  assert.deepEqual(JSON.parse(body.get('permission')), [{ action: 'update', role: 'view', member: { type: 'public' } }]);
  f.replies.push(ok({ album: { id: 11, passphrase: 'synthetic-share-2' } }),
    { status: 200, text: JSON.stringify({ success: false, error: { code: 105 } }) });
  await assert.rejects(f.connector.photoAction({ action: 'share', item }), error => error.kind === K.Protocol);
});

test('File Station preview selects Thumb first, Download only for original, and keeps authorization private', async () => {
  const f = await fixture();
  const control = { cancellation: new NasTransferCancellation() };
  for (const original of [false, true]) {
    await f.connector.fileImage('/photo/日落.jpg', { directory: '/private/image', maximumBytes: 100, expectedBytes: original ? 8 : undefined }, control, original);
    const request = f.calls.at(-1).request, query = fields(request);
    assert.equal(query.api, original ? 'SYNO.FileStation.Download' : 'SYNO.FileStation.Thumb');
    assert.equal(query.path, original ? '["/photo/日落.jpg"]' : '"/photo/日落.jpg"');
    assert.equal(request.session.sid, 'synthetic-sid'); assert.equal(request.address.includes('sid'), false);
    assert.equal(query._sid, undefined);
  }
});
