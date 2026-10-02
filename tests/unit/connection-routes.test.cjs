const test = require('node:test').test;
const assert = require('node:assert/strict');
const protocol = require('../../work/core-build/domain/DsmProtocol.js');
const routes = require('../../work/core-build/domain/ConnectionRoutes.js');
const kinds = protocol.NasErrorKind;
const address = { origin: 'https://nas.example.test:5001', name: '家中 NAS', kind: 'lan' };
const binding = { account: 'alice', fingerprint: 'ab'.repeat(32), model: 'DS920+' };
const isKind = kind => error => error instanceof protocol.NasFailure && error.kind === kind;
const book = addresses => JSON.stringify({ version: 1, addresses });

test('synthetic routes normalize HTTPS origins including IPv6 and retain all supported route kinds', () => {
  for (const kind of ['lan', 'remote', 'private']) {
    assert.deepEqual(routes.validateConnectionAddress({ ...address, origin: ' https://NAS.example.test/ ', kind }),
      { ...address, origin: 'https://nas.example.test', kind });
  }
  assert.equal(routes.validateConnectionAddress({ ...address, origin: 'https://[2001:DB8::1]:5001/' }).origin,
    'https://[2001:db8::1]:5001');
  assert.equal(routes.validateConnectionAddress({ ...address, origin: 'https://[2001:db8::1]:0443' }).origin,
    'https://[2001:db8::1]');
});

test('route validation trims names and accounts, returns new whitelist-only metadata and does not invent a device', () => {
  const input = { ...address, name: '  家中 NAS  ', device: { ...binding, account: '  alice  ' } };
  const output = routes.validateConnectionAddress(input);
  assert.deepEqual(output, { ...address, device: binding });
  assert.notEqual(output, input);
  assert.notEqual(output.device, input.device);
  assert.equal(input.device.account, '  alice  ');
  assert.deepEqual(Object.keys(routes.validateConnectionAddress(address)), ['origin', 'name', 'kind']);
  assert.deepEqual(routes.validateConnectionAddress({ ...address, device: undefined }), address);
});

test('HTTP downgrade, credentials, paths, queries and invalid origin types are rejected rather than repaired', () => {
  for (const origin of ['http://nas.example.test:5000', 'nas.example.test', 'https://alice:secret@nas.example.test',
    'https://nas.example.test/webman', 'https://nas.example.test?sid=secret', 'https://nas.example.test#secret',
    'https://nas.example.test:0', 'https://nas.example.test:65536', 42, null, undefined]) {
    assert.throws(() => routes.validateConnectionAddress({ ...address, origin }), isKind(kinds.InvalidInput));
    assert.throws(() => routes.decodeConnectionAddressBook(book([{ ...address, origin }])), isKind(kinds.Protocol));
  }
});

test('duplicate origins are detected after normalization in both encoding and decoding', () => {
  const entries = [{ ...address, origin: 'https://NAS.example.test:443/' },
    { ...address, name: '重复', kind: 'remote', origin: 'https://nas.example.test' }];
  assert.throws(() => routes.encodeConnectionAddressBook(entries), isKind(kinds.InvalidInput));
  assert.throws(() => routes.decodeConnectionAddressBook(book(entries)), isKind(kinds.Protocol));
});

test('the version-one book accepts zero through eight addresses and refuses over-capacity lists', () => {
  assert.equal(routes.MAX_NAS_CONNECTION_ADDRESSES, 8);
  assert.deepEqual(JSON.parse(routes.encodeConnectionAddressBook([])), { version: 1, addresses: [] });
  const entries = Array.from({ length: 8 }, (unused, index) => ({ ...address, origin: `https://nas-${index}.example.test` }));
  assert.deepEqual(routes.decodeConnectionAddressBook(routes.encodeConnectionAddressBook(entries)), entries);
  const overCapacity = [...entries, { ...address, origin: 'https://ninth.example.test' }];
  assert.throws(() => routes.encodeConnectionAddressBook(overCapacity), isKind(kinds.InvalidInput));
  assert.throws(() => routes.decodeConnectionAddressBook(book(overCapacity)), isKind(kinds.Protocol));
  for (const entries of [undefined, null, {}, 'addresses']) {
    assert.throws(() => routes.encodeConnectionAddressBook(entries), isKind(kinds.InvalidInput));
  }
});

test('secret and unknown fields cannot enter encoded metadata at address, binding or envelope level', () => {
  for (const secret of ['password', 'SID', 'sid', 'token', 'synoToken', 'otp', 'OTP', 'cookie', 'serial', 'extra']) {
    const input = { ...address, [secret]: 'synthetic-secret' };
    assert.throws(() => routes.validateConnectionAddress(input), isKind(kinds.InvalidInput));
    assert.throws(() => routes.encodeConnectionAddressBook([input]), isKind(kinds.InvalidInput));
    assert.throws(() => routes.decodeConnectionAddressBook(book([input])), isKind(kinds.Protocol));
    const bound = { ...address, device: { ...binding, [secret]: 'synthetic-secret' } };
    assert.throws(() => routes.encodeConnectionAddressBook([bound]), isKind(kinds.InvalidInput));
    assert.throws(() => routes.decodeConnectionAddressBook(JSON.stringify({ version: 1, addresses: [address],
      [secret]: 'synthetic-secret' })), isKind(kinds.Protocol));
  }
  const encoded = routes.encodeConnectionAddressBook([{ ...address, device: binding }]);
  assert.deepEqual(Object.keys(JSON.parse(encoded).addresses[0].device), ['account', 'fingerprint', 'model']);
  assert.doesNotMatch(encoded, /password|sid|token|otp|cookie|serial|synthetic-secret/i);
});

test('names require bounded nonempty text without control characters and kinds are an exact enum', () => {
  assert.equal(routes.validateConnectionAddress({ ...address, name: '名'.repeat(40) }).name.length, 40);
  for (const name of ['', '   ', '名'.repeat(41), 'bad\nname', '\tname', 'bad\u0000name', 'bad\u007fname',
    'bad\u0085name', 10, null, undefined]) {
    assert.throws(() => routes.validateConnectionAddress({ ...address, name }), isKind(kinds.InvalidInput));
  }
  for (const kind of ['LAN', 'internet', '', 1, null, undefined]) {
    assert.throws(() => routes.validateConnectionAddress({ ...address, kind }), isKind(kinds.InvalidInput));
  }
  for (const input of [null, undefined, [], false, 'https://nas.example.test', {}]) {
    assert.throws(() => routes.validateConnectionAddress(input), isKind(kinds.InvalidInput));
  }
});

test('optional bindings validate lowercase SHA256 fingerprints, accounts and model identifiers', () => {
  for (const fingerprint of ['AB'.repeat(32), 'ab'.repeat(31), 'ab'.repeat(33), 'g'.repeat(64), ' ' + binding.fingerprint,
    123, null, undefined]) {
    assert.throws(() => routes.validateConnectionAddress({ ...address, device: { ...binding, fingerprint } }),
      isKind(kinds.InvalidInput));
  }
  for (const field of ['account', 'model']) {
    for (const invalid of ['', '  ', '标'.repeat(129), 'bad\nvalue', '\tvalue', 'bad\u009fvalue', null, 42, undefined]) {
      assert.throws(() => routes.validateConnectionAddress({ ...address, device: { ...binding, [field]: invalid } }),
        isKind(kinds.InvalidInput));
    }
    assert.equal(routes.validateConnectionAddress({ ...address, device: { ...binding, [field]: '标'.repeat(128) } })
      .device[field].length, 128);
  }
  for (const device of [null, [], 'model', 1, {}]) {
    assert.throws(() => routes.validateConnectionAddress({ ...address, device }), isKind(kinds.InvalidInput));
  }
});

test('addresses never imply a shared NAS identity from IP, account or name', () => {
  const entries = [{ ...address, origin: 'https://192.0.2.1:5001' },
    { ...address, origin: 'https://192.0.2.1:5002' },
    { ...address, origin: 'https://remote.example.test', device: binding },
    { ...address, origin: 'https://other.example.test', device: { ...binding, fingerprint: 'cd'.repeat(32) } }];
  const restored = routes.decodeConnectionAddressBook(routes.encodeConnectionAddressBook(entries));
  assert.deepEqual(restored, entries);
  assert.equal(restored[0].device, undefined);
  assert.equal(restored[1].device, undefined);
  assert.notEqual(restored[2].device.fingerprint, restored[3].device.fingerprint);
});

test('corrupt JSON and unsupported or malformed envelopes produce formal protocol failures', () => {
  for (const text of ['', '{broken', 'null', '[]', 'true', JSON.stringify({ addresses: [] }),
    JSON.stringify({ version: 2, addresses: [] }), JSON.stringify({ version: '1', addresses: [] }),
    JSON.stringify({ version: 1 }), JSON.stringify({ version: 1, addresses: {} }),
    JSON.stringify({ version: 1, addresses: [null] }), null, undefined]) {
    assert.throws(() => routes.decodeConnectionAddressBook(text), error => isKind(kinds.Protocol)(error) &&
      /连接地址记录.*保留记录/.test(error.message));
  }
});

test('Core System.info identity decoding preserves raw model and serial and returns no unrelated fields', () => {
  const identity = { model: ' DS920+ ', serial: 'synthetic-serial-001 ', system_temperature: 41, password: 'synthetic-secret' };
  assert.deepEqual(routes.decodeNasDeviceIdentity(identity), { model: identity.model, serial: identity.serial });
  assert.equal(identity.serial, 'synthetic-serial-001 ');
});

test('missing identity fields are unsupported and invalid identity fields are protocol failures without default IDs', () => {
  for (const input of [{}, { model: 'DS920+' }, { serial: 'synthetic-serial-001' },
    { model: 'DS920+', serial: undefined }, { model: undefined, serial: 'synthetic-serial-001' }]) {
    assert.throws(() => routes.decodeNasDeviceIdentity(input), isKind(kinds.Unsupported));
  }
  for (const field of ['model', 'serial']) {
    for (const invalid of ['', '  ', 123, null, {}, [], 'bad\nidentifier', 'bad\u007fidentifier', '标'.repeat(129)]) {
      const input = { model: 'DS920+', serial: 'synthetic-serial-001', [field]: invalid };
      assert.throws(() => routes.decodeNasDeviceIdentity(input), isKind(kinds.Protocol));
    }
  }
  for (const input of [null, undefined, [], 1, 'DS920+']) {
    assert.throws(() => routes.decodeNasDeviceIdentity(input), isKind(kinds.Protocol));
  }
});
