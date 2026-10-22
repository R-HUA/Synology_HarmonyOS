const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.HARMONY_SDK_ROOT || 'D:/Program Files/DevEco Studio/sdk/default',
  'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

function fixture(options = {}) {
  const calls = [];
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/tasks/TransferLiveView.ets'), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
  const liveViewManager = { LifeCycleMode: { AUTO_STOP_WHEN_APP_TERMINATE: 0 }, CapsuleType: { CAPSULE_TYPE_TEXT: 0 },
    async isLiveViewEnabled() { return options.enabled !== false; } };
  for (const name of ['startLiveView', 'updateLiveView', 'stopLiveView']) {
    liveViewManager[name] = async view => {
      calls.push({ name, count: view.liveViewData.capsule.content });
      if (name === 'startLiveView' && options.start) await options.start;
      return { resultCode: options.resultCode || 0, message: 'receipt' };
    };
  }
  const mocks = { '@kit.LiveViewKit': { liveViewManager }, '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {} } },
    '@kit.AbilityKit': { wantAgent: { OperationType: { START_ABILITY: 0 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 0 },
      async getWantAgent() { return {}; } } } };
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, require: id => mocks[id],
    canIUse: () => true, $r: id => ({ id }), Error, Date });
  const view = new module.exports.TransferLiveView();
  const context = { abilityInfo: { bundleName: 'test', name: 'EntryAbility' }, resourceManager: { getStringSync: id => id } };
  return { view, context, calls };
}

test('live view serializes stop after a pending start and ignores unchanged counts', async () => {
  let release;
  const start = new Promise(resolve => { release = resolve; });
  const f = fixture({ start });
  f.view.update(f.context, 2);
  await new Promise(resolve => setImmediate(resolve));
  f.view.update(f.context, 0);
  release();
  await f.view.pending;
  assert.deepEqual(f.calls, [{ name: 'startLiveView', count: '2' }, { name: 'stopLiveView', count: '0' }]);
  f.view.update(f.context, 0);
  await f.view.pending;
  assert.equal(f.calls.length, 2);
});

test('disabled permission and rejected receipts remain visible failures', async () => {
  for (const options of [{ enabled: false }, { resultCode: 7 }]) {
    const f = fixture(options);
    f.view.update(f.context, 1);
    await f.view.pending;
    assert.equal(f.view.active, false);
    assert.equal(f.view.errorText, 'app.string.live_view_failed');
    assert.equal(f.calls.length, options.enabled === false ? 0 : 1);
  }
});
