const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const protocol = require('../../work/core-build/domain/DsmProtocol.js');
const sdkRoot = process.env.HARMONY_SDK_ROOT || 'C:/Program Files/command-line-tools/sdk/default';
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

function load(relative, mocks) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets', relative), 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true,
  });
  assert.equal((output.diagnostics || []).filter(diagnostic => diagnostic.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  vm.runInNewContext(output.outputText, {
    module, exports: module.exports, Error, Uint8Array, ArrayBuffer,
    require: id => { assert.ok(Object.hasOwn(mocks, id), 'unexpected dependency ' + id); return mocks[id]; },
  });
  return module.exports;
}

function fixture(failRead = false, failClose = false, failCleanup = false) {
  const events = [];
  const diagnostics = [];
  const primary = Object.assign(new Error('read failed'), { code: 13900028 });
  let read = 0;
  const io = {
    OpenMode: { READ_ONLY: 0, CREATE: 64, WRITE_ONLY: 1, TRUNC: 512 },
    async open(name) { return { fd: name.startsWith('file://') ? 1 : 2 }; },
    async stat() { return { size: 3, isFile: () => true }; },
    async read(descriptor, buffer) {
      if (failRead) throw primary;
      if (read === 3) return 0;
      const count = Math.min(buffer.byteLength, 3 - read);
      new Uint8Array(buffer).fill(65, 0, count); read += count; return count;
    },
    async write(descriptor, bytes) { return Math.min(1, bytes.byteLength); },
    async close(file) { events.push(['close', file.fd]); if (failClose) throw { code: 13900005 }; },
    async unlink(name) { events.push(['unlink', name]); if (failCleanup) throw { code: 13900013 }; },
  };
  const log = { hilog: { error(...args) { diagnostics.push(args); } } };
  const boundary = load('platform/SdkFileIO.ets', {
    '@kit.CoreFileKit': { fileIo: io }, '@kit.PerformanceAnalysisKit': log,
    '../core/domain/DsmProtocol': protocol,
  });
  const { SharedUploadInbox } = load('features/sharing/SharedUploadInbox.ets', {
    '@kit.AbilityKit': {}, '@kit.ShareKit': {},
    '@kit.ArkData': { uniformTypeDescriptor: { getTypeDescriptor: () => ({ belongsTo: () => false }) } },
    '@kit.ArkTS': { util: { generateRandomUUID: () => '11111111-1111-4111-8111-111111111111' } },
    '@kit.CoreFileKit': { fileIo: io, fileUri: {
      FileUri: class { name = '报告.txt'; }, getUriFromPath: value => 'file://' + value,
    } },
    '@kit.PerformanceAnalysisKit': log, '../../platform/SdkFileIO': boundary,
  });
  const inbox = new SharedUploadInbox();
  inbox.privateDir = '/private/inbox';
  return { inbox, events, diagnostics, primary };
}

test('shared copies preserve the original read error even when both closes and cleanup fail', async () => {
  const fixtureState = fixture(true, true, true);
  await assert.rejects(fixtureState.inbox.copyRecord({ uri: 'file://shared/report', utd: 'general.file' }, 0),
    error => error === fixtureState.primary);
  assert.deepEqual(fixtureState.events.slice(0, 2), [['close', 2], ['close', 1]]);
  assert.ok(fixtureState.events[2][1].startsWith('/private/inbox/'));
  assert.equal(fixtureState.diagnostics.length, 3);
  assert.ok(fixtureState.diagnostics.every(args => !JSON.stringify(args).includes('report')));
});

test('a shared copy is not accepted when closing fails and only its private copy is removed', async () => {
  const fixtureState = fixture(false, true);
  await assert.rejects(fixtureState.inbox.copyRecord({ uri: 'file://shared/report', utd: 'general.file' }, 0),
    error => error.kind === protocol.NasErrorKind.Protocol);
  assert.equal(fixtureState.events.filter(event => event[0] === 'close').length, 2);
  const removed = fixtureState.events.filter(event => event[0] === 'unlink');
  assert.equal(removed.length, 1);
  assert.ok(removed[0][1].startsWith('/private/inbox/'));
});

test('successful share intake still returns a private copy without enqueueing an upload', async () => {
  const fixtureState = fixture();
  const copied = await fixtureState.inbox.copyRecord({ uri: 'file://shared/report', utd: 'general.file' }, 0);
  assert.equal(copied.size, 3);
  assert.equal(copied.fileName, '报告.txt');
  assert.ok(copied.localPath.startsWith('/private/inbox/'));
  assert.deepEqual(fixtureState.events, [['close', 2], ['close', 1]]);
});
