const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const { TextEncoder } = require('node:util');
const sdkRoot = process.env.HARMONY_SDK_ROOT || path.join(process.env.DEVECO_CLI_CLT_PATH || 'C:/Program Files/command-line-tools', 'sdk/default');
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

function loadSource(relative, mocks = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets', relative), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true,
  });
  assert.equal((output.diagnostics || []).filter(diagnostic => diagnostic.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, {
    module, exports: module.exports, Error, Date, Uint8Array, ArrayBuffer,
    require: id => {
      if (id === '../../platform/SdkDigest') {
        return require('../helpers/load-sdk-digest.cjs')(mocks['@kit.CryptoArchitectureKit'].cryptoFramework, protocol);
      }
      assert.ok(Object.hasOwn(mocks, id), `unexpected dependency ${id}`); return mocks[id];
    },
  }, { filename: relative });
  return module.exports;
}

const protocol = loadSource('core/domain/DsmProtocol.ts');
const routes = loadSource('core/domain/ConnectionRoutes.ts', { './DsmProtocol': protocol });
const { nasDeviceFingerprint } = loadSource('features/connection/NasAddressBookStore.ets', {
  '../../core/domain/DsmProtocol': protocol,
  '../../core/domain/ConnectionRoutes': routes,
  '@kit.CoreFileKit': { fileIo: {} },
  '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } } },
  '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd(algorithm) {
    assert.equal(algorithm, 'SHA256');
    const hash = crypto.createHash('sha256');
    return { async update(blob) { hash.update(blob.data); }, async digest() { return { data: Uint8Array.from(hash.digest()) }; } };
  } } },
});
const { NasFailure, NasErrorKind: K } = protocol;
const context = { filesDir: '/synthetic-private' };
const origin = 'https://lan.example.test:5001';
const otherOrigin = 'https://remote.example.test';
const identity = { model: 'Synthetic NAS', serial: 'synthetic-private-serial' };
const address = { origin, name: '家中 NAS', kind: 'lan' };
const otherAddress = { origin: otherOrigin, name: '远程 NAS', kind: 'remote' };
const plain = value => JSON.parse(JSON.stringify(value));
const failure = (kind, code = 0) => new NasFailure(kind, '合成测试失败', code);
const isKind = kind => error => error instanceof NasFailure && error.kind === kind;
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((success, fail) => { resolve = success; reject = fail; });
  return { promise, resolve, reject };
};

async function fixture(options = {}) {
  const device = { account: 'alice', fingerprint: await nasDeviceFingerprint(identity), model: identity.model };
  const storage = { addresses: plain(options.addresses || [{ ...address, ...(options.bound ? { device } : {}) }, otherAddress]),
    loadError: undefined, saveError: undefined };
  const calls = [];
  const probes = [];
  class MockStore {
    async load(input) {
      calls.push({ method: 'store.load', args: [input] });
      if (storage.loadError) { throw storage.loadError; }
      return plain(storage.addresses);
    }
    async save(addresses) {
      calls.push({ method: 'store.save', args: [plain(addresses)] });
      if (storage.saveError) { throw storage.saveError; }
      storage.addresses = plain(addresses);
    }
  }
  class ProbeConnector {
    closed = false;
    constructor() { probes.push(this); }
    async discover(...args) {
      calls.push({ method: 'discover', connector: this, args });
      if (options.discover) { return options.discover(...args); }
      return [];
    }
    close() { this.closed = true; calls.push({ method: 'close', connector: this, args: [] }); }
    async login(...args) { calls.push({ method: 'login', args }); }
    restoreSession(...args) { calls.push({ method: 'restoreSession', args }); }
    async telemetrySystem(...args) { calls.push({ method: 'telemetrySystem', args }); return identity; }
    async list(...args) { calls.push({ method: 'list', args }); return { entries: [], offset: 0, total: 0 }; }
  }
  const { ConnectionAddressBook } = loadSource('features/connection/ConnectionAddressBook.ets', {
    '../../core/domain/DsmProtocol': protocol,
    '../../core/domain/ConnectionRoutes': routes,
    '../../core/network/NasConnector': { NasConnector: ProbeConnector },
    '../../core/network/RcpNasTransport': { RcpNasTransport: class {} },
    './NasAddressBookStore': { NasAddressBookStore: MockStore, nasDeviceFingerprint },
  });
  const book = new ConnectionAddressBook();
  const replies = { identity, error: undefined, gate: undefined };
  const current = { async telemetrySystem(...args) {
    calls.push({ method: 'current.telemetrySystem', args });
    if (replies.gate) { await replies.gate.promise; }
    if (replies.error) { throw replies.error; }
    return replies.identity;
  } };
  assert.equal(await book.load(context), true);
  book.draftOrigin = origin;
  book.draftName = '已确认 NAS';
  book.draftKind = 'private';
  return { book, storage, calls, probes, current, replies, device,
    count: method => calls.filter(call => call.method === method).length };
}

test('synthetic probe discovers only the explicitly selected HTTPS origin without credentials or identity reads', async () => {
  const { book, probes, calls } = await fixture({ bound: true });
  await book.probe(' https://REMOTE.example.test:443/ ');
  assert.equal(probes.length, 1);
  assert.deepEqual(calls.filter(call => call.connector === probes[0]).map(call => [call.method, call.args]),
    [['discover', [otherOrigin]], ['close', []]]);
  assert.equal(book.probeResult.origin, otherOrigin);
  assert.equal(book.probeResult.passed, true);
  assert.ok(book.probeResult.observedAt > 0);
  assert.match(book.probeResult.message, /未发送登录凭据.*未核验设备身份/);
  assert.equal(book.probing, false);
  assert.equal(calls.some(call => /login|restoreSession|telemetrySystem|list|store.save/.test(call.method)), false);
});

test('invalid probe origins cause no discovery, credential repair or fallback', async () => {
  for (const input of ['lan.example.test', 'https://alice:password@lan.example.test',
    'https://lan.example.test/webman', 'https://lan.example.test?sid=secret']) {
    const { book, probes, count } = await fixture();
    await book.probe(input);
    assert.equal(count('discover'), 0);
    assert.equal(book.probeResult.passed, false);
    assert.ok(book.probeResult.message);
    assert.equal(probes[0].closed, true);
    assert.equal(book.probing, false);
  }
});

test('unsupported discovery is a failed single-address probe, never a failover or identity success', async () => {
  const { book, count } = await fixture({ discover: async () => { throw failure(K.Unsupported); } });
  await book.probe(origin);
  assert.equal(count('discover'), 1);
  assert.equal(book.probeResult.passed, false);
  assert.match(book.probeResult.message, /未提供.*基础接口/);
  assert.equal(count('current.telemetrySystem'), 0);
});

test('an in-flight probe prevents a second discovery until explicitly cancelled', async () => {
  const gate = deferred();
  const { book, count } = await fixture({ discover: () => gate.promise });
  const pending = book.probe(origin);
  await book.probe(otherOrigin);
  assert.equal(count('discover'), 1);
  assert.equal(book.probing, true);
  gate.resolve([]);
  await pending;
  assert.equal(book.probeResult.origin, origin);
});

for (const outcome of ['success', 'failure']) {
  test(`cancelled probe late ${outcome} cannot publish over or release the replacement probe`, async () => {
    const oldGate = deferred();
    const nextGate = deferred();
    const { book, probes } = await fixture({ discover: input => input === origin ? oldGate.promise : nextGate.promise });
    const oldPending = book.probe(origin);
    book.cancelProbe();
    assert.equal(probes[0].closed, true);
    assert.equal(book.probing, false);
    const nextPending = book.probe(otherOrigin);
    if (outcome === 'success') { oldGate.resolve([]); } else { oldGate.reject(failure(K.Network)); }
    await oldPending;
    assert.equal(book.probing, true);
    assert.equal(book.probeResult, undefined);
    assert.equal(probes[1].closed, false);
    nextGate.resolve([]);
    await nextPending;
    assert.equal(book.probeResult.origin, otherOrigin);
    assert.equal(book.probeResult.passed, true);
    assert.equal(probes[1].closed, true);
  });
}

test('editing the draft invalidates both completed and pending observations', async () => {
  const gate = deferred();
  let delayed = false;
  const { book, probes } = await fixture({ discover: () => delayed ? gate.promise : [] });
  await book.probe(origin);
  book.setDraftOrigin(otherOrigin);
  assert.equal(book.probeResult, undefined);
  delayed = true;
  const pending = book.probe(otherOrigin);
  book.setDraftOrigin(origin);
  gate.resolve([]);
  await pending;
  assert.equal(book.draftOrigin, origin);
  assert.equal(book.probeResult, undefined);
  assert.equal(book.probing, false);
  assert.equal(probes[1].closed, true);
});

test('disposal cancels discovery and ignores its late result', async () => {
  const gate = deferred();
  const { book, probes } = await fixture({ discover: () => gate.promise });
  const pending = book.probe();
  book.dispose();
  gate.resolve([]);
  await pending;
  assert.equal(probes[0].closed, true);
  assert.equal(book.ready, false);
  assert.equal(book.probing, false);
  assert.equal(book.probeResult, undefined);
});

test('saving renamed route metadata preserves the original identity binding and other routes', async () => {
  const { book, storage, device, count } = await fixture({ bound: true });
  book.draftOrigin = ' https://LAN.example.test:5001/ ';
  assert.equal(await book.saveDraft(), true);
  const saved = storage.addresses.find(candidate => candidate.origin === origin);
  assert.deepEqual(saved, { origin, name: book.draftName, kind: 'private', device });
  assert.deepEqual(storage.addresses.find(candidate => candidate.origin === otherOrigin), otherAddress);
  assert.equal(count('current.telemetrySystem'), 0);
  assert.match(book.notice, /不会自动切换.*登录信息/);
});

test('saving an unbound draft does not invent identity verification', async () => {
  const { book, storage } = await fixture();
  assert.equal(await book.saveDraft(), true);
  assert.equal(storage.addresses.find(candidate => candidate.origin === origin).device, undefined);
  assert.doesNotMatch(book.notice, /已核验|已登记.*身份/);
});

test('registering the current device saves only a trimmed account, real identity hash and model', async () => {
  const { book, current, storage, device, count } = await fixture();
  assert.equal(await book.saveCurrent(current, ' https://LAN.example.test:5001/ ', '  alice  '), true);
  assert.deepEqual(storage.addresses.find(candidate => candidate.origin === origin).device, device);
  assert.equal(count('current.telemetrySystem'), 1);
  assert.equal(count('store.save'), 1);
  assert.doesNotMatch(JSON.stringify(storage.addresses), /synthetic-private-serial|password|synoToken|sid|otp/i);
  assert.match(book.notice, /设备身份已登记/);
});

for (const account of [' alice ', 'bob']) {
  test(`a changed serial cannot overwrite the origin binding even when registering account ${account.trim()}`, async () => {
    const { book, current, storage, replies, count } = await fixture({ bound: true });
    const original = plain(storage.addresses);
    replies.identity = { ...identity, serial: 'different-device-same-model' };
    assert.equal(await book.saveCurrent(current, origin, account), false);
    assert.equal(count('store.save'), 0);
    assert.deepEqual(storage.addresses, original);
    assert.deepEqual(plain(book.addresses), original);
    assert.match(book.errorText, /不一致.*不能覆盖/);
    assert.equal(book.notice, '');
    assert.equal(book.busy, false);
  });
}

test('explicitly registering a different account on the same fingerprint changes only the binding account', async () => {
  const { book, current, storage, device, count } = await fixture({ bound: true });
  assert.equal(await book.saveCurrent(current, origin, ' bob '), true);
  assert.deepEqual(storage.addresses.find(candidate => candidate.origin === origin).device, { ...device, account: 'bob' });
  assert.equal(count('store.save'), 1);
  assert.match(book.notice, /当前账号的设备身份已登记/);
  assert.equal(await book.verifyExpectedDevice(current, origin, 'alice'), undefined);
  assert.equal(count('current.telemetrySystem'), 1);
  assert.equal(await book.verifyExpectedDevice(current, origin, 'bob'), identity.model);
  assert.equal(count('current.telemetrySystem'), 2);
});

test('invalid draft labels are rejected before fetching identity or writing metadata', async () => {
  for (const draft of [{ draftName: '' }, { draftName: 'bad\nname' }, { draftKind: 'untrusted-kind' }]) {
    const { book, current, count } = await fixture({ bound: true });
    Object.assign(book, draft);
    assert.equal(await book.saveCurrent(current, origin, 'alice'), false);
    assert.equal(count('current.telemetrySystem'), 0);
    assert.equal(count('store.save'), 0);
    assert.ok(book.errorText);
    assert.equal(book.notice, '');
  }
});

for (const kind of [K.Permission, K.Unsupported]) {
  for (const bound of [false, true]) {
    test(`${K[kind]} while registering ${bound ? 'a bound' : 'an unbound'} address never claims identity verification`, async () => {
      const { book, current, storage, replies, device } = await fixture({ bound });
      replies.error = failure(kind, 105);
      assert.equal(await book.saveCurrent(current, origin, 'alice'), true);
      assert.deepEqual(storage.addresses.find(candidate => candidate.origin === origin).device, bound ? device : undefined);
      assert.match(book.notice, bound ? /原设备登记仍保留.*未完成身份核验/ : /无法读取设备标识.*未登记设备身份/);
      assert.doesNotMatch(book.notice, /设备身份已登记|身份已核验/);
      assert.equal(book.errorText, '');
    });
  }
}

test('permission downgrade under another account must retain the original account binding', async () => {
  const { book, current, storage, replies, device, count } = await fixture({ bound: true });
  replies.error = failure(K.Permission);
  assert.equal(await book.saveCurrent(current, origin, 'bob'), true);
  assert.deepEqual(storage.addresses.find(candidate => candidate.origin === origin).device, device);
  assert.equal(await book.verifyExpectedDevice(current, origin, 'bob'), undefined);
  assert.equal(count('current.telemetrySystem'), 1);
  assert.match(book.notice, /原设备登记仍保留.*未完成身份核验/);
});

test('a missing serial degrades registration to an explicitly unbound address', async () => {
  const { book, current, storage, replies } = await fixture();
  replies.identity = { model: identity.model };
  assert.equal(await book.saveCurrent(current, origin, 'alice'), true);
  assert.equal(storage.addresses.find(candidate => candidate.origin === origin).device, undefined);
  assert.match(book.notice, /未登记设备身份/);
});

test('malformed nonempty identity fields are protocol failures, not unsupported identity downgrade', async () => {
  const { book, current, replies, count } = await fixture();
  replies.identity = { model: identity.model, serial: '' };
  assert.equal(await book.saveCurrent(current, origin, 'alice'), false);
  assert.equal(count('store.save'), 0);
  assert.ok(book.errorText);
  assert.equal(book.notice, '');
});

for (const kind of [K.Network, K.Tls, K.Protocol]) {
  test(`${K[kind]} while reading the current identity must not silently save an unbound address`, async () => {
    const { book, current, storage, replies, count } = await fixture({ bound: true });
    const original = plain(storage.addresses);
    replies.error = failure(kind);
    assert.equal(await book.saveCurrent(current, origin, 'alice'), false);
    assert.equal(count('store.save'), 0);
    assert.deepEqual(storage.addresses, original);
    assert.ok(book.errorText);
    assert.equal(book.notice, '');
  });
}

test('expired registration sessions propagate the same error upward without a metadata write', async () => {
  const { book, current, replies, count } = await fixture();
  const expired = failure(K.SessionExpired, 119);
  replies.error = expired;
  await assert.rejects(book.saveCurrent(current, origin, 'alice'), error => error === expired);
  assert.equal(count('store.save'), 0);
  assert.equal(book.busy, false);
  assert.equal(book.notice, '');
});

test('address-book read failure blocks saving and verification instead of treating stale data as ready', async () => {
  const { book, storage, current, count } = await fixture({ bound: true });
  storage.loadError = failure(K.Protocol);
  assert.equal(await book.load(context), false);
  assert.equal(book.ready, false);
  assert.ok(book.errorText);
  assert.equal(await book.saveDraft(), false);
  assert.equal(await book.saveCurrent(current, origin, 'alice'), false);
  await assert.rejects(book.verifyExpectedDevice(current, origin, 'alice'), isKind(K.Protocol));
  assert.equal(count('store.save'), 0);
  assert.equal(count('current.telemetrySystem'), 0);
});

for (const operation of ['saveDraft', 'saveCurrent', 'remove']) {
  test(`I/O failure during ${operation} preserves published bindings and reports no success`, async () => {
    const { book, storage, current, count } = await fixture({ bound: true });
    const original = plain(storage.addresses);
    book.notice = '上次保存成功';
    storage.saveError = Object.assign(new Error('synthetic I/O failure'), { code: 13900005 });
    const result = operation === 'saveCurrent' ? await book.saveCurrent(current, origin, 'alice') :
      operation === 'remove' ? await book.remove(origin) : await book.saveDraft();
    if (operation !== 'remove') { assert.equal(result, false); }
    assert.equal(count('store.save'), 1);
    assert.deepEqual(storage.addresses, original);
    assert.deepEqual(plain(book.addresses), original);
    assert.ok(book.errorText);
    assert.equal(book.notice, '');
    assert.equal(book.busy, false);
  });
}

test('disposal during current identity retrieval prevents registration and all storage writes', async () => {
  const { book, current, replies, count } = await fixture();
  replies.gate = deferred();
  const pending = book.saveCurrent(current, origin, 'alice');
  book.dispose();
  replies.gate.resolve();
  assert.equal(await pending, false);
  assert.equal(count('store.save'), 0);
  assert.equal(book.notice, '');
});

test('matching origin and account verify the bound hash rather than only the model', async () => {
  const { book, current, count } = await fixture({ bound: true });
  assert.equal(await book.verifyExpectedDevice(current, ' https://LAN.example.test:5001/ ', ' alice '), identity.model);
  assert.equal(count('current.telemetrySystem'), 1);
  assert.equal(count('store.save'), 0);
});

test('unbound routes and different accounts stay explicitly unverified without borrowing another binding', async () => {
  const { book, current, count } = await fixture({ bound: true });
  assert.equal(await book.verifyExpectedDevice(current, otherOrigin, 'alice'), undefined);
  assert.equal(await book.verifyExpectedDevice(current, origin, 'bob'), undefined);
  assert.equal(count('current.telemetrySystem'), 0);
});

test('a matching model but changed serial rejects restoration of the bound account', async () => {
  const { book, current, replies, count } = await fixture({ bound: true });
  replies.identity = { ...identity, serial: 'different-device-same-model' };
  await assert.rejects(book.verifyExpectedDevice(current, origin, 'alice'), isKind(K.InvalidInput));
  assert.equal(count('store.save'), 0);
});

for (const kind of [K.Permission, K.Unsupported]) {
  test(`${K[kind]} when verifying an existing binding fails closed and preserves the provider code`, async () => {
    const { book, current, replies } = await fixture({ bound: true });
    replies.error = failure(kind, 105);
    await assert.rejects(book.verifyExpectedDevice(current, origin, 'alice'), error => {
      assert.equal(error.kind, kind);
      assert.equal(error.code, 105);
      assert.match(error.message, /无法核验已登记的设备.*停止恢复/);
      return true;
    });
  });
}

test('expired identity verification propagates the original session error', async () => {
  const { book, current, replies } = await fixture({ bound: true });
  const expired = failure(K.SessionExpired, 119);
  replies.error = expired;
  await assert.rejects(book.verifyExpectedDevice(current, origin, 'alice'), error => error === expired);
});

test('a configuration generation change invalidates a late successful identity verification', async () => {
  const { book, current, replies } = await fixture({ bound: true });
  replies.gate = deferred();
  const pending = book.verifyExpectedDevice(current, origin, 'alice');
  book.dispose();
  replies.gate.resolve();
  await assert.rejects(pending, isKind(K.Cancelled));
});
