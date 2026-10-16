const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/pages/Index.ets'), 'utf8');
const taskSource = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/tasks/TaskPage.ets'), 'utf8');
const refreshMethod = taskSource.match(/  private async refresh\([^]*?\n  }/)[0].replace('refresh(', 'refreshTaskPage(');
const methods = refreshMethod + ['prepareDriveUpload', 'startDriveUpload', 'uploadSheetClosed'].map(name => {
  const match = source.match(new RegExp(`  private (?:async )?${name}\\([^]*?\\n  }`));
  assert.ok(match, name);
  return match[0];
}).join('\n');
const output = ts.transpileModule(`class Harness { ${methods} }; module.exports = Harness;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
});
assert.equal((output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
const mod = { exports: {} };
vm.runInNewContext(output.outputText, { module: mod });
const Harness = mod.exports;
const gate = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

function fixture() {
  const h = new Harness();
  h.sheetVisible = false;
  h.pageActive = true;
  h.navigationBusy = () => false;
  h.openForm = kind => { h.opened = kind; h.sheetVisible = true; };
  h.openDriveTransfers = () => { h.openedTasks = true; };
  h.state = { scope: 'files' }; h.runQueue = work => work();
  h.model = { authenticated: true, address: 'https://nas.example', account: 'alice', sessionGeneration: 1,
    queue: { async reconcile() {} },
    driveTransfers: { busy: false, draft: undefined, errorText: '',
      clearDraft() { if (!this.busy) this.draft = undefined; } } };
  return h;
}

test('cancelled file picker cannot revive a draft left by a previous failed upload', async () => {
  const h = fixture();
  h.model.driveTransfers.draft = { name: 'old' };
  h.model.driveTransfers.prepareUpload = async () => {};
  await h.prepareDriveUpload({});
  assert.equal(h.model.driveTransfers.draft, undefined);
  assert.equal(h.opened, undefined);
});

test('upload confirmation opens only for the newly selected file', async () => {
  const h = fixture();
  const next = { name: 'new' };
  h.model.driveTransfers.prepareUpload = async () => { h.model.driveTransfers.draft = next; };
  await h.prepareDriveUpload({});
  assert.equal(h.opened, 'drive-upload');
  assert.equal(h.model.driveTransfers.draft, next);
});

test('confirmed upload releases a failed draft after its closed sheet and preserves a later account draft', async () => {
  for (const switchAccount of [false, true]) {
    const h = fixture();
    const pending = gate();
    const old = { name: 'old' };
    const next = { name: 'other-account' };
    h.sheetVisible = true;
    h.sheetKind = 'drive-upload';
    h.model.driveTransfers.draft = old;
    h.model.driveTransfers.upload = () => { h.model.driveTransfers.busy = true; return pending.promise; };
    h.startDriveUpload();
    h.uploadSheetClosed();
    assert.equal(h.model.driveTransfers.draft, old);
    assert.equal(h.openedTasks, true);
    h.model.driveTransfers.busy = false;
    if (switchAccount) h.model.driveTransfers.draft = next;
    pending.resolve();
    await pending.promise;
    assert.equal(h.model.driveTransfers.draft, switchAccount ? next : undefined);
  }
});

test('task page queries pending server records sequentially instead of reloading a ready local snapshot', async () => {
  for (const scope of ['files', 'drive']) {
    const h = fixture();
    h.state.scope = scope;
    const calls = [];
    let running = 0;
    const query = async id => { assert.equal(running++, 0); calls.push(id); await Promise.resolve(); running--; };
    h.model.fileTasksReady = true;
    h.model.fileTasks = [{ id: 'a', state: 'pending' }, { id: 'b', state: 'unknown' }, { id: 'c', state: 'completed' }];
    h.model.checkFileTask = query;
    h.model.reloadFileTasks = async () => { assert.fail('ready records should be queried'); };
    h.model.driveActions = { ready: true, items: [{ id: 'a', state: 'accepted' }, { id: 'b', state: 'accepted' }, { id: 'c', state: 'unknown' }],
      refresh: query, reload: async () => { assert.fail('ready records should be queried'); } };
    h.model.driveTransfers.ready = true; h.model.driveTransfers.refresh = async () => {};
    await h.refreshTaskPage();
    assert.deepEqual(calls, ['a', 'b']);
  }
});

test('task refresh loads missing records before querying and stops across account changes', async () => {
  const h = fixture();
  h.state.scope = 'files';
  const calls = [];
  h.model.fileTasksReady = false;
  h.model.fileTasks = [];
  h.model.reloadFileTasks = async () => { calls.push('reload'); h.model.fileTasksReady = true;
    h.model.fileTasks = [{ id: 'a', state: 'pending' }, { id: 'b', state: 'unknown' }]; };
  h.model.checkFileTask = async id => { calls.push(id); h.model.sessionGeneration++; };
  await h.refreshTaskPage();
  assert.deepEqual(calls, ['reload', 'a']);
});
