const { test } = require('node:test');
const assert = require('node:assert/strict');
const { SessionRegistry, parseBusinessSessionRecord, parseBusinessSessionRecords } =
  require('../../work/core-build/network/SessionRegistry.js');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');

const authorization = { sid: 'SID-0123.~_', synoToken: 'TOKEN-0123' };
const record = { name: 'FileStation', ...authorization };

test('register, get and has copy session credentials instead of sharing references', () => {
  const registry = new SessionRegistry();
  assert.equal(registry.has('FileStation'), false);
  registry.register('FileStation', authorization);
  assert.equal(registry.has('FileStation'), true);
  assert.deepEqual(registry.get('FileStation'), authorization);
  const exposed = registry.get('FileStation');
  exposed.sid = 'mutated';
  assert.equal(registry.get('FileStation').sid, authorization.sid);
  assert.equal(registry.get('DownloadStation'), undefined);
});

test('register rejects unknown business names and malformed credentials', () => {
  const registry = new SessionRegistry();
  for (const name of ['DownloadStation2', '', 'WebAPI', 'filestation', 'NasControl ']) {
    assert.throws(() => registry.register(name, authorization), isProtocol);
  }
  assert.throws(() => registry.register('DownloadStation', { sid: 'sid; id=other', synoToken: '' }), isProtocol);
  assert.throws(() => registry.register('DownloadStation', { sid: 'sid\r\nX-Injected: yes', synoToken: '' }), isProtocol);
  assert.throws(() => registry.register('DownloadStation', { sid: 'sid', synoToken: 'token\r\nInjected: yes' }), isProtocol);
  assert.equal(registry.revision(), 0);
});

function isProtocol(error) { return error instanceof NasFailure && error.kind === K.Protocol; }

test('invalidate removes one business while others keep working; clear removes all', () => {
  const registry = new SessionRegistry();
  registry.register('FileStation', authorization);
  registry.register('DownloadStation', { sid: 'download-sid', synoToken: '' });
  const revision = registry.revision();
  assert.equal(registry.invalidate('FileStation'), true);
  assert.equal(registry.invalidate('FileStation'), false);
  assert.equal(registry.revision(), revision + 1);
  assert.equal(registry.has('FileStation'), false);
  assert.deepEqual(registry.get('DownloadStation'), { sid: 'download-sid', synoToken: '' });
  registry.clear();
  assert.equal(registry.has('DownloadStation'), false);
  assert.equal(registry.revision(), revision + 2);
});

test('snapshot orders by registered business and restore replaces the whole set', () => {
  const registry = new SessionRegistry();
  registry.register('DownloadStation', { sid: 'download-sid', synoToken: 'download-token' });
  registry.register('FileStation', authorization);
  assert.deepEqual(registry.snapshot(), [record, { name: 'DownloadStation', sid: 'download-sid', synoToken: 'download-token' }]);
  registry.restore([record, { name: 'NasControl', sid: 'control-sid', synoToken: '' }]);
  assert.deepEqual(registry.snapshot(), [record, { name: 'NasControl', sid: 'control-sid', synoToken: '' }]);
  assert.equal(registry.has('DownloadStation'), false);
});

test('restore rejects invalid groups without keeping partial sessions', () => {
  const registry = new SessionRegistry();
  registry.register('FileStation', authorization);
  for (const input of [[], [record, record],
    [{ name: 'FileStation', sid: '', synoToken: '' }],
    [{ name: 'Unknown', sid: 'sid', synoToken: '' }],
    [{ name: 'FileStation', sid: 'sid; inject', synoToken: '' }],
    [record, { name: 'DownloadStation', sid: 'download-sid', synoToken: '' }, { name: 'NasControl', sid: 'control-sid', synoToken: '' },
      { name: 'FileStation', sid: 'duplicate-sid', synoToken: '' }]]) {
    assert.throws(() => registry.restore(input), isProtocol, JSON.stringify(input));
  }
  assert.deepEqual(registry.snapshot(), [record]);
});

test('parse helpers validate wire payloads for persistence boundaries', () => {
  assert.deepEqual(parseBusinessSessionRecord(record), record);
  assert.deepEqual(parseBusinessSessionRecords([record, { name: 'DownloadStation', sid: 'sid', synoToken: 'token' }]),
    [record, { name: 'DownloadStation', sid: 'sid', synoToken: 'token' }]);
  for (const input of ['text', 42, null, [], {}, { name: 'FileStation' }, { name: 'FileStation', sid: '', synoToken: '' },
    [{ name: 'FileStation', sid: 'sid', synoToken: '' }, { name: 'FileStation', sid: 'sid2', synoToken: '' }]]) {
    assert.throws(() => parseBusinessSessionRecords(input), isProtocol);
  }
});
