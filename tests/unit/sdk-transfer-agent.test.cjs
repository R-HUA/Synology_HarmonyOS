const { test } = require('node:test');
const assert = require('node:assert/strict');
const protocol = require('../../work/core-build/domain/DsmProtocol.js');
const load = require('../helpers/load-sdk-transfer-agent.cjs');
const events = ['response', 'progress', 'completed', 'failed'];

test('missing system transfer capability fails before calling SDK operations', async () => {
  const { sdkTransferAgent } = load({}, protocol, name => {
    assert.equal(name, 'SystemCapability.Request.FileTransferAgent'); return false;
  });
  const unsupported = error => error.kind === protocol.NasErrorKind.Unsupported;
  for (const action of [() => sdkTransferAgent.create({}, {}), () => sdkTransferAgent.getTask({}, '1'),
    () => sdkTransferAgent.show('1'), () => sdkTransferAgent.search({}), () => sdkTransferAgent.remove('1'),
    () => sdkTransferAgent.start({}), () => sdkTransferAgent.stop({})]) {
    await assert.rejects(action(), unsupported);
  }
  assert.throws(() => sdkTransferAgent.observe({}, {}), unsupported);
});

test('synchronous throws and asynchronous rejections preserve task-not-found codes without converting all failures to missing', async () => {
  for (const sync of [true, false]) {
    for (const code of [21900006, 201, 21900003]) {
      const failure = Object.assign(new Error('contains private task configuration'), { code });
      const fail = () => { if (sync) throw failure; return Promise.reject(failure); };
      const { sdkTransferAgent } = load({ create: fail, getTask: fail, show: fail, search: fail, remove: fail }, protocol);
      for (const action of [() => sdkTransferAgent.create({}, {}), () => sdkTransferAgent.getTask({}, '1'),
        () => sdkTransferAgent.show('1'), () => sdkTransferAgent.search({}), () => sdkTransferAgent.remove('1'),
        () => sdkTransferAgent.start({ start: fail }), () => sdkTransferAgent.stop({ stop: fail })]) {
        await assert.rejects(action(), error => error.code === code && !/private/.test(error.message));
      }
    }
  }
});

function fixture(failOn = '', failOff = '') {
  const callbacks = new Map();
  const removed = [];
  const delivered = [];
  const failures = [];
  const diagnostics = [];
  const task = {
    on(event, callback) { callbacks.set(event, callback); if (event === failOn) throw { code: 21900003 }; },
    off(event) { removed.push(event); if (event === failOff) throw { code: 201 }; },
  };
  const listeners = Object.fromEntries(events.map(event => [event, value => delivered.push([event, value])]));
  listeners.error = error => failures.push(error);
  const { sdkTransferAgent } = load({}, protocol, () => true, (...args) => diagnostics.push(args));
  return { sdkTransferAgent, task, listeners, callbacks, removed, delivered, failures, diagnostics };
}

test('partial listener registration unwinds every attempted registration and silences retained callbacks', () => {
  for (const event of events) {
    const f = fixture(event, 'response');
    assert.throws(() => f.sdkTransferAgent.observe(f.task, f.listeners), error => error.code === 21900003);
    assert.deepEqual(f.removed, events.slice(0, events.indexOf(event) + 1));
    for (const callback of f.callbacks.values()) callback({ processed: 42 });
    assert.equal(f.delivered.length, 0);
  }
});

test('one listener removal failure cannot prevent the other removals or allow late event delivery', () => {
  const f = fixture('', 'response');
  const dispose = f.sdkTransferAgent.observe(f.task, f.listeners);
  f.callbacks.get('progress')({ processed: 1 });
  assert.equal(f.delivered.length, 1);
  dispose();
  dispose();
  assert.deepEqual(f.removed, events);
  for (const callback of f.callbacks.values()) callback({ processed: 42 });
  assert.equal(f.delivered.length, 1);
  assert.equal(f.diagnostics.length, 1);
});

test('event callback exceptions reach the explicit error callback rather than escaping into the SDK', () => {
  const f = fixture();
  const cancelled = new protocol.NasFailure(protocol.NasErrorKind.Cancelled, 'cancelled');
  f.listeners.progress = () => { throw cancelled; };
  const dispose = f.sdkTransferAgent.observe(f.task, f.listeners);
  assert.doesNotThrow(() => f.callbacks.get('progress')({ processed: 1 }));
  assert.equal(f.failures[0], cancelled);
  dispose();
});
