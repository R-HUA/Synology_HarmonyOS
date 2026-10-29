const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'D:/Program Files/DevEco Studio/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const protocol = require('../../work/core-build/domain/DsmProtocol.js');

function fixture() {
  const events = [];
  let validate = async () => {}, expired = 0, cookieFailure = false;
  const source = fs.readFileSync('entry/src/main/ets/features/packages/OfficialWebModel.ets', 'utf8')
    .replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
  const module = { exports: {} };
  const cookies = {
    clearAllCookiesSync(incognito) { assert.equal(incognito, true); events.push(['clear']); },
    configCookieSync(origin, value, incognito, httpOnly) {
      if (cookieFailure) throw new Error('cookie rejected');
      events.push(['cookie', origin, value, incognito, httpOnly]);
    },
  };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, Error,
    require(id) {
      if (id === '@kit.ArkWeb') return { webview: { WebCookieManager: cookies } };
      if (id.endsWith('/DsmProtocol')) return protocol;
      if (id.endsWith('/NasConnector')) return {};
      throw new Error(id);
    },
  });
  const model = new module.exports.OfficialWebModel();
  const connector = {
    async validateSession() { events.push(['validate']); await validate(); },
    webSessionCookies() { return ['id=primary-sid; Path=/; HttpOnly; Secure']; },
  };
  model.attach(connector, 'https://nas.example.test:5001', true, async () => { expired++; });
  events.length = 0; model.open();
  return { model, events, connector, setValidation(value) { validate = value; }, expired: () => expired,
    failCookies() { cookieFailure = true; } };
}

test('the main session is verified before private cookies are configured and the URL contains no credentials', async () => {
  const f = fixture();
  const address = await f.model.prepare();
  assert.equal(address, 'https://nas.example.test:5001/');
  assert.deepEqual(f.events.map(x => x[0]), ['validate', 'clear', 'cookie']);
  assert.deepEqual(f.events[2], ['cookie', address, 'id=primary-sid; Path=/; HttpOnly; Secure', true, true]);
  assert.equal(f.model.accepts(address + 'webman/index.cgi'), true);
  for (const url of ['https://nas.example.test:5002/', 'http://nas.example.test:5001/', 'https://other.example.test/']) {
    assert.equal(f.model.accepts(url), false);
  }
});

test('closing during validation cannot install cookies or publish a new page', async () => {
  const f = fixture(); let finish;
  f.setValidation(() => new Promise(resolve => { finish = resolve; }));
  const pending = f.model.prepare(); f.model.close(); finish();
  await assert.rejects(pending, x => x.kind === protocol.NasErrorKind.Cancelled);
  assert.equal(f.model.active, false); assert.equal(f.events.some(x => x[0] === 'cookie'), false);
});

test('expiry goes to the account owner, while network and cookie errors stay visible without another login', async () => {
  for (const kind of [protocol.NasErrorKind.SessionExpired, protocol.NasErrorKind.Network]) {
    const f = fixture(); f.setValidation(async () => { throw new protocol.NasFailure(kind, '验证失败'); });
    await assert.rejects(f.model.prepare());
    assert.equal(f.expired(), kind === protocol.NasErrorKind.SessionExpired ? 1 : 0);
    assert.ok(f.model.errorText); assert.equal(f.events.some(x => x[0] === 'cookie'), false);
  }
  const f = fixture(); f.failCookies();
  await assert.rejects(f.model.prepare()); assert.ok(f.model.errorText); assert.equal(f.expired(), 0);
});

test('a late failure after an account reset cannot expire a new account', async () => {
  const f = fixture(); let reject;
  f.setValidation(() => new Promise((_, done) => { reject = done; }));
  const pending = f.model.prepare(); f.model.reset();
  reject(new protocol.NasFailure(protocol.NasErrorKind.SessionExpired, 'old'));
  await assert.rejects(pending); assert.equal(f.expired(), 0); assert.equal(f.model.errorText, '');
});
