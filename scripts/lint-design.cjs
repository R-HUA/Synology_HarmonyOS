const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const sourceRoot = path.join(root, 'entry/src/main/ets');
const sdk = process.env.HARMONY_SDK_ROOT || 'D:/Program Files/DevEco Studio/sdk/default';
const ts = require(path.join(sdk, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const symbols = new Set();
for (const provider of ['openharmony', 'hms']) {
  const catalog = path.join(sdk, provider, 'toolchains/id_defined.json');
  if (fs.existsSync(catalog)) {
    for (const item of JSON.parse(fs.readFileSync(catalog, 'utf8')).record) {
      if (item.type === 'symbol') symbols.add(item.name);
    }
  }
}
if (symbols.size === 0) throw new Error('未找到目标 SDK 的 Symbol 目录。');

const issues = [];
function report(rule, file, source, offset, message) {
  issues.push({ rule, file: path.relative(root, file).replaceAll('\\', '/'),
    line: source.slice(0, offset).split('\n').length, message });
}
function scan(directory) {
  const files = [];
  for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, item.name);
    if (item.isDirectory()) files.push(...scan(file));
    else if (item.name.endsWith('.ets')) files.push(file);
  }
  return files;
}
const files = scan(sourceRoot);
for (const file of files) {
  const source = fs.readFileSync(file, 'utf8');
  for (const hit of source.matchAll(/['"](?:#[\da-fA-F]{3,8}\b|rgba?\()/g)) {
    report('D-01', file, source, hit.index, '颜色字面量应使用主题资源。');
  }
  for (const hit of source.matchAll(/new\s+uiMaterial\.ImmersiveMaterial\s*\(/g)) {
    if (!file.endsWith(path.join('platform', 'ImmersiveMaterials.ets'))) {
      report('D-02', file, source, hit.index, '材质构造应集中在受控材质入口。');
    }
  }
  for (const hit of source.matchAll(/uiMaterial\.MaterialLevel|hdsMaterial\.ImmersiveStyle/g)) {
    report('D-05', file, source, hit.index, 'ArkUI 与 HDS 材质枚举不可混用。');
  }
  for (const hit of source.matchAll(/\$r\('sys\.symbol\.([^']+)'\)/g)) {
    if (!symbols.has(hit[1])) report('D-09', file, source, hit.index, `目标 SDK 未声明 Symbol：${hit[1]}`);
  }
  for (const hit of source.matchAll(/\bSearch\s*\(/g)) {
    if (!source.slice(hit.index, hit.index + 500).includes('.defaultFocus(false)')) {
      report('D-10', file, source, hit.index, '搜索框须显式关闭默认焦点。');
    }
  }
  for (const hit of source.matchAll(/\.barFloatingStyle\(/g)) {
    const modifiers = source.slice(Math.max(0, hit.index - 700), hit.index);
    if (!['.barOverlap(true)', '.vertical(false)', '.barPosition(BarPosition.End)'].every(value => modifiers.includes(value))) {
      report('D-08', file, source, hit.index, '悬浮页签须具备底置、横向与覆盖布局前置条件。');
    }
  }
  for (const hit of source.matchAll(/ · /g)) report('D-16', file, source, hit.index, '界面文案不使用中圆点拼接。');
  for (const hit of source.matchAll(/barBottomMargin\s*:\s*\d/g)) {
    report('D-30', file, source, hit.index, '悬浮底距须采用避让区或系统间距资源。');
  }
  for (const event of ['avoidAreaChange', 'windowSizeChange']) {
    const registrations = [...source.matchAll(new RegExp(`\\.on\\('${event}'`, 'g'))].length;
    const removals = [...source.matchAll(new RegExp(`\\.off\\('${event}'`, 'g'))].length;
    if (registrations > removals) report('D-29', file, source, 0, `${event} 监听未成对清理。`);
  }
  if (file.endsWith(path.join('platform', 'ImmersiveMaterials.ets'))) {
    const tree = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
    function check(node) {
      if (ts.isNewExpression(node) && node.expression.getText(tree) === 'uiMaterial.ImmersiveMaterial') {
        let parent = node.parent, guarded = false;
        while (parent) {
          if (ts.isIfStatement(parent) && parent.expression.getText(tree) === "deviceInfo.apiAvailable('26.0.0')" &&
              node.pos >= parent.thenStatement.pos && node.end <= parent.thenStatement.end) guarded = true;
          parent = parent.parent;
        }
        if (!guarded) report('D-26', file, source, node.getStart(tree), '材质构造缺少直接版本保护。');
      }
      ts.forEachChild(node, check);
    }
    check(tree);
  }
}
const reportFile = path.join(root, 'work/lint/design-report.json');
fs.mkdirSync(path.dirname(reportFile), { recursive: true });
fs.writeFileSync(reportFile, JSON.stringify({ filesChecked: files.length,
  rules: ['D-01', 'D-02', 'D-05', 'D-08', 'D-09', 'D-10', 'D-16', 'D-26', 'D-29', 'D-30'], issues }, null, 2));
for (const issue of issues) console.error(`${issue.file}:${issue.line} [${issue.rule}] ${issue.message}`);
console.log(`设计检查：${files.length} 个文件，${issues.length} 个问题。报告：work/lint/design-report.json`);
process.exitCode = issues.length === 0 ? 0 : 1;
