# NAS 工作台验证记录

验证日期：2026-10-09。分支：`feat/drive-photos-module-navigation`。本轮基线：`c0a36b3`；前一轮实现基线：`f2b31f7ed8af3acfe50e8928199641fe6578e072`。

本轮代码已通过核心编译、894 项单元测试和 debug 签名构建，最新签名包已更新安装到模拟器并成功启动。最新界面、Drive 静态图标与系统文件预览尚未在设备上验收；本轮未重新执行 release 和 DevEco Linter。前一轮 Linter 未通过，真实 NAS 兼容性仍待验收。

## 本轮界面与文件流程验证

| 范围 | 结果与边界 |
| --- | --- |
| 登录与历史 | 地址自动识别协议；忽略证书紧凑排列；应用图标与登录内容上移。认证或保存会话校验成功后自动记录地址，退出保留历史，移除入口仅在历史页。持久化失败不撤销认证，不冒充历史保存成功。 |
| 提示与选择 | 错误使用简短系统 Toast，保留中等厚度的沉浸材质。排序入口显示“按名称升序”等文案，方向选择位于标题右侧，普通选择控件与展开菜单分别设置材质。 |
| 文件列表 | Drive 与 File Station 触底追加读取，短页按实际页长前进；重复触底不重复请求，失败保留已有条目，刷新重置列表。上级面包屑使用普通文字颜色；File Station 三点操作改为原生菜单，详情操作行去掉箭头并缩小间距。文件行共用整行按压底色，分隔线覆盖图标与菜单区域，左右各保留 16vp。 |
| Drive 详情与图标 | 详情显示标题、扩展名类型、创建时间、修改时间、所有者、大小与所在位置；大小只显示合适的单位，路径保持在固定标签右侧换行。文件优先显示媒体缩略图，否则使用 128 尺寸的 Drive 文件类型资源；类型图标返回 404 时使用 xxx.png。同类型图标共用缓存，单行离屏不取消其他可见行的读取。 |
| Drive 搜索与打开 | 独立搜索页返回时恢复已加载列表，返回后丢弃迟到搜索响应。图片保留双击复位，移除底部复位按钮；常见文档和音视频在前台下载完成后调用 Preview Kit，不立即切到传输页，其他格式显示详情。取消下载不打开预览。 |
| 首页与监控 | 设备区保留与下方快捷卡片的间距，本轮向下微调 4vp。按分区记录权限失败，隐藏无权限的首页与监控详情卡片；网络失败继续保留反馈，人工重试成功恢复卡片。 |
| 核心检查 | 894 项通过，0 失败、跳过或取消；[日志](work/ui-correction/core-tests.log)。新增覆盖类型资源路径、404 回退与错误传播、共享缓存、可见行取消和连接切换。模型与平台能力使用受控替身，不能据此认定系统文件预览或真实 NAS 行为通过。 |
| 本机构建 | `devecocli build`，产品 `default`、模式 `debug`；[日志](work/ui-correction/build-final.log)。生成 [签名 HAP](entry/build/default/outputs/default/entry-default-signed.hap)，沿用本机签名配置，编译器仍有警告。 |
| 设备验收 | 最新包已在已连接模拟器更新安装并成功启动，应用数据保留；此前核对过登录应用图标、输入框内历史图标、无协议选择器、紧凑证书行、历史空态边距及简短 Toast。最新详情排版、文件图标、按压反馈、材质强度、列表滚动、搜索导航和 Preview Kit 的实际显示尚未验收。 |

## 实现范围

| 范围 | 当前行为 |
| --- | --- |
| 文件整理 | 新建、重命名、复制、移动和删除均在发送前保存操作意图。保存失败不发送；响应不明确时保留源、目标和时间，禁止自动重放。服务端任务标识保存失败时仍保留内存证据并冻结新增写入。 |
| 账号写入互斥 | File Station、Drive 文件操作及分享、手机上传、NAS 分享和下载控制共用账号写入准入。全部任务记录成功读取后才能写入；进行中、暂停或结果待确认的写入阻止其他写入。读取和下载不因其他写入被禁用，批量上传顺序启动。 |
| 连接安全 | 手动修改地址先清除跳过证书策略，只恢复同一规范化地址已确认的策略。明文连接和跳过证书校验在登录前确认当前地址风险，认证成功后保存策略。证书错误不建议降级为明文连接。 |
| 配置恢复 | 登录前可打开连接地址页并重试读取。只有确认解码损坏的配置可以隔离后重建；权限或输入输出错误不按空配置覆盖。 |
| 会话恢复 | 已保存会话先完成设备核验及受保护的 File Station 列表读取，再进入已登录状态和恢复任务。明确失效继续上抛并清除会话；网络故障保留重试。无该读取接口时要求重新登录。 |
| NAS 下载认证 | 下载页面可以独立验证 Download Station 会话及新的动态码，不替换主会话、不清除待确认写入、不自动重试原操作。密码和动态码在提交结束、离开页面或退出账号时清除。 |
| 照片入口和任务 | 照片备份统一要求 Photos 能力和 File Station 上传能力。照片任务入口默认筛选照片备份，可切换全部任务。新任务记录明确来源，历史记录不按文件后缀推断。 |
| 视图状态 | Drive 视图保留目录、搜索及分页上下文；照片视图保留空间、相册、分页及访问上下文。切换时丢弃旧请求的迟到结果，退出账号清除上下文。导航仅在账号切换等会话转换期间冻结。 |
| 本机空间 | 私有文件复制、Drive 剩余上传副本、前台下载、照片原文件及系统下载共享剩余字节预留，保留 32 MiB 余量。系统下载恢复时重新预留；空间不足不自动恢复。 |

继续使用现有模块、存储和原子快照，未增加独立协调子系统。未增加自动照片备份、任意字节下载续传、公共权限管理或新的设备类型。

## 数据格式与迁移

- 连接地址快照写入版本 2，读取兼容版本 1；风险策略增加确认时间。旧记录中的危险策略须重新确认。首次替换版本 1 前原子保存 `.v1.backup`，备份失败时停止替换。
- 文件整理快照写入版本 2，增加操作、源、目标和时间，服务端任务标识可以缺省。旧任务读取为历史操作；保留原快照备份。人工关闭表示已核对，不表示远端成功、撤销或回滚。
- 手机传输快照写入版本 2，来源区分文件上传、外部分享、照片备份、下载及历史任务。版本 1 按历史来源读取并保留备份；原有 NAS 地址和账号隔离保持不变。
- 未修改 NAS 外部端点或认证凭据存储方式；普通任务记录不增加密码、动态码、会话或分享凭据。

## 前一轮实现基线验证

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 核心 TypeScript 编译和全部单元测试 | 877 通过，0 失败、跳过或取消 | [测试日志](work/implementation/final-core-tests.log) |
| HarmonyOS debug 构建 | 通过；保留编译器警告，未配置签名 | [构建日志](work/implementation/final-debug-build.log) |
| HarmonyOS release 构建 | 通过；保留编译器警告，未配置签名及混淆 | [构建日志](work/implementation/final-release-build.log) |
| DevEco Linter | 未通过：893 错误、1 警告、0 建议 | [完整诊断](work/implementation/final-lint-report.json)、[扫描日志](work/implementation/final-lint.log) |
| 原生扫描覆盖 | Homecheck 实际扫描 94 个文件，其中 33 个文件有诊断 | 报告中的 `coverage`，原生日志 `C:\Users\huaru\.codelinter\arkPerfCheck.log` |
| 当轮设备连接 | 当时 `hdc list targets` 返回 `[Empty]` | 该记录不代表当前连接状态 |
| 真实 NAS | 未执行 | 套件版本、权限与真实写入结果未验收 |

测试执行实际协议代码与经 SDK 转译的 `.ets` 模型和适配器，平台文件系统、网络和系统任务使用受控替身。新增回归覆盖写入前保存失败、未知同步写入与人工关闭、跨模块及同模块恢复互斥、连接策略隔离、恢复前受保护读取、独立动态码认证、照片任务来源、视图迟到结果和分页恢复、空间并发预留、版本 1 配置备份与损坏配置隔离。上述证据不等同于系统 UI、真实后台传输或 NAS 互操作通过。

实际工具链：

- DevEco CLI：`1.3.0-stable`。
- DevEco Studio：`261.23567.138.36.2600851`，安装于 `D:\Program Files\DevEco Studio`。
- HarmonyOS SDK：API 26，`26.0.0.105 Release`，来自 `sdk/default/sdk-pkg.json`。
- Java：`D:\Program Files\jdk21`。构建使用 Studio 自带 Node 和 Hvigor JS 启动器。
- 产品：`default`；模块目标：`entry@default`；两种模式均使用 `--no-daemon`。

```powershell
./scripts/test-core.ps1 -SdkRoot 'D:\Program Files\DevEco Studio\sdk\default'

$env:JAVA_HOME = 'D:\Program Files\jdk21'
$env:DEVECO_SDK_HOME = 'D:\Program Files\DevEco Studio\sdk'
& 'D:\Program Files\DevEco Studio\tools\node\node.exe' `
  'D:\Program Files\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  assembleHap --mode module -p 'module=entry@default' -p 'product=default' -p 'buildMode=debug' --no-daemon
# release 使用相同命令，将 buildMode 改为 release。

./scripts/lint.ps1 -ReportPath 'work/implementation/final-lint-report.json' `
  -NativeLogPath 'C:\Users\huaru\.codelinter\arkPerfCheck.log'
```

## Linter 未通过的证据与边界

CLI 在报告有错误时仍可能返回退出码 0，`summary.filesChecked` 统计的是有诊断的文件集合。检查脚本验证完整报告，并从本次新增 Homecheck 日志确认扫描覆盖；本轮脚本按诊断结果返回失败。没有关闭规则、缩小正式扫描范围或把零诊断文件数当作零覆盖通过。

原生诊断包含 873 项不安全类型规则、18 项类型导入规则、2 项异步等待规则和 1 项日期实例复用警告。SDK 核心严格编译通过，但不能据此认定全部原生诊断均为误报。

同一份以下代码分别保存为临时 `.ts` 与 `.ets` 文件，使用相同项目配置和原生工具单独扫描：

```typescript
export class LintProbe {
  private values: Map<string, number> = new Map<string, number>();
  set(key: string, value: number): void { this.values.set(key, value); }
  get(key: string): number | undefined { return this.values.get(key); }
}
```

两个原生扫描均记录实际文件数 1。`.ts` 报告第 2 行 `no-unsafe-assignment`，`.ets` 报告零诊断，证明存在文件格式相关的诊断差异。复现源文件已移出正式扫描，结果保存在 [TS 报告](work/implementation/lint-probe-ts.json) 和 [ETS 报告](work/implementation/lint-probe-ets.json)。

另两项 `await-thenable` 分别位于 `DriveBrowserModel` 的会话失效回调和 `SdkBackgroundTransfer` 的停止后台运行调用；前者声明返回 `Promise<void>`，后者在 API 26 的 `@ohos.resourceschedule.backgroundTaskManager.d.ts` 中也声明返回 `Promise<void>`。保留等待，以维持账号清理和后台停止顺序。类型解析或分析器问题的根因仍待定位，Linter 验收保持未通过。

## 前一轮候选包

| 模式 | 产物 | 字节数 | SHA256 |
| --- | --- | ---: | --- |
| debug | [未签名 HAP](work/implementation/candidate/nas-workbench-debug-unsigned.hap) | 3996623 | `703FFC255A32EFD76052A1A354570BA85E2E8D2271FFD38E371EAE571D7E8391` |
| release | [未签名 HAP](work/implementation/candidate/nas-workbench-release-unsigned.hap) | 1782096 | `8890B90E1687B4113E16F676A38E6FD9E005E9F9EACAA17860DDA1E85C8456C3` |

候选包、完整日志和诊断位于已忽略的 `work/implementation/`，不随源码提交分发。安装包保留原包名 `com.dsage.nasworkspace`、版本 `1.0.0`、版本号 `1000000`、API 26 最低和目标版本及 `phone` 设备类型。未生成或提交签名凭据。

## 兼容性验收清单

| 场景 | 预期结果 | 当前证据 |
| --- | --- | --- |
| File Station 可用，Photos 不可用 | 文件上传可用，照片模块及照片备份入口不出现 | 能力与导航单元测试；真实 NAS 待验收 |
| Photos 可用，上传接口不可用 | 照片可浏览，备份入口不出现，直接提交备份被拒绝 | 能力与入口测试；真实 NAS 待验收 |
| Photos 与上传接口均可用 | 手动备份入队，来源为照片备份；NAS 索引决定图库是否显示 | 队列与来源测试；真实索引待验收 |
| 仅 Drive 或 Photos，无 File Station 列表 | 新登录可按实际能力使用；保存会话恢复要求重新登录 | 会话恢复测试；真实账号待验收 |
| Download Station 单独要求动态码 | 主会话继续有效，下载页可重新验证，原操作不自动重发 | 协议与模型测试；真实套件待验收 |
| 写入响应丢失、保存失败或进程中断 | 无新增重复写入，记录保留待核对；成功关闭前不放行其他写入 | 模型及持久化测试；设备强停和真实 NAS 待验收 |
| 多模块下载及复制接近剩余空间 | 共享预留限制并发占用，空间不足明确失败 | 空间与适配器测试；设备低空间待验收 |
| 字体放大、读屏、长错误和频繁切换 | 按钮可触达、认证字段可读、迟到结果不覆盖当前页 | 资源构建及模型测试；原生 UI 待验收 |

发布前必须完成：定位并解决原生 Linter 诊断；安装并验收最新候选包；在 API 26 手机和明确版本的 DSM、Drive、Photos、Download Station 上核对上述场景，记录实际版本、账号权限、测试目录和结果。真实写入只应在专用测试目录进行，证据不得包含凭据。
