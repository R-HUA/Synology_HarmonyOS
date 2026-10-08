const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdkRoot = process.env.HARMONY_SDK_ROOT;
const ts = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

module.exports = function loadSpaceBudget(protocol, free = async () => 8 * 1024 ** 3) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/platform/LocalSpaceBudget.ets'), 'utf8');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
  const module = { exports: {} };
  const mocks = { '@kit.CoreFileKit': { statfs: { getFreeSize: free } }, '../core/domain/DsmProtocol': protocol };
  vm.runInNewContext(output.outputText, { module, exports: module.exports, require: id => mocks[id] });
  return module.exports;
};
