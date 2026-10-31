const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'D:/Program Files/DevEco Studio/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/workbench/ServicePresentation.ts'), 'utf8');
const fixture = { exports: {} };
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText,
  { module: fixture, exports: fixture.exports, Date,
    require: id => { assert.equal(id, '../../core/domain/TelemetryProtocol'); return require('../../work/core-build/domain/TelemetryProtocol.js'); } });
const { serviceErrorKind, serviceUpdatedTime } = fixture.exports;

test('service failures retain actionable categories without exposing protocol diagnostics', () => {
  assert.equal(serviceErrorKind('当前账号没有执行此操作的权限。'), 'permission');
  assert.equal(serviceErrorKind('登录会话已过期。'), 'session');
  assert.equal(serviceErrorKind('服务器返回的连接列表格式不正确。'), 'protocol');
  assert.equal(serviceErrorKind('网络连接超时。'), 'network');
  assert.equal(serviceErrorKind('Unexpected field private-response-value'), 'unavailable');
});

test('update time uses Chinese page clock format and omits an unread timestamp', () => {
  assert.equal(serviceUpdatedTime(0), '');
  assert.equal(serviceUpdatedTime(new Date(2026, 9, 29, 8, 4, 15).getTime()), '08:04');
  assert.equal(serviceUpdatedTime(new Date(2026, 9, 29, 20, 40).getTime()), '20:40');
});

test('known device models use their bundled product artwork and unknown models keep the generic fallback', () => {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/workbench/NasDeviceArtwork.ets'), 'utf8');
  const model = { exports: {} };
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText,
    { module: model, exports: model.exports, require: () => ({}), $r: name => name });
  assert.equal(model.exports.hasModelArtwork(' DS3622xs+ '), true);
  assert.equal(model.exports.bundledDeviceArtwork('DS3622XS+'), 'app.media.device_ds3622xsplus');
  assert.equal(model.exports.hasModelArtwork('unknown-model'), false);
  assert.equal(model.exports.bundledDeviceArtwork('unknown-model'), 'app.media.nas_device_line');
});

test('device information fills a missing home model while stale responses cannot alter another session', async () => {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/connection/ConnectionViewModel.ets'), 'utf8');
  const body = source.match(/async serverInfo\(\): Promise<string> \{([\s\S]*?)\n  \}/)[1];
  const read = vm.runInNewContext(ts.transpileModule(`(async function() { ${body} })`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None }
  }).outputText, { hilog: { info() {} } });
  const info = { model: 'DS3622xs+', dsmVersion: '7.3', fileStationVersion: '', photosVersion: '', administrator: false };
  const state = { busy: false, authenticated: true, generation: 1, deviceModel: '',
    connector: { environment: async () => info } };
  assert.match(await read.call(state), /DS3622xs\+/); assert.equal(state.deviceModel, info.model);
  state.deviceModel = 'DS220+'; await read.call(state); assert.equal(state.deviceModel, 'DS220+');
  let complete;
  state.connector = { environment: () => new Promise(resolve => { complete = resolve; }) };
  const pending = read.call(state);
  state.generation++; state.busy = false; state.deviceModel = '';
  complete(info); assert.equal(await pending, ''); assert.equal(state.deviceModel, '');
});
