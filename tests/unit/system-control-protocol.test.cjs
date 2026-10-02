const test = require('node:test').test;
const assert = require('node:assert/strict');
const control = require('../../work/core-build/domain/SystemControl.js');
const protocol = require('../../work/core-build/domain/DsmProtocol.js');

const SYNTHETIC_RECORD = {
  id: '01234567-89ab-cdef-0123-456789abcdef', origin: 'https://nas.example.test:5001',
  account: 'synthetic-account', model: 'Synthetic NAS', fingerprint: 'ab'.repeat(32),
  action: 'reboot', state: 'pending', createdAt: 100, updatedAt: 100,
};
const isKind = kind => error => error instanceof protocol.NasFailure && error.kind === kind;
const notRejected = kind => error => isKind(kind)(error) && !(error instanceof control.NasControlRejection);
const rejectsInput = callback => assert.throws(callback, isKind(protocol.NasErrorKind.InvalidInput));
const rejectsProtocol = callback => assert.throws(callback, notRejected(protocol.NasErrorKind.Protocol));
const response = value => JSON.stringify(value);
const snapshot = record => response({ version: 1, record });

test('SYNTHETIC success=true accepts the request without resolving its pending or accepted record', () => {
  for (const envelope of [{ success: true }, { success: true, data: {} }, { success: true, data: { accepted: true } }]) {
    assert.equal(control.assertNasControlAccepted(200, response(envelope)), undefined);
  }
  assert.equal(control.nasControlUnresolved(SYNTHETIC_RECORD), true);
  assert.equal(control.nasControlUnresolved({ ...SYNTHETIC_RECORD, state: 'accepted' }), true);
  assert.equal(SYNTHETIC_RECORD.state, 'pending');
});

test('SYNTHETIC strict business refusals preserve mapped DSM kinds and codes', () => {
  for (const code of [0, 105, 106, 107, 119, 150, 102, 103, 104, 999, Number.MAX_SAFE_INTEGER]) {
    const mapped = protocol.dsmFailure('SYNO.Core.System', code);
    assert.throws(() => control.assertNasControlAccepted(200, response({ success: false, error: { code } })), error =>
      error instanceof control.NasControlRejection && error instanceof protocol.NasFailure &&
      error.name === 'NasControlRejection' && error.kind === mapped.kind && error.code === code &&
      error.message === mapped.message);
  }
  const direct = new control.NasControlRejection(protocol.NasErrorKind.InvalidInput, '操作未发送');
  assert.equal(direct.kind, protocol.NasErrorKind.InvalidInput);
  assert.equal(direct.message, '操作未发送');
  assert.equal(direct.code, 0);
});

test('SYNTHETIC non-200 statuses never become confirmed refusals, even with valid refusal bodies', () => {
  for (const status of [0, 201, 202, 204, 301, 302, 307, 400, 401, 403, 408, 500, 503, 504]) {
    for (const text of [response({ success: false, error: { code: 105 } }), '{broken', '']) {
      assert.throws(() => control.assertNasControlAccepted(status, text), error =>
        notRejected(protocol.NasErrorKind.Http)(error) && error.code === status);
    }
  }
});

test('SYNTHETIC malformed response roots and nonboolean success remain uncertain protocol failures', () => {
  for (const text of ['', '{broken', 'null', '[]', 'true', '0', '"false"']) {
    rejectsProtocol(() => control.assertNasControlAccepted(200, text));
  }
  for (const success of [undefined, null, 0, 1, 'true', 'false', {}, []]) {
    rejectsProtocol(() => control.assertNasControlAccepted(200, response({ success, error: { code: 105 } })));
  }
});

test('SYNTHETIC incomplete or malformed error codes cannot prove business refusal', () => {
  for (const error of [undefined, null, true, 105, '105', [], {}, { message: 'synthetic timeout' }]) {
    rejectsProtocol(() => control.assertNasControlAccepted(200, response({ success: false, error })));
  }
  for (const code of [undefined, null, true, '105', -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, {}, []]) {
    rejectsProtocol(() => control.assertNasControlAccepted(200, response({ success: false, error: { code } })));
  }
});

test('SYNTHETIC contradictory or unrecognized envelope fields never prove acceptance or refusal', () => {
  for (const envelope of [
    { success: true, error: { code: 105 } }, { success: true, error: null },
    { success: false, error: { code: 105 }, data: {} }, { success: false, error: { code: 105 }, data: null },
    { success: false, error: { code: 105, message: 'synthetic timeout' } },
    { success: false, error: { code: 105, errors: [] } },
    { success: false, error: { code: 105 }, token: 'synthetic-secret' },
    { success: true, sid: 'synthetic-secret' },
    { success: true, data: null }, { success: true, data: [] }, { success: true, data: 'accepted' },
  ]) {
    rejectsProtocol(() => control.assertNasControlAccepted(200, response(envelope)));
  }
});

test('SYNTHETIC actions are an exact allowlist without whitespace normalization or coercion', () => {
  for (const action of ['reboot', 'shutdown']) assert.equal(control.validateNasControlAction(action), action);
  for (const action of ['', 'restart', 'poweroff', 'Reboot', 'shutdown ', ' reboot', 'reboot\n', null, undefined, {}, []]) {
    rejectsInput(() => control.validateNasControlAction(action));
    rejectsInput(() => control.validateNasControlRecord({ ...SYNTHETIC_RECORD, action }));
  }
});

test('SYNTHETIC records round-trip one allowlisted snapshot, normalize origin/account and do not mutate inputs', () => {
  const input = { ...SYNTHETIC_RECORD, origin: ' https://NAS.EXAMPLE.TEST:443/ ', account: '  合成账号  ' };
  const original = { ...input };
  const expected = { ...input, origin: 'https://nas.example.test', account: '合成账号' };
  assert.deepEqual(control.validateNasControlRecord(input), expected);
  const text = control.encodeNasControlRecord(input);
  assert.deepEqual(JSON.parse(text), { version: 1, record: expected });
  assert.deepEqual(control.decodeNasControlRecord(text), expected);
  assert.deepEqual(input, original);
});

test('SYNTHETIC UUID identifiers accept the project compact format but reject arbitrary identifiers', () => {
  for (const id of [SYNTHETIC_RECORD.id, SYNTHETIC_RECORD.id.toUpperCase(), '0123456789abcdef'.repeat(2)]) {
    assert.equal(control.validateNasControlRecord({ ...SYNTHETIC_RECORD, id }).id, id);
  }
  for (const id of ['', 'synthetic-id', 'a'.repeat(31), 'a'.repeat(33), 'g'.repeat(32),
    SYNTHETIC_RECORD.id + '\n', ' ' + SYNTHETIC_RECORD.id, 123, null, {}]) {
    rejectsInput(() => control.validateNasControlRecord({ ...SYNTHETIC_RECORD, id }));
  }
});

test('SYNTHETIC credentials, serials and all unknown fields are forbidden at both persistence levels', () => {
  for (const field of ['password', 'sid', 'token', 'serial', 'synoToken', 'otp', 'device', 'records', '__proto__']) {
    const record = { ...SYNTHETIC_RECORD, [field]: 'synthetic-secret' };
    rejectsInput(() => control.validateNasControlRecord(record));
    rejectsInput(() => control.encodeNasControlRecord(record));
    rejectsProtocol(() => control.decodeNasControlRecord(snapshot(record)));
    rejectsProtocol(() => control.decodeNasControlRecord(response({ version: 1, record: SYNTHETIC_RECORD, [field]: 'synthetic-secret' })));
  }
  for (const field of Object.keys(SYNTHETIC_RECORD)) {
    const missing = { ...SYNTHETIC_RECORD };
    delete missing[field];
    rejectsInput(() => control.validateNasControlRecord(missing));
    rejectsProtocol(() => control.decodeNasControlRecord(snapshot(missing)));
  }
  rejectsInput(() => control.validateNasControlRecord(Object.create(SYNTHETIC_RECORD)));
});

test('SYNTHETIC account/model text enforce trimmed account, nonempty model and 128-character/control boundaries', () => {
  for (const field of ['account', 'model']) {
    for (const value of ['', ' ', 'a'.repeat(129), null, 42, true, {}, [], 'bad\ntext', 'bad\u0000text', 'bad\u007ftext', 'bad\u0085text', 'bad\u009ftext']) {
      rejectsInput(() => control.validateNasControlRecord({ ...SYNTHETIC_RECORD, [field]: value }));
    }
    for (const value of ['a', '合'.repeat(128), 'a'.repeat(128)]) {
      assert.equal(control.validateNasControlRecord({ ...SYNTHETIC_RECORD, [field]: value })[field], value);
    }
  }
  assert.equal(control.validateNasControlRecord({ ...SYNTHETIC_RECORD, account: ' ' + 'a'.repeat(128) + ' ' }).account.length, 128);
  assert.equal(control.validateNasControlRecord({ ...SYNTHETIC_RECORD, model: ' Synthetic NAS ' }).model, ' Synthetic NAS ');
});

test('SYNTHETIC record origins use the established HTTPS-only normalization boundary', () => {
  assert.equal(control.validateNasControlRecord({ ...SYNTHETIC_RECORD, origin: 'https://[2001:DB8::1]:5001/' }).origin, 'https://[2001:db8::1]:5001');
  for (const origin of ['http://nas.example.test', 'https://u:p@nas.example.test', 'https://nas.example.test/path',
    'https://nas.example.test?token=x', 'https://nas.example.test:0', 'https://nas.example.test:65536', '', null, {}]) {
    rejectsInput(() => control.validateNasControlRecord({ ...SYNTHETIC_RECORD, origin }));
  }
});

test('SYNTHETIC fingerprints are exactly 64 lower-case hex characters, never raw device identifiers', () => {
  for (const fingerprint of ['', 'a'.repeat(63), 'a'.repeat(65), 'AB'.repeat(32), 'gg'.repeat(32), 'ab'.repeat(32) + '\n', null, 123, {}]) {
    rejectsInput(() => control.validateNasControlRecord({ ...SYNTHETIC_RECORD, fingerprint }));
  }
});

test('SYNTHETIC state/timestamps reject invalid values and preserve unresolved semantics', () => {
  assert.equal(control.nasControlUnresolved(undefined), false);
  for (const state of ['pending', 'accepted', 'rejected', 'resolved']) {
    const record = control.validateNasControlRecord({ ...SYNTHETIC_RECORD, state });
    assert.equal(control.nasControlUnresolved(control.decodeNasControlRecord(control.encodeNasControlRecord(record))), ['pending', 'accepted'].includes(state));
  }
  for (const state of ['', 'completed', 'failed', 'unknown', 'Accepted', null, {}, []]) {
    rejectsInput(() => control.validateNasControlRecord({ ...SYNTHETIC_RECORD, state }));
  }
  for (const timestamp of [0, Number.MAX_SAFE_INTEGER]) {
    assert.equal(control.validateNasControlRecord({ ...SYNTHETIC_RECORD, createdAt: timestamp, updatedAt: timestamp }).updatedAt, timestamp);
  }
  for (const field of ['createdAt', 'updatedAt']) {
    for (const value of [-1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, '100', null, undefined, {}, []]) {
      rejectsInput(() => control.validateNasControlRecord({ ...SYNTHETIC_RECORD, [field]: value }));
    }
  }
  rejectsInput(() => control.validateNasControlRecord({ ...SYNTHETIC_RECORD, updatedAt: 99 }));
});

test('SYNTHETIC corrupt/unsupported snapshots and record lists fail closed', () => {
  for (const input of [null, undefined, [], 'record', 123, true]) rejectsInput(() => control.validateNasControlRecord(input));
  for (const text of ['', '{broken', 'null', '[]', 'true', response(SYNTHETIC_RECORD),
    response({ version: 2, record: SYNTHETIC_RECORD }), response({ version: '1', record: SYNTHETIC_RECORD }),
    response({ version: 1 }), response({ record: SYNTHETIC_RECORD }),
    response({ version: 1, record: [SYNTHETIC_RECORD] }), response({ version: 1, record: null })]) {
    rejectsProtocol(() => control.decodeNasControlRecord(text));
  }
});
