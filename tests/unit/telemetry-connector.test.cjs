const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdkRoot = process.env.HARMONY_SDK_ROOT || path.join(process.env.DEVECO_CLI_CLT_PATH || 'C:/Program Files/command-line-tools', 'sdk/default');
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

function load(relative, mocks = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets', relative), 'utf8');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020,
    module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal((output.diagnostics || []).filter(diagnostic => diagnostic.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, Error, Date, Uint8Array, ArrayBuffer,
    require: id => { assert.ok(Object.hasOwn(mocks, id), 'unexpected dependency ' + id); return mocks[id]; } });
  return module.exports;
}

const dsm = load('core/domain/DsmProtocol.ts');
const photos = load('core/domain/PhotosProtocol.ts', { './DsmProtocol': dsm });
const operations = load('core/domain/FileOperations.ts', { './DsmProtocol': dsm });
const queueState = load('core/domain/TransferQueueState.ts', { './DsmProtocol': dsm });
const control = load('core/domain/SystemControl.ts', { './DsmProtocol': dsm });
const drive = load('core/domain/DriveProtocol.ts', { './DsmProtocol': dsm });
const transferContracts = load('core/network/NasTransferTransport.ts', { '../domain/DsmProtocol': dsm });
const driveTransfer = load('core/domain/DriveTransferProtocol.ts', { './DsmProtocol': dsm, './DriveProtocol': drive,
  '../network/NasTransferTransport': transferContracts });
const driveThumbnail = load('core/domain/DriveThumbnailProtocol.ts', { './DsmProtocol': dsm, './DriveProtocol': drive,
  './DriveTransferProtocol': driveTransfer });
const { NasConnector, NAS_DISCOVERY_QUERY } = load('core/network/NasConnector.ts', {
  '../domain/ExtensionProtocol': load('core/domain/ExtensionProtocol.ts', { './DsmProtocol': dsm }),
  './ApiVersionPolicy': load('core/network/ApiVersionPolicy.ts', { '../domain/DsmProtocol': dsm }),
  './SessionRegistry': load('core/network/SessionRegistry.ts', { '../domain/DsmProtocol': dsm }),
  '../capabilities/CapabilityRegistry': load('core/capabilities/CapabilityRegistry.ts', { '../domain/DsmProtocol': dsm,
    '../network/ApiVersionPolicy': load('core/network/ApiVersionPolicy.ts', { '../domain/DsmProtocol': dsm }) }),
  './DsmRpcClient': load('core/network/DsmRpcClient.ts', { '../domain/DsmProtocol': dsm,
    './ApiVersionPolicy': load('core/network/ApiVersionPolicy.ts', { '../domain/DsmProtocol': dsm }) }),
  '../domain/DsmProtocol': dsm, '../domain/PhotoActions': load('core/domain/PhotoActions.ts', { './DsmProtocol': dsm, './PhotosProtocol': photos }), '../domain/PhotosProtocol': photos,
  '../domain/FileOperations': operations, '../domain/TransferQueueState': queueState,
  '../domain/DriveProtocol': drive, '../domain/DriveTransferProtocol': driveTransfer,
  '../domain/DriveThumbnailProtocol': driveThumbnail,
  './NasTransferTransport': transferContracts,
  '../domain/SystemControl': control,
});
const { NasFailure, NasErrorKind: K } = dsm;
const plain = value => JSON.parse(JSON.stringify(value));
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });
const bad = code => ({ status: 200, text: JSON.stringify({ success: false, error: { code } }) });
const isKind = (kind, code) => error => error instanceof NasFailure && error.kind === kind && (code === undefined || error.code === code);
const session = { sid: 'synthetic-private-sid', synoToken: 'synthetic-private-token' };
const sessions = [{ name: 'FileStation', sid: session.sid, synoToken: session.synoToken }];
const origin = 'https://nas.example.test:5001';
const monitorApis = [
  { method: 'telemetrySystem', api: 'SYNO.Core.System', operation: 'info', path: 'synthetic-system.cgi' },
  { method: 'telemetryUtilization', api: 'SYNO.Core.System.Utilization', operation: 'get', path: 'synthetic-utilization.cgi' },
  { method: 'telemetryStorage', api: 'SYNO.Storage.CGI.Storage', operation: 'load_info', path: 'synthetic-storage.cgi' },
];

class FakeTransport {
  calls = [];
  replies = [];
  closed = false;
  async post(address, body, authorization) {
    this.calls.push({ address, body: new URLSearchParams(body), rawBody: body, authorization });
    assert.ok(this.replies.length, 'unexpected network request');
    const reply = this.replies.shift();
    return typeof reply === 'function' ? reply() : reply;
  }
  close() { this.closed = true; }
}

function capabilities(includeMonitoring = true) {
  const result = {
    'SYNO.API.Auth': { path: 'synthetic-auth.cgi', minVersion: 1, maxVersion: 7, requestFormat: 'JSON' },
    'SYNO.FileStation.List': { path: 'synthetic-files.cgi', minVersion: 1, maxVersion: 2, requestFormat: 'JSON' },
  };
  if (includeMonitoring) {
    for (const descriptor of monitorApis) {
      result[descriptor.api] = { path: descriptor.path, minVersion: 1, maxVersion: 3, requestFormat: 'JSON' };
    }
  }
  return result;
}

async function discovered(descriptors = capabilities()) {
  const transport = new FakeTransport();
  const connector = new NasConnector(transport);
  transport.replies.push(ok(descriptors));
  const result = await connector.discover(origin);
  return { connector, transport, result };
}

async function authenticated(descriptors = capabilities()) {
  const context = await discovered(descriptors);
  context.connector.restoreSession(sessions);
  return context;
}

async function assertFilesRemainUsable(context) {
  context.transport.replies.push(ok({ offset: 0, total: 1, shares: [{ path: '/synthetic-share', name: 'synthetic-share' }] }));
  const page = await context.connector.list('');
  assert.equal(page.entries[0].path, '/synthetic-share');
  assert.equal(context.transport.calls.at(-1).body.get('api'), 'SYNO.FileStation.List');
  assert.deepEqual(plain(context.connector.sessionSnapshot()), sessions);
}

test('synthetic (not live NAS) discovery includes monitoring APIs without requiring them for login or files', async () => {
  const context = await discovered(capabilities(false));
  const query = context.transport.calls[0];
  assert.equal(query.address, origin + '/webapi/query.cgi');
  assert.equal(query.body.get('api'), 'SYNO.API.Info');
  assert.equal(query.body.get('method'), 'query');
  assert.equal(query.body.get('version'), '1');
  assert.equal(query.body.get('query'), NAS_DISCOVERY_QUERY);
  assert.equal(query.authorization, undefined);
  for (const descriptor of monitorApis) { assert.ok(query.body.get('query').split(',').includes(descriptor.api)); }
  assert.deepEqual(plain(context.result).map(descriptor => descriptor.name).sort(), ['SYNO.API.Auth', 'SYNO.FileStation.List']);
  context.transport.replies.push(ok({ sid: session.sid, synotoken: session.synoToken }));
  await context.connector.login('synthetic-reader', 'synthetic-password', '');
  assert.equal(context.transport.calls[1].address, origin + '/webapi/synthetic-auth.cgi');
  assert.equal(context.transport.calls[1].body.get('version'), '6');
  await assertFilesRemainUsable(context);
  const requestCount = context.transport.calls.length;
  for (const descriptor of monitorApis) {
    await assert.rejects(context.connector[descriptor.method](), isKind(K.Unsupported));
  }
  assert.equal(context.transport.calls.length, requestCount);
  assert.deepEqual(plain(context.connector.sessionSnapshot()), sessions);
});

for (const descriptor of monitorApis) {
  test(descriptor.method + ' uses discovered path, read-only v1 method and Cookie-session authorization only', async () => {
    const context = await authenticated();
    const data = { synthetic: true, api: descriptor.api };
    context.transport.replies.push(ok(data));
    assert.deepEqual(plain(await context.connector[descriptor.method]()), data);
    const request = context.transport.calls.at(-1);
    assert.equal(request.address, origin + '/webapi/' + descriptor.path);
    assert.deepEqual(Object.fromEntries(request.body), { api: descriptor.api, version: '1', method: descriptor.operation });
    assert.deepEqual(plain(request.authorization), session);
    for (const field of ['_sid', 'sid', 'SynoToken', 'synotoken', 'account', 'passwd', 'password', 'otp_code']) {
      assert.equal(request.body.has(field), false);
    }
    assert.equal(request.address.includes('synthetic-private'), false);
    assert.equal(request.rawBody.includes('synthetic-private'), false);
    assert.deepEqual(plain(context.connector.sessionSnapshot()), sessions);
  });

  test(descriptor.method + ' refuses undiscovered capability without making a request or clearing the session', async () => {
    const descriptors = capabilities();
    delete descriptors[descriptor.api];
    const context = await authenticated(descriptors);
    const requestCount = context.transport.calls.length;
    await assert.rejects(context.connector[descriptor.method](), isKind(K.Unsupported));
    assert.equal(context.transport.calls.length, requestCount);
    await assertFilesRemainUsable(context);
  });

  test(descriptor.method + ' refuses an unadapted version range rather than requesting the server maximum', async () => {
    const descriptors = capabilities();
    descriptors[descriptor.api].minVersion = 2;
    descriptors[descriptor.api].maxVersion = 9;
    const context = await authenticated(descriptors);
    const requestCount = context.transport.calls.length;
    await assert.rejects(context.connector[descriptor.method](), isKind(K.Unsupported));
    assert.equal(context.transport.calls.length, requestCount);
    await assertFilesRemainUsable(context);
  });

  test(descriptor.method + ' never requests monitoring before authentication', async () => {
    const transport = new FakeTransport();
    const connector = new NasConnector(transport);
    await assert.rejects(connector[descriptor.method](), isKind(K.SessionExpired));
    assert.equal(transport.calls.length, 0);
    const context = await discovered();
    const requestCount = context.transport.calls.length;
    await assert.rejects(context.connector[descriptor.method](), isKind(K.SessionExpired));
    assert.equal(context.transport.calls.length, requestCount);
  });

  for (const [code, kind] of [[105, K.Permission], [102, K.Unsupported], [103, K.Unsupported], [104, K.Unsupported], [500, K.Server]]) {
    test(descriptor.method + ' HTTP 200 business failure ' + code + ' rejects without invalidating file access', async () => {
      const context = await authenticated();
      context.transport.replies.push(bad(code));
      await assert.rejects(context.connector[descriptor.method](), isKind(kind, code));
      assert.deepEqual(plain(context.connector.sessionSnapshot()), sessions);
      await assertFilesRemainUsable(context);
    });
  }

  for (const code of [106, 107, 119, 150]) {
    test(descriptor.method + ' expiration ' + code + ' clears the session and blocks subsequent requests', async () => {
      const context = await authenticated();
      context.transport.replies.push(bad(code));
      await assert.rejects(context.connector[descriptor.method](), isKind(K.SessionExpired, code));
      assert.equal(context.connector.sessionSnapshot().length, 0);
      const requestCount = context.transport.calls.length;
      for (const next of monitorApis) {
        await assert.rejects(context.connector[next.method](), isKind(K.SessionExpired));
      }
      await assert.rejects(context.connector.list(''), isKind(K.SessionExpired));
      assert.equal(context.transport.calls.length, requestCount);
    });
  }

  test(descriptor.method + ' network and HTTP failures reject without reporting success or losing the session', async () => {
    const context = await authenticated();
    const networkError = new NasFailure(K.Network, '合成网络失败');
    context.transport.replies.push(() => { throw networkError; });
    await assert.rejects(context.connector[descriptor.method](), error => error === networkError);
    assert.deepEqual(plain(context.connector.sessionSnapshot()), sessions);
    context.transport.replies.push({ status: 503, text: JSON.stringify({ success: true, data: {} }) });
    await assert.rejects(context.connector[descriptor.method](), isKind(K.Http, 503));
    await assertFilesRemainUsable(context);
  });

  test(descriptor.method + ' malformed HTTP 200 response is a protocol error rather than empty success', async () => {
    const context = await authenticated();
    for (const text of ['not JSON', '{}', JSON.stringify({ success: true, data: [] })]) {
      context.transport.replies.push({ status: 200, text });
      await assert.rejects(context.connector[descriptor.method](), isKind(K.Protocol));
      assert.deepEqual(plain(context.connector.sessionSnapshot()), sessions);
    }
    await assertFilesRemainUsable(context);
  });
}
