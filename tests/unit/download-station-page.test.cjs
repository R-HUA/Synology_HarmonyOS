const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdk = process.env.HARMONY_SDK_ROOT || 'C:/Program Files/command-line-tools/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const protocolModule = { exports: {} };
const protocolSource = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/downloadStation/DownloadStationProtocol.ts'), 'utf8');
vm.runInNewContext(ts.transpileModule(protocolSource, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText,
  { module: protocolModule, exports: protocolModule.exports, require: () => require('../../work/core-build/domain/DsmProtocol.js') });

function page(model) {
  // 仅装载渲染前的真实页面行为；设备组件本身由应用构建验证。
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/downloadStation/DownloadStationPage.ets'), 'utf8');
  const methods = source.slice(0, source.indexOf('  private statusText('))
    .replace('export struct DownloadStationPage', 'export class DownloadStationPage')
    .replace(/^\s*@(?:ComponentV2|Monitor\([^\n]*\))\s*$/gm, '')
    .replace(/@(?:Param|Local|Event)\s+/g, '') + '}';
  const compiled = ts.transpileModule(methods, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  assert.equal(compiled.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const mod = { exports: {} };
  vm.runInNewContext(compiled.outputText, { module: mod, exports: mod.exports, Scroller: class {}, require(id) {
    if (id === '../extensions/NasExtensionsModel') return { NasExtensionsModel: class {} };
    if (id === './DownloadStationProtocol') return protocolModule.exports;
    if (id === '@kit.BasicServicesKit') return {};
    throw new Error(id);
  } });
  const instance = new mod.exports.DownloadStationPage(); instance.model = model; return instance;
}

test('sparse NAS filtering adds at most two pages and explicit continuation starts a new bounded scan', async () => {
  let count = 0;
  const model = { downloads: Array.from({ length: 50 }, () => ({ status: 'finished' })), downloadHasMore: true,
    async loadMoreDownloads() { count++; this.downloads.push(...Array.from({ length: 50 }, () => ({ status: 'finished' }))); return true; } };
  const p = page(model); p.filter = 'active';
  await p.supplement(); assert.equal(count, 2); assert.equal(model.downloads.length, 150); assert.equal(p.reachArmed, false);
  await p.loadMore(); assert.equal(count, 4); assert.equal(p.reachArmed, false);
});

test('NAS supplementation stops at six matches, end of data or the first failed request', async () => {
  for (const ending of ['matches', 'end', 'failure']) {
    let count = 0;
    const model = { downloads: [], downloadHasMore: true, async loadMoreDownloads() {
      count++;
      if (ending === 'matches') this.downloads.push(...Array.from({ length: 6 }, () => ({ status: 'paused' })));
      if (ending === 'end') this.downloadHasMore = false;
      return ending !== 'failure';
    } };
    const p = page(model); p.filter = 'active'; await p.supplement(); assert.equal(count, 1, ending);
  }
});

test('page exit cancels the remaining scan budget while a single list request is in flight', async () => {
  let count = 0, release;
  const model = { downloads: [], downloadHasMore: true, async loadMoreDownloads() {
    count++; await new Promise(resolve => { release = resolve; }); return true;
  } };
  const p = page(model); p.filter = 'active'; const scanning = p.supplement();
  p.visible = false; p.filterRevision++; release(); await scanning;
  assert.equal(count, 1); assert.equal(p.supplementing, false);
});
