const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT;
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const presentation = require('../../work/core-build/domain/TaskPresentation.js');
const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/tasks/TaskPage.ets'), 'utf8');
// 执行页面实际分区和清理准备逻辑；原生页签布局另由构建及模拟器验证。
const prefix = source.slice(source.indexOf('type TaskCategory'), source.indexOf('  @Builder'))
  .replace(/@Monitor\([^\n]*\)\s*/g, '')
  .replace(/@(?:ComponentV2|Require|Param|Event|Local|Computed)\b\s*/g, '')
  .replace('export struct TaskPage', 'class TaskPage');
const compiled = ts.transpileModule(prefix + '\n}\nmodule.exports = TaskPage;', {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText;
const mod = { exports: {} };
vm.runInNewContext(compiled, { module: mod, ...presentation, Scroller: class {}, $r: value => value });

function record(id, state, direction = 'download') {
  return { id, source: direction === 'download' ? 'download' : 'fileUpload', direction, state,
    name: id, remotePath: '/目标/' + id, bytes: 100, processed: 20, stateText: state, errorText: '',
    canRemove: presentation.taskEnded(state) };
}
function page() {
  const page = new mod.exports();
  page.state = { scope: 'root', categoryIndex: 0, filter: 'finished' };
  page.model = { queue: { ready: true, items: [record('paused', 'paused'), record('unknown', 'unknown'),
    record('done', 'completed'), record('failed', 'failed'), record('upload', 'running', 'upload')], errorText: '' },
    driveTransfers: { ready: true, items: [], errorText: '' }, fileTasksReady: true, fileTasks: [], fileTasksErrorText: '',
    driveActions: { ready: true, items: [], errorText: '' } };
  page.text = value => value;
  return page;
}

test('root category pages partition download and upload records into active and ended sections', () => {
  const p = page();
  assert.deepEqual(Array.from(p.entries, row => row.key), ['header:download:active', 'transfer:paused', 'transfer:unknown',
    'header:download:finished', 'transfer:done', 'transfer:failed']);
  assert.equal(p.groupRecords('download', 'active').length, 2);
  assert.equal(p.groupRecords('download', 'finished').length, 2);
  p.state.categoryIndex = 1;
  assert.deepEqual(Array.from(p.entries, row => row.key), ['header:upload:active', 'transfer:upload']);
  p.state.categoryIndex = 2;
  assert.equal(p.entries.length, 0);
  p.state.categoryIndex = 3;
  assert.equal(p.entries.length, 0);
});

test('unloaded or failed categories retain their sections rather than becoming an empty result', () => {
  const p = page(); p.model.queue.items = [];
  p.model.queue.ready = false;
  assert.equal(p.entries.length, 2); assert.equal(p.groupReady('download'), false);
  p.model.queue.ready = true; p.model.queue.errorText = '读取失败';
  assert.equal(p.entries.length, 2); assert.equal(p.groupError('download'), '读取失败');
  p.model.queue.errorText = '';
  assert.equal(p.entries.length, 0);
});

test('root ended-section cleanup freezes only ended records in the selected category', () => {
  const p = page();
  p.prepareClear(p.groupRecords('download', 'finished').filter(row => row.canRemove), 'finished');
  p.model.queue.items.push(record('later', 'completed'));
  assert.deepEqual(Array.from(p.clearRecords, row => row.id), ['done', 'failed']);
  assert.equal(p.deleteLocalFiles, false);
  assert.ok(p.clearScope.includes('app.string.task_finished'));
  assert.ok(p.clearScope.includes('app.string.task_downloads'));
});
