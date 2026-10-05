const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.join(__dirname, '../../entry/src/main/ets');
const index = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
const browser = fs.readFileSync(path.join(root, 'features/drive/DriveBrowserModel.ets'), 'utf8');

// 执行原始方法体，只替换平台依赖；不在测试中复制导航逻辑。
function method(source, name) {
  const match = source.match(new RegExp('^  (?:private )?(?:async )?' + name + '\\([^]*?^  }', 'm'));
  assert.ok(match, name);
  const compiled = ts.transpileModule('class Subject {\n' + match[0] + '\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  });
  return vm.runInNewContext(compiled.outputText + '\nSubject.prototype.' + name, {
    DriveEntryKind: { Folder: 'folder', File: 'file' }, DriveView: { Trash: 'trash' }
  });
}
function page() {
  const calls = [];
  return {
    calls, fileSource: 'drive', activeTab: 1,
    navStack: { size: () => 0, pop() { calls.push('pop'); }, clear() {} },
    backup: { reset() {} }, tabsController: { changeIndex() {} },
    updateTelemetryMode() {}, switchTab(index) { this.activeTab = index; calls.push('tab:' + index); },
    model: { authenticated: true, directory: '/hidden', busy: false, extensions: {},
      goBack() { calls.push('station-back'); },
      drive: { busy: false, available: true, canGoUp: () => true,
        goUp() { calls.push('drive-up'); }, open() { calls.push('drive-open'); },
        openFolder() { calls.push('drive-folder'); } } }
  };
}

test('system back navigates only the visible file source and consumes a busy Drive back', () => {
  const back = method(index, 'onBackPress');
  const state = page();
  assert.equal(back.call(state), true);
  assert.deepEqual(state.calls, ['drive-up']);
  state.calls.length = 0;
  state.model.drive.busy = true;
  assert.equal(back.call(state), true);
  assert.deepEqual(state.calls, []);
  state.model.drive.canGoUp = () => false;
  back.call(state);
  assert.deepEqual(state.calls, ['tab:0']);
  state.calls.length = 0;
  state.activeTab = 1; state.fileSource = 'station';
  back.call(state);
  assert.deepEqual(state.calls, ['station-back']);
});

test('download destination enters File Station and both destination flows lock source switching', () => {
  const state = page();
  method(index, 'chooseDownloadDirectory').call(state);
  assert.equal(state.fileSource, 'station');
  assert.equal(state.choosingDownloadTarget, true);
  assert.equal(state.activeTab, 1);
  const switchSource = method(index, 'switchFileSource');
  switchSource.call(state, 'drive');
  assert.equal(state.fileSource, 'station');
  state.choosingDownloadTarget = false; state.choosingBackupTarget = true;
  switchSource.call(state, 'drive');
  assert.equal(state.fileSource, 'station');
  state.choosingBackupTarget = false;
  switchSource.call(state, 'drive');
  assert.equal(state.fileSource, 'drive');
  assert.ok(state.calls.includes('drive-open'));
  // ArkUI 构建器无法在 Node 中执行，单独检查备份入口与来源控件绑定。
  assert.match(index, /this\.choosingDownloadTarget = false; this\.fileSource = 'station';\s*this\.choosingBackupTarget = true; this\.switchTab\(1\)/);
  assert.match(index, /available: this\.model\.drive\.available && !this\.choosingDownloadTarget && !this\.choosingBackupTarget/);
});

test('authentication loss resets the source so the next Drive selection loads again', () => {
  const state = page();
  state.model.authenticated = false;
  method(index, 'authenticationChanged').call(state);
  assert.equal(state.fileSource, 'station');
  assert.equal(state.activeTab, 0);
  state.model.authenticated = true;
  method(index, 'switchFileSource').call(state, 'drive');
  assert.ok(state.calls.includes('drive-open'));
});

test('unreadable entries cannot enter through either UI or model', async () => {
  const entry = { name: 'restricted', fileId: '123', kind: 'folder', capabilities: { canRead: false } };
  const state = page();
  method(index, 'openDriveEntry').call(state, entry);
  assert.deepEqual(state.calls, []);
  let loads = 0;
  const model = { busy: false, trail: [], async load(trail) { loads++; this.trail = trail; return true; } };
  const openFolder = method(browser, 'openFolder');
  await openFolder.call(model, entry);
  assert.equal(loads, 0);
  assert.equal(model.trail.length, 0);
  entry.capabilities.canRead = true;
  await openFolder.call(model, entry);
  assert.equal(loads, 1);
  assert.equal(model.trail[0].fileId, '123');
  assert.match(index, /available: !this\.model\.drive\.busy && entry\.capabilities\.canRead/);
});

test('Drive file action downloads only readable permitted live files and opens the Drive task section', () => {
  const state = page();
  state.model.driveTransfers = { download() { state.calls.push('drive-download'); } };
  state.openDriveTransfers = () => state.calls.push('drive-tasks');
  const open = method(index, 'openDriveEntry');
  const file = { name: '记录.txt', kind: 'file', capabilities: { canRead: true, canDownload: true } };
  open.call(state, file);
  assert.deepEqual(state.calls, ['drive-download', 'drive-tasks']);
  state.calls.length = 0;
  state.model.drive.view = 'trash';
  open.call(state, file);
  assert.deepEqual(state.calls, []);
  state.model.drive.view = 'mydrive';
  open.call(state, { ...file, capabilities: { canRead: true, canDownload: false } });
  open.call(state, { ...file, capabilities: { canRead: false, canDownload: true } });
  assert.deepEqual(state.calls, []);
});
