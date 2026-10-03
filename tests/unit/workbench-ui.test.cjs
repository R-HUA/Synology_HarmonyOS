const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/workbench/WorkbenchPresentation.ts'), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
const moduleFixture = { exports: {} };
vm.runInNewContext(compiled.outputText, { module: moduleFixture, exports: moduleFixture.exports, Date });
const { photoGridColumns, photoTimelineRows, photoTakenDate, photoMediaLabel,
  workbenchBottomInset, workbenchShortcutColumns, photoAlbumColumns, photoAlbumRows } = moduleFixture.exports;
const plain = value => JSON.parse(JSON.stringify(value));
const item = (id, year, month) => ({ id, space: 0, filename: '照片.jpg', bytes: 12, mediaType: 'photo',
  ...(year === undefined ? {} : { takenAt: new Date(year, month - 1, 15, 12).getTime() / 1000 }) });

test('photo columns adapt to narrow, unfolded and wide content containers', () => {
  assert.equal(photoGridColumns(240), 2);
  assert.equal(photoGridColumns(360), 3);
  assert.equal(photoGridColumns(500), 4);
  assert.equal(photoGridColumns(700), 6);
  assert.equal(photoGridColumns(1440), 6);
});

test('pagination append keeps dates and does not merge different months or unknown timestamps', () => {
  const rows = plain(photoTimelineRows([item(1, 2026, 10), item(2, 2026, 10), item(3, 2026, 10),
    item(4, 2026, 10), item(5, 2026, 9), item(6)], 3));
  assert.deepEqual(rows.map(row => row.title), ['2026年10月', '', '2026年9月', '拍摄时间未提供']);
  assert.deepEqual(rows.map(row => row.items.map(photo => photo.id)), [[1, 2, 3], [4], [5], [6]]);
  assert.equal(new Set(rows.map(row => row.key)).size, rows.length);
});

test('resizing the photo grid retains every item and identity', () => {
  const items = Array.from({ length: 17 }, (_, id) => item(id, 2026, 10));
  for (const columns of [2, 3, 4, 6]) {
    const rows = plain(photoTimelineRows(items, columns));
    assert.deepEqual(rows.flatMap(row => row.items.map(photo => photo.id)), items.map(photo => photo.id));
    assert.ok(rows.every(row => row.items.length <= columns));
  }
});

test('photo date and media labels show absent metadata and distinguish video and live photos', () => {
  assert.equal(photoTakenDate(item(1)), '拍摄时间未提供');
  assert.equal(photoTakenDate(item(2, 2026, 10)), '2026年10月15日');
  assert.equal(photoMediaLabel({ mediaType: 'video' }), '视频');
  assert.equal(photoMediaLabel({ mediaType: 'live' }), '动态照片');
  assert.equal(photoMediaLabel({ mediaType: 'photo' }), '照片');
  assert.deepEqual(plain(photoTimelineRows([], 3)), []);
});

test('floating navigation clearance follows the actual system navigation area', () => {
  assert.equal(workbenchBottomInset(0), 72);
  assert.equal(workbenchBottomInset(24), 96);
  assert.equal(workbenchBottomInset(40), 112);
  assert.equal(workbenchBottomInset(24, 64), 104);
});

test('shortcut and album layouts adapt at content width boundaries', () => {
  assert.equal(workbenchShortcutColumns(360), 5);
  assert.equal(workbenchShortcutColumns(840), 5);
  assert.equal(photoAlbumColumns(240), 1);
  assert.equal(photoAlbumColumns(360), 2);
  assert.equal(photoAlbumColumns(600), 3);
  assert.equal(photoAlbumColumns(840), 4);
});

test('album resizing preserves every album, its source space and partial final row', () => {
  const albums = Array.from({ length: 9 }, (_, index) => ({
    id: index % 3, space: Math.floor(index / 3), name: '相册 ' + index, itemCount: index
  }));
  for (const columns of [1, 2, 3, 4]) {
    const rows = plain(photoAlbumRows(albums, columns));
    assert.deepEqual(rows.flatMap(row => row.albums), albums);
    assert.equal(new Set(rows.map(row => row.key)).size, rows.length);
    assert.ok(rows.every(row => row.albums.length > 0 && row.albums.length <= columns));
  }
  assert.deepEqual(plain(photoAlbumRows([], 2)), []);
});
