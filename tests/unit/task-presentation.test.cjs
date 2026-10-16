const { test } = require('node:test');
const assert = require('node:assert/strict');
const { taskRecords, taskMatchesFilter, taskEnded } = require('../../work/core-build/domain/TaskPresentation.js');

const transfers = ['fileUpload', 'shareUpload', 'photoUpload', 'photoBackup', 'download', 'legacy'].map((source, index) => ({
  id: 't' + index, source, direction: source === 'download' ? 'download' : 'upload', name: source, remotePath: '/share/' + source,
  state: index % 2 === 0 ? 'running' : 'failed', bytes: 100, processed: 10, stateText: '', errorText: '', canRemove: index % 2 !== 0
}));
const drive = [{ id: 'same', direction: 'download', name: 'Drive', locationName: '/目标', state: 'paused', errorText: '' }];
const files = [{ id: 'same', operation: 'copy', label: '复制 文件', target: '/目标', sources: ['/来源'], state: 'completed', errorText: '' }];
const actions = [{ id: 'same', action: 'move', name: '文件', destination: '/目标', state: 'accepted', errorText: '' }];

test('task scopes share identities without cross-module records or legacy sources', () => {
  const records = scope => taskRecords(scope, transfers, drive, files, actions);
  const root = records('root');
  assert.equal(root.length, 8); assert.equal(new Set(root.map(item => item.key)).size, root.length);
  assert.deepEqual(records('files').map(item => item.key), ['transfer:t0', 'transfer:t1', 'transfer:t4', 'file:same']);
  assert.deepEqual(records('photos').map(item => item.key), ['transfer:t2', 'transfer:t3']);
  assert.deepEqual(records('drive').map(item => item.key), ['driveTransfer:same', 'driveAction:same']);
  assert.ok(root.find(item => item.key === 'driveAction:same').name.startsWith('移动'));
  assert.equal(root.find(item => item.key === 'file:same').path, '/目标');
});

test('active and ended partition every scope, retaining paused, verifying and uncertain work as active', () => {
  for (const state of ['preparing', 'queued', 'creating', 'running', 'waiting', 'paused', 'verifying', 'accepted', 'unknown']) {
    assert.equal(taskEnded(state), false, state);
  }
  for (const state of ['completed', 'failed', 'partial', 'closed', 'clearing']) assert.equal(taskEnded(state), true, state);
  for (const scope of ['root', 'files', 'photos', 'drive']) {
    const rows = taskRecords(scope, transfers, drive, files, actions);
    const count = filter => rows.filter(row => taskMatchesFilter(row, filter)).length;
    assert.equal(count('all'), count('active') + count('finished'));
  }
});

test('cancelled and legacy records never affect counts and unknown sizes do not produce a percentage', () => {
  const rows = taskRecords('root', [...transfers, { ...transfers[0], id: 'cancelled', state: 'cancelled' },
    { ...transfers[4], id: 'unknown-size', bytes: 0 }], [...drive, { ...drive[0], id: 'cancelled', state: 'cancelled' }],
    [...files, { ...files[0], id: 'legacy', operation: 'legacy' }], actions);
  assert.equal(rows.some(row => row.id === 'cancelled' || row.id === 'legacy'), false);
  assert.equal(rows.find(row => row.id === 'unknown-size').progress, undefined);
  assert.equal(rows.find(row => row.key === 'driveTransfer:same').progress, undefined);
});
