const { test } = require('node:test');
const assert = require('node:assert/strict');
const { SessionRegistry, parseNasSession } = require('../../work/core-build/network/SessionRegistry.js');

test('one primary session copies credentials and revisions invalidate late responses', () => {
  const registry = new SessionRegistry();
  const input = { sid: 'primary-sid', synoToken: 'primary-token' };
  assert.equal(registry.get(), undefined);
  const initial = registry.revision();
  registry.register(input);
  input.sid = 'mutated';
  assert.equal(registry.get().sid, 'primary-sid');
  const copy = registry.get(); copy.sid = 'mutated-again';
  assert.equal(registry.get().sid, 'primary-sid');
  assert.ok(registry.revision() > initial);
  const revision = registry.revision(); registry.clear();
  assert.equal(registry.has(), false); assert.equal(registry.get(), undefined);
  assert.ok(registry.revision() > revision);
});

test('invalid and old business-session payloads never replace the primary session', () => {
  const registry = new SessionRegistry();
  registry.register({ sid: 'valid', synoToken: '' });
  for (const input of [undefined, [], [{ name: 'FileStation', sid: 'old', synoToken: '' }],
    { sid: '', synoToken: '' }, { sid: 'bad;cookie', synoToken: '' }, { sid: 'good', synoToken: 4 }]) {
    assert.throws(() => registry.register(input));
    assert.equal(registry.get().sid, 'valid');
  }
  assert.deepEqual(parseNasSession({ sid: 'good', synoToken: '' }), { sid: 'good', synoToken: '' });
});
