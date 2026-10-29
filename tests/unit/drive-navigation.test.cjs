const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.join(__dirname, '../../entry/src/main/ets');
const index = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
const browser = fs.readFileSync(path.join(root, 'features/drive/DriveBrowserModel.ets'), 'utf8');
const drivePage = fs.readFileSync(path.join(root, 'features/drive/DriveModulePage.ets'), 'utf8');
const photoPage = fs.readFileSync(path.join(root, 'features/photos/PhotoModulePage.ets'), 'utf8');
const filePage = fs.readFileSync(path.join(root, 'features/files/FileStationPage.ets'), 'utf8');
const drive = require('../../work/core-build/domain/DriveProtocol.js');
const photos = require('../../work/core-build/domain/PhotosProtocol.js');
const { DriveView: V } = drive;
const { PhotosSpace: P } = photos;
const taskStateModule = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'features/tasks/TaskPageState.ets'), 'utf8')
  .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, ''), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText, { module: taskStateModule, exports: taskStateModule.exports });
const navFixture = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'features/workbench/ModuleNavigation.ts'), 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText, { module: navFixture, exports: navFixture.exports,
  require(id) { return require('../../work/core-build/domain/' + id.split('/').at(-1) + '.js'); } });
const globals = { ...navFixture.exports, DriveEntryKind: drive.DriveEntryKind, DriveView: V, PhotosSpace: P,
  TaskPageState: taskStateModule.exports.TaskPageState,
  HdsSnackBar: class { show(_options, message, operation) { this.message = message; this.operation = operation; } dismiss() {} },
  SnackBarOperationType: { TEXT_ONLY: 1 }, LengthMetrics: { vp: value => value }, $r: name => name,
  canPreviewDriveOriginal: require('../../work/core-build/domain/DriveOriginalProtocol.js').canPreviewDriveOriginal,
  canPreviewDriveMedia: require('../../work/core-build/domain/DriveOriginalProtocol.js').canPreviewDriveMedia };

// 执行实际方法体，支持单行方法；ArkUI 构建器仅检查必要的宿主连接。
function method(source, name) {
  const start = source.search(new RegExp('^  (?:private )?(?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  let end = source.indexOf('{', start) + 1, depth = 1;
  for (; end < source.length && depth; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  const compiled = ts.transpileModule('class Subject {\n' + source.slice(start, end) + '\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  });
  return vm.runInNewContext(compiled.outputText + '\nSubject.prototype.' + name, { ...globals });
}
function page() {
  const calls = [], paths = [];
  const state = {
    calls, module: 'drive', activeTab: 0, rootTab: 1, driveTabId: 'mydrive', photoTabId: 'photos',
    driveMoreView: '', photoMoreShared: false, photosInitialized: true,
    drivePinned: [], photoPinned: [], showPhotoShared: true, pickerMode: '', bootPending: false,
    sheetVisible: false, formSubmitting: false, pendingEntries: [], fileSelecting: false, selectedFiles: [], pageActive: true,
    photoSpace: P.Personal, albumSpace: P.Personal, sharedSpace: P.Shared,
    navStack: { size: () => paths.length, getAllPathName: () => paths, pop() { calls.push('pop'); paths.pop(); },
      clear() { paths.length = 0; }, pushPathByName(name, parameter) { paths.push(name); calls.push([name, parameter]); } },
    backup: { sources: [{}], selecting: false, submitting: false, reset() {}, async submit() { this.sources = []; } },
    tabsController: { changeIndex(index) { calls.push('index:' + index); } },
    updateTelemetryMode() {},
    model: { authenticated: true, directory: '/hidden', busy: false, supports: () => true, extensions: {}, queue: { ready: true },
      photoBackup: { busy: false },
      async submitPhotoUpload(upload) { calls.push('photos-upload'); await upload.submit(); },
      goBack() { calls.push('station-back'); this.directory = ''; },
      drive: { view: V.MyDrive, loaded: true, busy: false, available: true, trail: [{}], supportsView: () => true,
        activateView(view) { if (this.view !== view) { this.selectView(view); } },
        canGoUp() { return this.trail.length > 1 || this.view === V.Search; },
        goUp() { calls.push('drive-up'); this.trail = [{}]; },
        async exitSearch() { calls.push('exit-search'); this.view = V.MyDrive; },
        beginSearch() { calls.push('begin-search'); },
        selectView(view) { calls.push(['view', view]); this.view = view; this.loaded = true; },
        openFolder() { calls.push('drive-folder'); } },
      photoLibrary: { busy: false, space: P.Personal, section: 'timeline', selectedAlbum: undefined,
        activateTab(key, space, section) { if (this.space !== space || this.section !== section) { this.open(space, section); } },
        open(space, section) { calls.push(['photos', space, section]); this.space = space; this.section = section; this.selectedAlbum = undefined; },
        backToLibrary() { calls.push('albums'); this.selectedAlbum = undefined; } }
    }
  };
  for (const name of ['switchTab', 'exitModule', 'enterModule', 'selectModuleTab', 'navigationBusy', 'visibleTabs',
    'expectedPhotoSpace', 'expectedPhotoSection', 'ensurePhotosOpen', 'effectivePhotoTab', 'exitDriveSearch',
    'backToDriveMore', 'driveViewMatches', 'selectDriveMore', 'selectPhotoSpace', 'cancelDirectoryPicker', 'cancelFileSelection',
    'openModuleTasks', 'openPhotoTransfers', 'showAllTasks']) state[name] = method(index, name);
  return state;
}

test('system back closes sheet and destination before navigating the module', () => {
  const state = page(), back = method(index, 'onBackPress');
  state.sheetVisible = true; assert.equal(back.call(state), true);
  assert.equal(state.sheetVisible, false); assert.deepEqual(state.calls, []);
  state.navStack.pushPathByName('drive-original'); state.calls.length = 0;
  assert.equal(back.call(state), true); assert.deepEqual(state.calls, ['pop']);
});
test('Drive back traverses folders, ends search, returns more and restores the entry root tab', async () => {
  const state = page(), back = method(index, 'onBackPress');
  state.model.drive.trail.push({}); back.call(state);
  assert.deepEqual(state.calls, ['drive-up']); state.calls.length = 0;
  state.model.drive.view = V.Search; state.navStack.pushPathByName('drive-search'); state.calls.length = 0;
  back.call(state); await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(state.calls, ['exit-search', 'pop']);
  state.calls.length = 0; state.driveTabId = 'more'; state.driveMoreView = V.Trash;
  back.call(state); assert.equal(state.driveMoreView, ''); assert.equal(state.module, 'drive');
  state.model.drive.trail.push({}); back.call(state);
  assert.equal(state.module, 'root'); assert.equal(state.activeTab, 1);
  assert.deepEqual(state.calls, ['index:1']);
});
test('busy Drive consumes folder back but explicit module exit remains available', () => {
  const state = page(); state.model.drive.trail.push({}); state.model.drive.busy = true;
  assert.equal(method(index, 'onBackPress').call(state), true); assert.deepEqual(state.calls, []);
  state.exitModule(); assert.equal(state.module, 'root'); assert.equal(state.activeTab, 1);
});
test('File Station back and Drive tasks preserve the browser beneath the secondary page', () => {
  const state = page(); state.module = 'root'; state.activeTab = 1;
  method(index, 'onBackPress').call(state); assert.deepEqual(state.calls, ['station-back']);
  method(index, 'openDriveTransfers').call(state);
  assert.equal(state.activeTab, 1); assert.equal(state.navStack.getAllPathName().at(-1), 'drive-tasks');
  state.model.drive.view = V.Search;
  state.openModuleTasks('files'); state.navStack.pop();
  assert.equal(state.model.drive.view, V.Search);
  state.showAllTasks(); assert.equal(state.activeTab, 2); assert.equal(state.module, 'root'); assert.equal(state.navStack.size(), 0);
});

test('download feedback preserves the current preview and locates a finished record only on explicit action', () => {
  const state = page(); state.module = 'root'; state.activeTab = 1;
  state.model.sessionGeneration = 1; state.navigationInset = 24; state.bottomInset = () => 80; state.getUIContext = () => ({});
  state.model.fileOriginal = { close: () => state.calls.push('close-preview') };
  state.fileTasks = new globals.TaskPageState('files'); state.fileTasks.filter = 'active';
  state.navStack.pushPathByName('file-preview'); state.calls.length = 0;
  const feedback = method(index, 'downloadFeedback');
  feedback.call(state, { status: 'created', taskId: 'already-ended', message: '已添加下载任务' }, 'files', 'file-preview', 1);
  assert.deepEqual(state.calls, []); assert.equal(state.navStack.getAllPathName().at(-1), 'file-preview');
  state.downloadSnackBar.operation.onContentClick();
  assert.equal(state.navStack.getAllPathName().at(-1), 'files-tasks');
  assert.equal(state.fileTasks.filter, 'all'); assert.equal(state.fileTasks.focusKey, 'transfer:already-ended');
  assert.equal(state.model.directory, '/hidden'); assert.ok(state.calls.includes('close-preview'));
});

test('failure without a task uses its reason, and stale snackbar actions cannot enter a reconnected session', () => {
  const state = page(); state.model.sessionGeneration = 1; state.getUIContext = () => ({}); state.bottomInset = () => 80;
  state.showTitleMenuError = message => state.calls.push(message);
  const feedback = method(index, 'downloadFeedback');
  for (const status of ['rejected', 'failed']) feedback.call(state, { status, message: status }, 'files', '', 1);
  assert.deepEqual(state.calls, ['rejected', 'failed']); assert.equal(state.downloadSnackBar, undefined);
  for (const status of ['duplicate', 'unconfirmed']) {
    feedback.call(state, { status, taskId: 'retained', message: status }, 'files', '', 1);
    assert.ok(state.downloadSnackBar.operation);
  }
  const action = state.downloadSnackBar.operation.onContentClick;
  state.model.sessionGeneration = 2; action();
  assert.equal(state.navStack.size(), 0);
});

test('photo transfer entry stays in photo scope and locating one task preserves the other page filters', () => {
  const state = page(); state.module = 'photos'; state.visibleTabs = () => [{ id: 'photos' }];
  state.openPhotoTransfers(); assert.equal(state.navStack.getAllPathName().at(-1), 'photos-tasks');
  state.navStack.pop(); state.calls.length = 0;
  state.visibleTabs = () => [{ id: 'photos' }, { id: 'transfers' }];
  state.selectModuleTab = index => { state.activeTab = index; state.photoTabId = 'transfers'; };
  state.openPhotoTransfers(); assert.equal(state.navStack.size(), 0); assert.equal(state.photoTabId, 'transfers');
  const root = new globals.TaskPageState('root'), files = new globals.TaskPageState('files');
  root.filter = 'finished'; files.filter = 'active'; files.locate('transfer:one');
  assert.equal(root.filter, 'finished'); assert.equal(files.filter, 'all');
});

test('Drive operation polling follows visible task pages, overlays and foreground state', () => {
  const state = page(); let polling;
  state.foreground = true; state.module = 'root'; state.activeTab = 2; state.taskDestination = ''; state.taskOverlayVisible = false;
  state.rootTasks = new globals.TaskPageState('root');
  state.model.driveActions = { setPolling: value => { polling = value; } }; state.model.telemetry = { setMode() {} };
  const update = method(index, 'updateTelemetryMode');
  update.call(state); assert.equal(polling, false);
  state.rootTasks.categoryIndex = 2;
  update.call(state); assert.equal(polling, true);
  state.navStack.pushPathByName('nas-downloads'); update.call(state); assert.equal(polling, false);
  state.taskDestination = 'drive'; update.call(state); assert.equal(polling, true);
  state.taskOverlayVisible = true; update.call(state); assert.equal(polling, false);
  state.taskOverlayVisible = false; state.foreground = false; update.call(state); assert.equal(polling, false);
});
test('root category selection retains its matching navigation scroller', () => {
  const state = page(); state.module = 'root'; state.activeTab = 2;
  state.rootTasks = new globals.TaskPageState('root'); state.taskCategoryScrollers = [{}, {}, {}, {}];
  const active = method(index, 'activeScrollers');
  for (let category = 0; category < 4; category++) {
    state.rootTasks.categoryIndex = category;
    assert.equal(active.call(state)[0], state.taskCategoryScrollers[category]);
  }
});
test('File Station back exits multi-selection before leaving the current directory', () => {
  const state = page(); state.module = 'root'; state.activeTab = 1;
  state.fileSelecting = true; state.selectedFiles = [{ path: '/hidden/a' }, { path: '/hidden/b' }];
  method(index, 'onBackPress').call(state);
  assert.equal(state.fileSelecting, false); assert.equal(state.selectedFiles.length, 0);
  assert.equal(state.model.directory, '/hidden'); assert.deepEqual(state.calls, []);
});
test('backup uses Photos folders and NAS downloads retain the File Station picker', () => {
  const state = page(); state.module = 'photos'; state.photoTabId = 'more'; state.activeTab = 3;
  state.model.photoLibrary.loadActionTargets = mode => state.calls.push(['photo-target', mode]);
  state.openPhotoDestination = method(index, 'openPhotoDestination');
  method(index, 'chooseBackupDirectory').call(state);
  assert.deepEqual(state.calls, [['photo-actions', undefined], ['photo-target', 'backup']]); assert.equal(state.module, 'photos'); assert.equal(state.activeTab, 3);
  state.cancelDirectoryPicker(); state.calls.length = 0;
  method(index, 'chooseDownloadDirectory').call(state);
  assert.deepEqual(state.calls, [['directory-picker', 'download']]); assert.equal(state.model.extensions.downloadFormRequested, true);
  state.model.extensions.setDownloadDestination = path => { state.model.extensions.downloadDestination = path; };
  method(index, 'useDownloadDirectory').call(state); assert.equal(state.model.extensions.downloadDestination, 'hidden');
  assert.equal(state.pickerMode, ''); assert.equal(state.module, 'photos');
  assert.match(index, /name === 'directory-picker'/); assert.match(photoPage, /onChooseBackup/);
  assert.doesNotMatch(index + photoPage, /choosingBackupTarget|choosingDownloadTarget|fileSourceSwitch/);
});
test('picker back goes up the selected directory before returning to the existing stack', () => {
  const state = page(); method(index, 'chooseDownloadDirectory').call(state); state.calls.length = 0;
  method(index, 'onBackPress').call(state); assert.deepEqual(state.calls, ['station-back']); assert.equal(state.pickerMode, 'download');
  state.calls.length = 0; method(index, 'onBackPress').call(state); assert.deepEqual(state.calls, ['pop']); assert.equal(state.pickerMode, '');
});
test('manual photo upload submits the picker selection directly and cancellation cannot submit old choices', async () => {
  const state = page(); state.module = 'photos';
  state.backup.errorText = '';
  state.backup.clear = function () { this.sources = []; state.calls.push('clear'); };
  state.backup.select = async function () { state.calls.push('pick'); this.sources = [{}]; };
  state.getUIContext = () => ({ getHostContext: () => ({}) });
  state.showTitleMenuError = error => state.calls.push(error);
  await method(index, 'selectBackup').call(state);
  assert.deepEqual(state.calls, ['clear', 'pick', 'photos-upload']);
  assert.equal(state.pickerMode, ''); assert.equal(state.module, 'photos'); assert.equal(state.navStack.size(), 0);
  state.calls.length = 0; state.backup.sources = [{}];
  state.backup.select = async () => state.calls.push('cancel');
  await method(index, 'selectBackup').call(state);
  assert.deepEqual(state.calls, ['clear', 'cancel']);
  assert.equal(state.backup.sources.length, 0);
});
test('authentication loss resets module, search, picker and root selection', () => {
  const state = page(); state.model.authenticated = false; state.navStack.pushPathByName('drive-search'); state.pickerMode = 'backup';
  state.fileSelecting = true; state.selectedFiles = [{ path: '/hidden/a' }];
  method(index, 'authenticationChanged').call(state);
  assert.equal(state.module, 'root'); assert.equal(state.activeTab, 0); assert.equal(state.rootTab, 0);
  assert.equal(state.navStack.size(), 0); assert.equal(state.pickerMode, '');
  assert.equal(state.fileSelecting, false); assert.equal(state.selectedFiles.length, 0);
});
test('module entry captures the root and only loads a mismatched Drive view', () => {
  const state = page(); state.module = 'root'; state.activeTab = 3; state.enterModule('drive');
  assert.equal(state.rootTab, 3); assert.equal(state.module, 'drive');
  assert.equal(state.calls.filter(c => Array.isArray(c) && c[0] === 'view').length, 0);
  state.exitModule(); state.model.drive.view = V.TeamFolders; state.enterModule('drive');
  assert.deepEqual(state.calls.filter(c => Array.isArray(c) && c[0] === 'view'), [['view', V.MyDrive]]);
});
test('unrelated reads allow navigation while session transitions and unavailable modules block it', () => {
  const state = page(); state.module = 'root'; state.activeTab = 1;
  state.model.drive.busy = true; state.enterModule('photos'); assert.equal(state.module, 'photos');
  state.module = 'root'; state.activeTab = 1;
  state.model.sessionTransition = true; state.enterModule('photos'); assert.equal(state.module, 'root');
  state.model.sessionTransition = false;
  state.model.drive.busy = false; state.model.drive.supportsView = () => false; state.enterModule('drive');
  assert.equal(state.module, 'root'); assert.equal(state.activeTab, 1);
  assert.match(index, /\.onContentWillChange\([^]*?!this\.navigationBusy\(\)/);
});
test('photo tabs request their own space and section once and retain an open matching album', () => {
  const state = page(); state.module = 'photos'; state.photoTabId = 'photos'; state.ensurePhotosOpen(); assert.deepEqual(state.calls, []);
  state.photoTabId = 'albums'; state.ensurePhotosOpen(); assert.deepEqual(state.calls, [['photos', P.Personal, 'albums']]);
  state.model.photoLibrary.selectedAlbum = { space: P.Personal, id: 1 }; state.ensurePhotosOpen(); assert.equal(state.calls.length, 1);
  state.photoTabId = 'photos'; state.ensurePhotosOpen(); assert.deepEqual(state.calls.at(-1), ['photos', P.Personal, 'timeline']);
});
test('my shared view selects the outgoing album filter without changing personal albums', () => {
  const state = page(); state.module = 'photos'; state.photoTabId = 'shared';
  state.selectPhotoSpace('shared', P.Personal);
  assert.deepEqual(state.calls, [['photos', P.Personal, 'sharedByMe']]);
  state.photoTabId = 'albums'; state.ensurePhotosOpen();
  assert.deepEqual(state.calls.at(-1), ['photos', P.Personal, 'albums']);
});

test('hidden shared tab opens sharing in more with its own album space', () => {
  const state = page(); state.module = 'photos'; state.photoTabId = 'more'; state.showPhotoShared = false;
  method(index, 'openPhotoShared').call(state); assert.equal(state.photoMoreShared, true);
  assert.deepEqual(state.calls, [['photos', P.Shared, 'albums']]);
  method(index, 'onBackPress').call(state); assert.equal(state.photoMoreShared, false); assert.equal(state.module, 'photos');
});
test('Drive and photo content guards keep the shared model data out of unrelated or inactive tabs', () => {
  const d = { active: true, expectedView: V.TeamFolders, tabId: 'teamFolders', searchVisible: false, model: { drive: { view: V.MyDrive } } };
  assert.equal(method(drivePage, 'canRenderEntries').call(d), false); d.model.drive.view = V.TeamFolders;
  assert.equal(method(drivePage, 'canRenderEntries').call(d), true); d.active = false;
  assert.equal(method(drivePage, 'canRenderEntries').call(d), false);
  const p = { active: true, tabId: 'photos', expectedSpace: P.Personal, expectedSection: 'timeline',
    model: { supports: () => true, photoLibrary: { space: P.Shared, section: 'timeline' } } };
  for (const name of ['supportsSpace', 'supportsExpectedView', 'libraryMatches']) p[name] = method(photoPage, name);
  const canShow = method(photoPage, 'canShowLibrary'); assert.equal(canShow.call(p), false);
  p.model.photoLibrary.space = P.Personal; assert.equal(canShow.call(p), true);
  p.model.photoLibrary.selectedAlbum = { space: P.Personal }; assert.equal(canShow.call(p), false);
  p.tabId = 'albums'; p.expectedSection = p.model.photoLibrary.section = 'albums'; assert.equal(canShow.call(p), true);
  p.model.photoLibrary.selectedAlbum.space = P.Shared; assert.equal(canShow.call(p), false);
});

test('Drive file menu keeps metadata details available without granting unavailable or pending write operations', () => {
  const file = { fileId: '71', name: '只读目录', kind: drive.DriveEntryKind.Folder,
    capabilities: { canRead: true, canWrite: false } };
  for (const condition of ['not-ready', 'busy', 'pending', 'trash', 'no-operations']) {
    const state = { model: {
      drive: { view: condition === 'trash' ? V.Trash : V.MyDrive },
      driveTransfers: { ready: condition !== 'not-ready', busy: condition === 'busy', available: false },
      driveActions: { ready: true, busy: false, hasPending: condition === 'pending', available: false },
      driveSharing: { available: false }
    }, detailVisible: false };
    const menu = method(drivePage, 'driveEntryMenu').call(state, file);
    assert.equal(menu.length, 1);
    assert.equal(menu[0].value, '查看详情');
    menu[0].action();
    assert.equal(state.detailEntry, file);
    assert.equal(state.detailVisible, true);
  }
});
test('one floating HdsTabs owns every module and file tools remain in the title bar', () => {
  assert.equal((index.match(/HdsTabs\(/g) || []).length, 1);
  assert.doesNotMatch(drivePage + photoPage + filePage, /HdsTabs|HdsNavigation/);
  assert.match(drivePage, /NavigationMode.Split/);
  assert.match(filePage, /NavigationMode.Split/);
  assert.match(index, /barPosition\(BarPosition.End\).*scrollable\(false\)/);
  assert.match(index, /barOverlap\(true\).vertical\(false\)/);
  assert.match(index, /barFloatingStyle\(\{ barBottomMargin: this.floatingBarBottomMargin\(\)/);
  assert.match(index, /backIcon:[\s\S]*?icon: this.navigationBackSymbol\(\)[\s\S]*?this.onBackPress\(\)/);
  assert.doesNotMatch(index, /backIcon:.*label: '返回'/);
  assert.doesNotMatch(filePage, /fileSourceSwitch|filePageActions|sortLabel|Button\('上传'\)/);
  assert.match(filePage, /workbenchBreadcrumbs\(this.model.directory\)/);
});

test('floating bar uses the measured navigation area or the system spacing when it is absent', () => {
  let resourceReads = 0;
  const state = { navigationInset: 0, getUIContext: () => ({ getHostContext: () => ({
    resourceManager: { getNumber() { resourceReads++; return 32; } }
  }) }) };
  const margin = method(index, 'floatingBarBottomMargin');
  assert.equal(margin.call(state), 32);
  for (const inset of [24, 28, 40]) {
    state.navigationInset = inset;
    assert.equal(margin.call(state), inset);
  }
  assert.equal(resourceReads, 1);
});

test('unreadable entries cannot enter through either UI or model', async () => {
  const entry = { name: 'restricted', fileId: '123', kind: 'folder', capabilities: { canRead: false } };
  const state = page();
  method(drivePage, 'openDriveEntry').call(state, entry);
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
  assert.match(drivePage, /available: !this\.model\.busy && !this\.model\.drive\.busy && entry\.capabilities\.canRead/);
});

test('Drive file action prepares supported files for preview without navigating to transfers', () => {
  const state = page();
  state.model.driveTransfers = { canPreview: () => true, download(_entry, preview) { state.calls.push(['drive-download', preview]); } };
  state.openDriveTransfers = () => state.calls.push('drive-tasks');
  state.onDownload = (_entry, preview) => state.calls.push(['drive-download', preview]);
  const open = method(drivePage, 'openDriveEntry');
  const file = { name: '记录.txt', kind: 'file', capabilities: { canRead: true, canDownload: true } };
  open.call(state, file);
  assert.deepEqual(state.calls, [['drive-download', true]]);
  state.calls.length = 0;
  state.model.drive.view = 'trash';
  open.call(state, file);
  assert.deepEqual(state.calls, []);
  state.model.driveTransfers.canPreview = () => false;
  state.model.drive.view = 'mydrive';
  open.call(state, { ...file, name: '安装包.apk' });
  assert.equal(state.detailVisible, true);
  assert.deepEqual(state.calls, []);
  state.model.drive.view = 'mydrive';
  open.call(state, { ...file, capabilities: { canRead: true, canDownload: false } });
  open.call(state, { ...file, capabilities: { canRead: false, canDownload: true } });
  assert.deepEqual(state.calls, []);
});

test('permitted media open thumbnail preview even when original downloading is forbidden', () => {
  const state = page(); state.openDriveOriginal = () => state.calls.push('drive-original');
  state.model.driveTransfers = { download() { state.calls.push('drive-download'); } };
  state.openDriveTransfers = () => state.calls.push('drive-tasks');
  const open = method(drivePage, 'openDriveEntry');
  const picture = { name: '照片.jpg', kind: 'file', capabilities: { canRead: true, canDownload: true, canPreview: true } };
  open.call(state, picture); assert.deepEqual(state.calls, ['drive-original']);
  state.calls.length = 0;
  open.call(state, { ...picture, capabilities: { canRead: true, canDownload: false, canPreview: true } });
  assert.deepEqual(state.calls, ['drive-original']);
});


test('photo backup home shortcut opens backup settings without invoking manual selection', () => {
  const state = page(); state.module = 'root'; state.photoMoreShared = true;
  state.selectBackup = () => state.calls.push('choose-media');
  method(index, 'openPhotoBackup').call(state);
  assert.equal(state.module, 'photos'); assert.equal(state.photoTabId, 'more'); assert.equal(state.photoMoreShared, false);
  assert.equal(state.effectivePhotoTab(), 'more'); assert.ok(!state.calls.includes('choose-media'));
});
test('returning from the directory picker reopens the retained NAS download form once', () => {
  const source = fs.readFileSync(path.join(root, 'features/downloadStation/DownloadStationPage.ets'), 'utf8');
  const restore = method(source, 'restoreDownloadForm');
  const state = { visible: false, creating: false, model: { downloadFormRequested: true, downloadUri: 'https://example.test/a', downloadDestination: 'old', cancelDownloadAuthentication() {} } };
  restore.call(state); assert.equal(state.creating, false); assert.equal(state.model.downloadFormRequested, true);
  state.visible = true; restore.call(state); assert.equal(state.creating, true); assert.equal(state.model.downloadFormRequested, false);
  assert.equal(state.model.downloadUri, 'https://example.test/a'); assert.equal(state.model.downloadDestination, 'old');
  state.creating = false; restore.call(state); assert.equal(state.creating, false);
  assert.ok(index.includes('DownloadStationPage({ model: this.model.extensions, scroller: this.downloadsScroller, visible: this.downloadsVisible,'));
  assert.match(index, /if \(!this\.model\.extensions\.downloadsLoaded\) \{ this\.model\.extensions\.refreshDownloads\(\); \}/);
});
test('directory pickers filter files without changing the regular File Station list', () => {
  const entries = [{ path: '/a', isDirectory: true }, { path: '/a/b.txt', isDirectory: false }];
  const state = { pickerMode: '', model: { entries } }; const visible = method(filePage, 'visibleEntries');
  assert.equal(visible.call(state), entries); state.pickerMode = 'backup';
  assert.deepEqual(Array.from(visible.call(state), e => e.path), ['/a']); state.pickerMode = 'download';
  assert.deepEqual(Array.from(visible.call(state), e => e.path), ['/a']);
});


test('failed Drive view switches cannot navigate or search the hidden old folder', () => {
  const state = page(); state.driveTabId = 'teamFolders'; state.model.drive.trail.push({});
  method(index, 'onBackPress').call(state); assert.equal(state.module, 'root'); assert.deepEqual(state.calls, ['index:1']);
  state.module = 'drive'; state.driveTabId = 'more'; state.driveMoreView = V.Trash; state.calls.length = 0;
  method(index, 'onBackPress').call(state); assert.equal(state.driveMoreView, ''); assert.deepEqual(state.calls, []);
  state.driveTabId = 'mydrive'; state.model.drive.view = V.TeamFolders;
  method(index, 'showDriveSearch').call(state); assert.equal(state.navStack.size(), 0);
});


test('module back preserves a pending File Station operation in the hidden root page', () => {
  const state = page(); const pending = [{ path: '/a' }, { path: '/b' }]; state.pendingEntries = pending; state.pendingOperation = 'copy';
  method(index, 'onBackPress').call(state);
  assert.equal(state.module, 'root'); assert.equal(state.pendingEntries, pending); assert.equal(state.pendingOperation, 'copy');
  method(index, 'onBackPress').call(state); assert.equal(state.pendingEntries.length, 0); assert.equal(state.pendingOperation, '');
});
