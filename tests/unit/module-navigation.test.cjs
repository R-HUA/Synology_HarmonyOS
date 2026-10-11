const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/workbench/ModuleNavigation.ts'), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
const fixture = { exports: {} };
vm.runInNewContext(compiled.outputText, { module: fixture, exports: fixture.exports,
  require(id) { return require('../../work/core-build/domain/' + id.split('/').at(-1) + '.js'); } });
const n = fixture.exports;
const { DriveView: V } = require('../../work/core-build/domain/DriveProtocol.js');
const ids = tabs => Array.from(tabs, tab => tab.id);

test('root navigation has home files tasks and settings in stable order', () => {
  assert.deepEqual(ids(n.rootTabs()), ['home', 'files', 'tasks', 'settings']);
});
test('Drive hides unsupported roots and has no entrance without a supported browse view', () => {
  assert.deepEqual(ids(n.driveTabs(() => false, [])), []);
  assert.deepEqual(ids(n.driveTabs(v => v === V.TeamFolders, [])), ['teamFolders', 'more']);
});
test('Drive promotions are deduplicated filtered and capped at two with a five-tab limit', () => {
  const pinned = [V.Search, V.MyDrive, V.Recent, V.Recent, V.Starred, V.Trash];
  assert.deepEqual(ids(n.driveTabs(() => true, pinned)), ['mydrive', 'teamFolders', 'recent', 'starred', 'more']);
  assert.deepEqual(Array.from(n.driveMoreViews(() => true, pinned)), [V.SharedWithMe, V.SharedWithOthers, V.Trash]);
  assert.deepEqual(ids(n.driveTabs(v => v !== V.Recent, pinned)), ['mydrive', 'teamFolders', 'starred', 'trash', 'more']);
});
test('Photos backup requires personal photo upload and folder APIs', () => {
  assert.deepEqual(ids(n.photoTabs(() => false, true, [])), []);
  assert.deepEqual(ids(n.photoTabs(api => api === 'SYNO.Foto.Browse.Item', true, [])), ['photos', 'albums', 'more']);
  assert.deepEqual(ids(n.photoTabs(api => api === 'SYNO.FileStation.Upload', true, ['backup'])), []);
  assert.deepEqual(ids(n.photoTabs(api => ['SYNO.Foto.Upload.Item', 'SYNO.Foto.Browse.Folder', 'SYNO.Foto.Browse.Item'].includes(api), true, ['backup'])), ['photos', 'albums', 'backup', 'more']);
  assert.equal(n.supportsPhotoBackup(api => ['SYNO.FileStation.Upload', 'SYNO.Foto.Browse.Item'].includes(api)), false);
});
test('Photos sharing can move to more and promotions respect the five-tab maximum', () => {
  assert.deepEqual(ids(n.photoTabs(api => ['SYNO.Foto.Browse.Item', 'SYNO.Foto.Browse.Album'].includes(api), true, [])),
    ['photos', 'albums', 'shared', 'more']);
  assert.deepEqual(ids(n.photoTabs(() => true, true, ['backup', 'transfers'])), ['photos', 'albums', 'shared', 'backup', 'more']);
  assert.deepEqual(ids(n.photoTabs(() => true, false, ['backup', 'transfers'])), ['photos', 'albums', 'backup', 'transfers', 'more']);
});
test('index recovery uses page identity when capability gates or customization change positions', () => {
  const tabs = n.driveTabs(() => true, [V.Recent]);
  assert.equal(n.moduleTabIndex(tabs, 'recent'), 2);
  assert.equal(n.moduleTabIndex(tabs, 'unsupported'), 0);
  assert.equal(n.rootReturnIndex(2), 2);
  for (const bad of [-1, 4, NaN, 1.5]) assert.equal(n.rootReturnIndex(bad), 0);
});
test('settings decoder rejects invalid persisted values and normalizes allowed tab identifiers', () => {
  assert.throws(() => n.decodeModuleTabSettings('{broken'));
  assert.throws(() => n.decodeModuleTabSettings('{"drivePinned":[],"photoPinned":[],"showPhotoShared":"yes"}'));
  const settings = n.decodeModuleTabSettings('{"drivePinned":["recent","recent","trash","search"],"photoPinned":["backup","transfers","backup"],"showPhotoShared":false}');
  assert.deepEqual(Array.from(settings.drivePinned), ['recent', 'trash']);
  assert.deepEqual(Array.from(settings.photoPinned), ['backup', 'transfers']);
  assert.equal(settings.showPhotoShared, false);
});


test('photo pinned order survives persisted settings and reconstructs the same bottom bar', () => {
  const before = n.photoTabs(() => true, false, ['transfers', 'backup']);
  const saved = JSON.stringify({ drivePinned: [], photoPinned: ['transfers', 'backup'], showPhotoShared: false });
  const restored = n.decodeModuleTabSettings(saved);
  assert.deepEqual(Array.from(restored.photoPinned), ['transfers', 'backup']);
  assert.deepEqual(ids(n.photoTabs(() => true, restored.showPhotoShared, restored.photoPinned)), ids(before));
});
