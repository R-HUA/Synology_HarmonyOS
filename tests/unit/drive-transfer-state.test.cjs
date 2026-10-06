const { test } = require('node:test');
const assert = require('node:assert/strict');
const state = require('../../work/core-build/domain/DriveTransferState.js');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');
const origin = 'https://nas.example.test:5001';
const record = (changes = {}) => ({ id: '11111111-1111-4111-8111-111111111111', direction: 'upload',
  resource: { nasOrigin: origin, account: 'alice', fileId: '821014439470870977' },
  name: '记录.txt', locationName: '测试目录', bytes: 3, state: 'running', errorText: '', ...changes });
const decode = records => state.decodeDriveTransfers(JSON.stringify({ version: 1, scope: 'scope', records }), 'scope', origin, 'alice');

test('Drive resource snapshots preserve long IDs and reject cross-account, malformed or duplicate history', () => {
  assert.equal(decode([record()])[0].resource.fileId, '821014439470870977');
  for (const bad of [record({ resource: { nasOrigin: origin, account: 'bob', fileId: '1' } }),
    record({ resource: { nasOrigin: 'https://other.test', account: 'alice', fileId: '1' } }),
    record({ resource: { nasOrigin: origin, account: 'alice', fileId: 821014439470870977 } }),
    record({ name: '../file' }), record({ id: '../escape' }), record({ bytes: -1 }),
    record({ bytes: state.DRIVE_TRANSFER_MAX_BYTES + 1 }), record({ direction: 'download', state: 'unknown' })]) {
    assert.throws(() => decode([bad]));
  }
  assert.throws(() => decode([record(), record()]));
  assert.throws(() => state.decodeDriveTransfers('{', 'scope', origin, 'alice'));
  assert.throws(() => state.decodeDriveTransfers('{"version":1,"scope":"other","records":[]}', 'scope', origin, 'alice'));
});

test('zero-byte downloads are distinct from unknown sizes and interrupted history never resumes requests', () => {
  assert.equal(decode([record({ direction: 'download', state: 'completed', bytes: 0 })])[0].bytes, 0);
  assert.equal(decode([record({ direction: 'download', bytes: undefined })])[0].bytes, undefined);
  assert.throws(() => decode([record({ state: 'completed', bytes: undefined })]));
  assert.equal(state.recoverDriveTransfer(record()).state, 'unknown');
  assert.equal(state.recoverDriveTransfer(record({ direction: 'download' })).state, 'cancelled');
  assert.equal(state.recoverDriveTransfer(record({ state: 'preparing' })).state, 'cancelled');
  assert.equal(state.recoverDriveTransfer(record({ state: 'completed' })).state, 'completed');
});

test('ambiguous upload failures remain unknown while rejected inputs and cancelled downloads have definite outcomes', () => {
  for (const kind of [K.Network, K.Http, K.Protocol, K.Cancelled, K.SessionExpired]) {
    assert.equal(state.driveTransferFailureState('upload', true, new NasFailure(kind, 'failed')), 'unknown');
  }
  for (const kind of [K.Permission, K.InvalidInput, K.Unsupported]) {
    assert.equal(state.driveTransferFailureState('upload', true, new NasFailure(kind, 'failed')), 'failed');
  }
  assert.equal(state.driveTransferFailureState('upload', false, new NasFailure(K.Cancelled, 'stop')), 'cancelled');
  assert.equal(state.driveTransferFailureState('download', true, new NasFailure(K.Cancelled, 'stop')), 'cancelled');
  assert.equal(state.driveTransferFailureState('upload', true, new Error('unknown')), 'unknown');
});

test('RCP background records recover as interrupted, while verification evidence survives schema-one snapshots', () => {
  assert.equal(state.recoverDriveTransfer(record({ executor: 'rcpBackground' })).state, 'unknown');
  assert.equal(state.recoverDriveTransfer(record({ direction: 'download', executor: 'rcpBackground' })).state, 'cancelled');
  const waiting = record({ direction: 'download', state: 'verifying', systemCompleted: true, executor: 'agent',
    downloadVersionId: 'v1', downloadModifiedAt: 123.5 });
  assert.equal(decode([waiting])[0].state, 'verifying'); assert.equal(state.recoverDriveTransfer(waiting).state, 'verifying');
  assert.equal(state.driveTransferStateText('verifying'), '下载待校验');
  for (const bad of [record({ state: 'verifying', systemCompleted: true }), { ...waiting, systemCompleted: false },
    { ...waiting, bytes: undefined }, { ...waiting, executor: 'daemon' }, { ...waiting, verifiedMd5: 'wrong' },
    { ...waiting, downloadModifiedAt: -1 }, { ...waiting, systemCompleted: 'true' }]) assert.throws(() => decode([bad]));
  const complete = { ...waiting, state: 'completed', verifiedMd5: 'a'.repeat(32) };
  assert.equal(decode([complete])[0].verifiedMd5, complete.verifiedMd5);
});

test('schema one remains compatible while background and slice records are bounded and account scoped', () => {
  const background = { taskId: '123', attempt: 1, createdAt: 12345, startAttempted: true, processed: 1,
    httpStatus: 200, contentType: '', contentLength: '', contentDisposition: '' };
  const uploadSession = { token: 'a'.repeat(32), modifiedTime: 123.5, sourceMtime: 124, sourceMd5: 'b'.repeat(32), started: true, offset: 1 };
  const pending = record({ background, uploadSession });
  assert.deepEqual(decode([pending])[0].uploadSession, uploadSession);
  assert.equal(state.recoverDriveTransfer(pending).state, 'running');
  assert.equal(state.recoverDriveTransfer(record({ state: 'creating', background })).state, 'creating');
  const copied = state.copyDriveTransfer(pending); copied.background.taskId = '999'; copied.uploadSession.offset = 2;
  assert.equal(pending.background.taskId, '123'); assert.equal(pending.uploadSession.offset, 1);
  for (const bad of [record({ background: { ...background, taskId: '../task' } }), record({ background: { ...background, startAttempted: 'true' } }),
    record({ background: { ...background, processed: -1 } }), record({ uploadSession: { ...uploadSession, token: 'new' } }),
    record({ uploadSession: { ...uploadSession, offset: 4 } }), record({ uploadSession: { ...uploadSession, sourceMd5: '' } }),
    record({ state: 'paused' }), record({ direction: 'download', state: 'running', uploadSession })]) {
    assert.throws(() => decode([bad]));
  }
});
