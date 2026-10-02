const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdkRoot = process.env.HARMONY_SDK_ROOT || path.join(process.env.DEVECO_CLI_CLT_PATH || 'C:/Program Files/command-line-tools', 'sdk/default');
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

function load(relative, mocks = {}, globals = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets', relative), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020,
    module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((output.diagnostics || []).filter(diagnostic => diagnostic.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, Error, Date, ...globals,
    require: id => { assert.ok(Object.hasOwn(mocks, id), 'unexpected dependency ' + id); return mocks[id]; } });
  return module.exports;
}

const dsm = load('core/domain/DsmProtocol.ts');
const telemetry = load('core/domain/TelemetryProtocol.ts', { './DsmProtocol': dsm });
const { NasFailure, NasErrorKind: K } = dsm;
const plain = value => JSON.parse(JSON.stringify(value));
const sections = ['utilization', 'system', 'storage'];
const apis = { utilization: 'SYNO.Core.System.Utilization', system: 'SYNO.Core.System', storage: 'SYNO.Storage.CGI.Storage' };
const failure = kind => new NasFailure(kind, '合成测试失败');
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((success, fail) => { resolve = success; reject = fail; });
  return { promise, resolve, reject };
};
const flush = async () => { for (let turn = 0; turn < 32; turn++) { await Promise.resolve(); } };

const samples = {
  utilization: { cpu: { user_load: 12, system_load: 8, other_load: 0 },
    memory: { total_real: 1024, avail_real: 256, real_usage: 75 }, network: [{ device: 'eth-synthetic', rx: 4096, tx: 2048 }] },
  system: { model: 'Synthetic NAS', firmware_ver: '7.2.synthetic', sys_temp: 35, up_time: '03:04:05' },
  storage: { volumes: [{ id: 'volume-synthetic', size: { total: '1073741824', used: '268435456' }, status: 'normal' }] },
};

function fakeClock() {
  const clock = { now: 1700000000000, timers: new Map(), nextId: 0 };
  clock.setTimeout = (callback, delay) => {
    const id = ++clock.nextId;
    clock.timers.set(id, { callback, at: clock.now + delay });
    return id;
  };
  clock.clearTimeout = id => { clock.timers.delete(id); };
  clock.delays = () => [...clock.timers.values()].map(timer => timer.at - clock.now);
  clock.advance = async milliseconds => {
    const until = clock.now + milliseconds;
    await flush();
    for (let count = 0; ; count++) {
      const next = [...clock.timers.entries()].filter(([, timer]) => timer.at <= until)
        .sort((left, right) => left[1].at - right[1].at)[0];
      if (next === undefined) { break; }
      assert.ok(count < 128, 'unexpected recurring timer loop');
      clock.now = next[1].at;
      clock.timers.delete(next[0]);
      next[1].callback();
      await flush();
    }
    clock.now = until;
    await flush();
  };
  return clock;
}

function fakeConnector(clock, overrides = {}) {
  const calls = [];
  const replies = Object.fromEntries(sections.map(section => [section, () => structuredClone(samples[section])]));
  Object.assign(replies, overrides);
  const connector = {};
  for (const section of sections) {
    const method = 'telemetry' + section[0].toUpperCase() + section.slice(1);
    connector[method] = async () => { calls.push({ section, at: clock.now }); return replies[section](); };
  }
  return { connector, calls, replies, count: section => calls.filter(call => call.section === section).length };
}

function harness(overrides = {}) {
  const clock = fakeClock();
  class ControlledDate extends Date {
    static now() { return clock.now; }
  }
  const { TelemetryMonitor } = load('features/telemetry/TelemetryMonitor.ets', {
    '../../core/domain/DsmProtocol': dsm,
    '../../core/domain/TelemetryProtocol': telemetry,
    '../../core/network/NasConnector': {},
    '@kit.PerformanceAnalysisKit': { hilog: { error() {}, info() {} } },
  }, { Date: ControlledDate, setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout });
  const monitor = new TelemetryMonitor();
  const source = fakeConnector(clock, overrides);
  const sessionFailures = [];
  monitor.attach(source.connector, async error => { sessionFailures.push(error); });
  return { monitor, clock, sessionFailures, ...source };
}

test('synthetic (not live NAS) decoder samples reach sections with distinct observations and byte units', async () => {
  const context = harness();
  context.monitor.setMode('home');
  await flush();
  assert.deepEqual(plain(context.monitor.utilization.data), { cpuPercent: 20, memoryTotalBytes: 1048576,
    memoryUsedBytes: 786432, memoryUsagePercent: 75,
    networks: [{ id: 'eth-synthetic', receiveBytesPerSecond: 4096, sendBytesPerSecond: 2048 }] });
  assert.deepEqual(plain(context.monitor.system.data), { model: 'Synthetic NAS', dsmVersion: '7.2.synthetic',
    temperatureC: 35, uptime: '03:04:05' });
  assert.deepEqual(plain(context.monitor.storage.data), [{ id: 'volume-synthetic', totalBytes: 1073741824,
    usedBytes: 268435456, status: 'normal' }]);
  for (const section of sections) {
    assert.equal(context.monitor[section].status, 'ready');
    assert.equal(context.monitor[section].observedAt, context.clock.now);
  }
  assert.equal(context.monitor.busy, false);
});

test('hidden monitor never samples, including attach, repeated refresh and manual refresh', async () => {
  const context = harness();
  await context.monitor.refresh();
  await context.monitor.refresh(true);
  await context.clock.advance(120000);
  assert.equal(context.calls.length, 0);
  assert.equal(context.clock.timers.size, 0);
  assert.equal(context.monitor.busy, false);
  for (const section of sections) { assert.equal(context.monitor[section].status, 'idle'); }
});

for (const [mode, interval] of [['home', 15000], ['detail', 5000]]) {
  test(mode + ' samples utilization every ' + interval + 'ms and static sections only at 60 seconds', async () => {
    const context = harness();
    context.monitor.setMode(mode);
    await flush();
    assert.equal(context.count('utilization'), 1);
    assert.deepEqual(context.clock.delays(), [interval]);
    await context.clock.advance(interval - 1);
    assert.equal(context.count('utilization'), 1);
    await context.clock.advance(1);
    assert.equal(context.count('utilization'), 2);
    await context.clock.advance(60000 - interval - 1);
    assert.equal(context.count('utilization'), 60000 / interval);
    assert.equal(context.count('system'), 1);
    assert.equal(context.count('storage'), 1);
    await context.clock.advance(1);
    assert.equal(context.count('utilization'), 60000 / interval + 1);
    assert.equal(context.count('system'), 2);
    assert.equal(context.count('storage'), 2);
    assert.deepEqual(context.clock.delays(), [interval]);
  });
}

test('changing home/detail cancels the old timer and adopts the new cadence', async () => {
  const context = harness();
  context.monitor.setMode('home');
  await flush();
  context.monitor.setMode('detail');
  await flush();
  assert.deepEqual(context.clock.delays(), [5000]);
  await context.clock.advance(5000);
  assert.equal(context.count('utilization'), 3);
  context.monitor.setMode('home');
  await flush();
  assert.deepEqual(context.clock.delays(), [15000]);
  await context.clock.advance(14999);
  assert.equal(context.count('utilization'), 4);
  await context.clock.advance(1);
  assert.equal(context.count('utilization'), 5);
  assert.equal(context.count('system'), 1);
  assert.equal(context.count('storage'), 1);
});

test('leaving monitoring marks previous data stale, pauses timers and foreground immediately resamples', async () => {
  const context = harness();
  context.monitor.setMode('home');
  await flush();
  const snapshots = Object.fromEntries(sections.map(section => [section, context.monitor[section]]));
  await context.clock.advance(1000);
  context.monitor.setMode('hidden');
  for (const section of sections) {
    assert.equal(context.monitor[section].status, 'stale');
    assert.equal(context.monitor[section].data, snapshots[section].data);
    assert.equal(context.monitor[section].observedAt, snapshots[section].observedAt);
  }
  assert.equal(context.clock.timers.size, 0);
  await context.clock.advance(1000);
  await context.monitor.refresh(true);
  assert.equal(context.calls.length, 3);
  context.monitor.setMode('home');
  await flush();
  for (const section of sections) {
    assert.equal(context.count(section), 2);
    assert.equal(context.monitor[section].status, 'ready');
    assert.equal(context.monitor[section].observedAt, context.clock.now);
  }
  assert.deepEqual(context.clock.delays(), [15000]);
});

test('remaining on non-monitoring pages makes no background requests', async () => {
  const context = harness();
  context.monitor.setMode('detail');
  await flush();
  context.monitor.setMode('hidden');
  await context.clock.advance(180000);
  assert.equal(context.calls.length, 3);
  assert.equal(context.clock.timers.size, 0);
});

for (const lateOutcome of ['success', 'session-expired']) {
  test('hidden mode ignores a late ' + lateOutcome + ' response and does not revive sampling', async () => {
    const pending = deferred();
    const context = harness({ utilization: () => pending.promise });
    context.monitor.setMode('home');
    assert.equal(context.monitor.busy, true);
    context.monitor.setMode('hidden');
    if (lateOutcome === 'success') { pending.resolve(structuredClone(samples.utilization)); }
    else { pending.reject(failure(K.SessionExpired)); }
    await flush();
    assert.equal(context.calls.length, 1);
    assert.equal(context.monitor.utilization.status, 'idle');
    assert.equal(context.monitor.utilization.data, undefined);
    assert.equal(context.monitor.busy, false);
    assert.equal(context.sessionFailures.length, 0);
    await context.clock.advance(60000);
    assert.equal(context.calls.length, 1);
    assert.equal(context.clock.timers.size, 0);
  });
}

test('duplicate refreshes share one in-flight sampling pass without an automatic extra request', async () => {
  const pending = deferred();
  const context = harness({ utilization: () => pending.promise });
  context.monitor.setMode('home');
  await Promise.all(Array.from({ length: 5 }, () => context.monitor.refresh()));
  await context.clock.advance(60000);
  assert.equal(context.count('utilization'), 1);
  assert.equal(context.count('system'), 0);
  assert.equal(context.clock.timers.size, 0);
  pending.resolve(structuredClone(samples.utilization));
  await flush();
  assert.equal(context.calls.length, 3);
  assert.equal(context.monitor.busy, false);
  assert.deepEqual(context.clock.delays(), [15000]);
});

for (const lateOutcome of ['success', 'session-expired']) {
  test('detach/attach switches accounts without accepting the old ' + lateOutcome + ' response', async () => {
    const pending = deferred();
    const context = harness({ utilization: () => pending.promise });
    context.monitor.setMode('detail');
    context.monitor.detach();
    const replacement = fakeConnector(context.clock, {
      utilization: () => ({ cpu: { user_load: 41, system_load: 1, other_load: 0 } }),
      system: () => ({ model: 'Synthetic second account' }),
    });
    const newSessionFailures = [];
    context.monitor.attach(replacement.connector, async error => { newSessionFailures.push(error); });
    for (const section of sections) { assert.equal(context.monitor[section].data, undefined); }
    if (lateOutcome === 'success') { pending.resolve(structuredClone(samples.utilization)); }
    else { pending.reject(failure(K.SessionExpired)); }
    await flush();
    assert.equal(context.calls.length, 1);
    assert.equal(replacement.calls.length, 3);
    assert.equal(context.monitor.utilization.data.cpuPercent, 42);
    assert.equal(context.monitor.system.data.model, 'Synthetic second account');
    assert.equal(context.sessionFailures.length, 0);
    assert.equal(newSessionFailures.length, 0);
    assert.equal(context.monitor.busy, false);
    assert.deepEqual(context.clock.delays(), [5000]);
    await context.clock.advance(5000);
    assert.equal(context.calls.length, 1);
    assert.equal(replacement.count('utilization'), 2);
  });
}

test('detaching a ready monitor clears all account data and stops timers', async () => {
  const context = harness();
  context.monitor.setMode('home');
  await flush();
  context.monitor.detach();
  await context.clock.advance(120000);
  await context.monitor.refresh(true);
  assert.equal(context.calls.length, 3);
  assert.equal(context.clock.timers.size, 0);
  for (const section of sections) {
    assert.equal(context.monitor[section].status, 'idle');
    assert.equal(context.monitor[section].data, undefined);
    assert.equal(context.monitor[section].observedAt, 0);
  }
});

for (const section of sections) {
  for (const [reason, kind] of [['permission-105', K.Permission], ['unsupported-capability', K.Unsupported]]) {
    test(section + ' ' + reason + ' disables only that section; automatic polls skip it and manual retries it', async () => {
      const denied = kind === K.Permission ? dsm.dsmFailure(apis[section], 105) : failure(kind);
      const context = harness({ [section]: () => { throw denied; } });
      context.monitor.setMode('home');
      await flush();
      assert.equal(context.monitor[section].status, 'unavailable');
      assert.equal(context.monitor[section].data, undefined);
      for (const healthy of sections.filter(name => name !== section)) {
        assert.equal(context.monitor[healthy].status, 'ready');
      }
      assert.equal(context.sessionFailures.length, 0);
      await context.clock.advance(60000);
      assert.equal(context.count(section), 1);
      assert.equal(context.count(section === 'utilization' ? 'system' : 'utilization'), section === 'utilization' ? 2 : 5);
      assert.equal(context.sessionFailures.length, 0);
      context.replies[section] = () => structuredClone(samples[section]);
      await context.monitor.refresh(true);
      assert.equal(context.count(section), 2);
      assert.equal(context.monitor[section].status, 'ready');
      assert.equal(context.sessionFailures.length, 0);
    });
  }
}

test('all unavailable sections stop automatic probing but allow an explicit manual retry', async () => {
  const context = harness(Object.fromEntries(sections.map(section => [section, () => { throw failure(K.Unsupported); }])));
  context.monitor.setMode('detail');
  await flush();
  assert.equal(context.calls.length, 3);
  assert.equal(context.clock.timers.size, 0);
  await context.clock.advance(120000);
  assert.equal(context.calls.length, 3);
  for (const section of sections) { context.replies[section] = () => structuredClone(samples[section]); }
  await context.monitor.refresh(true);
  for (const section of sections) { assert.equal(context.monitor[section].status, 'ready'); }
  assert.equal(context.calls.length, 6);
  assert.deepEqual(context.clock.delays(), [5000]);
});

for (const section of sections) {
  test(section + ' SessionExpired notifies once and stops all further sampling', async () => {
    const expired = failure(K.SessionExpired);
    const context = harness({ [section]: () => { throw expired; } });
    context.monitor.setMode('detail');
    await flush();
    assert.equal(context.sessionFailures.length, 1);
    assert.equal(context.sessionFailures[0], expired);
    const requestCount = context.calls.length;
    assert.equal(requestCount, sections.indexOf(section) + 1);
    assert.equal(context.monitor.busy, false);
    assert.equal(context.clock.timers.size, 0);
    await context.monitor.refresh(true);
    await context.clock.advance(120000);
    assert.equal(context.calls.length, requestCount);
    assert.equal(context.sessionFailures.length, 1);
  });
}

test('network failures preserve last successful values and observation times as stale', async () => {
  const context = harness();
  context.monitor.setMode('home');
  await flush();
  const snapshots = Object.fromEntries(sections.map(section => [section, context.monitor[section]]));
  await context.clock.advance(1000);
  for (const section of sections) { context.replies[section] = () => { throw failure(K.Network); }; }
  await context.monitor.refresh(true);
  for (const section of sections) {
    assert.equal(context.monitor[section].status, 'stale');
    assert.equal(context.monitor[section].data, snapshots[section].data);
    assert.equal(context.monitor[section].observedAt, snapshots[section].observedAt);
    assert.ok(context.monitor[section].notice.length > 0);
  }
  assert.equal(context.sessionFailures.length, 0);
  assert.deepEqual(context.clock.delays(), [15000]);
});

test('first network failure is an error with no fabricated data and a later automatic poll can recover', async () => {
  const context = harness({ utilization: () => { throw failure(K.Network); } });
  context.monitor.setMode('detail');
  await flush();
  assert.equal(context.monitor.utilization.status, 'error');
  assert.equal(context.monitor.utilization.data, undefined);
  assert.equal(context.monitor.utilization.observedAt, 0);
  context.replies.utilization = () => structuredClone(samples.utilization);
  await context.clock.advance(5000);
  assert.equal(context.monitor.utilization.status, 'ready');
  assert.equal(context.monitor.utilization.data.cpuPercent, 20);
});

test('malformed decoder input keeps prior values stale rather than replacing them with zero', async () => {
  const context = harness();
  context.monitor.setMode('home');
  await flush();
  const snapshots = Object.fromEntries(sections.map(section => [section, context.monitor[section]]));
  context.replies.utilization = () => ({ cpu: { user_load: '20' } });
  context.replies.system = () => ({ sys_temp: -1 });
  context.replies.storage = () => ({ volumes: [{ id: 'volume-synthetic', size: { total: '8', used: '9' } }] });
  await context.monitor.refresh(true);
  for (const section of sections) {
    assert.equal(context.monitor[section].status, 'stale');
    assert.equal(context.monitor[section].data, snapshots[section].data);
    assert.match(context.monitor[section].notice, /格式/);
  }
});

test('empty and unrecognized successful output stays empty without zero-filled metrics', async () => {
  const context = harness({ utilization: () => ({ cpu: { unknown_load: 0 }, memory: { unknown_capacity: 0 } }),
    system: () => ({ unknown_model: 'Synthetic NAS' }), storage: () => ({ unknown_volumes: [] }) });
  context.monitor.setMode('home');
  await flush();
  for (const section of sections) { assert.equal(context.monitor[section].status, 'empty'); }
  assert.equal(context.monitor.utilization.data.cpuPercent, undefined);
  assert.equal(context.monitor.utilization.data.memoryTotalBytes, undefined);
  assert.equal(context.monitor.utilization.data.memoryUsedBytes, undefined);
  assert.equal(context.monitor.utilization.data.memoryUsagePercent, undefined);
  assert.deepEqual(plain(context.monitor.utilization.data.networks), []);
  assert.deepEqual(plain(context.monitor.system.data), {});
  assert.equal(context.monitor.storage.data, undefined);
  context.replies.utilization = () => ({});
  context.replies.system = () => ({});
  context.replies.storage = () => ({ volumes: [] });
  await context.monitor.refresh(true);
  for (const section of sections) { assert.equal(context.monitor[section].status, 'empty'); }
  assert.equal(context.monitor.utilization.data.cpuPercent, undefined);
  assert.deepEqual(plain(context.monitor.storage.data), []);
});

test('explicit zero-valued metrics remain real data, distinct from missing fields', async () => {
  const context = harness({ utilization: () => ({ cpu: { user_load: 0, system_load: 0, other_load: 0 },
    memory: { total_real: 0, avail_real: 0, real_usage: 0 }, network: [{ device: 'eth-synthetic', rx: 0, tx: 0 }] }),
    system: () => ({ sys_temp: 0 }),
    storage: () => ({ volumes: [{ id: 'volume-synthetic', size: { total: '0', used: '0' } }] }) });
  context.monitor.setMode('detail');
  await flush();
  for (const section of sections) { assert.equal(context.monitor[section].status, 'ready'); }
  assert.equal(context.monitor.utilization.data.cpuPercent, 0);
  assert.equal(context.monitor.utilization.data.memoryUsedBytes, 0);
  assert.equal(context.monitor.system.data.temperatureC, 0);
  assert.equal(context.monitor.storage.data[0].totalBytes, 0);
});

test('manual refresh immediately rereads static sections before the 60-second deadline', async () => {
  const context = harness();
  context.monitor.setMode('home');
  await flush();
  await context.clock.advance(1000);
  await context.monitor.refresh(true);
  for (const section of sections) {
    assert.equal(context.count(section), 2);
    assert.equal(context.monitor[section].observedAt, context.clock.now);
  }
  assert.deepEqual(context.clock.delays(), [15000]);
});

test('manual refreshes during an unavailable-section retry merge into one further manual retry', async () => {
  const context = harness({ utilization: () => { throw failure(K.Unsupported); } });
  context.monitor.setMode('home');
  await flush();
  const pending = deferred();
  context.replies.utilization = () => pending.promise;
  const current = context.monitor.refresh(true);
  await Promise.all(Array.from({ length: 4 }, () => context.monitor.refresh(true)));
  assert.equal(context.count('utilization'), 2);
  context.replies.utilization = () => structuredClone(samples.utilization);
  pending.reject(dsm.dsmFailure(apis.utilization, 105));
  await current;
  await flush();
  assert.equal(context.count('utilization'), 3, 'queued manual retry must retry unavailable utilization once');
  assert.equal(context.monitor.utilization.status, 'ready');
  assert.equal(context.count('system'), 3);
  assert.equal(context.count('storage'), 3);
  assert.equal(context.sessionFailures.length, 0);
  assert.deepEqual(context.clock.delays(), [15000]);
});

test('manual refresh during a static sampling pass retains the queued static reread intent', async () => {
  const context = harness();
  context.monitor.setMode('home');
  await flush();
  const pending = deferred();
  context.replies.utilization = () => pending.promise;
  const current = context.monitor.refresh(true);
  await Promise.all(Array.from({ length: 4 }, () => context.monitor.refresh(true)));
  assert.equal(context.count('utilization'), 2);
  assert.equal(context.count('system'), 1);
  context.replies.utilization = () => structuredClone(samples.utilization);
  pending.resolve(structuredClone(samples.utilization));
  await current;
  await flush();
  assert.equal(context.count('utilization'), 3);
  assert.equal(context.count('system'), 3, 'queued manual refresh must not lose system reread intent');
  assert.equal(context.count('storage'), 3, 'queued manual refresh must not lose storage reread intent');
  assert.deepEqual(context.clock.delays(), [15000]);
});
