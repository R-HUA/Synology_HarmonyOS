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
      if (id === '../../platform/SdkFileIO') { return require('../helpers/load-sdk-file-io.cjs')(mocks['@kit.CoreFileKit'].fileIo, protocol); }
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
const photos = loadSource('core/domain/PhotosProtocol.ts', { './DsmProtocol': protocol });
const operations = loadSource('core/domain/FileOperations.ts', { './DsmProtocol': protocol });
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
const oldOrigin = 'https://lan.example.test:5001';
const nextOrigin = 'https://remote.example.test';
const identity = { model: 'Synthetic NAS', serial: 'synthetic-device-serial' };
const savedSession = { origin: oldOrigin, account: 'alice', insecureTls: false,
  sessions: [{ name: 'FileStation', sid: 'old-origin-only-sid', synoToken: 'old-origin-only-token' }] };
const newSession = { sid: 'new-login-sid', synoToken: 'new-login-token' };
const newSessionRecord = { name: 'FileStation', sid: newSession.sid, synoToken: newSession.synoToken };
const context = { filesDir: '/synthetic-private' };
const plain = value => JSON.parse(JSON.stringify(value));
const failure = kind => new NasFailure(kind, '合成测试失败', 105);
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((success, fail) => { resolve = success; reject = fail; });
  return { promise, resolve, reject };
};
const flush = async () => { for (let turn = 0; turn < 32; turn++) { await Promise.resolve(); } };

test('editing the server origin cannot inherit an approved certificate exception', async () => {
  const { model, count } = await fixture();
  model.addressBook.addresses[0].insecureTls = true; model.addressBook.addresses[0].riskConfirmedAt = 1;
  model.setAddress(oldOrigin); assert.equal(model.insecureTls, true);
  model.setAddress(nextOrigin); assert.equal(model.insecureTls, false);
  model.insecureTls = true;
  assert.equal(await model.connect(), false); assert.equal(count('discover'), 0);
});

test('the login address detects the scheme and returns to HTTPS when the scheme is omitted', async () => {
  const { model } = await fixture({ bound: false });
  model.addressBook.addresses = [];
  model.setAddress('HTTP://NAS.example.test:5000');
  assert.equal(model.useHttps, false);
  assert.equal(model.insecureTls, false);
  assert.equal(model.connectionRiskOrigin(), 'http://nas.example.test:5000');
  model.setAddress('https://nas.example.test:5001');
  model.setInsecureTls(true);
  assert.equal(model.insecureTls, true);
  model.setAddress('nas.example.test:5001');
  assert.equal(model.useHttps, true);
  assert.equal(model.insecureTls, false);
  assert.equal(model.connectionRiskOrigin(), undefined);
});

test('login-page confirmation allows HTTP and certificate exceptions without a saved address', async () => {
  for (const [origin, insecureTls] of [['http://nas.example.test:5000', false], ['https://nas.example.test:5001', true]]) {
    const { model, state, count } = await fixture({ bound: false });
    state.session = undefined;
    model.addressBook.addresses = [];
    model.setAddress(origin);
    model.setInsecureTls(insecureTls);
    assert.equal(model.connectionRiskOrigin(), origin);
    assert.equal(count('discover'), 0);
    model.confirmConnectionRisk(origin, insecureTls);
    assert.equal(model.connectionRiskOrigin(), undefined);
    await model.submitLogin();
    assert.equal(model.authenticated, true);
    assert.equal(count('discover'), 1);
    assert.equal(count('book.save'), 1);
    assert.ok(model.addressBook.addresses[0].riskConfirmedAt > 0);
  }
});

test('login-page risk confirmation expires when the address or connection policy changes', async () => {
  const { model, count } = await fixture({ bound: false });
  model.addressBook.addresses = [];
  model.setAddress(oldOrigin); model.setInsecureTls(true);
  model.confirmConnectionRisk(oldOrigin, true);
  model.setAddress(nextOrigin); model.setInsecureTls(true);
  assert.equal(model.connectionRiskOrigin(), nextOrigin);
  assert.throws(() => model.confirmConnectionRisk(oldOrigin, true), error => error.kind === K.InvalidInput);
  model.confirmConnectionRisk(nextOrigin, true);
  model.setUseHttps(false);
  assert.equal(model.connectionRiskOrigin(), nextOrigin.replace('https:', 'http:'));
  assert.equal(model.insecureTls, false);
  assert.equal(await model.connect(), false);
  assert.equal(count('discover'), 0);
});

test('verified login history survives logout and reload, deduplicates repeats and supports removal', async () => {
  const { model, state } = await fixture({ bound: false });
  state.session = undefined; state.addressRecords = []; model.addressBook.addresses = [];
  model.setAddress(oldOrigin); await model.submitLogin();
  assert.equal(state.addressRecords.length, 1);
  assert.equal(state.addressRecords[0].origin, oldOrigin);
  await model.disconnect(); await model.addressBook.load(context);
  assert.equal(model.addressBook.addresses[0].origin, oldOrigin);
  await model.submitLogin();
  assert.equal(state.addressRecords.length, 1);
  await model.disconnect();
  await model.addressBook.remove(oldOrigin);
  await model.addressBook.load(context);
  assert.equal(model.addressBook.addresses.length, 0);
  assert.equal(state.addressRecords.length, 0);
});

test('failed authentication does not create history and local history write failure preserves authenticated state', async () => {
  const denied = await fixture({ bound: false });
  denied.state.loginError = failure(K.Permission);
  await denied.model.submitLogin();
  assert.equal(denied.count('book.save'), 0);
  assert.equal(denied.model.authenticated, false);
  const local = await fixture({ bound: false });
  const original = plain(local.state.addressRecords);
  local.state.addressSaveError = new Error('disk failure');
  await local.model.submitLogin();
  assert.equal(local.model.authenticated, true);
  assert.deepEqual(local.state.addressRecords, original);
  assert.match(local.model.errorText, /登录记录/);
});

test('verified restored session updates history without another login or identity request', async () => {
  const { model, state, count } = await fixture();
  await model.restore(context);
  assert.equal(model.authenticated, true);
  assert.equal(state.addressRecords[0].origin, oldOrigin);
  assert.equal(count('book.save'), 1);
  assert.equal(count('login'), 0);
  assert.equal(count('identity'), 1);
  assert.ok(state.addressRecords[0].device);
});

test('saved sessions require a successful protected read before authentication and task attachment', async () => {
  for (const kind of [K.SessionExpired, K.Network]) {
    const { model, state, count } = await fixture({ bound: false });
    state.listError = failure(kind);
    await model.restore(context);
    assert.equal(model.authenticated, false); assert.equal(count('queue.attach'), 0);
    assert.equal(model.savedSession, kind === K.Network);
  }
});
class SessionStoreFailure extends Error {}

async function fixture(options = {}) {
  const binding = { account: 'alice', fingerprint: await nasDeviceFingerprint(identity), model: identity.model };
  const addresses = [{ origin: oldOrigin, name: '局域网 NAS', kind: 'lan', ...(options.bound === false ? {} : { device: binding }) },
    { origin: nextOrigin, name: '远程 NAS', kind: 'remote', device: binding }];
  const state = { session: plain(savedSession), addressRecords: plain(addresses), addressSaveError: undefined,
    addressLoadError: undefined, sessionLoadError: undefined,
    sessionSaveError: undefined, loginError: undefined, clearError: undefined, stopError: undefined, logoutError: undefined,
    identityError: undefined, observedIdentity: identity, identityGate: undefined, stopGate: undefined, clearGate: undefined,
    discoverError: undefined, taskRecords: new Map([[JSON.stringify([oldOrigin, 'alice']), [{ id: 'old-file-task', taskId: 'dsm-task' }]]]),
    transferRecords: new Map([[JSON.stringify([oldOrigin, 'alice']), [{ id: 'old-transfer', state: 'unknown' }]]]) };
  const calls = [];
  const connectors = [];
  const record = (method, details = {}) => { calls.push({ method, ...details }); };
  class MockAddressStore {
    async load() {
      record('book.load');
      if (state.addressLoadError) { throw state.addressLoadError; }
      return plain(state.addressRecords);
    }
    async save(input) {
      record('book.save', { addresses: plain(input) });
      if (state.addressSaveError) { throw state.addressSaveError; }
      state.addressRecords = plain(input);
    }
  }
  class MockSessionStore {
    async load() {
      record('session.load');
      if (state.sessionLoadError) { throw state.sessionLoadError; }
      return state.session === undefined ? undefined : plain(state.session);
    }
    async save(input) {
      record('session.save', { session: plain(input) });
      if (state.sessionSaveError) { throw state.sessionSaveError; }
      state.session = plain(input);
    }
    async clear() {
      record('session.clear');
      if (state.clearGate) { await state.clearGate.promise; }
      if (state.clearError) { throw state.clearError; }
      state.session = undefined;
    }
  }
  class MockConnector {
    origin = undefined;
    session = undefined;
    closed = false;
    constructor() { connectors.push(this); }
    event(method, args = []) { record(method, { connector: this, origin: this.origin, sid: this.session?.sid, args }); }
    async discover(...args) {
      this.origin = args[0];
      this.event('discover', args);
      if (state.discoverError) { throw state.discoverError; }
      const apis = [{ name: 'SYNO.API.Auth', minVersion: 6, maxVersion: 6 }];
      if (options.fileStation !== false) { apis.push({ name: 'SYNO.FileStation.List', minVersion: 2, maxVersion: 2 }); }
      return apis;
    }
    restoreSession(input) { this.event('restoreSession', [plain(input)]); this.session = plain(input); }
    async login(...args) { this.event('login', args); if (state.loginError) { throw state.loginError; } this.session = [plain(newSessionRecord)]; }
    async telemetrySystem(...args) {
      this.event('identity', args);
      if (state.identityGate) { await state.identityGate.promise; }
      if (state.identityError) { throw state.identityError; }
      return state.observedIdentity;
    }
    async deviceIdentity() { return { model: identity.model, serverName: '测试设备' }; }
    async list(...args) {
      this.event('list', args);
      if (state.listError) { throw state.listError; }
      return { entries: [{ name: '旧目录', path: '/old-share', isDirectory: true }], offset: 0, total: 1 };
    }
    sessionSnapshot() { this.event('snapshot'); return this.session === undefined ? [] : plain(this.session); }
    async logout() {
      this.event('logout');
      try { if (state.logoutError) { throw state.logoutError; } } finally { this.close(); }
    }
    close() { this.event('close'); this.closed = true; this.session = undefined; }
  }
  class MockQueue {
    ready = true;
    busy = false;
    items = [];
    async attach(_context, connector, origin, account) {
      record('queue.attach', { connector, origin, account });
      this.items = plain(state.transferRecords.get(JSON.stringify([origin, account])) || []);
    }
    detach() { record('queue.detach'); this.items = []; }
    async stopAll() {
      record('queue.stopAll');
      if (state.stopGate) { await state.stopGate.promise; }
      if (state.stopError) { throw state.stopError; }
    }
  }
  class MockFileTaskStore {
    async load(_context, origin, account) {
      record('tasks.load', { origin, account });
      return plain(state.taskRecords.get(JSON.stringify([origin, account])) || []);
    }
    async save(tasks) { record('tasks.save', { tasks: plain(tasks) }); }
  }
  class MockPhotos {
    errorText = '';
    attach(connector) { record('photos.attach', { connector }); }
    reset() { record('photos.reset'); }
  }
  class MockTelemetry {
    attach(connector) { record('telemetry.attach', { connector }); }
    detach() { record('telemetry.detach'); }
  }
  const { ConnectionAddressBook } = loadSource('features/connection/ConnectionAddressBook.ets', {
    '../../core/domain/DsmProtocol': protocol,
    '../../core/domain/ConnectionRoutes': routes,
    '../../core/network/NasConnector': { NasConnector: MockConnector },
    '../../core/network/RcpNasTransport': { RcpNasTransport: class {} },
    './NasAddressBookStore': { NasAddressBookStore: MockAddressStore, nasDeviceFingerprint },
  });
  const { ConnectionViewModel } = loadSource('features/connection/ConnectionViewModel.ets', {
    '../../core/domain/DsmProtocol': protocol,
    '../../core/network/NasConnector': { NasConnector: MockConnector },
    '../../core/network/RcpNasTransport': { RcpNasTransport: class {} },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
    './NasSessionStore': { NasSessionStore: MockSessionStore, NasSessionStoreFailure: SessionStoreFailure },
    '../../core/domain/PhotosProtocol': photos,
    '../transfers/TransferQueue': { TransferQueue: MockQueue },
    '../../core/domain/FileOperations': operations,
    '../sharing/SharedUploadInbox': { sharedUploadInbox: {} },
    './FileTaskStore': { FileTaskStore: MockFileTaskStore },
    '@kit.ArkTS': { util: { generateRandomUUID: () => '11111111-1111-4111-8111-111111111111' } },
    '../photos/PhotoLibrary': { PhotoLibrary: MockPhotos },
    '../backup/AutomaticPhotoBackup': { AutomaticPhotoBackup: class { async attach() {} detach() {} } },
    '../telemetry/TelemetryMonitor': { TelemetryMonitor: MockTelemetry },
    './ConnectionAddressBook': { ConnectionAddressBook },
    '../control/SystemControlModel': { SystemControlModel: class { deactivate() {} } },
    '../extensions/NasExtensionsModel': { NasExtensionsModel: class { recordsReady = true; busy = false; pending = []; async attach() {} reset() {} } },
    '../drive/DriveBrowserModel': { DriveBrowserModel: class { attach() {} detach() {} reset() {} } },
    '../drive/DriveThumbnailStore': { DriveThumbnailStore: class { attach() {} detach() {} } },
    '../drive/DriveOriginalModel': { DriveOriginalModel: class { attach() {} detach() {} async close() {} } },
    '../drive/DriveSharingModel': { DriveSharingModel: class {
      ready = true; busy = false; hasPending = false; async attach() {} detach() {} async stopAll() {}
    } },
    '../drive/DriveNotificationsModel': { DriveNotificationsModel: class { attach() {} detach() {} } },
    '../drive/DriveActionModel': { DriveActionModel: class {
      ready = true; busy = false; hasPending = false;
      async attach(...args) { this.canWrite = args[5]; }
      async stopAll() { record('drive-actions.stopAll'); } detach() {}
    } },
    '../drive/DriveTransferModel': { DriveTransferModel: class {
      ready = true; busy = false; items = [];
      async attach(...args) { this.canStart = args[5]; this.insecureTls = args[6]; }
      async stopAll() { record('drive.stopAll'); if (state.driveStopGate) await state.driveStopGate.promise; }
      detach() { record('drive.detach'); }
    } },
  });
  const model = new ConnectionViewModel();
  Object.assign(model, { context, address: oldOrigin, account: 'alice', password: 'typed-password', otp: '123456' });
  if (options.loaded !== false) { assert.equal(await model.addressBook.load(context), true); }
  return { model, state, calls, connectors, count: method => calls.filter(call => call.method === method).length };
}

function assertNoAccountEffects(calls) {
  assert.deepEqual(calls.filter(call => ['list', 'queue.attach', 'tasks.load', 'tasks.save', 'photos.attach',
    'telemetry.attach', 'session.save', 'snapshot'].includes(call.method)), []);
}

for (const operation of ['restore', 'login']) {
  test(`${operation} waits for the real bound identity check before files, queue attachment and session persistence`, async () => {
    const { model, state, calls, connectors, count } = await fixture();
    if (operation === 'login') { await model.connect(); state.session = undefined; }
    state.identityGate = deferred();
    const pending = operation === 'restore' ? model.restore(context) : model.login();
    await flush();
    assert.equal(count('identity'), 1);
    assertNoAccountEffects(calls);
    assert.equal(model.authenticated, false);
    assert.equal(model.busy, true);
    state.identityGate.resolve();
    await pending;
    assert.equal(model.authenticated, true);
    assert.equal(model.connected, true);
    assert.equal(model.busy, false);
    assert.match(model.deviceCheckText, /设备身份已核验/);
    const identityIndex = calls.findIndex(call => call.method === 'identity');
    for (const method of ['list', 'tasks.load', 'queue.attach', 'photos.attach', 'telemetry.attach']) {
      assert.equal(count(method), 1);
      assert.ok(calls.findIndex(call => call.method === method) > identityIndex, `${method} must follow verification`);
    }
    const queue = calls.find(call => call.method === 'queue.attach');
    assert.equal(queue.connector, connectors[0]);
    assert.equal(queue.origin, oldOrigin);
    assert.equal(queue.account, 'alice');
    assert.equal(count('session.save'), operation === 'login' ? 1 : 0);
    if (operation === 'login') {
      assert.ok(calls.findIndex(call => call.method === 'session.save') > calls.findIndex(call => call.method === 'queue.attach'));
      assert.deepEqual(state.session, { origin: oldOrigin, account: 'alice', insecureTls: false, sessions: [newSessionRecord] });
    } else {
      assert.deepEqual(calls.find(call => call.method === 'restoreSession').args, [savedSession.sessions]);
    }
  });

  test(`${operation} closes a changed device without listing files, attaching old tasks or saving a session`, async () => {
    const { model, state, calls, connectors } = await fixture();
    if (operation === 'login') { await model.connect(); }
    state.observedIdentity = { ...identity, serial: 'changed-serial-same-model' };
    if (operation === 'restore') { await model.restore(context); } else { await model.login(); }
    assertNoAccountEffects(calls);
    assert.equal(model.authenticated, false);
    assert.equal(model.connected, false);
    assert.equal(model.busy, false);
    assert.equal(model.connector, undefined);
    assert.equal(connectors[0].closed, true);
    assert.equal(connectors[0].session, undefined);
    assert.match(model.errorText, /设备标识已变化/);
    assert.doesNotMatch(model.deviceCheckText, /身份已核验/);
  });

  for (const kind of [K.Permission, K.Unsupported, K.SessionExpired]) {
    test(`${operation} fails closed on ${K[kind]} instead of treating a bound device as unregistered`, async () => {
      const { model, state, calls, connectors, count } = await fixture();
      if (operation === 'login') { await model.connect(); }
      state.identityError = failure(kind);
      if (operation === 'restore') { await model.restore(context); } else { await model.login(); }
      assertNoAccountEffects(calls);
      assert.equal(model.authenticated, false);
      assert.equal(model.connected, false);
      assert.equal(connectors[0].closed, true);
      assert.ok(model.errorText);
      assert.equal(count('session.clear'), kind === K.SessionExpired ? 1 : 0);
      if (kind === K.SessionExpired) {
        assert.equal(model.savedSession, false);
        assert.equal(state.session, undefined);
      } else { assert.match(model.errorText, /无法核验已登记的设备/); }
    });
  }

  test(`${operation} ignores a late identity response after disposal`, async () => {
    const { model, state, calls, connectors } = await fixture();
    if (operation === 'login') { await model.connect(); }
    state.identityGate = deferred();
    const pending = operation === 'restore' ? model.restore(context) : model.login();
    await flush();
    assert.equal(calls.filter(call => call.method === 'identity').length, 1);
    model.dispose();
    state.identityGate.resolve();
    await pending;
    assertNoAccountEffects(calls);
    assert.equal(connectors[0].closed, true);
    assert.equal(model.connected, false);
    assert.equal(model.authenticated, false);
    assert.equal(model.busy, false);
  });
}

test('an explicitly unbound login is allowed but cannot claim that the device was verified', async () => {
  const { model, count } = await fixture({ bound: false });
  await model.connect();
  await model.login();
  assert.equal(model.authenticated, true);
  assert.equal(count('identity'), 0);
  assert.match(model.deviceCheckText, /未登记设备身份.*不合并登录和任务/);
  assert.equal(count('session.save'), 1);
});

test('login without File Station still saves the session, attaches tasks and explains the file tab', async () => {
  const { model, count } = await fixture({ fileStation: false });
  await model.connect();
  await model.login();
  assert.equal(model.authenticated, true);
  assert.equal(count('session.save'), 1);
  assert.equal(count('queue.attach'), 1);
  assert.equal(count('list'), 0);
  assert.match(model.directoryErrorText, /File Station/);
});

test('restore without a protected verification interface requires fresh login', async () => {
  const { model, count } = await fixture({ fileStation: false });
  await model.restore(context);
  assert.equal(model.authenticated, false);
  assert.equal(model.savedSession, true);
  assert.equal(count('list'), 0);
  assert.equal(count('queue.attach'), 0);
  assert.match(model.errorText, /重新登录/);
});

test('a file permission failure after login does not block session persistence or queue attachment', async () => {
  const { model, state, count } = await fixture();
  state.listError = failure(K.Permission);
  await model.connect();
  await model.login();
  assert.equal(model.authenticated, true);
  assert.equal(count('session.save'), 1);
  assert.equal(count('queue.attach'), 1);
  assert.equal(count('list'), 1);
  assert.ok(model.directoryErrorText.length > 0);
});

for (const operation of ['restore', 'login']) {
  test(`another account during ${operation} does not inherit the bound identity or task scope`, async () => {
    const { model, state, calls, count } = await fixture();
    model.account = 'bob';
    state.session.account = 'bob';
    state.identityError = failure(K.Permission);
    if (operation === 'restore') { await model.restore(context); } else { await model.connect(); await model.login(); }
    assert.equal(model.authenticated, true);
    assert.equal(count('identity'), 0);
    assert.match(model.deviceCheckText, /未登记设备身份/);
    assert.equal(calls.find(call => call.method === 'queue.attach').account, 'bob');
    assert.equal(calls.find(call => call.method === 'tasks.load').account, 'bob');
    assert.deepEqual(plain(model.fileTasks), []);
    assert.deepEqual(model.queue.items, []);
    assert.equal(state.session.account, 'bob');
  });
}

test('address-book I/O failure blocks automatic restore before discovery or SID installation', async () => {
  const { model, state, count, connectors } = await fixture({ loaded: false });
  state.addressLoadError = failure(K.Protocol);
  await model.restore(context);
  assert.equal(count('book.load'), 1);
  assert.equal(count('session.load'), 0);
  assert.equal(count('discover'), 0);
  assert.equal(count('restoreSession'), 0);
  assert.equal(connectors.length, 0);
  assert.equal(model.authenticated, false);
  assert.ok(model.errorText);
});

test('manual connect cannot bypass unread address configuration', async () => {
  const { model, count } = await fixture({ loaded: false });
  await model.connect();
  assert.equal(count('discover'), 0);
  assert.equal(model.connected, false);
  assert.match(model.errorText, /读取配置/);
});

test('session-store read failure is exposed without an invented empty session or network requests', async () => {
  const { model, state, count } = await fixture();
  state.sessionLoadError = new SessionStoreFailure('无法读取保存的登录信息');
  await model.restore(context);
  assert.equal(count('discover'), 0);
  assert.equal(model.savedSession, true);
  assert.equal(model.authenticated, false);
  assert.match(model.errorText, /无法读取保存的登录信息/);
});

test('session persistence I/O failure after verified login is not reported as saved', async () => {
  const { model, state, count } = await fixture();
  state.session = undefined;
  state.sessionSaveError = new SessionStoreFailure('无法保存登录信息');
  await model.connect();
  await model.login();
  assert.equal(count('session.save'), 1);
  assert.equal(model.authenticated, true);
  assert.equal(model.savedSession, false);
  assert.equal(state.session, undefined);
  assert.match(model.errorText, /无法保存登录信息/);
});

test('manual route switch stops the old scope, clears credentials and discovers only the selected new origin', async () => {
  const { model, state, calls, connectors } = await fixture();
  await model.restore(context);
  model.password = 'leftover-password';
  model.otp = '654321';
  model.needsOtp = true;
  assert.equal(model.fileTasks.length, 1);
  assert.equal(model.queue.items.length, 1);
  const fileRecords = plain([...state.taskRecords]);
  const transferRecords = plain([...state.transferRecords]);
  const before = calls.length;
  assert.equal(await model.useSavedAddress(' https://REMOTE.example.test:443/ '), true);
  const switching = calls.slice(before);
  const fresh = connectors[1];
  assert.deepEqual(switching.filter(call => call.connector === fresh).map(call => [call.method, call.args, call.sid]),
    [['discover', [nextOrigin], undefined]]);
  assert.ok(switching.findIndex(call => call.method === 'queue.stopAll') < switching.findIndex(call => call.method === 'session.clear'));
  assert.ok(switching.findIndex(call => call.method === 'session.clear') < switching.findIndex(call => call.method === 'discover'));
  assert.equal(switching.find(call => call.method === 'logout').origin, oldOrigin);
  assert.equal(connectors[0].closed, true);
  assert.equal(fresh.session, undefined);
  assert.equal(model.address, nextOrigin);
  assert.equal(model.account, '');
  assert.equal(model.password, '');
  assert.equal(model.otp, '');
  assert.equal(model.needsOtp, false);
  assert.equal(model.connected, true);
  assert.equal(model.authenticated, false);
  assert.equal(model.savedSession, false);
  assert.deepEqual(plain(model.entries), []);
  assert.deepEqual(plain(model.fileTasks), []);
  assert.deepEqual(model.queue.items, []);
  assertNoAccountEffects(switching);
  assert.equal(switching.some(call => ['restoreSession', 'login', 'identity'].includes(call.method)), false);
  assert.deepEqual(plain([...state.taskRecords]), fileRecords);
  assert.deepEqual(plain([...state.transferRecords]), transferRecords);
  assert.equal(state.session, undefined);
});

test('manual switching waits for both queue shutdown and session clear before any new-origin discovery', async () => {
  const { model, state, calls, count, connectors } = await fixture();
  await model.restore(context);
  state.stopGate = deferred();
  state.clearGate = deferred();
  const pending = model.useSavedAddress(nextOrigin);
  await flush();
  assert.equal(count('queue.stopAll'), 1);
  assert.equal(count('session.clear'), 0);
  assert.equal(connectors.length, 1);
  state.stopGate.resolve();
  await flush();
  assert.equal(count('session.clear'), 1);
  assert.equal(connectors.length, 1);
  assert.equal(calls.some(call => call.method === 'discover' && call.origin === nextOrigin), false);
  state.clearGate.resolve();
  assert.equal(await pending, true);
  assert.equal(connectors.length, 2);
});

test('disconnect blocks Drive writes throughout queue shutdown and restores permission only when shutdown fails', async () => {
  for (const stopFails of [false, true]) {
    const { model, state, count } = await fixture();
    state.taskRecords.clear(); state.transferRecords.clear();
    await model.restore(context);
    const canWrite = model.driveActions.canWrite, canStart = model.driveTransfers.canStart;
    assert.equal(canWrite(), true); assert.equal(canStart(), true);
    state.stopGate = deferred();
    if (stopFails) { state.stopError = failure(K.Protocol); }
    const leaving = model.disconnect(); await flush();
    assert.equal(count('drive-actions.stopAll'), 1); assert.equal(count('drive.stopAll'), 1);
    assert.equal(count('queue.stopAll'), 1); assert.equal(count('session.clear'), 0);
    assert.equal(model.busy, true); assert.equal(model.authenticated, true);
    assert.equal(canWrite(), false); assert.equal(canStart(), false);
    state.stopGate.resolve(); await leaving;
    assert.equal(model.busy, false); assert.equal(model.authenticated, stopFails);
    assert.equal(canWrite(), stopFails); assert.equal(canStart(), stopFails);
  }
});

test('switching addresses waits for foreground Drive cancellation before clearing the account', async () => {
  const { model, state, calls, count } = await fixture();
  await model.restore(context);
  state.driveStopGate = deferred();
  const switching = model.useSavedAddress(nextOrigin);
  await flush();
  assert.equal(count('drive.stopAll'), 1);
  assert.equal(count('queue.stopAll'), 0);
  assert.equal(count('session.clear'), 0);
  state.driveStopGate.resolve();
  assert.equal(await switching, true);
  assert.equal(count('drive.detach') > 0, true);
  assert.equal(calls.findIndex(call => call.method === 'drive.stopAll') < calls.findIndex(call => call.method === 'session.clear'), true);
});

test('queue.stopAll failure keeps the old connection and cannot probe the new origin', async () => {
  const { model, state, calls, connectors, count } = await fixture();
  await model.restore(context);
  state.stopError = failure(K.Protocol);
  const before = calls.length;
  assert.equal(await model.useSavedAddress(nextOrigin), false);
  assert.equal(connectors.length, 1);
  assert.equal(connectors[0].closed, false);
  assert.equal(model.address, oldOrigin);
  assert.equal(model.authenticated, true);
  assert.equal(model.savedSession, true);
  assert.equal(count('session.clear'), 0);
  assert.equal(count('logout'), 0);
  assert.equal(calls.slice(before).some(call => call.method === 'discover'), false);
  assert.equal(model.busy, false);
  assert.ok(model.errorText);
});

test('session clear failure cannot probe a new origin or reuse the old saved SID', async () => {
  const { model, state, calls, connectors, count } = await fixture();
  await model.restore(context);
  state.clearError = new SessionStoreFailure('清除保存的登录信息失败');
  const before = calls.length;
  assert.equal(await model.useSavedAddress(nextOrigin), false);
  assert.equal(connectors.length, 1);
  assert.equal(connectors[0].closed, true);
  assert.equal(model.address, oldOrigin);
  assert.equal(model.authenticated, false);
  assert.equal(model.connected, false);
  assert.equal(model.savedSession, true);
  assert.deepEqual(state.session, savedSession);
  assert.equal(count('session.clear'), 1);
  assert.equal(calls.slice(before).some(call => call.method === 'discover' || call.method === 'restoreSession'), false);
  assert.match(model.errorText, /清除保存的登录信息失败/);
});

for (const failedStep of ['stop', 'clear']) {
  test(`${failedStep} failure also blocks switching from an unauthenticated connection without a saved session`, async () => {
    const { model, state, calls, connectors, count } = await fixture();
    state.session = undefined;
    await model.connect();
    assert.equal(model.authenticated, false);
    assert.equal(model.savedSession, false);
    if (failedStep === 'stop') { state.stopError = failure(K.Protocol); }
    else { state.clearError = new SessionStoreFailure('清除登录信息失败'); }
    const before = calls.length;
    assert.equal(await model.useSavedAddress(nextOrigin), false);
    assert.equal(connectors.length, 1);
    assert.equal(calls.slice(before).some(call => call.method === 'discover'), false);
    assert.equal(count('session.clear'), failedStep === 'clear' ? 1 : 0);
    assert.equal(model.address, oldOrigin);
    assert.equal(model.busy, false);
    assert.ok(model.errorText);
  });
}

test('the certificate policy follows the address scheme and round-trips through the saved session', async () => {
  const { model, state } = await fixture();
  model.setAddress('http://lan.example.test:5000');
  assert.equal(model.useHttps, false);
  assert.equal(model.insecureTls, false);
  model.setAddress('https://lan.example.test:5001');
  assert.equal(model.useHttps, true);
  model.setInsecureTls(true);
  assert.equal(model.insecureTls, true);
  model.setUseHttps(false);
  assert.equal(model.useHttps, false);
  assert.equal(model.insecureTls, false);
  assert.equal(model.address, 'http://lan.example.test:5001');
  model.setUseHttps(true);
  assert.equal(model.address, 'https://lan.example.test:5001');

  model.account = 'alice';
  model.password = 'typed-password';
  model.address = 'nas.example.test:5001';
  model.setInsecureTls(true);
  state.session = undefined;
  model.addressBook.addresses.push({ origin: 'https://nas.example.test:5001', name: '证书例外地址', kind: 'remote', insecureTls: true, riskConfirmedAt: 1 });
  await model.submitLogin();
  assert.equal(model.authenticated, true);
  assert.equal(model.address, 'https://nas.example.test:5001');
  assert.deepEqual(state.session, { origin: 'https://nas.example.test:5001', account: 'alice',
    insecureTls: true, sessions: [newSessionRecord] });
});

test('a submitted login keeps a self-signed https policy but never keeps it for a plain http origin', async () => {
  const insecure = await fixture();
  insecure.state.session = { ...plain(savedSession), origin: 'https://self-signed.example.test:5001', insecureTls: true };
  insecure.model.addressBook.addresses.push({ origin: insecure.state.session.origin, name: '证书例外地址', kind: 'remote', insecureTls: true, riskConfirmedAt: 1 });
  await insecure.model.restore(context);
  assert.equal(insecure.model.authenticated, true);
  assert.equal(insecure.model.useHttps, true);
  assert.equal(insecure.model.insecureTls, true);

  const downgraded = await fixture();
  downgraded.state.session = { ...plain(savedSession), origin: 'http://lan.example.test:5000', insecureTls: true };
  downgraded.model.addressBook.addresses.push({ origin: downgraded.state.session.origin, name: '未加密地址', kind: 'lan', riskConfirmedAt: 1 });
  await downgraded.model.restore(context);
  assert.equal(downgraded.model.authenticated, true);
  assert.equal(downgraded.model.useHttps, false);
  assert.equal(downgraded.model.insecureTls, false);
});

test('an unknown saved route cannot disconnect the current account or issue discovery', async () => {
  const { model, calls, connectors } = await fixture();
  await model.restore(context);
  const before = calls.length;
  assert.equal(await model.useSavedAddress('https://unlisted.example.test'), false);
  assert.deepEqual(calls.slice(before), []);
  assert.equal(connectors.length, 1);
  assert.equal(model.authenticated, true);
  assert.match(model.errorText, /先保存并确认/);
});

test('switching to the current authenticated route is a no-op, not a logout or credential replay', async () => {
  const { model, calls } = await fixture();
  await model.restore(context);
  const before = calls.length;
  assert.equal(await model.useSavedAddress(oldOrigin), true);
  assert.deepEqual(calls.slice(before), []);
});

test('failed new-origin discovery is not successful switching and cannot restore an old account automatically', async () => {
  const { model, state, calls, connectors } = await fixture();
  await model.restore(context);
  state.discoverError = failure(K.Tls);
  const before = calls.length;
  assert.equal(await model.useSavedAddress(nextOrigin), false);
  const switching = calls.slice(before);
  assert.equal(connectors[1].closed, true);
  assert.equal(switching.filter(call => call.method === 'discover').length, 1);
  assert.equal(switching.find(call => call.method === 'discover').origin, nextOrigin);
  assert.equal(switching.some(call => ['restoreSession', 'login', 'identity', 'session.save', 'queue.attach'].includes(call.method)), false);
  assert.equal(model.connected, false);
  assert.equal(model.authenticated, false);
  assert.equal(model.savedSession, false);
  assert.equal(model.account, '');
  assert.ok(model.errorText);
});

test('Drive background mode receives the active TLS policy when the connection attaches', async () => {
  const { model } = await fixture(); model.insecureTls = true;
  model.addressBook.addresses[0].insecureTls = true; model.addressBook.addresses[0].riskConfirmedAt = 1;
  await model.connect(); await model.login();
  assert.equal(model.driveTransfers.insecureTls, true);
});

test('session expiry waits for old Drive background tasks to stop before clearing the account', async () => {
  const { model, state } = await fixture(); await model.connect(); await model.login();
  const stopping = deferred(); state.driveStopGate = stopping;
  const expiring = model.showFailure(failure(K.SessionExpired), 'drive');
  await new Promise(setImmediate); assert.equal(model.authenticated, true);
  stopping.resolve(); await expiring; assert.equal(model.authenticated, false);
});

for (const kind of [K.Permission, K.Unsupported]) {
  for (const bound of [true, false]) {
    test(`current-address registration exposes the book notice for ${K[kind]} with ${bound ? 'preserved' : 'no'} binding`, async () => {
      const { model, state } = await fixture({ bound });
      await model.connect();
      await model.login();
      model.addressBook.draftName = '当前 NAS';
      state.identityError = failure(kind);
      await model.saveCurrentAddress();
      assert.equal(model.deviceCheckText, model.addressBook.notice);
      assert.match(model.deviceCheckText, bound ? /原设备登记仍保留.*未完成身份核验/ : /未登记设备身份/);
      assert.doesNotMatch(model.deviceCheckText, /设备身份已登记|设备身份已核验/);
      assert.equal(model.authenticated, true);
      assert.equal(model.busy, false);
    });
  }
}
