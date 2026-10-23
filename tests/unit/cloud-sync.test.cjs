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
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/cloudsync', name), 'utf8').replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
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
const p = load('CloudSyncProtocol.ts');
const { CloudSyncModel } = load('CloudSyncModel.ets');
const { CloudSyncRepository } = load('CloudSyncRepository.ts');
const connection = { id: '9007199254740993', task_name: 'Drive', user_name: 'private@example.test', status: 'future', resource: 'Drive' };
const item = p.decodeCloudConnections({ conn: [connection] })[0];
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });

test('cloud connections redact accounts and directories retain separate identities and directions', () => {
  assert.equal(item.account, 'p***'); assert.equal(item.status, '未知状态');
  assert.doesNotMatch(JSON.stringify(item), /private|example|user_name/);
  const sess = [1, 2].map((id, i) => ({ sess_id: id, conn_id: connection.id, sync_direction: i ? 'ONLY_UPLOAD' : 'ONLY_DOWNLOAD', sync_status: 'uptodate' }));
  const folders = p.decodeCloudFolders({ sess }, connection.id);
  assert.equal(folders.length, 2); assert.equal(folders[1].direction, '仅上传');
  assert.throws(() => p.decodeCloudFolders({ sess }, 'other'));
  assert.equal(p.decodeCloudQuota({}).total, undefined);
  assert.throws(() => p.decodeCloudConnections({ conn: [connection, connection] }));
});

test('cloud history respects time boundary, duplicate events, page limits and retained byte window', () => {
  const row = { time: 100, file_name: 'same', action: 1, log_level: 2 };
  assert.equal(p.decodeCloudHistory({ items: [row, row] }, 0, 100).items.length, 2);
  assert.throws(() => p.decodeCloudHistory({ items: [row] }, 0, 99));
  assert.throws(() => p.decodeCloudHistory({ items: Array(101).fill(row) }, 0, 100));
  assert.equal(p.cloudHistoryWindow(Array(600).fill({ ...row, path: '😀'.repeat(2000) })).length < 500, true);
});

test('cloud connector only calls the four read methods with fixed version and connection-scoped history', async () => {
  const calls = [], replies = [ok({ 'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 6 }, 'SYNO.CloudSync': { path: 'entry.cgi', minVersion: 1, maxVersion: 9, requestFormat: 'JSON' } })];
  const connector = new NasConnector({ async post(...args) { calls.push(args); return replies.shift(); }, close() {} });
  await connector.discover('https://nas.example'); connector.restoreSession([{ name: 'FileStation', sid: 'sid', synoToken: '' }]);
  replies.push(ok({ conn: [connection] })); await connector.readCloudSync('connections', '', 0, 0, p.decodeCloudConnections);
  assert.equal(connector.capabilitySnapshots().find(x => x.feature === 'cloudSyncConnections').state, 'available');
  assert.equal(connector.capabilitySnapshots().find(x => x.feature === 'cloudSyncHistory').state, 'unverified');
  replies.push(ok({ items: [] })); await connector.readCloudSync('history', connection.id, 100, 200, x => x);
  const fields = new URLSearchParams(calls.at(-1)[1]);
  assert.equal(fields.get('method'), 'get_log'); assert.equal(fields.get('version'), '1'); assert.equal(fields.get('limit'), '100');
  assert.equal(JSON.parse(fields.get('connection_id')), connection.id); assert.equal(fields.get('date_to'), '200');
  await assert.rejects(connector.readCloudSync('pause', connection.id, 0, 0, x => x));
  assert.equal(calls.length, 3);
  assert.doesNotMatch(calls.map(x => x[1]).join(' '), /get_conn_auth_info|pause|resume|relink|create|delete/);
});

test('deleted connection and cancellation cannot continue directory reads', async () => {
  let reads = 0;
  const repository = new CloudSyncRepository({ readCloudSync: async () => { reads++; return []; } });
  await assert.rejects(repository.folders(item.id, () => {}), /已被移除/); assert.equal(reads, 1);
  await assert.rejects(repository.folders(item.id, () => { throw Error('cancel'); }), /cancel/); assert.equal(reads, 2);
});

test('cloud cache survives read failure, history stays scoped, and late reads cannot cross pages or accounts', async () => {
  const model = new CloudSyncModel(); let complete; const calls = [];
  model.repository = { list: async () => [item], folders: async () => [], quota: async () => ({}), history: async (...args) => {
    calls.push(args); return { items: [], received: 100, more: true };
  } };
  model.setVisible(true); await tick(); const checked = model.checkedAt;
  model.repository.list = async () => { throw new dsm.NasFailure(dsm.NasErrorKind.Network, '断网'); };
  await model.refresh(); assert.equal(model.items[0].id, item.id); assert.equal(model.checkedAt, checked);
  model.select(item); await tick(); await model.readHistory(); await model.readHistory(true);
  assert.equal(calls[0][0], item.id); assert.equal(calls[1][1], 100); assert.equal(calls[0][2], calls[1][2]);
  model.repository.history = () => new Promise(resolve => { complete = resolve; });
  const pending = model.readHistory(); model.back(); complete({ items: [{ key: 'late' }], received: 1, more: false }); await pending;
  assert.equal(model.history.length, 0); model.reset(); assert.equal(model.items.length, 0);
});
