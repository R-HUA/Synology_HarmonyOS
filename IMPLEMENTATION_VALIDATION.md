# NAS 工作台验证记录

验证日期：2026-10-09。分支：`feat/drive-photos-module-navigation`。基线：`f2b31f7ed8af3acfe50e8928199641fe6578e072`。

当前代码已通过核心编译、877 项单元测试及 debug、release 构建。DevEco Linter 未通过；设备、真实 NAS 与签名安装验收尚未完成。候选包仅用于内部评审，尚未达到发布条件。

## 实现范围

| 范围 | 当前行为 |
| --- | --- |
| 文件整理 | 新建、重命名、复制、移动和删除均在发送前保存操作意图。保存失败不发送；响应不明确时保留源、目标和时间，禁止自动重放。服务端任务标识保存失败时仍保留内存证据并冻结新增写入。 |
| 账号写入互斥 | File Station、Drive 文件操作及分享、手机上传、NAS 分享和下载控制共用账号写入准入。全部任务记录成功读取后才能写入；进行中、暂停或结果待确认的写入阻止其他写入。读取和下载不因其他写入被禁用，批量上传顺序启动。 |
| 连接安全 | 手动修改地址先清除跳过证书策略，只恢复同一规范化地址已确认的策略。明文连接和跳过证书校验在保存地址时确认风险。证书错误不建议降级为明文连接。 |
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

## 本机验证

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 核心 TypeScript 编译和全部单元测试 | 877 通过，0 失败、跳过或取消 | [测试日志](work/implementation/final-core-tests.log) |
| HarmonyOS debug 构建 | 通过；保留编译器警告，未配置签名 | [构建日志](work/implementation/final-debug-build.log) |
| HarmonyOS release 构建 | 通过；保留编译器警告，未配置签名及混淆 | [构建日志](work/implementation/final-release-build.log) |
| DevEco Linter | 未通过：893 错误、1 警告、0 建议 | [完整诊断](work/implementation/final-lint-report.json)、[扫描日志](work/implementation/final-lint.log) |
| 原生扫描覆盖 | Homecheck 实际扫描 94 个文件，其中 33 个文件有诊断 | 报告中的 `coverage`，原生日志 `C:\Users\huaru\.codelinter\arkPerfCheck.log` |
| 设备连接 | `hdc list targets` 返回 `[Empty]` | 真机及模拟器交互未验收 |
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

## 候选包

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

发布前必须完成：定位并解决原生 Linter 诊断；使用本机签名安装候选包；在 API 26 手机和明确版本的 DSM、Drive、Photos、Download Station 上核对上述场景，记录实际版本、账号权限、测试目录和结果。真实写入只应在专用测试目录进行，证据不得包含凭据。
