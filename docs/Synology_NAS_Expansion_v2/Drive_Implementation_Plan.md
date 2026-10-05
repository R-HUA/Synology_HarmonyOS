# Drive 接入实施方案

编写 2026-10-04，核验更新 2026-10-05。上游依据：`Drive_Access_Plan.md`（可行性，含三轮探测记录）与 `work/drive-probe/drive-api-map.json`（方法总表）。
本文回答"怎么接"，并区分协议证据、已实现代码、模拟验证和真机验收。当前核验与推进结果见 §11。

## 0. 一句话定位

走 **DSM 内部 `SYNO.SynologyDrive.*` WebAPI**（entry.cgi）接入 Drive 的**浏览 / 搜索 / 最近 / 星标 / 共享 / 回收站 / 上传下载 / 文件操作 / 分享链接**。
**不得对外宣称采用官方 Office Suite REST** —— 那条路线（v1/v2）规格仍未取得，继续单独申请；本方案的适配器边界必须留出将来整体切换到官方 REST 的余地。

## 1. 已验证的前提（限当前 NAS、套件版本与账号）

| 前提 | 结论 |
| --- | --- |
| 认证 | Cookie `id` + 头 `X-SYNO-TOKEN` 直通（仅 `_sid` 表参返 1002）→ **复用现有 `DsmRpcClient` 与 `FileStation` 会话**，`SessionRegistry` 不新增业务名 |
| 请求格式 | 普通 JSON RPC（`Files.list` 等）`jsonParameters=true` → 参数值 JSON 编码；**传输接口不是**：上传 multipart 的 `path`/`type`/`conflict_action`/`modified_time` 是原始标量，下载 GET 的 `force_download`/`is_preview`/`json_error` 也是原始值（见 §10） |
| 导航主键 | `path=id:<file_id>`；`/team-folders` 不存在（1000） |
| 分页 | 不传 `limit` 默认每页 10 → **必须显式传 `offset`/`limit`**（Web UI 用 1000，本应用用 200）；续页 offset 按实际返回数量递增 |
| 版本 | **按方法选**：`Files.list`→v2，`Files.get`/`list_backup_tasks`→v3 |
| 分享权限 | 普通账号**可以**列（`Share.list_active`）与建（`Sharing.create_link`）分享链接 |
| 团队文件夹 | 两步：`TeamFolders.list` 取 `file_id` → `list` 带 `path=id:<file_id>` |
| 异步 | `copy`/`delete` 返回 `async_task_id`（形如 `task-4`）→ `Tasks.get` 轮询 `{progress,status,result,task_id}` |

## 2. API 映射表（客户端能力 → 真实调用）

映射表同时列出已实现与后续目标，不代表所有方法已经验收。原始证据保留情况及返回结构的限制见 §11；接口发现只证明命名空间和版本范围，不证明具体方法、参数或条目结构。

| 客户端能力 | api | ver | method | 关键参数 | 返回 |
| --- | --- | --- | --- | --- | --- |
| 浏览目录 | `.Files` | **2** | `list` | `path`,`offset`,`limit`,`filter`,`sort_by`,`sort_direction` | `items[]`,`total` |
| 单条详情 | `.Files` | **3** | `get` | `path` | 条目对象 |
| 面包屑（祖先链） | `.Files` | 2 | `list_ancestor` | `path=id:<id>` | `items[]`,`total`；祖先包含范围、顺序待核对，当前 UI 用访问栈 |
| 搜索 | `.Files` | 2 | `search` | `keyword`；其余参数待重抓确认 | 方法总表记有 `items[]`,`total`,`search_time`，未找到保留的成功原始样本 |
| 最近 | `.Files` | 2 | `recent` | 分页 + `sort_by="atime"` | 实测可只有 `items[]`，`total` 可缺省 |
| 星标列表 | `.Files` | 2 | `list_starred` | 分页 | `items[]`,`total` |
| 设/取消星标 | `.Files` | 2 | `star` | `starred`(bool),`files=["id:…"]` | `{success}` |
| 共享给我 | `.Files` | 2 | `shared_with_me` | 分页 | `items[]`,`total` |
| 我共享出去的 | `.Files` | 2 | `shared_with_others` | 分页 | `items[]`,`total` |
| 回收站 | `.Trash` | 1 | `list` | `path`,分页 | `items[]`,`total` |
| 团队文件夹 | `.TeamFolders` | 1 | `list` | 分页、`sort_by`,`sort_direction` | `items[]`,`total`；条目无 `type`，按此端点解为文件夹 |
| 标签 | `.Labels` | 1 | `list` | `filter` | `items[]`,`total` |
| 改名 | `.Files` | 2 | `update` | `path=id:<id>`,`name` | 更新后的条目 |
| 移动 | `.Files` | 2 | `move` | `files`,`to_parent_folder`,`to_parent_folder_name`,`conflict_action`,`dry_run` | `{result}` |
| 复制 | `.Files` | 2 | `copy` | 同上（无 `dry_run`） | `{async_task_id}` |
| 删除 | `.Files` | 2 | `delete` | `files`,`permanent`,`revisions` | `{async_task_id}` |
| 上传 | `.Files` | 2 | `upload` | `path=id:<父目录id>/<文件名>`,`type=file`,`conflict_action`,`modified_time` + multipart `file` | `{tmp_newly_created,uploaded_size}` |
| 下载 | `.Files` | 2 | `download` | `files`,`force_download`,`is_preview`,`SynoToken` | **非 JSON，直接回内容** |
| 缩略图 | `.Files` | 2 | `get_thumbnail` | `path`,`size`,`version_id`,`SynoToken` | 二进制图片 |
| 分享链接列表 | `.Share` | 1 | `list_active` | — | `items[]`,`total` |
| 建分享链接 | `.Sharing` | 1 | `create_link` | `path=id:<id>` | `{url}` |
| 任务状态 | `.Tasks` | 1 | `get` | `task_id` | `{progress,status,result,task_id}` |
| 配额 | `.Info` | 2 | `quota` | — | `{share_list}` |
| 分享策略 | `.Settings` | 2 | `list` | — | `enable_normal_user_sharing` 等开关 |
| 通知 | `.Notifications` | 1 | `list` | `limit` | `items[]`,`total` |

⚠️ `rename` 不是方法名，**改名用 `update`**；`Share.list` 会返 105，**列表用 `list_active`**。

星标和两个共享列表的成功样本均为空，非空条目结构仍需验证。回收站当前使用已探测的 `path=/mydrive`，不推断其他空间的汇总范围；尚不打开回收站内的目录。

## 3. 领域模型（`core/domain/DriveProtocol.ts`）

下列资源引用、位置、分享和任务模型是目标契约。当前代码已实现 `DriveEntry`（平铺 `fileId`）、`DrivePage`、`DriveViewPage`、`DriveFolderRef` 和 `DriveView`；尚未实现跨 NAS/账号的持久化 `DriveResourceRef`，接入队列前必须补齐，不能拿当前列表条目充当可恢复资源。

```
DriveResourceRef { nasId, account, fileId, space, revision? }   // fileId 为主键；显示路径只用于 UI
DriveEntry       { ref, name, kind: file|folder, sizeBytes?, createdAt?, modifiedAt?,
                   pathText, displayPath, parentRef?, starred, shared, capabilities }  // 解码白名单 40 键
DrivePage<T>     { items: T[], total, offset }
DriveViewPage    { items: DriveEntry[], total?, offset, hasMore } // 最近可能无总数
DriveLocation    { kind: mydrive | teamFolder | recent | starred | sharedWithMe | sharedWithOthers | trash | search,
                   query?, folderRef? }
DriveShareLink   { url, ref }
DriveTaskRef     { taskId }
```

铁律：

- **不得**把 `fileId` 交给 File Station 的下载 URL；**不得**把 `/mydrive` 简单替换成 `/home`。
- 数字 ID 可能超出 JS 安全整数范围 → 解析入口保精度，不在 `JSON.parse` 舍入后 `String()` 补救。
- 解码一律按白名单取字段，无对应字段显示"未知"，不猜。
- 可选文本字段的空字符串按无值处理；必需的 `name` 仍拒绝空值。字段类型错误继续报协议失败。
- 按钮可见性（改名/删除/下载/分享）读条目的 `capabilities`，**不要**用账号角色推断。
- 能力字段缺失全部按 false，包括 `can_read`；不能把缺字段当成允许读取。

### `capabilities` → UI 映射（实测 11 个布尔）

| capability | 控制的 UI |
| --- | --- |
| `can_read` | 能否打开/进入该条目；为 false 时条目不可点 |
| `can_download` | 下载按钮 |
| `can_preview` | 预览 / 缩略图 |
| `can_write` | 可编辑（Office 文档） |
| `can_rename` | 改名 |
| `can_delete` | 删除 |
| `can_share` | 分享（生成链接） |
| `can_organize` | 整理类操作（移动/复制，**推断，未实测**） |
| `can_comment` | 评论 |
| `can_sync` | 同步到本地 |
| `can_encrypt` | 加密 |

条目其余嵌套结构：`owner` = `display_name`/`name`/`nickname`/`uid`；`revisions` 是数字；`adv_shared` 是布尔。`labels[]`/`shared_with[]` 的元素结构未知，目前不消费这些元素，也不据此做权限判断。

## 4. 与现有架构的接缝

| 现有件 | 处置 |
| --- | --- |
| `NasTransport.post` / `DsmRpcClient` | 普通 JSON RPC 通路**不动**：复用表单 POST + Cookie；multipart 与二进制响应走专用传输端口（已落地，见 §10），不塞进现有字符串/JSON 端口 |
| `SessionRegistry` | **不加**业务名，复用 `FileStation` 会话 |
| `ApiVersionPolicy` | 复用；Drive 的"已验证版本"按**方法**登记（见 §2） |
| `CapabilityRegistry` | 已登记 `driveBrowse` / `driveTeamFolders` / `driveRecent` / `driveStarred` / `driveSharedWithMe` / `driveSharedWithOthers` / `driveTrash`，各自绑定 api+版本；后续能力随真实调用方加入 |
| `core/network/DriveAdapter.ts` | 只调用内核协议层，不碰 UI；当前暴露 `available(view?)` / `list()` / `readView()`，返回领域模型；其余方法随阶段实现 |
| `TransferQueueState` | 记录增加 `provider: fileStation | drive` 与远端资源引用；Drive 下载 URL **不得**持久化为唯一恢复依据 |
| `features/workbench/` | 新增 `features/drive/`（ViewModel 与页面），复用 `WorkbenchUi.ets` 的共享组件与 `WorkbenchMetrics` |

### P2 专用传输边界（已落地，实现记录见 §10）

- `DriveKernelPort.requestDrive()` 继续只承载 JSON RPC。另设 `DriveTransferKernelPort`（`uploadDrive`/`downloadDrive`），由 `NasConnector` 实现；文件内容不得经 `{status,text}` 或 JSON 对象往返。
- 传输契约在 `core/network/NasTransferTransport.ts`（取消信号、进度、上传源、下载目标、二进制回执、上限与本地路径校验），执行实现在 `core/network/RcpTransferTransport.ets`；与普通 RPC **共用同一个 `rcp.Session`**，因此继承同一套连接级证书策略，且不跟随任何重定向。
- `DriveTransferAdapter` 负责 Drive 参数与资源引用，内核负责会话与实际传输；Drive 文件 ID 不转交 File Station 下载接口。
- Cookie 与令牌由内核从当前会话注入。§2 的 `SynoToken` 是抓包参数，不是业务方可自由传入的字段：`DsmRpcClient` 的保留认证字段校验不放宽；下载 GET 的 `SynoToken` 只由专用端口在临时请求上注入，禁止写入日志、持久化 URL 或交给页面。
- 取消为单次请求级，不影响同一连接上的并发请求；会话失效、连接切换与关闭都会中止进行中的传输；跨源重定向不得自动转发认证信息。

## 5. UI 落点

- **文件页顶部加来源切换**：File Station / Drive。Drive 不可用（套件未装或无权限）时保留原来源并说明原因。
- **Drive 左侧/顶部分组入口**：我的文件（`/mydrive`）、团队文件夹、最近、星标、共享给我、我共享出去的、回收站、搜索。
- **面包屑**当前使用访问栈，目录按 `id:<file_id>` 进入，点击可回跳；`list_ancestor` 的顺序与边界验证后再提供规范祖先链。
- **条目操作菜单**按 `capabilities` 决定显示：打开/下载/分享/改名/移动/复制/删除/星标。
- **移动/复制**用选择目标目录的完整页面；`move` 可先用 `dry_run=true` 预检冲突再提交。
- **分享弹层**：`create_link` 后展示 `url` 并可复制；列表页用 `list_active`。入口是否显示读 `Settings.list` 的开关。
- **传输**：写操作返回 `async_task_id` 时进统一任务页，用 `Tasks.get` 轮询。
- 沿用既有约定：空/错/受限状态都要有明确文案；长解释压一句 12 号 `font_tertiary`。

## 6. 分阶段

| 阶段 | 内容 | 依赖 | 验收 |
| --- | --- | --- | --- |
| **P0** 骨架 | `DriveProtocol.ts`、`DriveAdapter.ts`、能力注册、来源切换、只读浏览 `/mydrive` | 无 | 本轮真机列出我的文件、目录进退、面包屑回跳、来源切换通过；错误路径与会话代际有模拟测试。见 §11 |
| **P1** 视图入口 | 最近 / 星标 / 共享给我 / 我共享出去的 / 回收站 / 团队文件夹 / 标签 / 搜索 / 面包屑 | P0 | **部分完成**：六个新增只读入口已实现并真机打开；标签、搜索、规范祖先链未实现；非空共享/星标和超过 200 项的真机跨页仍待验收 |
| **P2** 上传下载 | `upload`（multipart，冲突 `version`/`autorename`）、`download`（二进制流）、缩略图 | P0 | **前台传输边界已落地**（协议 + 内核 + 传输层测试全绿，见 §10）；**真机往返验收未做**：需在用户指定测试目录完成一次上传与下载回读校验，同名冲突按 UI 选择生效。缩略图与 UI 未做 |
| **P3** 文件操作 | 改名（`update`）、移动（`move` + `dry_run` 预检）、复制、删除；`Tasks.get` 轮询 | P2 | 每个操作的成功/失败/任务进度都有 UI 反馈；结果未知时保留待确认状态，由用户核对，不自动重放或猜测回滚 |
| **P4** 分享 | `create_link` / `list_active`，入口按 `Settings.list` 控制 | P1 | 普通账号能建链接并在列表看到；无权限时给出明确原因 |
| **P5** 可选 | 配额（`Info.quota`）、通知、客户端备份任务（`list_backup_tasks`） | P1 | — |

后台传输注意：平台限制 —— `request.agent` 无证书开关，**https + 忽略证书时只有前台 rcp 可用**，后台上传/下载必失败。P2 的 UI 必须如实提示，不能标称"后台继续传输"。

## 7. 待补测（方案已就位，这些是并行补齐项）

按优先级：

1. **P1 剩余契约与验收**：重抓成功搜索请求、祖先链顺序和范围，取得 `labels[]` / `shared_with[]` 元素、非空星标/共享样本；用超过 200 项的真实目录验证前后翻页。未知元素不阻塞目录浏览，但阻塞依赖其结构的功能。
2. **上传/下载往返（仍待真机）**：上传 `conflict_action` 两个取值（`version`/`autorename`）的实际行为、服务端是否对下载返回重定向（客户端一律不跟随）、是否支持 Range —— 都要在真实 NAS 上验证。
3. **错误语义**：权限被剥夺、ID 被移动或删除、分页期间内容变化时各返回什么错误码 —— 决定错误文案与重试策略。
4. `AdvanceSharing.get` 两轮共 4 次全失败，原因未明（进阶分享权限，暂不纳入）。
5. `Tasks` 的 `status` 取值枚举。
6. `capabilities.can_organize` 是否真的对应移动/复制（当前是推断）。

已补齐（第三轮探测）：`capabilities` 11 键、`owner` 4 键、`image_metadata`/`app_properties` 键名、`offset`/`limit` 分页生效已验证。

## 8. 风险

- **无合同保障**：内部 API 不承诺兼容。Drive 语义收敛在协议和适配器两层（含 `DriveTransferProtocol` / `DriveTransferAdapter`），便于切到官方 REST 或适配版本漂移。
- **版本漂移**：`Files` 已通告到 v10，当前只用 v2/v3。升级前先跑探测脚本回归。
- **权限模型差异**：Drive ACL ≠ File Station 权限，不得合并成一个"可编辑"布尔值。
- **大文件**：断点续传**不做**（协议未完全确认），UI 不标称分片续传。下载失败可重新发起完整下载；上传结果未确认须先人工核对远端，不自动重发。

## 9. P0 落地记录（2026-10-04）

分支 `feat/drive-p0-foundation`。

本节保留 2026-10-04 的实现记录；本轮修正及真机验收已覆盖部分历史未做项，当前状态以 §11 为准。

### 已实现

| 件 | 位置 | 说明 |
| --- | --- | --- |
| 领域与协议 | `core/domain/DriveProtocol.ts` | 模型、参数编码、条目解码、分页校验、错误码解释、保精度解析 |
| 适配器 | `core/network/DriveAdapter.ts` | `DriveKernelPort` 窄端口 + `available()` / `list()` |
| 内核接缝 | `core/network/NasConnector.ts` | 发现查询加入 `SYNO.SynologyDrive.Files`；实现 `DriveKernelPort`；`call` 拆出可换解码器的 `callWith` |
| 能力注册 | `CapabilityRegistry` | 新增 `driveBrowse`（Files v2） |
| 浏览状态 | `features/drive/DriveBrowserModel.ets` | 目录栈、面包屑、分页、错误与提示，与 File Station 完全独立 |
| 界面 | `pages/Index.ets` | 文件页顶部来源切换（`WorkbenchChoice`）+ Drive 只读列表；新增 `features/workbench/WorkbenchUi.ets` 的 `WorkbenchEntryRow` |
| 测试 | `tests/unit/drive-protocol.test.cjs` | 17 项：参数编码对齐抓包原文、保精度、解码白名单、分页契约、错误码、适配器行为 |

### 与本文原计划的偏差（都是有意的）

1. **适配器只暴露 `list()`（+`available()`）**。§2 的其余方法分别在 P1–P4 落地 —— 先把没有调用方的方法写出来只会留下无法验证的空壳。
2. **每页 200 条，不是 Web UI 的 1000**。手机端单页渲染与常驻内存更可控，且让 `offset`/`limit` 分页在真实数据量下就能被验证，而不是永远只请求第一页。
3. **能力注册只加 `driveBrowse`**。仅注册 P0 真正会读取的 feature；注册一批永远停在"未验证"的行会让能力面板自说自话。
4. **`file_id` 保精度做在解析入口**：Drive 目前把 ID 作为**字符串**返回（实测 18 位；若为 number 早已超出安全整数范围）。预处理扫描字符串 token，只给已知 ID 字段的合法长整数补引号，不改写正文，不将前导零等非法 JSON 修成合法 ID。
5. **`relabelDriveFailure` 只看错误码、不限定错误类别**：实测 105 落到 `Permission`、120 落到 `Server`，但真实含义都是 Drive 特有的，不能按类别放行。

### 未做（如实标注）

- 截至 2026-10-04 **界面未经真机验证**；2026-10-05 已补本轮验证，范围与缺口见 §11。
- 文件条目当前只有"提示暂不支持"的点击反馈（预览/下载属 P2）；目录条目可进入、面包屑可回跳。
- `labels[]` / `shared_with[]` 元素结构仍未知（该账号恒为空数组）。
- 团队文件夹、最近、星标、共享、回收站、搜索均为 P1。

## 10. P2 传输边界落地记录（2026-10-05）

分支 `feat/drive-p0-foundation`（未提交）。该边界实现时只做**可执行的前台传输边界**：不含上传下载 UI、未接后台队列、未对真实 NAS 发起任何写入。随后补充的 P1 只读页面见 §11。

### 已实现

| 件 | 位置 | 说明 |
| --- | --- | --- |
| 传输契约 | `core/network/NasTransferTransport.ts` | 纯 TS：单次请求级取消信号、进度、上传源、下载目标、二进制回执、`validate` 回调、响应/前缀上限与本地路径校验 |
| Drive 传输协议 | `core/domain/DriveTransferProtocol.ts` | multipart 标量与下载 GET 参数编码、`uploaded_size` 确认、二进制响应校验 |
| 内核端口 | `core/network/NasConnector.ts` | 实现 `DriveTransferKernelPort`；从当前 `FileStation` 会话与已发现 API 构造受控请求；代际绑定、会话失效、取消传播 |
| RCP 实现 | `core/network/RcpTransferTransport.ets` | 原生 multipart（文件按本地路径交给 RCP，不整文件入内存）、流式落盘、独占临时目录、失败即清理 |
| 适配入口 | `core/network/DriveTransferAdapter.ts` | `upload`/`download`；按条目类型与 `capabilities` 拒绝不可用操作 |
| 接线 | `core/network/RcpNasTransport.ets` | 以 `NasTransport.transfers` 暴露传输能力，共用同一 `rcp.Session` |
| 测试 | `tests/unit/drive-transfer-protocol.test.cjs`、`drive-transfer-kernel.test.cjs`、`rcp-transfer.test.cjs` | 27 项（协议 8 / 内核 9 / RCP 10）；另同步更新 `photos-media`、`photos-state`、`telemetry-connector` 三个既有测试的依赖 mock（新增模块依赖） |

### 原始抓包修正的两处方案假设

1. **上传 multipart 用原始标量**：`path`/`type`/`conflict_action`/`modified_time` 不带 JSON 引号 —— §1 的"参数值必须 JSON 编码"只适用于普通 JSON RPC。上传成功有两种形状（仅 `tmp_newly_created` + `uploaded_size`，或完整条目 + `uploaded_size`），因此只认 `uploaded_size`，不要求每次都回条目。
2. **下载是 GET 且携带 `SynoToken`**，不是普通 POST：`files`/`download_type`/`c2_offload` 带 JSON 引号，`force_download`/`is_preview`/`json_error` 是原始标量。

### 安全与失败语义（均有测试覆盖）

- 认证材料（Cookie `id`、`X-SYNO-TOKEN`、查询里的 `SynoToken`）只存在于临时请求；不写日志、不持久化、不进用户可见文案，也不随返回结果交给调用方。
- **不跟随任何重定向**（含同源）；3xx 显式失败，认证信息不会转发到其他地址。
- 上传进度只是传输进度，不等于服务端确认；响应超限或丢失一律报"结果未能确认"，**不自动重试**可能已落盘的写操作。
- 下载只写入本次独占创建的私有临时目录；失败、取消或代际切换都会删除本次拥有的文件，已存在的路径一律不覆盖、不删除。内核在最终代际检查失败时用下载收据丢弃刚拿到的结果。
- 本地磁盘错误（写入、flush、关闭、落盘大小校验）按协议失败上报，不会被说成网络问题。

### 未做（如实标注）

- **真机往返未验证**：没有对真实 NAS 发起过上传或下载；`conflict_action` 两种取值的实际行为、服务端是否重定向、Range 支持情况均未测。真机写入须在用户指定的测试目录进行。
- **无 UI、无后台队列**：没有页面调用这两个端口；`TransferQueueState` 的 `provider: drive` 与队列持久化（§4 原计划）未改。后台 `request.agent` 无证书开关的限制不变，UI 不得标称"后台继续传输"。
- **缩略图未做**：未取得 `get_thumbnail` 的 `size`/`version_id` 枚举证据前不实现。
- 边界实现时的历史记录止于静态与模拟层面：`devecocli build` 通过（0 error；48 个 warning 中未出现当时新增的传输与协议文件），`scripts/test-core.ps1` 629/629 通过。当前独立复核以 §11 为准。

## 11. 计划核验、代码修正与 P1 推进（2026-10-05）

### 计划核验结论

内部 WebAPI、FileStation 会话复用、方法级版本、ID 保精度和前台二进制传输边界的方向成立；统一分页返回、团队条目类型、可选文本、分页步长及全部阶段已经验收的假设不成立。

| 证据 | 可证明的范围 | 限制 |
| --- | --- | --- |
| `work/drive-probe/drive-api-map.json` | 三轮探测汇总与方法线索 | 派生资料；不能替代各方法的保留原始成功样本 |
| `captures/mitm-2026-10-04T08-37-15-099Z.jsonl` 与摘要 | 当前保留的 Web UI 抓包 | 较早轮次原始抓包已不在目录中，不将汇总结论冒充本轮重测 |
| `diagnostics/latest-drive-probe.json` | 认证方式、版本、字段键及分页探测 | `recent` 只有 `items`；TeamFolders 条目无 `type`；共享/星标成功为空；未含成功搜索样本 |
| 本轮 Chrome 已登录 Drive 页面 | 当前账号各视图的内容数量 | 页面核对，不等同于请求/响应抓包；浏览后恢复我的文件入口 |
| 本轮 HAP 真机 `uitest dumpLayout` 与截图 | 实际应用接线、导航、空态与数量显示 | 受当前数据及设备形态限制，不能外推权限变更、所有宽度和传输写入 |

### 代码核验及修正

- `recent` 改用允许未知总数的 `DriveViewPage`；不以当前页长度伪造总数。满页再请求到空页时保留最后一页并提示末尾。
- `TeamFolders.list` 独立解码为文件夹；具体目录只请求 `Files.list(path=id:<file_id>)`，不拼虚拟根。
- 缺失能力全部 false。可选文本的空字符串允许缺省，必需名称及类型校验保留。真机曾因空文本无法列个人根，修正后恢复 4 个目录。
- 协议失败提示改为刷新及 DSM 网页核对，不把未识别数据一概归因为套件需升级。
- 续页按实际返回数量计算 offset，上一页保存已访问的 offset；不要求 offset 是 200 的倍数，防止短页跳过数据。
- 保精度预处理按完整字符串 token 扫描，不改正文或非法 JSON；原始数字 ID 先保精度再解析。
- `reset`/`detach` 使旧响应失效并清除可用性。视图、目录栈和数据只在同一代际的成功响应后一起提交；失败保留原位置与内容。
- 面包屑的节点键包含视图和名称；真机发现的切入口后根标签残留已修复。回收站目录保持不可进入，不将已删除条目当成普通目录访问。

P1 已接入七个入口（含原我的文件）、按命名空间发现和方法版本分别登记能力；复用 `WorkbenchChoice`、现有列表与水平 Scroll。Scroll 采用单个 Row 子节点，符合 [华为 Scroll 文档](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/ts-container-scroll) 的单子节点约束；本机 API 26 SDK、ArkTS 构建及真机水平滑动均已核对。

### 当前验证结果

| 验证 | 实际结果 | 证据 |
| --- | --- | --- |
| 修改前核心基线 | 629/629 通过 | `work/drive-audit-baseline-tests.log` |
| 修正后核心测试 | **641/641 通过，0 skipped** | `work/drive-audit-tests.log`；含真实模型的短页、返回、失败、会话代际和未知总数行为测试 |
| API 26 签名构建 | **`hvigorw assembleHap --no-daemon` 成功**，30.044 秒；已安装最新签名 HAP并复核个人根、团队目录进退 | `work/drive-audit-build.log` |
| 代码检查 | **未通过：706 个 Error，0 Warning，检查 26 文件**；工具进程退出码为 0 不能当作通过 | `work/drive-audit-lint.json`、`.log`；含本任务文件，未证明全部属于历史问题，未关闭规则 |
| 差异检查 | `git diff --check` 通过 | 不含提交/推送；保留已有未提交传输等改动 |

SDK：`C:/Users/rhua0016/.VirtualDisk/Programs/command-line-tools/sdk/default`。本轮 `devecocli build` 出现 daemon 等待后终止，后续只采用无 daemon 的 hvigor 构建；历史 629 项及旧构建不作为当前工作区的验收凭据。

### 真机与 NAS 只读验收

设备无线调试 `192.168.50.188:42347`，应用 `com.dsage.nasworkspace`；使用设备现有登录和 Chrome 已登录会话，本轮不采集凭证，不发起 NAS 写操作。

| 场景 | 结果 | 布局证据（`work/` 下） |
| --- | --- | --- |
| 我的文件 | 4 个目录，与 Chrome 一致；上下页均禁用 | `drive-audit-final-mydrive-layout.json` |
| 团队文件夹 | Archive、music 共 2 项；入口与面包屑均为团队文件夹 | `drive-audit-final-teams-layout.json`、`.jpeg` |
| 团队目录进退 | Archive 5 项、music 9 项；返回键回到团队入口 | `drive-audit-final-build-archive-layout.json`、`music-scrolled`、`final-build-teams-back` |
| 最近 | 正常空态，不伪造总数；根标签为最近；非空及分页仍待实测 | `drive-audit-final-recent-layout.json` |
| 星标、共享给我、我共享出去的 | 三个入口均成功空态，根标签正确；非空结构仍未验收 | `drive-audit-final-starred-layout.json`、`final-shared-with-me`、`final-shared-with-others` |
| 回收站 | 187 项，与 Chrome 一致；滚至末尾显示 `1–187 / 187 项`，下一页禁用 | `drive-audit-trash-scroll-eighteen-layout.json` |
| 个人目录、面包屑 | 多层 Photos/PhotoLibrary 目录可进入；点击根回到 4 项 | `drive-audit-photos-month-layout.json`、`breadcrumb-root-return` |
| 来源切换 | File Station 原 5 个共享位置可返回；再回 Drive 保留个人根 4 项 | `drive-audit-station-return-layout.json`、`delivery-mydrive` |

我的文件与团队入口截图已目视核对，无控件重叠；回收站等长列表已检查末页计数。当前检查到的数据不足以完成超过 200 项的应用跨页验收；既有探测的小 limit/offset 与本轮模拟分页测试不能替代该项。长路径可水平滚动，但全套宽度、横屏及生命周期验收尚未覆盖。

### 后续工作顺序

1. 保留成功搜索、非空最近/星标/共享、标签元素和祖先链的原始脱敏响应，补协议与页面，再完成超过 200 项的真机前后页、权限变化及返回验收。P1 仍为部分完成。
2. 处理本轮代码检查报告，区分明确代码问题与类型解析问题；保留有效规则，取得实际通过的报告。
3. P2 在指定测试目录完成一次小文件上传、下载回读与内容校验，验证两个冲突选项和结果未知状态；随后接入 UI。前台边界的 27 项模拟测试通过不代表真机传输通过。
4. 持久化队列前增加 NAS/账号归属的资源引用；未确认的上传、文件操作和分享写入不得自动重放。缩略图、后台队列、P3/P4 操作继续以真实契约及独立验收推进。

交付文件仍在当前工作区；`docs/` 与 `work/` 受现有 `.gitignore` 忽略。本轮未变更忽略规则、未提交或推送，后续提交需明确纳入所需方案文档。
