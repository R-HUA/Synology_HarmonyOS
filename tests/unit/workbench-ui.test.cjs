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
  workbenchBottomInset, workbenchShortcutColumns, photoAlbumColumns, photoAlbumRows,
  workbenchUsageLevel, workbenchRelativeDate, workbenchProtocolHint,
  workbenchFileGridColumns, workbenchFileGridMetadata } = moduleFixture.exports;
const plain = value => JSON.parse(JSON.stringify(value));
const item = (id, year, month) => ({ id, space: 0, filename: '照片.jpg', bytes: 12, mediaType: 'photo',
  ...(year === undefined ? {} : { takenAt: new Date(year, month - 1, 15, 12).getTime() / 1000 }) });

test('photo columns adapt to narrow, unfolded and wide content containers', () => {
  assert.equal(photoGridColumns(240), 3);
  assert.equal(photoGridColumns(360), 4);
  assert.equal(photoGridColumns(500), 4);
  assert.equal(photoGridColumns(700), 6);
  assert.equal(photoGridColumns(1440), 6);
});

test('pagination append keeps dates and does not merge different months or unknown timestamps', () => {
  const rows = plain(photoTimelineRows([item(1, 2026, 10), item(2, 2026, 10), item(3, 2026, 10),
    item(4, 2026, 10), item(5, 2026, 9), item(6)], 3));
  assert.deepEqual(rows.map(row => row.title), ['2026年10月15日', '', '2026年9月15日', '拍摄时间未提供']);
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
  assert.equal(workbenchShortcutColumns(280), 3);
  assert.equal(workbenchShortcutColumns(360), 4);
  assert.equal(workbenchShortcutColumns(840), 4);
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

test('file grid uses its own viewport width with at least three columns and real gutters', () => {
  for (const [width, columns] of [[200, 3], [320, 3], [360, 3], [419, 3], [420, 4], [440, 4], [600, 5], [840, 8]]) {
    assert.equal(workbenchFileGridColumns(width), columns);
    if (width >= 320) assert.ok((width - 32 - (columns - 1) * 12) / columns >= 88);
  }
  assert.notEqual(workbenchFileGridColumns(840), workbenchFileGridColumns(360));
});

test('file grid metadata excludes folder type and invented size or child counts', () => {
  const modified = new Date(2020, 0, 2, 12).getTime() / 1000;
  assert.equal(workbenchFileGridMetadata(true, modified, 1024), '2020/01/02');
  assert.equal(workbenchFileGridMetadata(false, modified, 1024), '2020/01/02\n1.0 KB');
  assert.equal(workbenchFileGridMetadata(true, undefined, undefined), '');
  assert.equal(workbenchFileGridMetadata(false, undefined, undefined), '');
  assert.equal(workbenchFileGridMetadata(false, undefined, 0), '0 B');
});

test('usage level thresholds distinguish normal, warning and danger capacity', () => {
  assert.equal(workbenchUsageLevel(undefined), 'normal');
  assert.equal(workbenchUsageLevel(0), 'normal');
  assert.equal(workbenchUsageLevel(74.9), 'normal');
  assert.equal(workbenchUsageLevel(75), 'warning');
  assert.equal(workbenchUsageLevel(89.9), 'warning');
  assert.equal(workbenchUsageLevel(90), 'danger');
  assert.equal(workbenchUsageLevel(100), 'danger');
});

test('relative dates format today, yesterday and historical dates deterministically', () => {
  const now = new Date(2026, 9, 22, 14, 30, 0).getTime();
  const todayMorning = new Date(2026, 9, 22, 8, 5, 0).getTime() / 1000;
  const yesterdayEvening = new Date(2026, 9, 21, 19, 45, 0).getTime() / 1000;
  const earlierDate = new Date(2026, 2, 7, 10, 0, 0).getTime() / 1000;
  assert.equal(workbenchRelativeDate(undefined, now), '');
  assert.equal(workbenchRelativeDate(todayMorning, now), '今天 08:05');
  assert.equal(workbenchRelativeDate(yesterdayEvening, now), '昨天 19:45');
  assert.equal(workbenchRelativeDate(earlierDate, now), '2026/03/07');
});

test('protocol hint reflects explicit schemes, ports and default HTTPS/HTTP ports', () => {
  assert.equal(workbenchProtocolHint('', true), '默认使用 HTTPS 加密连接（端口 443，可附加 :5001）');
  assert.equal(workbenchProtocolHint('', false), '当前选择 HTTP 明文连接（端口 80，可附加 :5000）');
  assert.equal(workbenchProtocolHint('192.168.1.10', true), '将通过 https://192.168.1.10 连接（未指定端口，若使用 DSM 默认端口请加 :5001）');
  assert.equal(workbenchProtocolHint('192.168.1.10', false), '将通过 http://192.168.1.10 连接（未指定端口，若使用 DSM 默认端口请加 :5000）');
  assert.equal(workbenchProtocolHint('192.168.1.10:5001', true), '将通过 https://192.168.1.10:5001 连接');
  assert.equal(workbenchProtocolHint('https://nas.local:8443/', true), '将通过 https://nas.local:8443 连接');
});
