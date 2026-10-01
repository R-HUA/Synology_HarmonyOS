# NAS 工作台

HarmonyOS 原生 NAS 客户端，手机直接通过 HTTPS 连接群晖 DSM。

使用 API 26 Stage 工程和 ArkUI V2，实现 HTTPS 能力发现、Auth 6 登录与动态码输入、File Station 2 共享目录浏览和分页、安全会话保存与恢复、系统代理上传下载校验，以及 Synology Photos 个人照片与“与我共享”相册的只读分页浏览。当前尚未提供通用传输队列、照片预览或自动备份。

## 本地开发

开发工具链：DevEco CLI `1.3.0-stable`，HarmonyOS SDK `26.0.0.105 Release`；最低支持版本和目标版本均为 `26.0.0`。含本机签名配置的 `build-profile.json5` 不纳入版本管理，新环境从无签名模板复制后配置自己的签名。

```powershell
Copy-Item build-profile.template.json5 build-profile.json5 # 仅新环境初始化
devecocli build
./scripts/test-core.ps1
```

配置签名后构建产物为 `entry/build/default/outputs/default/entry-default-signed.hap`，未配置签名时为 `entry-default-unsigned.hap`。测试脚本复用本机 SDK 的 TypeScript 编译器，再使用 Node 内置测试运行器；没有额外 npm 依赖。SDK 安装在其它位置时传入 `-SdkRoot`。

```powershell
# 只读、无凭证的 HTTPS/API 发现
./scripts/probe-nas.ps1 -Address https://nas.example.com:5001

# 本机弹窗输入凭证：登录 → 读取共享目录首批 → 登出
./scripts/probe-nas.ps1 -Address https://nas.example.com:5001 -Login

# 已启用 OTP 时，额外在本机输入动态码
./scripts/probe-nas.ps1 -Address https://nas.example.com:5001 -Login -WithOtp
```

诊断脚本不执行上传、覆盖或删除。结果位于已忽略的 `work/diagnostics/latest-probe.json`，只保存能力表、检查状态、文件数量和错误类别/数值；不保存账号、密码、SID、SynoToken 或文件名。账号需具备 File Station 权限。

应用中填写最终 HTTPS origin（允许自定义端口），先连接再输入账号密码。应用保留系统 TLS 校验并拒绝自动跳转；密码仅暂存内存以完成 OTP，成功登录或断开后清除。经文件读取验证的会话保存到 Asset Store 加密 Secret，包括 NAS 地址、账号、SID 与 SynoToken，不保存密码、不跨设备同步。再次启动先验证保存的会话；网络故障保留会话供重试，明确失效时清除并要求重新登录，主动登出清除本地保存并尝试服务器登出。认证请求通过内存 Cookie `id` 和 `X-SYNO-TOKEN` 请求头发送，不把会话凭证放入 URL 或业务表单。文件列表每次只显示最多 100 项，以真实逻辑路径访问目录。

可在允许写入的目录选择“验证上传下载”。确认后新增随机命名的 88 字节或 64 MB 文本，使用系统 `request.agent` 上传并读取 DSM 业务响应，再查询目标大小、下载并分块逐字节比对；不覆盖、不创建父目录、不删除 NAS 文件。任务 ID 在启动前保存到应用私有记录，按 NAS 与账号隔离，不在普通记录中保存认证信息。重启后自动接回仍在运行或已完成但尚未校验的原任务；运行中的上传只重新挂接监听，不重新发送文件。系统未保留上传响应正文时，须通过唯一随机文件的目标大小和完整下载内容核对才能确认结果。“重新检查”复核原任务及已下载内容，不检测远端文件后续同大小修改。失败时可“取消检查”清理本机任务和记录，NAS 文件保留。系统任务恢复不等于 File Station 支持任意字节续传。

Photos 每页读取最多 20 项，分享访问凭证仅保存在当前账号的内存中并随认证 POST 发送，不进入 URL 或普通存储。此适配使用套件内部接口，版本变更或套件拒绝会话时明确报告错误，并先核对文件会话，避免误报整个 NAS 登录失效。“选择照片”通过系统选择器读取一张用户指定的图片，验证临时复制后清理副本，不上传 NAS，也不申请整个媒体库的读取权限。

## 代码位置

- `entry/src/main/ets/core/domain/DsmProtocol.ts`：边界校验、响应解析与错误分类。
- `entry/src/main/ets/core/network/`：会话、API 版本选择与 rcp 原生传输。
- `entry/src/main/ets/features/connection/`：V2 ViewModel、加密会话保存、媒体选择与系统代理验证。
- `entry/src/main/ets/pages/Index.ets`：连接、文件浏览及上传下载验证入口。
- `tests/`：脱敏能力样本与协议/会话测试。
