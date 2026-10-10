const { test } = require('node:test');
const assert = require('node:assert/strict');
const p = require('../../work/core-build/domain/DriveThumbnailProtocol.js');
const d = require('../../work/core-build/domain/DriveProtocol.js');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');
const png = new Uint8Array([137,80,78,71,13,10,26,10,0]);
const reply = over => ({ status: 200, contentType: 'image/png', contentLength: String(png.length),
  contentDisposition: '', bytes: png.length, prefix: png, prefixText: '', ...over });
const isKind = kind => e => e instanceof NasFailure && e.kind === kind;

test('file type assets use the observed 128 path and restrict extensions to a single safe segment', () => {
  const base = '/webman/3rdparty/SynologyDrive-Drive/images/_Asset/FileType/128/';
  assert.equal(p.driveFileTypeIconPath('报告.TXT'), base + 'txt.png');
  assert.equal(p.driveFileTypeIconPath('照片', true), base + 'folder.png');
  for (const name of ['a.jpg', 'a.PNG', 'a.heic', 'a.webp']) {
    assert.equal(p.driveFileTypeIconPath(name), base + 'image.png');
  }
  for (const name of ['a.mp4', 'a.MOV', 'a.webm']) {
    assert.equal(p.driveFileTypeIconPath(name), base + 'video.png');
  }
  assert.equal(p.driveFileTypeIconPath('archive.tar.gz'), base + 'gz.png');
  for (const name of ['README', '.hidden', 'report.', 'a.../secret', 'a.txt?token=1', 'a.汉字']) {
    assert.equal(p.driveFileTypeIconPath(name), base + 'xxx.png');
  }
});

test('thumbnail request matches the target web list, preserves long IDs and omits absent revisions', () => {
  assert.deepEqual(p.driveThumbnailFields({ fileId: '976700457026108129', versionId: '976700457026108130' }), [
    { name: 'path', content: '"id:976700457026108129"' }, { name: 'size', content: '"small"' },
    { name: 'version_id', content: '"976700457026108130"' }
  ]);
  assert.equal(p.driveThumbnailFields({ fileId: '1', SynoToken: 'injected' }).length, 2);
  for (const invalid of ['', 'id:1', '1.2', '123456789012345678901']) {
    assert.throws(() => p.driveThumbnailFields({ fileId: invalid }), isKind(K.InvalidInput));
    assert.throws(() => p.driveThumbnailFields({ fileId: '1', versionId: invalid }), isKind(K.InvalidInput));
  }
});

test('revision decoding preserves precision and absent revision does not fabricate one', () => {
  const data = d.decodeDriveResponse(d.DRIVE_FILES_API, 200,
    '{"success":true,"data":{"items":[{"file_id":"1","name":"a.jpg","type":"file","version_id":976700457026108130}]}}');
  assert.equal(d.decodeDriveEntryList(data)[0].versionId, '976700457026108130');
  assert.equal(d.decodeDriveEntry({ file_id: '1', name: 'a.jpg', type: 'file' }).versionId, undefined);
  assert.throws(() => d.decodeDriveEntry({ file_id: '1', name: 'a.jpg', type: 'file', version_id: 'bad' }), isKind(K.Protocol));
});

test('thumbnail eligibility requires read and preview permissions for a supported media file', () => {
  const entry = { name: 'a.JPG', kind: d.DriveEntryKind.File, capabilities: { canRead: true, canPreview: true } };
  assert.equal(p.canLoadDriveThumbnail(entry), true);
  for (const override of [{ name: 'a.txt' }, { kind: d.DriveEntryKind.Folder },
    { capabilities: { canRead: true } }, { capabilities: { canPreview: true } }]) {
    assert.equal(p.canLoadDriveThumbnail({ ...entry, ...override }), false);
  }
});

test('thumbnail response rejects login/error bodies, redirects, overflow, truncation and fake images', () => {
  p.validateDriveThumbnail(reply());
  for (const over of [{ bytes: 0 }, { bytes: p.DRIVE_THUMBNAIL_MAX_BYTES + 1 },
    { contentLength: '100' }, { prefix: new Uint8Array([1,2,3]) }, { contentType: 'text/html' },
    { contentType: 'image/svg+xml' }]) {
    assert.throws(() => p.validateDriveThumbnail(reply(over)), isKind(K.Protocol));
  }
  assert.throws(() => p.validateDriveThumbnail(reply({ status: 302 })), isKind(K.Http));
  const text = '{"success":false,"error":{"code":119}}';
  assert.throws(() => p.validateDriveThumbnail(reply({ bytes: text.length, contentLength: '', prefixText: text,
    prefix: new TextEncoder().encode(text), contentType: 'application/json' })), isKind(K.SessionExpired));
});
