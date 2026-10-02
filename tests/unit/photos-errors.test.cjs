const { test } = require('node:test');
const assert = require('node:assert/strict');
const { NasConnector } = require('../../work/core-build/network/NasConnector.js');
const { NasFailure, NasErrorKind, selectNasApi } = require('../../work/core-build/domain/DsmProtocol.js');
const { PhotosSpace } = require('../../work/core-build/domain/PhotosProtocol.js');

const photoApis = ['SYNO.Foto.Browse.Item', 'SYNO.FotoTeam.Browse.Item', 'SYNO.Foto.Browse.Album',
  'SYNO.FotoTeam.Browse.Album', 'SYNO.Foto.Sharing.Misc', 'SYNO.Foto.Thumbnail', 'SYNO.FotoTeam.Thumbnail',
  'SYNO.Foto.Download', 'SYNO.FotoTeam.Download'];
const descriptor = (version = 1) => ({ path: 'entry.cgi', minVersion: version, maxVersion: version });
const media = space => ({ id: 1, filename: '照片.jpg', bytes: 12, space, mediaType: 'photo', thumbnail: { unitId: 1 } });
const unsupportedMessage = operation => '当前服务器不支持' + operation + '，请检查 Synology Photos 套件版本及空间设置。';
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });

async function connected(changeCapabilities = () => {}) {
  const capabilities = { 'SYNO.API.Auth': descriptor(6), 'SYNO.FileStation.List': descriptor(2),
    'SYNO.FileStation.Download': descriptor(2) };
  for (const name of photoApis) { capabilities[name] = descriptor(); }
  changeCapabilities(capabilities);
  const transport = {
    calls: [], replies: [ok(capabilities), ok({ sid: 'test-sid', synotoken: 'test-token' })],
    async post(address, body) {
      this.calls.push({ address, body });
      assert.ok(this.replies.length, 'unexpected network request');
      const reply = this.replies.shift();
      if (reply instanceof Error) { throw reply; }
      return reply;
    },
    close() {}
  };
  const connector = new NasConnector(transport);
  await connector.discover('https://nas.example.test:5001');
  await connector.login('reader', 'test-password', '');
  return { connector, transport };
}

const boundaries = [
  { api: 'SYNO.Foto.Browse.Item', operation: '浏览个人空间照片', call: connector => connector.photos(PhotosSpace.Personal) },
  { api: 'SYNO.FotoTeam.Browse.Item', operation: '浏览共享空间照片', call: connector => connector.photos(PhotosSpace.Shared) },
  { api: 'SYNO.Foto.Browse.Album', operation: '浏览个人空间相册', call: connector => connector.photoAlbums(PhotosSpace.Personal) },
  { api: 'SYNO.FotoTeam.Browse.Album', operation: '浏览共享空间相册', call: connector => connector.photoAlbums(PhotosSpace.Shared) },
  { api: 'SYNO.Foto.Sharing.Misc', operation: '浏览分享给我的相册', call: connector => connector.sharedAlbums() },
  { api: 'SYNO.Foto.Sharing.Misc', operation: '浏览分享给我的相册', call: connector => connector.photoAlbums(PhotosSpace.WithMe) },
  { api: 'SYNO.Foto.Browse.Item', operation: '浏览个人空间照片', call: connector => connector.sharedAlbumPhotos({ id: 1, name: '相册', itemCount: 1 }) },
  { api: 'SYNO.Foto.Browse.Item', operation: '浏览个人空间照片', call: connector => connector.photoDetail(media(PhotosSpace.Personal)) },
  { api: 'SYNO.Foto.Thumbnail', operation: '读取个人空间照片缩略图', call: connector => connector.photoThumbnailPlan(media(PhotosSpace.Personal)) },
  { api: 'SYNO.FotoTeam.Thumbnail', operation: '读取共享空间照片缩略图', call: connector => connector.photoThumbnailPlan(media(PhotosSpace.Shared)) },
  { api: 'SYNO.Foto.Download', operation: '下载个人空间照片或视频原文件', call: connector => connector.photoOriginalPlan(media(PhotosSpace.Personal)) },
  { api: 'SYNO.FotoTeam.Download', operation: '下载共享空间照片或视频原文件', call: connector => connector.photoOriginalPlan(media(PhotosSpace.Shared)) }
];

test('missing and incompatible photo capabilities have Chinese errors without changing session or issuing writes', async () => {
  for (const boundary of boundaries) {
    for (const incompatible of [false, true]) {
      const { connector, transport } = await connected(capabilities => {
        if (incompatible) { capabilities[boundary.api] = descriptor(2); }
        else { delete capabilities[boundary.api]; }
      });
      await assert.rejects(async () => boundary.call(connector), error => {
        assert.ok(error instanceof NasFailure);
        assert.equal(error.kind, NasErrorKind.Unsupported);
        assert.equal(error.code, 0);
        assert.equal(error.message, unsupportedMessage(boundary.operation));
        assert.doesNotMatch(error.message, /SYNO\./);
        return true;
      });
      assert.equal(transport.calls.length, 2);
      assert.equal(connector.sessionSnapshot().sid, 'test-sid');
    }
  }
});

test('photo business unsupported errors retain their code and get the same Chinese presentation', async () => {
  const { connector, transport } = await connected();
  transport.replies.push({ status: 200, text: JSON.stringify({ success: false, error: { code: 104 } }) });
  await assert.rejects(connector.photoAlbums(PhotosSpace.Shared), error =>
    error instanceof NasFailure && error.kind === NasErrorKind.Unsupported && error.code === 104 &&
    error.message === unsupportedMessage('浏览共享空间相册'));
  assert.equal(connector.sessionSnapshot().sid, 'test-sid');
});

test('generic capability errors remain unchanged outside photo call boundaries', async () => {
  const name = 'SYNO.FileStation.Download';
  const expected = '服务器不支持已验证的 ' + name + ' 接口版本。';
  const original = error => error instanceof NasFailure && error.kind === NasErrorKind.Unsupported && error.message === expected;
  assert.throws(() => selectNasApi([], name, [2]), original);
  const { connector } = await connected(capabilities => { delete capabilities[name]; });
  assert.throws(() => connector.transferDownloadPlan('/share/文件.txt'), original);
});

test('photo presentation leaves permission, transport and pre-login errors unchanged', async () => {
  const { connector, transport } = await connected();
  for (const error of [new NasFailure(NasErrorKind.Permission, '原权限提示', 105), new Error('原网络错误')]) {
    transport.replies.push(error);
    await assert.rejects(connector.photos(PhotosSpace.Personal), received => received === error);
  }
  const signedOut = new NasConnector(transport);
  await assert.rejects(signedOut.photos(PhotosSpace.Personal), error =>
    error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired && error.message === '请先登录 NAS。');
  assert.equal(connector.sessionSnapshot().sid, 'test-sid');
});
