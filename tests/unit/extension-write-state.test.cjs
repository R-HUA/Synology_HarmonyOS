const { test } = require('node:test');
const assert = require('node:assert/strict');
const { decodeExtensionWrites, extensionWriteIsUncertain } = require('../../work/core-build/domain/ExtensionWriteState.js');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');
const pending = [{ feature: 'fileSharing', operation: 'create', createdAt: 100 }];
const encode = (changes = {}) => JSON.stringify({ version: 1, scope: 'account-scope', pending, ...changes });

test('pending extension writes survive restart without storing credentials or user inputs', () => {
  assert.deepEqual(decodeExtensionWrites(encode(), 'account-scope'), pending);
  assert.deepEqual(decodeExtensionWrites(encode({ pending: [] }), 'account-scope'), []);
});

test('corrupt, duplicate and cross-account pending records cannot be overwritten as empty', () => {
  for (const text of ['{', encode({ version: 2 }), encode({ scope: 'another-account' }),
    encode({ pending: [...pending, ...pending] }), encode({ pending: [{ ...pending[0], feature: 'unknown' }] }),
    encode({ pending: [{ ...pending[0], operation: 'clear_invalid' }] }),
    encode({ pending: [{ ...pending[0], createdAt: Number.MAX_SAFE_INTEGER + 1 }] })]) {
    assert.throws(() => decodeExtensionWrites(text, 'account-scope'), error => error.kind === K.Protocol);
  }
});

test('ambiguous transport and parsing failures retain the no-replay guard', () => {
  for (const kind of [K.Network, K.Tls, K.Http, K.Protocol, K.Cancelled]) {
    assert.equal(extensionWriteIsUncertain(new NasFailure(kind, 'synthetic failure')), true);
  }
  for (const kind of [K.InvalidInput, K.Permission, K.SessionExpired, K.Unsupported, K.Server]) {
    assert.equal(extensionWriteIsUncertain(new NasFailure(kind, 'rejected')), false);
  }
  assert.equal(extensionWriteIsUncertain(new Error('unknown')), true);
});
