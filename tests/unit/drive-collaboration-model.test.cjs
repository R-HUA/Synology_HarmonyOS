const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const p = require('../../work/core-build/domain/DriveCollaborationProtocol.js');
const contract = require('../fixtures/drive-collaboration-contract.json');
const clone = value => JSON.parse(JSON.stringify(value));
const gate = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const flush = () => new Promise(setImmediate);
const file = () => ({ fileId: '900000000000000001', name: '资料.txt', kind: 'file', capabilities: { canRead: true, canShare: false } });

function loadModel(name, mocks) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/drive', name + '.ets'), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const mod = { exports: {} };
  vm.runInNewContext(compiled.outputText, { module: mod, exports: mod.exports,
    require(id) { assert.ok(Object.hasOwn(mocks, id), id); return mocks[id]; } });
  return mod.exports[name];
}

function fixture(options = {}) {
  const events = [], history = new Map(), failures = [];
  let id = 0, saves = 0;
  class Store {
    async load(context, origin, account) {
      this.scope = JSON.stringify([origin, account]);
      events.push(['load', this.scope]);
      return clone(history.get(this.scope) || []);
    }
    async save(records) {
      events.push(['save', this.scope, clone(records)]); saves++;
      if (options.save) await options.save(saves, records);
      history.set(this.scope, clone(records));
    }
  }
  const mocks = {
    '@kit.ArkTS': { util: { generateRandomUUID: () => `11111111-1111-4111-8111-${String(++id).padStart(12, '0')}` } },
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
    '../../core/domain/DsmProtocol': dsm, '../../core/domain/DriveCollaborationProtocol': p,
    './DriveSharingStore': { DriveSharingStore: Store }
  };
  const Sharing = loadModel('DriveSharingModel', mocks);
  const Notifications = loadModel('DriveNotificationsModel', mocks);
  const sharing = new Sharing(), notifications = new Notifications();
  const kernel = {
    supportsDriveApi: () => options.available !== false,
    readDriveFeature: (feature, read) => { events.push(['feature', feature]); return read(); },
    async requestDrive(api, version, method, fields) {
      events.push(['request', api, version, method, clone(fields)]);
      if (options.request) return options.request(api, method, fields);
      return api === p.DRIVE_SHARING_API ? contract.fileLink : clone(contract.notifications);
    }
  };
  const attach = (account = 'alice', origin = 'https://nas.test') => sharing.attach({ filesDir: '/private' }, kernel, origin, account,
    async error => { failures.push(error); if (options.sessionFailure) await options.sessionFailure(sharing, error); }, () => options.canWrite !== false);
  const attachNotifications = () => notifications.attach(kernel, async error => failures.push(error));
  return { sharing, notifications, kernel, events, history, failures, options, attach, attachNotifications,
    stored: (account = 'alice', origin = 'https://nas.test') => history.get(JSON.stringify([origin, account])),
    requests: () => events.filter(e => e[0] === 'request') };
}

test('selecting file prepares confirmation only; unknown is durably recorded before the single write and URL is published after saving', async () => {
  const f = fixture(); await f.attach();
  assert.equal(f.sharing.prepare(file()), true);
  assert.equal(f.requests().length, 0); assert.equal(f.stored(), undefined);
  assert.equal(await f.sharing.submit(), true);
  const requestAt = f.events.findIndex(e => e[0] === 'request');
  assert.equal(f.events[requestAt - 1][0], 'save'); assert.equal(f.events[requestAt - 1][2][0].state, 'unknown');
  assert.equal(f.requests()[0][1], p.DRIVE_SHARING_API); assert.equal(f.requests()[0][2], 1);
  assert.equal(f.requests()[0][3], 'create_link');
  assert.deepEqual(f.requests()[0][4], [{ name: 'path', content: '"id:900000000000000001"' }]);
  assert.equal(f.sharing.items[0].state, 'completed'); assert.equal(f.stored()[0].url, contract.fileLink.url);
  assert.equal(f.sharing.draft, undefined);
});

test('permission and discovery denial do not send writes, ordinary file links do not require canShare or guessed global policy', async () => {
  const f = fixture(); await f.attach();
  assert.equal(f.sharing.prepare({ ...file(), capabilities: { canRead: false, canShare: true } }), false);
  assert.equal(f.requests().length, 0);
  assert.equal(f.sharing.prepare(file()), true); assert.equal(await f.sharing.submit(), true);
  const unavailable = fixture({ available: false }); await unavailable.attach();
  assert.equal(unavailable.sharing.prepare(file()), false); assert.equal(unavailable.requests().length, 0);
});

test('network ambiguity and unexpected success shape survive reload without replay, and block new links until explicitly closed', async () => {
  for (const response of [() => { throw new dsm.NasFailure(dsm.NasErrorKind.Network, '连接中断'); }, () => ({ items: [{ id: 1 }] })]) {
    const f = fixture({ request: response }); await f.attach(); f.sharing.prepare(file());
    assert.equal(await f.sharing.submit(), false); assert.equal(f.stored()[0].state, 'unknown');
    assert.equal(f.sharing.hasPending, true); assert.equal(f.sharing.prepare(file()), false);
    await f.sharing.remove(f.sharing.items[0].id); assert.equal(f.stored().length, 1);
    await f.attach(); await f.sharing.reload();
    assert.equal(f.requests().length, 1); assert.equal(f.sharing.items[0].state, 'unknown');
    await f.sharing.closeUnknown(f.sharing.items[0].id);
    assert.equal(f.stored()[0].state, 'closed'); assert.equal(f.requests().length, 1);
    assert.equal(f.sharing.prepare(file()), true);
  }
});

test('definite NAS permission refusal is stored as failed and session expiry preserves uncertainty and notifies connection layer', async () => {
  for (const kind of [dsm.NasErrorKind.Permission, dsm.NasErrorKind.SessionExpired]) {
    const f = fixture({ request: () => { throw new dsm.NasFailure(kind, '请求未完成'); } });
    await f.attach(); f.sharing.prepare(file()); await f.sharing.submit();
    assert.equal(f.stored()[0].state, kind === dsm.NasErrorKind.Permission ? 'failed' : 'unknown');
    assert.equal(f.failures.length, kind === dsm.NasErrorKind.SessionExpired ? 1 : 0);
  }
});

test('persistence failures send no request before unknown save, retain unknown after final save failure, and freeze further obtains', async () => {
  for (const failAt of [1, 2]) {
    const f = fixture({ save: count => { if (count === failAt) throw new Error('disk full'); } });
    await f.attach(); f.sharing.prepare(file()); assert.equal(await f.sharing.submit(), false);
    assert.equal(f.requests().length, failAt === 1 ? 0 : 1);
    assert.equal(f.sharing.ready, false); assert.match(f.sharing.errorText, /记录未保存/);
    assert.equal(f.sharing.prepare(file()), false);
    if (failAt === 2) {
      assert.equal(f.stored()[0].state, 'unknown'); assert.equal(f.sharing.items[0].state, 'unknown');
      assert.equal(f.sharing.items[0].url, undefined);
      await f.sharing.reload(); assert.equal(f.sharing.hasPending, true); assert.equal(f.requests().length, 1);
    }
  }
});

test('background or stopAll between durable save and dispatch prevents request and records definite unsent result', async () => {
  for (const stop of [false, true]) {
    const saved = gate();
    const f = fixture({ save: count => count === 1 ? saved.promise : undefined });
    await f.attach(); f.sharing.prepare(file()); const write = f.sharing.submit(); await flush();
    let stopped;
    if (stop) stopped = f.sharing.stopAll(); else f.sharing.setForeground(false);
    saved.resolve(); await write; if (stopped) await stopped;
    assert.equal(f.requests().length, 0); assert.equal(f.stored()[0].state, 'failed');
  }
});

test('late file link completion stays in original NAS/account history and does not publish to another connection', async () => {
  const response = gate(); const f = fixture({ request: () => response.promise }); await f.attach();
  f.sharing.prepare(file()); const write = f.sharing.submit(); await flush();
  const switched = f.attach('bob', 'https://second.test');
  assert.equal(f.sharing.items.length, 0); response.resolve(contract.fileLink);
  await Promise.all([write, switched]);
  assert.equal(f.sharing.items.length, 0); assert.equal(f.sharing.notice, '');
  assert.equal(f.stored('alice')[0].state, 'completed');
  await f.attach('alice'); assert.equal(f.sharing.items[0].url, contract.fileLink.url);
  await f.attach('alice', 'https://second.test'); assert.equal(f.sharing.items.length, 0);
  assert.equal(f.requests().length, 1);
});

test('repeated submit while busy never duplicates create_link and canWrite is checked after save', async () => {
  const response = gate(); const f = fixture({ request: () => response.promise }); await f.attach();
  f.sharing.prepare(file()); const write = f.sharing.submit(); await flush();
  assert.equal(await f.sharing.submit(), false); response.resolve(contract.fileLink); await write;
  assert.equal(f.requests().length, 1);
  const held = gate(); const guarded = fixture({ save: n => n === 1 ? held.promise : undefined }); await guarded.attach();
  guarded.sharing.prepare(file()); const pending = guarded.sharing.submit(); await flush(); guarded.options.canWrite = false;
  held.resolve(); await pending; assert.equal(guarded.requests().length, 0); assert.equal(guarded.stored()[0].state, 'failed');
});

test('notification refresh reads only list with limit, marks local read without writes and maintains read state on same-session refresh', async () => {
  const f = fixture(); f.attachNotifications();
  assert.equal(f.requests().length, 0); assert.equal(await f.notifications.refresh(), true);
  assert.equal(f.requests()[0][1], p.DRIVE_NOTIFICATIONS_API); assert.equal(f.requests()[0][2], 1);
  assert.equal(f.requests()[0][3], 'list'); assert.deepEqual(f.requests()[0][4], [{ name: 'limit', content: '100' }]);
  assert.equal(f.events.some(e => e[0] === 'feature' && e[1] === 'driveNotifications'), true);
  assert.equal(f.notifications.items[0].read, false);
  f.notifications.markRead(f.notifications.items[0].id); assert.equal(f.notifications.items[0].read, true);
  await f.notifications.refresh(); assert.equal(f.notifications.items[0].read, true);
  f.notifications.markAllRead(); assert.equal(f.notifications.items.every(n => n.read), true);
  assert.equal(f.requests().length, 2); assert.equal(f.events.some(e => e[0] === 'save'), false);
  f.attachNotifications(); await f.notifications.refresh(); assert.equal(f.notifications.items.every(n => !n.read), true);
});

test('notification true empty refresh clears stale rows, failed refresh preserves rows and never masquerades as empty', async () => {
  const f = fixture(); f.attachNotifications(); await f.notifications.refresh();
  f.options.request = () => { throw new dsm.NasFailure(dsm.NasErrorKind.Protocol, '格式不匹配'); };
  assert.equal(await f.notifications.refresh(), false); assert.equal(f.notifications.items.length, 4);
  assert.equal(f.notifications.errorText, '格式不匹配');
  f.options.request = () => contract.notificationsEmpty;
  assert.equal(await f.notifications.refresh(), true); assert.equal(f.notifications.items.length, 0);
  assert.equal(f.notifications.total, 0); assert.equal(f.notifications.errorText, '');
});

test('notification expiry calls connection layer; late response and late expiry from detached session cannot alter new session', async () => {
  const f = fixture({ request: () => { throw new dsm.NasFailure(dsm.NasErrorKind.SessionExpired, '请重新登录'); } });
  f.attachNotifications(); await f.notifications.refresh(); assert.equal(f.failures.length, 1);
  for (const expiry of [false, true]) {
    const response = gate(); const stale = fixture({ request: () => response.promise }); stale.attachNotifications();
    const read = stale.notifications.refresh(); stale.attachNotifications();
    if (expiry) response.reject(new dsm.NasFailure(dsm.NasErrorKind.SessionExpired, '请重新登录')); else response.resolve(contract.notifications);
    await read; assert.equal(stale.notifications.items.length, 0); assert.equal(stale.notifications.loaded, false);
    assert.equal(stale.notifications.errorText, ''); assert.equal(stale.failures.length, 0);
  }
});

test('link session expiry can await shutdown in the connection callback without deadlocking the pending write', { timeout: 2000 }, async () => {
  const f = fixture({ request: () => { throw new dsm.NasFailure(dsm.NasErrorKind.SessionExpired, 'expired'); },
    sessionFailure: async sharing => { await sharing.stopAll(); } });
  await f.attach(); assert.equal(f.sharing.prepare(file()), true); await f.sharing.submit();
  assert.equal(f.failures.length, 1); assert.equal(f.sharing.items[0].state, 'unknown');
});
