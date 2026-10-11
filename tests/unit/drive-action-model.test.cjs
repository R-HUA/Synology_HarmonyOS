const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const p = require('../../work/core-build/domain/DriveActionProtocol.js');
const state = require('../../work/core-build/domain/DriveActionState.js');
const { DriveActionAdapter } = require('../../work/core-build/network/DriveActionAdapter.js');
const clone = value => JSON.parse(JSON.stringify(value));
const gate = () => { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; };
const flush = () => new Promise(setImmediate);
const file = () => ({ fileId: '900000000000000001', name: 'a.txt', kind: 'file', revisionCount: 1,
  capabilities: { canRead: true, canRename: true, canDelete: true } });
const folder = () => ({ fileId: '900000000000000002', name: '目标', kind: 'folder',
  capabilities: { canRead: true, canWrite: true } });

function fixture(options = {}) {
  const events = [], history = new Map(), failures = [], timers = new Map();
  let id = 0, saves = 0;
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/drive/DriveActionModel.ets'), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  class Store {
    async load(context, origin, account) { this.account = account; return clone(history.get(account) || options.records || []); }
    async save(records) {
      events.push(['save', this.account, clone(records)]); saves++;
      if (options.save) await options.save(saves, records);
      history.set(this.account, clone(records));
    }
  }
  const mocks = {
    '@kit.ArkTS': { util: { generateRandomUUID: () => `11111111-1111-4111-8111-${String(++id).padStart(12, '0')}` } },
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
    '../../core/domain/DsmProtocol': dsm, '../../core/domain/DriveActionProtocol': p,
    '../../core/domain/DriveActionState': state, '../../core/network/DriveActionAdapter': { DriveActionAdapter },
    './DriveActionStore': { DriveActionStore: Store },
    './DriveBrowserModel': { DriveBrowserModel: class { attach() {} detach() {} reset() {} async open() {} } }
  };
  const mod = { exports: {} };
  vm.runInNewContext(compiled.outputText, { module: mod, exports: mod.exports,
    setTimeout(fn) { const timer = ++id; timers.set(timer, () => { timers.delete(timer); fn(); }); return timer; }, clearTimeout(timer) { timers.delete(timer); },
    require(id) { assert.ok(Object.hasOwn(mocks, id), id); return mocks[id]; } });
  const kernel = {
    supportsDriveApi: () => true, readDriveFeature: (_, fn) => fn(),
    async requestDrive(api, version, method, fields) {
      const params = Object.fromEntries(fields.map(f => [f.name, f.content]));
      events.push(['request', method, clone(params)]);
      if (options.request) { const result = await options.request(method, params); if (result !== undefined) return result; }
      if (params.dry_run === 'true') return { result: options.conflicts || [] };
      if (method === 'update') return { file_id: file().fileId, name: JSON.parse(params.name), type: 'file' };
      if (method === 'get') return options.status || { task_id: 'task-1', status: 'finished', progress: 100, result: { errors: [], skips: [] } };
      return { async_task_id: 'task-1' };
    }
  };
  const model = new mod.exports.DriveActionModel();
  const attach = account => model.attach({ filesDir: '/private' }, kernel, 'https://nas.test', account,
    async error => { failures.push(error); if (options.sessionFailure) await options.sessionFailure(model, error); }, () => options.canWrite !== false);
  return { model, events, history, failures, timers, attach, options,
    requests: () => events.filter(e => e[0] === 'request') };
}

test('rename selection has no write; confirmation durably saves uncertainty before dispatch and checks renamed identity', async () => {
  const f = fixture(); await f.attach('alice');
  assert.equal(await f.model.prepare(file(), 'rename'), true);
  assert.equal(f.requests().length, 0); f.model.newName = '新文件.txt';
  assert.equal(await f.model.submit(), true);
  const n = f.events.findIndex(e => e[0] === 'request');
  assert.equal(f.events[n - 1][0], 'save'); assert.equal(f.events[n - 1][2][0].state, 'unknown');
  assert.equal(f.model.items[0].state, 'completed');
  assert.equal(f.history.get('alice')[0].destination, '新文件.txt');
});

test('folder creation saves the parent and requested name before dispatch and survives record reload', async () => {
  const f = fixture({ request: method => method === 'create' ?
    { file_id: '900000000000000003', parent_id: folder().fileId, name: '新目录', type: 'dir' } : undefined });
  await f.attach('alice');
  assert.equal(await f.model.prepare(folder(), 'create'), true);
  assert.equal(f.model.newName, ''); assert.equal(f.requests().length, 0);
  f.model.newName = ' 新目录 ';
  assert.equal(await f.model.submit(), true);
  const n = f.events.findIndex(e => e[0] === 'request');
  assert.equal(f.events[n - 1][0], 'save'); assert.equal(f.events[n - 1][2][0].state, 'unknown');
  assert.equal(f.model.items[0].name, '新目录'); assert.equal(f.model.items[0].resource.fileId, folder().fileId);
  assert.equal(f.model.items[0].destination, folder().name); assert.equal(f.model.items[0].state, 'completed');
  assert.equal(await f.model.submit(), false); assert.equal(f.requests().length, 1);
  await f.attach('alice'); assert.equal(f.model.items[0].action, 'create'); assert.equal(f.requests().length, 1);
});

test('an unconfirmed folder creation remains pending and cannot be sent twice', async () => {
  const f = fixture({ request: () => ({}) }); await f.attach('alice');
  await f.model.prepare(folder(), 'create'); f.model.newName = '新目录'; await f.model.submit();
  assert.equal(f.model.items[0].state, 'unknown'); assert.equal(f.model.hasPending, true);
  assert.equal(await f.model.submit(), false); assert.equal(f.requests().length, 1);
});

test('target selection performs only dry run; accepted task is stored then queried without replaying the write', async () => {
  const f = fixture({ conflicts: [{}] }); await f.attach('alice');
  await f.model.prepare(file(), 'move'); await f.model.selectDestination(folder());
  assert.equal(f.requests().length, 1); assert.equal(f.requests()[0][2].dry_run, 'true');
  assert.equal(f.model.draft.conflicts, 1); await f.model.submit();
  assert.equal(f.model.items[0].state, 'accepted'); assert.equal(f.history.get('alice')[0].taskId, 'task-1');
  assert.equal(f.requests()[1][2].dry_run, undefined);
  const id = f.model.items[0].id;
  await f.model.refresh(id); await f.model.refresh(id);
  assert.deepEqual(f.requests().map(e => e[1]), ['move', 'move', 'get']);
  assert.equal(f.model.items[0].state, 'completed');
});

test('empty preflight results make move and copy destinations selectable and still require explicit submission', async () => {
  for (const action of ['move', 'copy']) {
    for (const result of [null, {}]) {
      const f = fixture({ request: (_, params) => params.dry_run === 'true' ? { result } : undefined });
      await f.attach('alice');
      await f.model.prepare(file(), action);
      await f.model.selectDestination(folder());
      assert.equal(f.model.errorText, '');
      assert.equal(f.model.draft.target.fileId, folder().fileId);
      assert.equal(f.model.draft.conflicts, 0);
      assert.equal(f.model.items.length, 0);
      assert.equal(f.events.filter(e => e[0] === 'save').length, 0);
      assert.equal(f.requests().length, 1);
      assert.equal(f.requests()[0][2].dry_run, 'true');
      assert.equal(await f.model.submit(), true);
      assert.equal(f.model.items[0].state, 'accepted');
      const write = f.events.findIndex(e => e[0] === 'request' && e[2].dry_run !== 'true');
      assert.equal(f.events[write - 1][0], 'save');
      assert.equal(f.events[write - 1][2][0].state, 'unknown');
      assert.equal(f.requests()[1][2].conflict_action, '"autorename"');
    }
  }
});

test('failed persistence before dispatch sends nothing and completion-save failure freezes further writes', async () => {
  for (const failAt of [1, 2]) {
    const f = fixture({ save: n => { if (n === failAt) throw new Error('disk full'); } }); await f.attach('alice');
    await f.model.prepare(file(), 'rename'); f.model.newName = '新名称'; await f.model.submit();
    assert.equal(f.requests().length, failAt === 1 ? 0 : 1);
    assert.equal(f.model.ready, false); assert.match(f.model.errorText, /记录未保存/);
    assert.equal(await f.model.prepare(file(), 'delete'), false);
    assert.equal(f.requests().length, failAt === 1 ? 0 : 1);
  }
});

test('network ambiguity survives restart and blocks another write until explicit business-level closure', async () => {
  const f = fixture({ request: method => { if (method === 'delete') throw new dsm.NasFailure(dsm.NasErrorKind.Network, 'lost'); } });
  await f.attach('alice'); await f.model.prepare(file(), 'delete'); await f.model.submit();
  assert.equal(f.model.items[0].state, 'unknown');
  await f.attach('alice'); assert.equal(f.requests().length, 1);
  assert.equal(await f.model.prepare(file(), 'rename'), false); assert.equal(f.requests().length, 1);
  await f.model.closeUnknown(f.model.items[0].id);
  assert.equal(f.model.items[0].state, 'closed'); assert.equal(f.requests().length, 1);
  assert.equal(await f.model.prepare(file(), 'rename'), true);
});

test('an account switch cannot publish a late old response or turn it into a new-account task', async () => {
  const pending = gate(); const f = fixture({ request: method => method === 'copy' ? pending.promise : undefined });
  await f.attach('alice'); await f.model.prepare(file(), 'copy');
  // Preflight has a distinct read response.
  f.options.request = (method, params) => method === 'copy' && params.dry_run !== 'true' ? pending.promise : undefined;
  await f.model.selectDestination(folder());
  const sending = f.model.submit(); await flush();
  const switching = f.attach('bob'); pending.resolve({ async_task_id: 'task-1' });
  assert.equal(await sending, false); await switching;
  assert.equal(f.model.items.length, 0); assert.equal(f.failures.length, 0);
  assert.equal(f.history.get('alice')[0].taskId, 'task-1');
  assert.equal(f.history.get('bob'), undefined);
});

test('detaching during a submitted write preserves the old history without requesting caller navigation', async () => {
  const pending = gate(); const f = fixture({ request: method => method === 'delete' ? pending.promise : undefined });
  await f.attach('alice'); await f.model.prepare(file(), 'delete');
  const sending = f.model.submit(); await flush(); f.model.detach();
  pending.resolve({ async_task_id: 'task-1' });
  assert.equal(await sending, false);
  assert.equal(f.model.items.length, 0);
  assert.equal(f.history.get('alice')[0].state, 'accepted');
  assert.equal(f.history.get('alice')[0].taskId, 'task-1');
  assert.equal(f.requests().length, 1);
});

test('background or another active transfer after initial save prevents dispatch', async () => {
  const pending = gate(); const f = fixture({ save: n => n === 1 ? pending.promise : undefined });
  await f.attach('alice'); await f.model.prepare(file(), 'delete'); const sending = f.model.submit(); await flush();
  f.model.setForeground(false); pending.resolve(); await sending;
  assert.equal(f.requests().length, 0); assert.equal(f.model.items[0].state, 'failed');
  f.model.setForeground(true); f.options.canWrite = false;
  assert.equal(await f.model.prepare(file(), 'delete'), false); assert.equal(f.requests().length, 0);
});

test('restored accepted tasks query only while their page is visible and foreground; query failure permits manual closure', async () => {
  const record = { id: '11111111-1111-4111-8111-111111111111', action: 'copy', resource: { nasOrigin: 'https://nas.test', account: 'alice', fileId: file().fileId },
    name: 'a.txt', destination: '目标', taskId: 'task-1', state: 'accepted', errorText: '' };
  const f = fixture({ records: [record], request: () => { throw new dsm.NasFailure(dsm.NasErrorKind.Network, 'lost'); } });
  await f.attach('alice'); assert.equal(f.requests().length, 0);
  f.model.setPolling(true); assert.equal(f.timers.size, 1);
  f.model.setForeground(false); assert.equal(f.timers.size, 0);
  f.model.setForeground(true); const callback = [...f.timers.values()][0]; callback(); await flush();
  assert.equal(f.requests().length, 1); assert.equal(f.requests()[0][1], 'get');
  assert.equal(f.timers.size, 0); assert.match(f.model.items[0].errorText, /核对/);
  await f.model.closeUnknown(record.id); assert.equal(f.model.items[0].state, 'closed');
  assert.equal(f.requests().length, 1);
});

test('a finished task without a result retains uncertainty and permits manual closure without replay', async () => {
  const f = fixture({ status: { task_id: 'task-1', status: 'finished', progress: 100 } });
  await f.attach('alice'); await f.model.prepare(file(), 'delete'); await f.model.submit();
  const id = f.model.items[0].id;
  f.model.setPolling(true); assert.equal(f.timers.size, 1);
  await f.model.refresh(id);
  assert.equal(f.model.items[0].state, 'accepted');
  assert.match(f.model.items[0].errorText, /核对/);
  assert.equal(f.model.hasPending, true); assert.equal(f.model.ready, true);
  assert.equal(f.timers.size, 0);
  await f.attach('alice');
  assert.equal(f.model.items[0].state, 'accepted'); assert.match(f.model.items[0].errorText, /核对/);
  assert.equal(await f.model.prepare(file(), 'delete'), false);
  await f.model.closeUnknown(id);
  assert.equal(f.model.items[0].state, 'closed');
  assert.equal(f.history.get('alice')[0].state, 'closed');
  assert.equal(await f.model.prepare(file(), 'delete'), true);
  assert.deepEqual(f.requests().map(e => e[1]), ['delete', 'get']);
});

test('reported errors and skipped items never become completed; failed preflight clears the previous target', async () => {
  for (const [result, expected] of [[{ errors: [{}] }, 'failed'], [{ skips: [{}] }, 'partial']]) {
    const f = fixture({ status: { task_id: 'task-1', status: 'finished', progress: 100, result } });
    await f.attach('alice'); await f.model.prepare(file(), 'delete'); await f.model.submit();
    await f.model.refresh(f.model.items[0].id); assert.equal(f.model.items[0].state, expected);
  }
  const f = fixture(); await f.attach('alice'); await f.model.prepare(file(), 'copy'); await f.model.selectDestination(folder());
  f.options.request = () => { throw new dsm.NasFailure(dsm.NasErrorKind.Permission, 'denied'); };
  await f.model.selectDestination(folder()); assert.equal(f.model.draft.target, undefined);
  assert.equal(await f.model.submit(), false);
});

test('accepted work cannot be removed or submitted again; session expiry retains the write uncertainty before notification', async () => {
  const f = fixture(); await f.attach('alice'); await f.model.prepare(file(), 'delete'); await f.model.submit();
  await f.model.remove(f.model.items[0].id); assert.equal(f.model.items.length, 1);
  assert.equal(await f.model.submit(), false); assert.equal(f.requests().length, 1);
  const expired = fixture({ request: () => { throw new dsm.NasFailure(dsm.NasErrorKind.SessionExpired, 'expired'); } });
  await expired.attach('alice'); await expired.model.prepare(file(), 'delete'); await expired.model.submit();
  assert.equal(expired.failures.length, 1); assert.equal(expired.history.get('alice')[0].state, 'unknown');
});

test('session expiry permits the connection callback to await action shutdown without waiting on its own tail', { timeout: 2000 }, async () => {
  const f = fixture({ request: () => { throw new dsm.NasFailure(dsm.NasErrorKind.SessionExpired, 'expired'); },
    sessionFailure: async model => { await model.stopAll(); } });
  await f.attach('alice'); await f.model.prepare(file(), 'delete'); await f.model.submit();
  assert.equal(f.failures.length, 1); assert.equal(f.model.items[0].state, 'unknown');
});
