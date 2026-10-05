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
