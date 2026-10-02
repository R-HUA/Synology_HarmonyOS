const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdkRoot = process.env.HARMONY_SDK_ROOT || path.join(process.env.DEVECO_CLI_CLT_PATH || 'C:/Program Files/command-line-tools', 'sdk/default');
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

module.exports = function loadSdkDigest(cryptoFramework, protocol, supports = () => true) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/platform/SdkDigest.ets'), 'utf8');
  const output = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true,
  });
  assert.equal((output.diagnostics || []).filter(diagnostic => diagnostic.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  const mocks = { '@kit.CryptoArchitectureKit': { cryptoFramework }, '../core/domain/DsmProtocol': protocol };
  vm.runInNewContext(output.outputText, {
    module, exports: module.exports, Error, Uint8Array, canIUse: supports,
    require: id => { assert.ok(Object.hasOwn(mocks, id), 'unexpected dependency ' + id); return mocks[id]; },
  });
  return module.exports;
};
