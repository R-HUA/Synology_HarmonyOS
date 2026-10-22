const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const base = path.join(__dirname, '../../entry/src/main/ets');
const presentationModule = { exports: {} };
const presentation = ts.transpileModule(fs.readFileSync(path.join(base, 'features/workbench/WorkbenchPresentation.ts'), 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
vm.runInNewContext(presentation.outputText, { module: presentationModule, exports: presentationModule.exports, Date });
const functions = presentationModule.exports;
const pageSource = fs.readFileSync(path.join(base, 'features/photos/PhotoModulePage.ets'), 'utf8');

// 运行页面实际的分行和视口方法，UI DSL 交由综合 ArkTS 构建验证。
function method(name) {
  const match = new RegExp('  private ' + name + '\\([^\\n]*\\)[^\\n]*\\{').exec(pageSource);
  assert.ok(match, 'missing page method ' + name);
  const start = match.index; const open = pageSource.indexOf('{', start);
  let depth = 1, end = open + 1;
  for (; depth > 0 && end < pageSource.length; end++) {
    if (pageSource[end] === '{') depth++;
    if (pageSource[end] === '}') depth--;
  }
  assert.equal(depth, 0);
  return pageSource.slice(start, end).replace('private ', '');
}
const harness = ts.transpileModule('class PhotoPageHarness {' + method('columns') + method('syncRows') + method('syncDemand') + '} module.exports = PhotoPageHarness;',
  { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
assert.equal((harness.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
const pageModule = { exports: {} }; const groups = [];
vm.runInNewContext(harness.outputText, { module: pageModule, ScrollAlign: { START: 'start' }, ...functions,
  photoTimelineRows(items, columns, previous) { groups.push(items.map(i => i.id)); return functions.photoTimelineRows(items, columns, previous); } });
const item = (id, month = 9) => ({ id, space: 0, filename: '照片.jpg', takenAt: new Date(2026, month - 1, 15, 12).getTime() / 1000 });
function fixture(width = 360) {
  const viewport = []; const releases = []; const scrolls = [];
  const p = new pageModule.exports();
  const library = { items: [], albums: [], dataGeneration: 1,
    updateViewport(...args) { viewport.push(args); }, releaseView(id) { releases.push(id); } };
  Object.assign(p, { model: { photoLibrary: library }, previousPhotos: [], previousAlbums: [], groupGeneration: -1,
    photoColumns: 0, albumColumns: 0, timelineRows: [], albumRows: [], mounted: true, viewVisible: true,
    viewId: 'photo-view', startIndex: 0, endIndex: -1, contentWidth: width, contentHeight: 640,
    topInset: 64, bottomInset: 80, scrolling: false, active: true,
    canShowLibrary() { return this.active; }, visiblePhotos() { return library.items; }, visibleAlbums() { return library.albums; },
    scroller: { scrollToIndex(...args) { scrolls.push(args); } } });
  groups.length = 0;
  return { p, library, viewport, releases, scrolls };
}

test('page keeps existing row identities on append and thumbnail-only changes do not invoke grouping', () => {
  const { p, library } = fixture();
  library.items = Array.from({ length: 20 }, (_, i) => item(i + 1)); p.syncRows();
  const first = p.timelineRows[0]; const oldRows = p.timelineRows;
  p.syncDemand(); p.syncRows();
  assert.strictEqual(p.timelineRows, oldRows); assert.equal(groups.length, 1);
  library.items = library.items.concat([item(21), item(22, 10)]); p.syncRows();
  assert.strictEqual(p.timelineRows[0], first);
  assert.deepEqual(groups.at(-1), [21, 22]);
  assert.equal(p.timelineRows.at(-1).title, '2026年10月15日');
  assert.equal(p.timelineRows.flatMap(row => row.items).length, 22);
  const beforeResize = p.timelineRows;
  p.contentWidth = 700; p.syncRows();
  assert.notStrictEqual(p.timelineRows, beforeResize);
  assert.equal(groups.at(-1).length, 22);
});

test('page derives visible rows from List indexes and requests only one adjacent row on each side', () => {
  const { p, library, viewport, releases } = fixture();
  library.items = Array.from({ length: 60 }, (_, i) => item(i + 1)); p.syncRows();
  p.startIndex = 4; p.endIndex = 7; p.syncDemand();
  const demand = viewport.at(-1);
  assert.deepEqual(Array.from(demand[1], i => i.id), Array.from({ length: 16 }, (_, i) => i + 13));
  assert.deepEqual(Array.from(demand[2], i => i.id), [9, 10, 11, 12, 29, 30, 31, 32]);
  assert.equal(demand[3], false);
  p.startIndex = 17; p.endIndex = 20; p.syncDemand();
  assert.equal(viewport.at(-1)[3], true, 'prefetch the next page when less than one visible screen remains');
  p.active = false; p.syncDemand();
  assert.deepEqual(releases, ['photo-view']);
});

test('short first page automatically requests filling and a column change retains the leading photo anchor', () => {
  const { p, library, viewport, scrolls } = fixture();
  library.items = [item(1), item(2)]; p.syncRows();
  assert.equal(viewport.at(-1)[3], true); assert.equal(viewport.at(-1)[4], 2);
  library.items = Array.from({ length: 40 }, (_, i) => item(i + 1)); p.syncRows();
  p.startIndex = 5; p.endIndex = 8;
  const anchor = p.timelineRows[4].items[0].id;
  p.contentWidth = 700; p.syncRows();
  const index = scrolls.at(-1)[0] - 1;
  assert.ok(p.timelineRows[index].items.some(i => i.id === anchor));
  assert.equal(p.endIndex, -1, 'column changes re-estimate the visible range until List reports its new indexes');
});

test('album append fills only its tail and preserves prior row objects', () => {
  const albums = Array.from({ length: 5 }, (_, i) => ({ id: i + 1, space: 0 }));
  const rows = functions.photoAlbumRows(albums, 2);
  const next = functions.photoAlbumRows([{ id: 6, space: 0 }, { id: 7, space: 0 }], 2, rows);
  assert.strictEqual(next[0], rows[0]); assert.strictEqual(next[1], rows[1]);
  assert.deepEqual(Array.from(next[2].albums, a => a.id), [5, 6]);
  assert.deepEqual(Array.from(next[3].albums, a => a.id), [7]);
  assert.strictEqual(functions.photoAlbumRows([], 2, next), next);
});
