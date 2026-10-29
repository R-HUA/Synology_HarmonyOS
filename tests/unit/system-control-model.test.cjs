const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.HARMONY_SDK_ROOT || 'D:/Program Files/DevEco Studio/sdk/default', 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const control = require('../../work/core-build/domain/SystemControl.js');

function fixture() {
  const calls = [], records = [];
  const state = { fingerprint: 'serial', saveError: false, gate: undefined };
  const source = fs.readFileSync('entry/src/main/ets/features/control/SystemControlModel.ets', 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, Date, Error,
    require(id) {
      if (id === '@kit.AbilityKit') return {};
      if (id === '@kit.ArkTS') return { util: { generateRandomUUID: () => 'record-id' } };
      if (id.endsWith('/DsmProtocol')) return dsm;
      if (id.endsWith('/ConnectionRoutes')) return { decodeNasDeviceIdentity: row => row };
      if (id.endsWith('/SystemControl')) return control;
      if (id.endsWith('/NasConnector')) return {};
      if (id.endsWith('/NasAddressBookStore')) return { nasDeviceFingerprint: async identity => identity.serial };
      if (id.endsWith('/NasControlRecordStore')) return { NasControlRecordStore: class {
        async load() { return undefined; }
        async save(record) { if (state.saveError) throw new Error('store'); records.push(record); }
      } };
      throw new Error(id);
    },
  });
  const model = new module.exports.SystemControlModel();
  const connector = {
    async telemetrySystem() { calls.push('identity'); return { model: 'NAS', serial: state.fingerprint }; },
    async systemControl(action) { calls.push(action); if (state.gate) await state.gate; },
    async logout() { calls.push('logout'); },
  };
  return { model, calls, records, state, async open() { return model.open({}, connector, 'https://nas.example.test', 'alice', () => {}); } };
}

test('control uses the current account, requires the full action word and never logs out the shared connector', async () => {
  const f = fixture(); await f.open();
  assert.equal(f.model.account, 'alice'); assert.equal(f.model.authorized, true);
  f.model.prepare('reboot'); f.model.confirmationText = '确定'; await f.model.submit();
  assert.equal(f.calls.includes('reboot'), false); assert.equal(f.records.length, 0);
  f.model.confirmationText = '重启'; await f.model.submit();
  assert.equal(f.calls.filter(x => x === 'reboot').length, 1);
  assert.deepEqual(f.records.map(x => x.state), ['pending', 'accepted']);
  assert.equal(f.records[0].account, 'alice');
  assert.equal(f.calls.filter(x => x === 'identity').length, 2);
  f.model.deactivate(); assert.equal(f.calls.includes('logout'), false);
});

test('changed device identity and failed intent persistence prevent control dispatch', async () => {
  for (const scenario of ['identity', 'save']) {
    const f = fixture(); await f.open(); f.model.prepare('shutdown'); f.model.confirmationText = '关机';
    if (scenario === 'identity') f.state.fingerprint = 'changed';
    else f.state.saveError = true;
    await f.model.submit();
    assert.equal(f.calls.includes('shutdown'), false);
    assert.ok(f.model.errorText);
  }
});

test('a pending operation cannot be submitted twice', async () => {
  const f = fixture(); await f.open(); f.model.prepare('reboot'); f.model.confirmationText = '重启';
  let release; f.state.gate = new Promise(resolve => { release = resolve; });
  const pending = f.model.submit();
  while (!f.calls.includes('reboot')) await Promise.resolve();
  await f.model.submit(); release(); await pending;
  assert.equal(f.calls.filter(x => x === 'reboot').length, 1);
});
