const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const drive = require('../../work/core-build/domain/DriveProtocol.js');
const adapter = require('../../work/core-build/network/DriveAdapter.js');
const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/drive/DriveBrowserModel.ets'), 'utf8')
  .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
const output = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
});
assert.equal((output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
const deps = {
  '../../core/domain/DsmProtocol': dsm, '../../core/domain/DriveProtocol': drive,
  '../../core/network/DriveAdapter': adapter, '../../core/network/NasConnector': {},
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {} } }
};
const mod = { exports: {} };
vm.runInNewContext(output.outputText, { module: mod, exports: mod.exports,
  require(id) { assert.ok(Object.hasOwn(deps, id), id); return deps[id]; } });
const { DriveBrowserModel } = mod.exports;
const { DriveView: V, DRIVE_PAGE_SIZE } = drive;
const { NasFailure, NasErrorKind: K } = dsm;
const entry = (id, type = 'dir', canRead = true) => ({ file_id: String(id), name: '项目' + id, type,
  capabilities: { can_read: canRead } });
const gate = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { resolve, promise }; };

function fixture(reply = () => ({ items: [], total: 0 }), supported = () => true) {
  const calls = [], failures = [];
  const kernel = {
    supportsDriveApi: supported,
    async requestDrive(api, version, method, fields) {
      const args = { api, version, method, fields: Object.fromEntries(fields.map(f => [f.name, f.content])) };
      calls.push(args); return reply(args);
    },
    readDriveFeature: (_, read) => read()
  };
  const model = new DriveBrowserModel();
  model.attach(kernel, async failure => { failures.push(failure); });
  return { model, calls, failures, kernel };
}

function pageRenderKey(relative, dataSource) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets', relative), 'utf8');
  const start = source.indexOf(`ForEach(${dataSource},`);
  assert.ok(start >= 0, relative);
  const match = source.slice(start).match(/\}, \(entry: DriveEntry\): string => ([^\r\n]+)\)/);
  assert.ok(match, relative);
  // 执行页面实际使用的键表达式；旧的内容修订键和 id-only 键都必须被回归测试检出。
  return vm.runInNewContext(`(entry) => ${match[1]}`, { driveEntryRenderKey: drive.driveEntryRenderKey });
}

for (const [relative, dataSource, view] of [
  ['features/drive/DriveModulePage.ets', 'this.model.drive.entries', V.MyDrive],
  ['features/drive/DriveActionUi.ets', 'this.model.destinations.entries', V.TeamFolders],
]) {
  test(`${relative} refreshes row data and captured actions after metadata-only reloads`, async () => {
    const keyOf = pageRenderKey(relative, dataSource);
    const original = { ...entry('900000000000000001'), name: '旧目录', parent_id: '7', revisions: 1,
      version_id: '1', modified_time: 1700000000, size: 0,
      capabilities: { can_read: true, can_write: true, can_rename: true, can_delete: true } };
    const changes = view === V.TeamFolders ? [
      { name: '新目录' }, { capabilities: { ...original.capabilities, can_write: false } },
    ] : [
      { name: '新目录' }, { capabilities: { ...original.capabilities, can_delete: false } },
      { parent_id: '8' }, { display_path: '另一位置/旧目录' }, { revisions: 2 },
    ];
    let raw = original;
    const f = fixture(() => ({ total: 1, items: [raw] }));
    for (const change of changes) {
      raw = original;
      await f.model.selectView(view);
      await f.model.reload();
      const previous = f.model.entries[0];
      const previousKey = keyOf(previous);
      // 只模拟 ForEach 同键保留生成结果的契约，不冒充 ArkUI 运行时渲染。
      const rows = new Map([[previousKey, { title: previous.name, onOpen: () => previous }]]);
      raw = { ...original, ...change };
      await f.model.reload();
      const current = f.model.entries[0];
      const currentKey = keyOf(current);
      assert.equal(current.fileId, previous.fileId);
      assert.deepEqual([current.versionId, current.modifiedAt, current.sizeBytes],
        [previous.versionId, previous.modifiedAt, previous.sizeBytes]);
      assert.notEqual(currentKey, previousKey, JSON.stringify(change));
      const row = rows.get(currentKey) || { title: current.name, onOpen: () => current };
      assert.equal(row.title, current.name);
      assert.equal(row.onOpen(), current);
      await f.model.reload();
      assert.equal(keyOf(f.model.entries[0]), currentKey);
    }
  });
}

test('search paging and folder return preserve the accepted query after a failed replacement', async () => {
  const f = fixture(({ method, fields }) => {
    if (method === 'search') {
      const query = JSON.parse(fields.keyword);
      if (query === '失败') throw new NasFailure(K.Network, '连接暂不可用');
      return { total: 2, items: [entry(Number(fields.offset) + 1)] };
    }
    return { total: 0, items: [] };
  });
  await f.model.search('  资料  ');
  assert.equal(f.model.view, V.Search);
  assert.equal(f.model.searchKeyword, '资料');
  await f.model.nextPage();
  await f.model.openFolder(f.model.entries[0]);
  await f.model.goToTrail(0);
  assert.equal(f.calls.at(-1).method, 'search');
  assert.equal(f.calls.at(-1).fields.keyword, '"资料"');
  assert.equal(f.model.pageOffset, 1);
  await f.model.search('失败');
  assert.equal(f.model.searchKeyword, '资料');
  assert.equal(f.model.entries[0].fileId, '2');
  assert.match(f.model.errorText, /连接/);
  await f.model.reload();
  assert.equal(f.calls.at(-1).fields.keyword, '"资料"');
});

test('blank search never submits and a response after reset cannot restore its query', async () => {
  const pending = gate();
  const f = fixture(() => pending.promise);
  await f.model.search('  ');
  assert.equal(f.calls.length, 0);
  assert.equal(f.model.loaded, false);
  assert.match(f.model.errorText, /请输入/);
  const loading = f.model.search('资料');
  f.model.reset();
  pending.resolve({ total: 1, items: [entry(1)] });
  await loading;
  assert.equal(f.model.view, V.MyDrive);
  assert.equal(f.model.searchKeyword, '');
  assert.equal(f.model.loaded, false);
});

test('short pages never skip entries and previous-page navigation uses visited offsets', async () => {
  const f = fixture(({ fields }) => ({ total: 5, items: [entry(Number(fields.offset) + 1)] }));
  await f.model.open();
  await f.model.nextPage();
  await f.model.nextPage();
  assert.deepEqual(f.calls.map(c => Number(c.fields.offset)), [0, 1, 2]);
  assert.equal(f.model.pageOffset, 2);
  await f.model.previousPage();
  assert.equal(f.model.pageOffset, 1);
  await f.model.previousPage();
  assert.equal(f.model.pageOffset, 0);
  const count = f.calls.length;
  await f.model.previousPage();
  assert.equal(f.calls.length, count);
});

test('team folders use the endpoint-specific schema and preserve their root view on return', async () => {
  const f = fixture(({ api }) => api.endsWith('.TeamFolders') ?
    { total: 1, items: [{ file_id: '821014439470870977', name: '团队资料', capabilities: { can_read: true } }] } :
    { total: 1, items: [entry(7)] });
  await f.model.selectView(V.TeamFolders);
  assert.equal(f.model.view, V.TeamFolders);
  await f.model.openFolder(f.model.entries[0]);
  assert.equal(f.calls[1].api, 'SYNO.SynologyDrive.Files');
  assert.equal(f.calls[1].fields.path, '"id:821014439470870977"');
  assert.equal(f.model.trail.length, 2);
  await f.model.goUp();
  assert.equal(f.calls[2].api, 'SYNO.SynologyDrive.TeamFolders');
  assert.equal(f.model.trail.length, 1);
});

test('recent does not fabricate totals and can probe a page after a full result', async () => {
  const f = fixture(({ fields }) => ({ items: Number(fields.offset) === 0 ?
    Array.from({ length: DRIVE_PAGE_SIZE }, (_, i) => entry(i + 1, 'file')) : [] }));
  await f.model.selectView(V.Recent);
  assert.equal(f.model.total, undefined);
  assert.equal(f.model.more(), true);
  await f.model.nextPage();
  assert.equal(f.model.more(), false);
  assert.equal(f.model.pageOffset, 0);
  assert.equal(f.model.entries.length, DRIVE_PAGE_SIZE);
  assert.equal(f.calls[1].fields.offset, String(DRIVE_PAGE_SIZE));
  assert.match(f.model.notice, /末尾/);
  await f.model.previousPage();
  assert.equal(f.model.pageOffset, 0);
});

test('failed view or folder navigation keeps the accepted view, contents and trail together', async () => {
  let fail = false;
  const f = fixture(() => {
    if (fail) { throw new NasFailure(K.Protocol, '列表变化'); }
    return { items: [entry(1)], total: 1 };
  });
  await f.model.open();
  const entries = f.model.entries, trail = f.model.trail;
  fail = true;
  await f.model.selectView(V.Starred);
  assert.equal(f.model.view, V.MyDrive);
  assert.equal(f.model.entries, entries);
  assert.equal(f.model.trail, trail);
  await f.model.openFolder(entries[0]);
  assert.equal(f.model.trail, trail);
  assert.equal(f.model.errorText, '列表变化');
  assert.equal(f.model.busy, false);
});

test('detach and reattach discard in-flight data and navigation from the previous connection', async () => {
  const pending = gate();
  const f = fixture(() => pending.promise);
  const open = f.model.selectView(V.TeamFolders);
  assert.equal(f.model.busy, true);
  f.model.detach();
  assert.equal(f.model.available, false);
  f.model.attach({ ...f.kernel, requestDrive: async () => ({ items: [entry(9)], total: 1 }) }, async () => {});
  await f.model.open();
  pending.resolve({ items: [{ file_id: '1', name: '旧团队', capabilities: { can_read: true } }], total: 1 });
  await open;
  assert.equal(f.model.view, V.MyDrive);
  assert.equal(f.model.entries[0].fileId, '9');
  assert.equal(f.model.trail.length, 1);
  assert.equal(f.model.busy, false);
});

test('unavailable endpoints, unreadable entries and trash folders do not send requests', async () => {
  const f = fixture(() => ({ items: [entry(1)], total: 1 }), api => !api.endsWith('.TeamFolders'));
  assert.equal(f.model.supportsView(V.TeamFolders), false);
  await f.model.selectView(V.TeamFolders);
  assert.equal(f.calls.length, 0);
  await f.model.open();
  await f.model.openFolder(drive.decodeDriveEntry(entry(2, 'dir', false)));
  assert.equal(f.calls.length, 1);
  await f.model.selectView(V.Trash);
  await f.model.openFolder(f.model.entries[0]);
  assert.equal(f.calls.length, 2);
  assert.match(f.model.notice, /回收站/);
});

test('session failures reach the connection callback and late reset responses cannot repopulate the model', async () => {
  const f = fixture(() => { throw new NasFailure(K.SessionExpired, '需要重新登录', 119); });
  await f.model.open();
  assert.equal(f.failures.length, 1);
  assert.equal(f.model.loaded, false);
  assert.equal(f.model.busy, false);
  const pending = gate();
  f.kernel.requestDrive = () => pending.promise;
  const open = f.model.open();
  f.model.reset();
  pending.resolve({ items: [entry(1)], total: 1 });
  await open;
  assert.equal(f.model.entries.length, 0);
  assert.equal(f.model.loaded, false);
});

test('custom searches preserve their scope through pagination and return to the original team folder page', async () => {
  const f = fixture(({ api, method, fields }) => {
    if (api.endsWith('.TeamFolders')) return { total: 1, items: [{ ...entry(7), name: '团队资料' }] };
    if (method === 'search') return { total: 2, items: [entry(Number(fields.offset) + 21, 'file')] };
    return { total: 2, items: [entry(Number(fields.offset) + 11, 'file')] };
  });
  await f.model.selectView(V.TeamFolders);
  await f.model.openFolder(f.model.entries[0]);
  await f.model.nextPage();
  await f.model.search('资料');
  assert.equal(f.calls.at(-1).fields.location, '"custom"');
  assert.equal(f.calls.at(-1).fields.custom_location, '"id:7"');
  assert.equal(f.model.searchScopeName, '团队资料');
  await f.model.nextPage();
  assert.equal(f.calls.at(-1).fields.custom_location, '"id:7"');
  assert.equal(f.model.pageOffset, 1);
  await f.model.search('文档');
  assert.equal(f.calls.at(-1).fields.custom_location, '"id:7"');
  await f.model.goUp();
  assert.equal(f.model.view, V.TeamFolders);
  assert.equal(f.model.trail.at(-1).fileId, '7');
  assert.equal(f.model.pageOffset, 1);
  assert.equal(f.model.searchKeyword, '');
  assert.equal(f.model.searchText, '');
  await f.model.previousPage();
  assert.equal(f.model.pageOffset, 0);
});

test('cross-directory results use the captured ancestor chain and keep the accepted search result page', async () => {
  const contract = require('../fixtures/drive-readonly-contract.json');
  const f = fixture(({ method }) => {
    if (method === 'search') return contract.searchResponse.data;
    if (method === 'list_ancestor') return contract.ancestorResponse.data;
    return { items: [], total: 0 };
  });
  await f.model.search('PhotoLibrary');
  await f.model.openFolder(f.model.entries[0]);
  assert.deepEqual(f.calls.map(call => call.method), ['search', 'list_ancestor', 'list']);
  assert.deepEqual(Array.from(f.model.trail, item => item.fileId), [undefined,
    ...contract.ancestorResponse.data.items.map(item => item.file_id), contract.searchResponse.data.items[0].file_id]);
  assert.equal(f.model.trail[1].name, '根目录');
  await f.model.goUp();
  assert.equal(f.calls.at(-1).fields.path, '"id:' + contract.ancestorResponse.data.items[1].file_id + '"');
  await f.model.goToTrail(0);
  assert.equal(f.calls.at(-1).method, 'search');
  assert.equal(f.model.searchKeyword, 'PhotoLibrary');
  assert.equal(f.model.entries.length, 1);
  assert.equal(f.model.canGoUp(), true);
});

test('ancestor failures preserve the search result and session expiry reaches the common callback', async () => {
  let expire = false;
  const f = fixture(({ method }) => {
    if (method === 'list_ancestor') throw new NasFailure(expire ? K.SessionExpired : K.Network, '祖先读取失败', 119);
    return { total: 1, items: [entry(3)] };
  });
  await f.model.search('资料');
  const entries = f.model.entries, trail = f.model.trail;
  await f.model.openFolder(entries[0]);
  assert.equal(f.model.entries, entries);
  assert.equal(f.model.trail, trail);
  assert.equal(f.model.searchKeyword, '资料');
  assert.equal(f.model.busy, false);
  assert.match(f.model.errorText, /祖先/);
  expire = true;
  await f.model.openFolder(entries[0]);
  assert.equal(f.failures.length, 1);
  assert.equal(f.calls.filter(call => call.method === 'list').length, 0);
});

test('reset during ancestor loading prevents a second request and discards old query and navigation', async () => {
  const pending = gate();
  const f = fixture(({ method }) => method === 'list_ancestor' ? pending.promise : { items: [entry(3)], total: 1 });
  await f.model.search('资料');
  const loading = f.model.openFolder(f.model.entries[0]);
  f.model.reset();
  pending.resolve({ items: [], total: 0 });
  await loading;
  assert.equal(f.calls.length, 2);
  assert.equal(f.model.loaded, false);
  assert.equal(f.model.searchKeyword, '');
  assert.equal(f.model.canGoUp(), false);
  assert.equal(f.model.busy, false);
});

test('a failed search exit keeps its query and result so the same destination can be retried', async () => {
  let unavailable = false;
  const f = fixture(({ method }) => {
    if (unavailable && method === 'list') throw new NasFailure(K.Network, '暂不可用');
    return { items: [], total: 0 };
  });
  await f.model.open();
  await f.model.search('资料');
  unavailable = true;
  await f.model.exitSearch();
  assert.equal(f.model.view, V.Search);
  assert.equal(f.model.searchKeyword, '资料');
  assert.equal(f.model.canGoUp(), true);
  unavailable = false;
  await f.model.exitSearch();
  assert.equal(f.model.view, V.MyDrive);
  assert.equal(f.model.searchKeyword, '');
  assert.equal(f.model.canGoUp(), false);
});


test('team-only browsing can refresh its accepted view without requiring My Drive', async () => {
  const f = fixture(() => ({ total: 1, items: [{ file_id: '11', name: '团队资料', capabilities: { can_read: true } }] }),
    api => api === 'SYNO.SynologyDrive.TeamFolders');
  assert.equal(f.model.available, false); assert.equal(f.model.supportsView(V.TeamFolders), true);
  await f.model.selectView(V.TeamFolders); const count = f.calls.length;
  await f.model.reload(); assert.equal(f.calls.length, count + 1);
  assert.equal(f.calls.at(-1).api, 'SYNO.SynologyDrive.TeamFolders'); assert.equal(f.model.entries[0].name, '团队资料');
});
