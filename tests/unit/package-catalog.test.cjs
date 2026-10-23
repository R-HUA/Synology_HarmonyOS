const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdkRoot = process.env.HARMONY_SDK_ROOT || 'D:/Program Files/DevEco Studio/sdk/default';
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const { NasConnector } = require('../../work/core-build/network/NasConnector.js');
const plain = value => JSON.parse(JSON.stringify(value));
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
const cache = new Map();
function load(name) {
  if (cache.has(name)) return cache.get(name);
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/packages', name), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, Date, Error, require: id => {
    if (id === '../../core/domain/DsmProtocol') return dsm;
    if (id === '@kit.PerformanceAnalysisKit') return { hilog: { error() {} } };
    if (id === './PackageProtocol') return load('PackageProtocol.ts');
    if (id === './PackageRepository') return load('PackageRepository.ts');
    throw new Error('unexpected dependency: ' + id);
  } }, { filename: name });
  cache.set(name, module.exports);
  return module.exports;
}
const p = load('PackageProtocol.ts');
const { PackageRepository } = load('PackageRepository.ts');
const { PackageCatalogModel } = load('PackageCatalogModel.ets');
const raw = (id = 'FileStation', extra = {}) => ({ id, name: id, version: '1.0', additional: { status: 'running' }, ...extra });
const isProtocol = error => error instanceof dsm.NasFailure && error.kind === dsm.NasErrorKind.Protocol;
const fail = kind => new dsm.NasFailure(kind, '合成错误', 105);

test('catalog decodes only display fields, preserves unknown optional values and sorts deterministically', () => {
  const items = p.decodePackageList({ packages: [raw('z', { name: 'B' }), raw('b', { name: 'A' }), raw('a', { name: 'A' }),
    { id: 'unknown', additional: { status: 'future-value', available_operation: ['uninstall'] }, secret: 'unused' }] }, 123);
  assert.deepEqual(plain(items.map(item => item.id)), ['unknown', 'a', 'b', 'z']);
  assert.deepEqual(plain(items[0]), { id: 'unknown', name: '', version: '', state: 'unknown', checkedAt: 123 });
  assert.equal(p.decodePackageDetail(raw('x', { additional: { status: 'stopped' } }), 'x').state, 'stopped');
  assert.equal(p.decodePackageDetail({ id: 'x' }, 'x').state, 'unknown');
  assert.deepEqual(plain(p.decodePackageList({ packages: [] })), []);
});

test('invalid catalog identity or schema fails as a whole, and detail must match requested identity', () => {
  for (const data of [{}, { packages: {} }, { packages: [null] }, { packages: [{ name: 'x' }] },
    { packages: [{ id: ' ' }] }, { packages: [raw(), raw()] }, { packages: [raw('x', { version: 2 })] },
    { packages: [raw('x', { additional: [] })] }, { packages: [raw('x', { additional: { status: false } })] }]) {
    assert.throws(() => p.decodePackageList(data), isProtocol);
  }
  assert.throws(() => p.decodePackageDetail(raw('other'), 'requested'), isProtocol);
});

test('native support uses exact identities while search matches name and identity locally', () => {
  const items = p.decodePackageList({ packages: [raw('FileStation'), raw('SynologyDrive'), raw('SynologyPhotos'),
    raw('DownloadStation'), raw('third-party', { name: 'FileStation' }), raw('synologydrive')] });
  assert.equal(p.filterPackages(items, '', true).length, 4);
  assert.equal(p.filterPackages(items, ' photos ', false)[0].id, 'SynologyPhotos');
  assert.equal(p.filterPackages(items, 'third-PARTY', false)[0].id, 'third-party');
  assert.equal(p.packageNativeTarget('synologydrive'), undefined);
  assert.equal(p.packageNativeTarget('third-party'), undefined);
});

async function connectorFixture(descriptor = { path: 'entry.cgi', minVersion: 1, maxVersion: 99, requestFormat: 'JSON' }) {
  const replies = [{ status: 200, text: JSON.stringify({ success: true, data: {
    'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 1, maxVersion: 6 },
    'SYNO.FileStation.List': { path: 'entry.cgi', minVersion: 1, maxVersion: 2 },
    ...(descriptor ? { 'SYNO.Core.Package': descriptor } : {}),
  } }) }];
  const calls = [];
  const connector = new NasConnector({ post(...args) { calls.push(args); return Promise.resolve(replies.shift()); }, close() {} });
  await connector.discover('https://nas.example.test:5001');
  connector.restoreSession([{ name: 'FileStation', sid: 'private-sid', synoToken: 'private-token' }]);
  const repository = new PackageRepository((method, fields) => connector.packageRequest(method, fields));
  const state = () => connector.capabilitySnapshots().find(item => item.feature === 'packageCatalog').state;
  const ok = data => replies.push({ status: 200, text: JSON.stringify({ success: true, data }) });
  const bad = code => replies.push({ status: 200, text: JSON.stringify({ success: false, error: { code } }) });
  return { connector, repository, calls, state, ok, bad };
}

test('package reads use fixed v1 and discovery CGI with protected session; no management commands', async () => {
  for (const jsonParameters of [true, false]) {
    const f = await connectorFixture({ path: 'packages/read.cgi', minVersion: 1, maxVersion: 99,
      ...(jsonParameters ? { requestFormat: 'JSON' } : {}) });
    assert.equal(f.state(), 'unverified');
    f.ok({ packages: [raw()] });
    await f.connector.readPackageCatalog(() => f.repository.list());
    assert.equal(f.state(), 'available');
    let [address, body, session] = f.calls.at(-1);
    const fields = new URLSearchParams(body);
    assert.equal(address, 'https://nas.example.test:5001/webapi/packages/read.cgi');
    assert.equal(fields.get('version'), '1');
    assert.equal(fields.get('method'), 'list');
    assert.equal(fields.get('additional'), '["status"]');
    assert.equal(fields.get('ignore_hidden'), 'false');
    assert.equal(session.sid, 'private-sid');
    assert.doesNotMatch(address + body, /private-sid|private-token|_sid|synotoken/);
    f.ok(raw()); await f.repository.get('FileStation');
    assert.equal(new URLSearchParams(f.calls.at(-1)[1]).get('id'), jsonParameters ? '"FileStation"' : 'FileStation');
    const before = f.calls.length;
    await assert.rejects(f.connector.packageRequest('uninstall', []), error => error.kind === dsm.NasErrorKind.InvalidInput);
    await assert.rejects(f.repository.get(''), error => error.kind === dsm.NasErrorKind.InvalidInput);
    assert.equal(f.calls.length, before);
  }
});

test('missing or incompatible API rejects without fallback, retries or false availability', async () => {
  for (const descriptor of [null, { path: 'entry.cgi', minVersion: 2, maxVersion: 99 }]) {
    const f = await connectorFixture(descriptor);
    await assert.rejects(f.connector.readPackageCatalog(() => f.repository.list()), error => error.kind === dsm.NasErrorKind.Unsupported);
    assert.equal(f.calls.length, 1); assert.notEqual(f.state(), 'available');
  }
});

test('catalog permissions and detail failures stay local; schema validation controls list capability', async () => {
  const f = await connectorFixture();
  f.bad(105);
  await assert.rejects(f.connector.readPackageCatalog(() => f.repository.list()), error => error.kind === dsm.NasErrorKind.Permission);
  assert.equal(f.state(), 'unauthorized'); assert.equal(f.connector.sessionSnapshot().length, 1);
  f.ok({ shares: [], total: 0, offset: 0 }); await f.connector.list('');
  f.ok({ packages: {} });
  await assert.rejects(f.connector.readPackageCatalog(() => f.repository.list()), isProtocol);
  assert.equal(f.state(), 'schemaMismatch');
  f.ok({ packages: [] }); await f.connector.readPackageCatalog(() => f.repository.list());
  f.bad(105); await assert.rejects(f.repository.get('FileStation'));
  assert.equal(f.state(), 'available');
  f.bad(107); await assert.rejects(f.repository.get('FileStation'), error => error.kind === dsm.NasErrorKind.SessionExpired);
  assert.equal(f.connector.sessionSnapshot().length, 0);
});

function modelFixture() {
  const model = new PackageCatalogModel();
  const pending = [], calls = [];
  let expired = 0;
  const connector = {
    readPackageCatalog: read => read(),
    packageRequest(method, fields) { calls.push({ method, fields }); assert.ok(pending.length); return pending.shift()(); },
  };
  const bind = () => model.attach(connector, 'https://nas.example.test:5001/', async () => { expired++; });
  bind();
  return { model, pending, calls, bind, expired: () => expired };
}

test('binding is lazy, returning uses session cache, failed refresh retains its timestamp and data', async () => {
  const f = modelFixture();
  assert.equal(f.calls.length, 0);
  assert.equal(f.model.managementOrigin(), 'https://nas.example.test:5001');
  f.pending.push(async () => ({ packages: [raw()] })); f.model.showList(); await tick();
  const checkedAt = f.model.checkedAt;
  assert.equal(f.model.loaded, true); assert.equal(f.model.items.length, 1);
  f.model.hideList(); f.model.showList(); await tick(); assert.equal(f.calls.length, 1);
  f.pending.push(async () => { throw fail(dsm.NasErrorKind.Network); });
  await f.model.refresh();
  assert.equal(f.model.items.length, 1); assert.equal(f.model.checkedAt, checkedAt); assert.ok(f.model.error);
  assert.equal(f.expired(), 0);
  f.pending.push(async () => ({ packages: [] })); await f.model.refresh();
  assert.equal(f.model.loaded, true); assert.equal(f.model.items.length, 0); assert.equal(f.model.error, undefined);
});

test('duplicate refresh is coalesced, hiding drops late list success or session failure', async () => {
  for (const rejected of [false, true]) {
    const f = modelFixture(), remote = deferred();
    f.pending.push(() => remote.promise); f.model.showList(); await f.model.refresh();
    assert.equal(f.calls.length, 1);
    f.model.hideList();
    if (rejected) remote.reject(fail(dsm.NasErrorKind.SessionExpired));
    else remote.resolve({ packages: [raw()] });
    await tick(); assert.equal(f.model.loaded, false); assert.equal(f.model.loading, false);
    assert.equal(f.model.error, undefined); assert.equal(f.expired(), 0);
  }
});

test('reset or reconnect clears cache and rejects pending results from the previous session', async () => {
  const f = modelFixture(), old = deferred();
  f.pending.push(() => old.promise); f.model.showList();
  f.bind();
  f.pending.push(async () => ({ packages: [raw('new')] })); f.model.showList(); await tick();
  old.resolve({ packages: [raw('old')] }); await tick();
  assert.equal(f.model.items[0].id, 'new');
  f.model.query = 'query'; f.model.supportedOnly = true; f.model.select(f.model.items[0]); f.model.reset();
  assert.equal(f.model.loaded, false); assert.equal(f.model.items.length, 0); assert.equal(f.model.selected, undefined);
  assert.equal(f.model.query, ''); assert.equal(f.model.supportedOnly, false); assert.equal(f.model.managementOrigin(), '');
});

test('detail shows snapshot immediately, reads current state, and ignores replaced or hidden selection results', async () => {
  const f = modelFixture(), old = deferred();
  const first = p.decodePackageDetail(raw('first'), 'first');
  f.model.select(first); assert.equal(f.model.selected.id, 'first');
  f.pending.push(() => old.promise); f.model.showDetail();
  f.model.select(p.decodePackageDetail(raw('second'), 'second'));
  f.pending.push(async () => raw('second', { additional: { status: 'stopped' } }));
  f.model.showDetail(); await tick();
  old.resolve(raw('first')); await tick();
  assert.equal(f.model.selected.id, 'second'); assert.equal(f.model.selected.state, 'stopped');
  const hidden = deferred(); f.pending.push(() => hidden.promise); const read = f.model.refreshDetail();
  f.model.hideDetail(); hidden.reject(fail(dsm.NasErrorKind.SessionExpired)); await read;
  assert.equal(f.model.detailError, undefined); assert.equal(f.model.detailLoading, false); assert.equal(f.expired(), 0);
});

test('detail failure preserves snapshot and current session expiry uses the existing callback once', async () => {
  const f = modelFixture(); f.model.select(p.decodePackageDetail(raw(), 'FileStation'));
  f.pending.push(async () => { throw fail(dsm.NasErrorKind.Permission); }); f.model.showDetail(); await tick();
  assert.equal(f.model.selected.id, 'FileStation'); assert.ok(f.model.detailError); assert.equal(f.expired(), 0);
  f.pending.push(async () => { throw fail(dsm.NasErrorKind.SessionExpired); }); await f.model.refreshDetail();
  assert.equal(f.expired(), 1);
});

function navigationFixture(available = true) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/pages/Index.ets'), 'utf8');
  const methods = source.slice(source.indexOf('  private updatePackageVisibility()'), source.indexOf('  private remoteDownloadMenus()'));
  const output = ts.transpileModule('class Page {' + methods + '}\nmodule.exports = Page;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
  });
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, $r: value => value,
    driveTabs: () => available ? [{}] : [] });
  const page = new module.exports(), events = [], links = [];
  Object.assign(page, {
    pageActive: true, foreground: true, packageDestination: 'package-detail', drivePinned: [],
    model: { authenticated: true, sessionGeneration: 1, supports: () => available, drive: { supportsView: () => available },
      containers: { setVisible() {} },
      cloudSync: { setVisible() {} },
      systemLogs: { setVisible() {} },
      notes: { setVisible() {} },
      packages: { hideList: () => events.push('hideList'), hideDetail: () => events.push('hideDetail'),
        showList: () => events.push('showList'), showDetail: () => events.push('showDetail'),
        managementOrigin: () => 'https://nas.example.test:5001' } },
    abilityContext: { openLink: async link => { links.push(link); } },
    navStack: { clear: () => events.push('clear') }, navigationBusy: () => false, supportsPhotos: () => available,
    showTitleMenuError: () => events.push('error'), previewText: value => value,
    switchTab: index => events.push('tab:' + index), enterModule: name => events.push('module:' + name),
    openNasDownloads: () => events.push('downloads'), updateTelemetryMode() {},
  });
  return { page, events, links };
}

test('native package navigation clears catalog destinations before opening the existing module', () => {
  for (const [target, expected] of [['files', 'tab:1'], ['drive', 'module:drive'], ['photos', 'module:photos'], ['downloads', 'downloads']]) {
    const f = navigationFixture(); f.page.openPackageNative(target);
    assert.deepEqual(f.events, ['hideList', 'hideDetail', 'clear', expected]);
    assert.equal(f.page.packageDestination, '');
  }
  const unavailable = navigationFixture(false); unavailable.page.openPackageNative('drive');
  assert.deepEqual(unavailable.events, ['error']);
  const busy = navigationFixture(); busy.page.navigationBusy = () => true; busy.page.openPackageNative('files');
  assert.deepEqual(busy.events, []);
});

test('management opens only the normalized origin and a stale browser failure cannot affect another session', async () => {
  const f = navigationFixture(); await f.page.openPackageManagement();
  assert.deepEqual(f.links, ['https://nas.example.test:5001']);
  const remote = deferred(); f.page.abilityContext.openLink = () => remote.promise;
  const operation = f.page.openPackageManagement();
  f.page.model.sessionGeneration++; remote.reject(new Error('failed')); await operation;
  assert.deepEqual(f.events, []);
  f.page.abilityContext.openLink = async () => { throw new Error('failed'); };
  await f.page.openPackageManagement(); assert.deepEqual(f.events, ['error']);
});

test('more features can open management when native modules are unavailable and ignores hidden browser failures', async () => {
  const f = navigationFixture(false);
  f.page.packageDestination = 'more-features';
  f.page.updatePackageVisibility();
  assert.deepEqual(f.events, []);
  await f.page.openPackageManagement();
  assert.deepEqual(f.links, ['https://nas.example.test:5001']);
  for (const hidden of ['destination', 'foreground', 'account']) {
    const remote = deferred();
    f.page.packageDestination = 'more-features'; f.page.foreground = true;
    f.page.abilityContext.openLink = () => remote.promise;
    const operation = f.page.openPackageManagement();
    if (hidden === 'destination') f.page.packageDestination = 'package-detail';
    else if (hidden === 'foreground') f.page.foreground = false;
    else f.page.model.sessionGeneration++;
    remote.reject(new Error('failed')); await operation;
    assert.deepEqual(f.events, []);
  }
  f.page.model.authenticated = false;
  await f.page.openPackageManagement();
  assert.equal(f.links.length, 1);
});

test('backgrounding invalidates both catalog requests and foreground resumes only the current page', () => {
  const f = navigationFixture(); f.page.foreground = false; f.page.updatePackageVisibility();
  assert.deepEqual(f.events, ['hideList', 'hideDetail']);
  f.page.foreground = true; f.page.updatePackageVisibility(); assert.equal(f.events.at(-1), 'showDetail');
  f.page.packageDestination = 'packages'; f.page.updatePackageVisibility(); assert.equal(f.events.at(-1), 'showList');
});
