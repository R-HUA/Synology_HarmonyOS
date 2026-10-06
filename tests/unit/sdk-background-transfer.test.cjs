const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');

function fixture(options = {}) {
  const events = [], observers = new Map(), taskListeners = new Map(), timers = new Map();
  let clock = 10000, counter = 0, interrupts = 0;
  const network = { netId: 1, bearerTypes: ['wifi'], networkCap: ['unmetered'], metered: false };
  const connection = {
    NetBearType: { BEARER_WIFI: 'wifi', BEARER_CELLULAR: 'cellular', BEARER_VPN: 'vpn' },
    NetCap: { NET_CAPABILITY_NOT_METERED: 'unmetered' },
    getDefaultNetSync() { if (options.queryFailure) throw new Error('network query'); return { netId: network.netId }; },
    getNetCapabilitiesSync() { return { bearerTypes: network.bearerTypes, networkCap: network.networkCap }; },
    isDefaultNetMeteredSync() { return network.metered; },
    createNetConnection() { return {
      register(callback) { events.push(['network-register']); callback(options.registerFailure ? new Error('register') : undefined); },
      on(name, callback) { observers.set(name, callback); },
      unregister(callback) { events.push(['network-unregister']); observers.clear(); callback(); }
    }; }
  };
  const manager = {
    on(name, callback) { taskListeners.set(name, callback); },
    off(name) { taskListeners.delete(name); },
    async startBackgroundRunning(context, modes, agent) {
      events.push(['start', modes, agent]);
      if (options.startFailure) throw new Error('denied');
      return { notificationId: 91, continuousTaskId: 37, contentType: 1, slotType: 1 };
    },
    async stopBackgroundRunning(context, id) {
      events.push(['stop', id]); if (options.stopFailure) throw new Error('stop failed');
      taskListeners.get('continuousTaskCancel')?.({ id: 37 });
    }
  };
  const notificationManager = {
    SlotType: { LIVE_VIEW: 8 }, ContentType: { NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW: 17 },
    async publish(value) { events.push(['publish', value]); if (options.publishFailure) throw new Error('publish denied'); }
  };
  const mocks = {
    '@kit.NetworkKit': { connection },
    '@kit.AbilityKit': { wantAgent: {
      OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 4 },
      async getWantAgent(value) { events.push(['want', value]); return value; }
    } },
    '@kit.BackgroundTasksKit': { backgroundTaskManager: manager },
    '@kit.NotificationKit': { notificationManager },
    '../core/domain/DsmProtocol': dsm
  };
  function load(name) {
    const file = path.join(__dirname, '../../entry/src/main/ets/platform', name + '.ets');
    const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
    assert.equal(compiled.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
    const mod = { exports: {} };
    vm.runInNewContext(compiled.outputText, { module: mod, exports: mod.exports, Error,
      Date: class extends Date { static now() { return clock; } }, canIUse: () => options.unsupported !== true,
      setInterval(callback) { const id = ++counter; timers.set(id, callback); return id; }, clearInterval(id) { timers.delete(id); },
      require(id) { assert.ok(Object.hasOwn(mocks, id), id); return mocks[id]; } });
    return mod.exports;
  }
  mocks['./SdkTransferNetwork'] = load('SdkTransferNetwork');
  const { SdkBackgroundTransfer } = load('SdkBackgroundTransfer');
  const lease = new SdkBackgroundTransfer();
  return { lease, options, events, observers, taskListeners, timers, network, SdkBackgroundTransfer,
    start: () => lease.start({ abilityInfo: { bundleName: 'com.example.test', name: 'EntryAbility' } }, 'Drive 上传', () => interrupts++),
    tick(ms) { clock += ms; for (const callback of timers.values()) callback(); },
    interrupts: () => interrupts };
}

test('continuous task uses official dataTransfer live-view notification and cleans only its own ID', async () => {
  const f = fixture(); await f.start(); assert.equal(f.lease.active, true);
  const request = f.events.find(e => e[0] === 'want')[1];
  assert.equal(request.wants[0].parameters.driveTransfers, true);
  assert.deepEqual(Array.from(f.events.find(e => e[0] === 'start')[1]), ['dataTransfer']);
  const notice = f.events.find(e => e[0] === 'publish')[1];
  assert.equal(notice.id, 91); assert.equal(notice.notificationSlotType, 8);
  assert.equal(notice.content.notificationContentType, 17); assert.equal(notice.content.systemLiveView.typeCode, 8);
  assert.equal(notice.template.name, 'downloadTemplate'); assert.equal(notice.template.data.progressValue, 0);
  f.lease.progress(5, 10); await f.lease.stop();
  assert.equal(f.events.filter(e => e[0] === 'publish').at(-1)[1].template.data.progressValue, 50);
  assert.equal(f.events.find(e => e[0] === 'stop')[1], 37);
  assert.equal(f.interrupts(), 0, 'self-requested stop must not cancel a confirmed successful transfer');
  assert.equal(f.timers.size, 0); assert.equal(f.observers.size, 0); assert.equal(f.taskListeners.size, 0);
  await f.lease.stop(); assert.equal(f.events.filter(e => e[0] === 'stop').length, 1);
});

test('network gate rejects metered Wi-Fi, cellular, VPN, unknown capabilities and unavailable default route', async () => {
  for (const override of [{ metered: true }, { bearerTypes: ['cellular'] }, { bearerTypes: ['wifi', 'vpn'] },
    { networkCap: undefined }, { networkCap: [] }, { netId: 0 }]) {
    const f = fixture(); Object.assign(f.network, override);
    await assert.rejects(f.start()); assert.equal(f.events.some(e => e[0] === 'start'), false);
    assert.equal(f.observers.size, 0); assert.equal(f.timers.size, 0);
  }
});

test('network change and system cancellation interrupt once and release listeners', async () => {
  for (const trigger of ['metered', 'lost', 'different-route', 'system']) {
    const f = fixture(); await f.start();
    if (trigger === 'metered') { f.network.metered = true; f.observers.get('netCapabilitiesChange')(); }
    if (trigger === 'lost') f.observers.get('netLost')();
    if (trigger === 'different-route') { f.network.netId = 2; f.observers.get('netAvailable')(); }
    if (trigger === 'system') f.taskListeners.get('continuousTaskCancel')({ id: 37 });
    assert.equal(f.interrupts(), 1); assert.throws(() => f.lease.check());
    await f.lease.stop(); assert.equal(f.interrupts(), 1); assert.equal(f.observers.size, 0);
    assert.equal(f.timers.size, 0); assert.equal(f.taskListeners.size, 0);
  }
});

test('failed task or notification acquisition leaves no unobserved continuous task', async () => {
  for (const options of [{ startFailure: true }, { publishFailure: true }, { registerFailure: true }, { queryFailure: true }, { unsupported: true }]) {
    const f = fixture(options); await assert.rejects(f.start());
    assert.equal(f.lease.active, false); assert.equal(f.observers.size, 0); assert.equal(f.taskListeners.size, 0);
    assert.equal(f.timers.size, 0);
    if (options.publishFailure) assert.equal(f.events.filter(e => e[0] === 'stop').length, 1);
  }
});

test('stalled data transfer is stopped instead of sending artificial progress to maintain its lease', async () => {
  const f = fixture(); await f.start();
  f.tick(180001); assert.equal(f.interrupts(), 1);
  assert.equal(f.events.filter(e => e[0] === 'publish').length, 1);
  await f.lease.stop();
});

test('stop failure remains retryable and cannot be overwritten by another lease', async () => {
  const f = fixture(); await f.start(); f.options.stopFailure = true;
  await assert.rejects(f.lease.stop()); await assert.rejects(f.start());
  f.options.stopFailure = false; await f.lease.stop(); assert.equal(f.observers.size, 0);
});

test('late progress publication failure interrupts instead of silently retaining the background privilege', async () => {
  const f = fixture(); await f.start(); f.options.publishFailure = true;
  f.lease.progress(1, 8); await f.lease.publishing;
  assert.equal(f.interrupts(), 1); await f.lease.stop(); assert.equal(f.timers.size, 0);
});

test('module declares only required runtime policies for the RCP background path', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '../../entry/src/main/module.json5'), 'utf8'));
  assert.ok(manifest.module.abilities[0].backgroundModes.includes('dataTransfer'));
  const names = manifest.module.requestPermissions.map(p => p.name);
  assert.ok(names.includes('ohos.permission.KEEP_BACKGROUND_RUNNING')); assert.ok(names.includes('ohos.permission.GET_NETWORK_INFO'));
  assert.equal(names.includes('ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM'), false);
});
