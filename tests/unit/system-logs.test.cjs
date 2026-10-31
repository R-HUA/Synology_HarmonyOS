const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.HARMONY_SDK_ROOT || 'D:/Program Files/DevEco Studio/sdk/default', 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const common = require('../../work/core-build/domain/ReadOnlyProtocol.js');
const { NasConnector } = require('../../work/core-build/network/NasConnector.js');
const tick = () => new Promise(resolve => setImmediate(resolve));
function load(name) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/systemlogs', name), 'utf8').replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const module = { exports: {} };
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText, {
    module, exports: module.exports, Date, Error, require(id) {
      if (id.endsWith('/DsmProtocol')) return dsm;
      if (id.endsWith('/ReadOnlyProtocol')) return common;
      if (id === '@kit.PerformanceAnalysisKit') return { hilog: { error() {} } };
      if (id.startsWith('./')) return load(id.slice(2) + '.ts');
      throw Error(id);
    }
  }); return module.exports;
}
const p = load('SystemLogProtocol.ts');
const { SystemLogModel } = load('SystemLogModel.ets');
const row = { time: '2026-10-24T10:00:00+08:00', level: 'Information', logtype: 'system', who: 'user', descr: 'error is part of this message' };
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });

test('log decoding retains duplicate and unordered events without inferring severity from messages', () => {
  const page = p.decodeSystemLogs({ items: [row, { ...row, time: '2026-10-23 10:00:00', level: 'future' }, row] }, 100);
  assert.equal(page.items.length, 3); assert.equal(page.items[0].level, '信息'); assert.equal(page.items[1].level, '未知级别');
  assert.equal(page.items[1].timestamp, undefined); assert.equal(page.items[1].time, '2026-10-23 10:00:00');
  assert.equal(new Set(page.items.map(x => x.key)).size, 3);
  assert.equal(p.filterSystemLogs(page.items, 'error', '信息', '系统', 0, Date.now()).length, 2);
  assert.equal(p.filterSystemLogs(page.items, '', '全部', '全部', 1, Date.parse(row.time)).length, 2);
  assert.match(p.systemLogCopy(page.items[0]), /user/); assert.equal(p.decodeSystemLogs({ items: [] }, 0).items.length, 0);
  assert.throws(() => p.decodeSystemLogs({ items: Array(101).fill(row) }, 0));
});

test('system log connector fixes read source, page size and upper time boundary', async () => {
  const calls = [], replies = [ok({ 'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 6 }, 'SYNO.Core.SyslogClient.Log': { path: 'entry.cgi', minVersion: 1, maxVersion: 9 } })];
  const connector = new NasConnector({ async post(...args) { calls.push(args); return replies.shift(); }, close() {} });
  await connector.discover('https://nas.example'); connector.restoreSession({ sid: 'sid', synoToken: '' });
  replies.push(ok({ items: [row] })); await connector.readSystemLogs(100, 200, x => p.decodeSystemLogs(x, 100));
  const fields = new URLSearchParams(calls.at(-1)[1]);
  assert.equal(fields.get('api'), 'SYNO.Core.SyslogClient.Log'); assert.equal(fields.get('method'), 'list');
  assert.equal(fields.get('version'), '1'); assert.equal(fields.get('limit'), '100'); assert.equal(fields.get('dateto'), '200');
  await assert.rejects(connector.readSystemLogs(500, 200, x => x)); assert.equal(calls.length, 2);
});

test('manual pagination freezes time, bounds retained records and leaves failed refresh cache intact', async () => {
  const model = new SystemLogModel(), calls = [];
  model.repository = { async list(offset, until) { calls.push([offset, until]); return p.decodeSystemLogs({ items: Array(100).fill(row), total: 1000 }, offset); } };
  model.setVisible(true); await tick();
  for (let i = 0; i < 4; i++) await model.refresh(true);
  assert.equal(model.items.length, 500); assert.equal(model.truncated, true); assert.equal(model.more, false);
  assert.equal(new Set(calls.map(x => x[1])).size, 1); assert.equal(calls[4][0], 400);
  await model.refresh(true); assert.equal(calls.length, 5);
  const old = model.checkedAt;
  model.repository.list = async () => { throw new dsm.NasFailure(dsm.NasErrorKind.Network, '断网'); };
  await model.refresh(); assert.equal(model.items.length, 500); assert.equal(model.checkedAt, old); assert.match(model.errorText, /断网/);
  assert.equal(p.systemLogWindow(Array(100).fill({ ...row, message: '😀'.repeat(3000) })).length < 100, true);
});

test('hiding, reconnecting and switching accounts discard pending system log results', async () => {
  const model = new SystemLogModel(); let complete;
  model.repository = { list: () => new Promise(resolve => { complete = resolve; }) };
  model.setVisible(true); model.setVisible(false); complete({ items: [row], more: false, received: 1 }); await tick();
  assert.equal(model.items.length, 0); assert.equal(model.loading, false);
  model.setVisible(true); model.reset(); complete({ items: [row], more: false, received: 1 }); await tick();
  assert.equal(model.items.length, 0); assert.equal(model.checkedAt, 0);
  const page = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/systemlogs/SystemLogPage.ets'), 'utf8');
  assert.match(page, /defaultFocus\(false\)/);
  assert.doesNotMatch(page, /搜索与筛选仅限已加载记录/);
});
