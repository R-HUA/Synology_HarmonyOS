# Drive 接入实施方案

编写 2026-10-04，核验更新 2026-10-06。上游依据：`Drive_Access_Plan.md`（可行性，含三轮探测记录）与 `work/drive-probe/drive-api-map.json`（方法总表）。
本文回答"怎么接"，并区分协议证据、已实现代码、模拟验证和真机验收。本轮分享、通知、原图、后台传输与上传续传见 §19，Review 修复与忽略证书后台传输及最新验证见 §20；此前真机范围见 §11、§13。

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
| 面包屑（祖先链） | `.Files` | 2 | `list_ancestor` | `path=id:<id>` | `items[]`,`total`；个人目录实测为根到父级、不含当前目录，个人根名称为空；独立解码，团队边界待实测 |
| 搜索 | `.Files` | 2 | `search` | `keyword`、`location="mydrive"/"custom"`、`custom_location="id:<id>"`、`sort_by="score"`、`sort_direction="asc"`、两个正文开关为 false、分页与 filter | 成功非空脱敏样本已保留：`items[]`,`total`,`search_time`；应用每页 200 项，网页样本为 25 项 |
| 最近 | `.Files` | 2 | `recent` | 分页 + `sort_by="atime"` | 实测可只有 `items[]`，`total` 可缺省 |
| 星标列表 | `.Files` | 2 | `list_starred` | 分页 | `items[]`,`total` |
| 设/取消星标 | `.Files` | 2 | `star` | `starred`(bool),`files=["id:…"]` | `{success}` |
| 共享给我 | `.Files` | 2 | `shared_with_me` | 分页 | `items[]`,`total` |
| 我共享出去的 | `.Files` | 2 | `shared_with_others` | 分页 | `items[]`,`total` |
| 回收站 | `.Trash` | 1 | `list` | `path`,分页 | `items[]`,`total` |
| 团队文件夹 | `.TeamFolders` | 1 | `list` | 分页、`sort_by`,`sort_direction` | `items[]`,`total`；条目无 `type`，按此端点解为文件夹 |
| 标签 | `.Labels` | 1 | `list` | `filter` | `items[]`,`total` |
| 改名 | `.Files` | 2 | `update` | `path=id:<id>`,`name` | 更新后的条目 |
| 移动 | `.Files` | 2 | `move` | `files`,`to_parent_folder`,`to_parent_folder_name`,`conflict_action`,`dry_run` | 预检 `{result}`，提交 `{async_task_id}` |
| 复制 | `.Files` | 2 | `copy` | 同上；目标网页代码同样使用 `dry_run` | 预检 `{result}`，提交 `{async_task_id}` |
| 删除 | `.Files` | 2 | `delete` | `files`,`permanent`,`revisions` | `{async_task_id}` |
| 上传 | `.Files` | 2 | `upload` | `path=id:<父目录id>/<文件名>`,`type=file`,`conflict_action`,`modified_time` + multipart `file` | `{tmp_newly_created,uploaded_size}` |
| 下载 | `.Files` | 2 | `download` | `files`,`force_download`,`is_preview`,`SynoToken` | **非 JSON，直接回内容** |
| 缩略图 | `.Files` | 2 | `get_thumbnail` | `path=id:<fileId>`、`size=small`、可选 `version_id`；业务参数 JSON 编码，内核注入 `SynoToken` | 有界图片；请求格式取自目标 NAS 网页代码，真实图片响应待人工验收 |
| 分享链接列表 | `.Share` | 1 | `list_active` | — | `items[]`,`total` |
| 建分享链接 | `.Sharing` | 1 | `create_link` | `path=id:<id>` | `{url}` |
| 任务状态 | `.Tasks` | 1 | `get` | `task_id` | `{progress,status,result,task_id}` |
| 配额 | `.Info` | 2 | `quota` | — | `{share_list}` |
| 分享策略 | `.Settings` | 2 | `list` | — | `enable_normal_user_sharing` 等开关 |
| 通知 | `.Notifications` | 1 | `list` | `limit` | `items[]`,`total` |

⚠️ `rename` 不是方法名，**改名用 `update`**；`Share.list` 会返 105，**列表用 `list_active`**。

星标和两个共享列表的成功样本均为空，非空条目结构仍需验证。回收站当前使用已探测的 `path=/mydrive`，不推断其他空间的汇总范围；尚不打开回收站内的目录。

## 3. 领域模型（`core/domain/DriveProtocol.ts`）

下列位置、分享和任务模型是目标契约。当前代码已实现 `DriveEntry`（平铺 `fileId`）、`DrivePage`、`DriveViewPage`、`DriveFolderRef` 和 `DriveView`。P2 的 `DriveTransferState.ts` 已增加持久化 `DriveResourceRef { nasOrigin, account, fileId }`，归属与现有任务一致，按规范化地址和账号隔离；不同连接地址不会自动合并。空间和修订版本尚不持久化，不据此提供断点续传或修订恢复。

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
| `can_share` | 共享权限管理和保护链接；普通文件链接只要求读权限，见 §19 |
| `can_organize` | 不用于移动/复制。目标网页规则为复制读权限、移动读及删除权限；服务端最终校验，见 §16 |
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
- **面包屑**普通目录使用访问栈；从搜索、最近、星标及共享的根列表进入目录时，先读取并校验根到父级的祖先链，再按 `id:<file_id>` 读取目标目录。成功后一起更新内容与导航；失败保留原位置。空名称的根显示为“根目录”，不推断其空间归属。
- **搜索**使用原生 Search。入口页搜索“我的文件”，具体目录搜索当前目录；结果显示已接受的关键词和范围，翻页与返回结果保留条件及页码，“结束搜索”及结果根的系统返回键回到搜索前的位置。
- **条目操作菜单**按 `capabilities` 决定显示：打开/下载/分享/改名/移动/复制/删除/星标。
- **移动/复制**用选择目标目录的完整页面；`move` 可先用 `dry_run=true` 预检冲突再提交。
- **文件链接**：确认获取 `create_link` 返回的普通文件链接，展示、复制并保存本机历史。链接保留 NAS 原权限；服务端活动链接列表和保护链接策略仍待契约，不把 `list_active` 条目猜成 URL。
- **传输**：写操作返回 `async_task_id` 时进统一任务页，用 `Tasks.get` 轮询。
- 沿用既有约定：空/错/受限状态都要有明确文案；长解释压一句 12 号 `font_tertiary`。

## 6. 分阶段

| 阶段 | 内容 | 依赖 | 验收 |
| --- | --- | --- | --- |
| **P0** 骨架 | `DriveProtocol.ts`、`DriveAdapter.ts`、能力注册、来源切换、只读浏览 `/mydrive` | 无 | 本轮真机列出我的文件、目录进退、面包屑回跳、来源切换通过；错误路径与会话代际有模拟测试。见 §11 |
| **P1** 视图入口 | 最近 / 星标 / 共享给我 / 我共享出去的 / 回收站 / 团队文件夹 / 标签 / 搜索 / 面包屑 | P0 | **部分完成**：用户已报告上一签名包的搜索与导航人工验证完成，见 §14；标签未实现；缺适用数据的非空视图、团队祖先链和大列表不据一句汇总反馈外推通过 |
| **P2** 上传下载与图片 | 前台/后台上传下载、缩略图、原图预览、保存新版本上传的续传 | P0 | **代码已接入，整体验收待完成**，最新结果见 §20。忽略证书的 HTTPS 改用应用自管的 RCP 长时任务，进程终止会中断；未知上传不自动重发 |
| **P3** 文件操作 | 改名、移动、复制、删除及异步任务状态 | P2 | **代码已接入，整体验收待完成**，见 §16、§18–19。未知结果保留记录，不重放或猜测回滚 |
| **P4** 文件链接 | 普通文件链接获取、展示、复制、本机历史 | P1 | **本轮已接入，待 NAS 验收**。服务端活动链接列表、保护链接及共享权限编辑未实现 |
| **P5** 其他能力 | Drive 通知、配额、客户端备份任务 | P1 | **通知列表本轮已接入，待非空 NAS 样本验收**；配额与客户端备份任务未实现 |

后台传输注意：平台限制 —— `request.agent` 的代理 Config 没有跳过证书校验的选项，**https + 忽略证书时不能用系统托管后台传输**，改用应用自管的 RCP + `dataTransfer` 长时任务（见 §20），进程终止后传输会中断。P2 的 UI 必须如实提示，不能标称"后台继续传输"。

## 7. 待补测（方案已就位，这些是并行补齐项）

按优先级：

1. **P1 剩余契约与验收**：个人根和具体目录的成功搜索、个人祖先链契约已补齐；继续取得非空标签、星标/共享/最近以及团队祖先链样本，完成当前 HAP 的输入、返回、来源切换和超过 200 项的真机翻页。未知元素不阻塞目录浏览，但阻塞依赖其结构的功能。
2. **上传/下载往返（仍待真机）**：上传 `conflict_action` 两个取值（`version`/`autorename`）的实际行为、服务端是否对下载返回重定向（客户端一律不跟随）、是否支持 Range —— 都要在真实 NAS 上验证。
   **缩略图（仍待真机）**：`small` 请求格式已有目标 NAS 网页代码证据，仍需核对 JPEG/PNG/GIF、视频缩略图、修订后的图片、权限变化及列表可见区域触发行为。未提供断点续传，不依赖 Range。
3. **错误语义**：权限被剥夺、ID 被移动或删除、分页期间内容变化时各返回什么错误码 —— 决定错误文案与重试策略。
4. `AdvanceSharing.get` 两轮共 4 次全失败，原因未明（进阶分享权限，暂不纳入）。
5. `Tasks` 的 `status` 取值枚举。
6. 移动/复制使用目标网页已核对的读/删除权限规则；实际账号权限变更、目标权限和服务端拒绝行为留待验收，不使用 `can_organize` 推断。

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
- **当时缩略图未做**：本轮边界实现没有足够参数证据；后续已从目标 NAS 网页代码核对并实现，见 §15。
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
| 代码检查 | **未通过：706 个 Error，0 Warning，26 个文件含诊断**；该报告的 `filesChecked` 不能证明实际扫描数量，工具进程退出码为 0 不能当作通过 | `work/drive-audit-lint.json`、`.log`；含本任务文件，未证明全部属于历史问题，未关闭规则 |
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
3. P2 前台 UI 和按 NAS/账号隔离的记录已接入（§14），继续在用户选择的测试目录完成小文件往返、冲突选项和结果未知状态的人工验证。模拟测试通过不代表真机传输通过。
4. 缩略图已按目标 NAS 网页契约接入，仍需独立真机验收；后台队列、P3/P4 操作继续以真实契约及独立验收推进。未确认的上传、文件操作和分享写入不得自动重放。

交付文件仍在当前工作区；`docs/` 与 `work/` 受现有 `.gitignore` 忽略。本轮未变更忽略规则、未提交或推送，后续提交需明确纳入所需方案文档。

## 12. 共享内核复核与分批提交（2026-10-05）

此前 Drive 工作已提交为 `4fcc73b`，包括只读视图、导航修正、前台传输边界及本计划；还原提交快照后重新执行核心测试为 641/641。方案文件已单独纳入版本控制，未修改忽略规则。

独立会话修复共享内核的业务会话代际、登出期间请求拦截、重新登录的账号隔离，以及分享和控制授权过期的统一失效处理，已提交为 `30f3ecb`；FileStation 失效不会清除 DownloadStation 独立会话。协议拒绝矛盾成功信封，媒体响应拒绝重复响应头和不可能的写入数量，清理失败保留原始失败并记录日志。

独立会话验证：核心测试 655/655（新增 14 项），API 26 签名构建成功、47 个编译警告；SDK 严格类型检查覆盖 26 个 `.ts` 文件、0 错误。`work/kernel-audit-lint.json` 根据本次新增 Homecheck 日志确认实际扫描 61 个文件，26 个文件包含诊断、723 个错误，**lint 未通过**。已确认部分类型诊断属于误报，但其余诊断仍待逐条定性；未关闭规则或过滤报告。

共享内核复核没有执行真实 NAS 写入或设备安装；当前 HAP 真机验收仍以 §11 所列版本和范围为准。两组修改按独立提交保存，不推送。

## 13. 搜索与祖先链续作（2026-10-05）

核对当前分支 `feat/drive-p0-foundation` 后，在此前未提交搜索代码上完成本轮修正。修改前测试为 657/657；历史构建和真机结果不作为本轮变更的验收凭据。

### 契约与实现

- 来源：`work/drive-probe/captures/mitm-2026-10-05T05-51-13-988Z.jsonl`。已取出成功的非空个人搜索、祖先链完整脱敏响应和搜索参数，纳入 `tests/fixtures/drive-readonly-contract.json`；没有凭证或真实文件 ID。
- 搜索按成功请求携带范围、score 排序、分页、过滤器以及正文搜索和片段开关。只支持已证实的个人范围与具体目录范围；具体目录必须有合法 fileId，不构造团队虚拟根或未验证的“全部”范围。
- 搜索条件仅在请求成功后替换；替换失败保留既有结果。分页和返回结果使用接受的查询、范围与已访问页码；结束搜索恢复原视图、目录及页码。会话切换或 reset 清除查询、返回位置及旧响应。
- 祖先链允许首项为空名称，拒绝重复 ID、当前目录重复、乱序、断裂、非目录、总数不一致和末项父级不匹配。从跨目录列表进目录时，祖先链和目录列表全部成功后才更新界面；祖先读取失败不伪造路径，reset 后不继续第二个请求。
- Search 的输入、提交和结束操作沿用页面 V2 状态、系统组件及语义色；提交使用 SearchController.stopEditing 收起键盘。接口与参数核对本机 API 26 SDK，并保留[华为 Search 文档入口](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-basic-components-search)。网页正文未被检索工具解析，当前依据为目标 SDK 签名与实际构建。

### 当前验证

| 验证 | 实际结果 | 证据 |
| --- | --- | --- |
| 核心编译与测试 | 666/666 通过，0 skipped；本轮新增 9 项，覆盖参数、脱敏契约、链条拒绝、范围和返回位置、失败保留、会话失效及迟到响应 | `work/drive-p1-resume-tests.log` |
| API 26 签名构建 | `assembleHap --no-daemon` 成功，21.649 秒，46 个编译警告 | `work/drive-p1-resume-build.log` |
| Lint | 未通过；本次实际扫描 61 个文件，26 个文件含诊断，共 735 个 Error、0 Warning | `work/drive-p1-resume-lint.json`、`.log` |
| 差异检查 | `git diff --check` 通过 | 未关闭检查规则，未过滤报告 |
| 设备及浏览器 | 设备列表为空；原无线地址 `192.168.50.188:42347` 重连失败。Chrome 连接器返回 `unsupported Codex auth method: apikey` | 本轮未安装 HAP、未做真机 UI 或实时 NAS 验收 |

Lint 相比共享内核报告增加 12 条诊断，位于 Drive 协议和适配器；涉及集合、数组、枚举和类型解析。严格核心编译及实际 ArkTS 构建通过，但不能据此宣称 lint 通过或将全部诊断归为误报。

标签只保留了空列表响应，未知元素结构不作实现依据。本轮未进行 NAS 写入、创建标签/星标/共享或推送。用户已要求由其手工验收，本轮交付签名 HAP 及验收说明。P1 仍未完整验收：待核对非空标签、星标/共享/最近、团队祖先链、超过 200 项的跨页，以及搜索键盘、焦点、返回和窗口适配；有效 lint 诊断仍需继续处理。P2/P3/P4 本轮没有扩展。

## 14. 人工验收反馈与 P2 前台上传下载（2026-10-05）

用户报告 `work/delivery/drive-p1-20261005/entry-default-signed.hap` 已人工验证，并要求继续。记为该交付包搜索与导航的用户验收反馈；未提供逐项结果，不据此宣称标签、缺适用数据的非空视图或大列表已经完成。本轮继续 P2 的上传下载页面与结果管理；P3/P4 不在本轮实现范围。

### 行为与边界

- 可读且可写的目录菜单提供“上传到此文件夹”。系统选择器每次选一个文件，确认区展示名称、大小、目标以及 `autorename` / `version`，默认自动改名；点击“开始上传”后才复制到私有目录并发起请求。无具体 ID/能力的虚拟根不伪造上传权限。
- 普通列表中可读且可下载的文件显示“点击下载到本机”，下载后进入“任务 → Drive 传输”；校验成功的私有文件再通过系统保存选择器导出。回收站不执行传输；权限以条目能力和服务端校验为准。
- 单次上限 512 MiB、一次一个请求；下载未知大小也受上限约束，已知大小传入严格长度校验。继续复用 RCP 会话、证书策略、进度和单请求取消，不添加后台继续、Range 或自动重试承诺。
- `DriveTransferModel` / `DriveTransferStore` 与 File Station 系统后台队列分开执行，在统一任务页展示。规范化 NAS 地址与账号形成存储范围，持久化 ID 引用，不持久化下载 URL、会话、Cookie、令牌或外部文件 URI。
- 准备和运行状态都须先保存成功；保存失败不发送新请求。进度只反映传输过程，运行中最高显示 99%，服务端成功回执或下载完整性校验完成、结果记录保存成功后才标记完成。
- 离开应用或退出账号会取消当前前台请求；退出等候取消收尾。已发送上传发生网络、协议、取消或会话失效时保留“结果待确认”，阻止同目录同名再次上传，必须由用户在 NAS 核对后明确关闭。恢复历史不会重发上传或下载，旧账号迟到响应只能记录在旧账号范围内。
- 已完成下载可保存到本机；取消保存或导出失败不显示成功，私有副本继续保留。已结束记录可以移除；待确认上传不能直接删除。记录读取失败不会用空历史覆盖。系统重启/关机入口将 Drive 进行中、未读取成功和待确认记录纳入现有任务检查。

### 页面与平台依据

沿用 API 26、Stage、V2 状态和现有页面风格：目录操作用锚定菜单，少量上传选项用 `WorkbenchChoice`，进度与历史复用任务页的有界 `List`，不新增同轴滚动容器。选择与保存调用 `@kit.CoreFileKit` 的 `DocumentViewPicker.select/save`，依据[华为选择器 API 文档](https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-file-picker)及本机目标 SDK 声明；本机 `fileIo.Stat.mtime` 为秒，与现有 Drive 上传参数一致。编译不能证明真机选择器、菜单、取消、保存和窗口适配已通过。

### 当前验证

| 验证 | 实际结果 | 证据 |
| --- | --- | --- |
| 核心编译与测试 | **685/685 通过，0 skipped**；新增 19 项，覆盖上传前确认、两个存储边界、持久保存先于请求、中断/恢复/账号切换、未知结果阻止重发、零字节下载、导出失败、目录操作入口及系统控制任务检查 | `work/drive-p2-tests.log` |
| API 26 签名构建 | **`assembleHap --no-daemon` 成功**，30.887 秒；日志含 48 个 ArkTS 警告 | `work/drive-p2-build.log` |
| Lint | **未通过**；实际扫描 65 个文件，27 个文件含诊断，743 个 Error、0 Warning。相较上轮 735 个增加 8 条，集中在 `DriveTransferState.ts` 的类型导入与 unsafe assignment/call/member-access 诊断；保留完整报告，尚未逐条定性，不宣称全部误报 | `work/drive-p2-lint.json`、`.log`；首次受沙箱写入工具目录限制，获准后完成有效扫描 |
| 差异检查 | `git diff --check` 通过 | 未关闭规则、未过滤诊断 |

签名包及人工步骤：`work/delivery/drive-p2-20261005/entry-default-signed.hap`、`验收说明.md`、`包信息.json`。没有自动安装、实时 NAS 写入或往返内容验收；仍按用户此前要求交付包供人工验收。缩略图尚未取得足够的成功响应契约，保留后续实现项。P2 仍为部分完成，下一步是用户选择测试目录后的往返、冲突和中断人工验收，以及缩略图协议与有效 lint 诊断处理。

## 15. P2 前台范围补齐（2026-10-05）

用户要求先整体完成 P2。本轮补齐剩余的缩略图协议、可见行读取和私有缓存；上传下载及持久记录沿用 §14。P2 的前台代码范围已齐，但不将本地验证当成 NAS、真机或视觉验收，也不将尚未通过的全仓 lint 标为通过。

### 请求依据与实现

- 对目标 NAS 只读取公开的 Drive 网页静态资源，没有登录或发起 NAS 写入。`SynologyDrive-Drive/config` 指向 `synodrive_common.js`；该文件的列表缩略图使用 `Files.get_thumbnail` v2、`path=id:<fileId>`、`size=small` 和条目提供的 `version_id`。`scripts/synowebapi.js/synowebapi.min.js` 的普通 WebAPI 编码将业务参数 JSON 序列化。该证据证明请求格式，不证明实际图片成功或适用于其他套件版本。
- `DriveEntry.versionId` 按既有 ID 规则保精度解码；未返回修订号时省略参数，不猜测修订。`DriveThumbnailProtocol.ts` 只接受数值字符串 ID。会话与令牌仍由内核注入，页面与缓存不持有下载 URL 或认证材料。
- 缩略图与下载共用二进制传输收尾：当前会话校验、主动取消、禁止重定向、临时文件收据释放。单图最多 4 MiB，检查 HTTP、长度、错误信封、MIME 与 PNG/JPEG/GIF/WebP 签名，再用 ImageKit 检查尺寸并解码；最大 4 百万像素，验证后释放解码资源。
- `DriveThumbnailStore.ets` 只读取可见且有读取/预览权限的常见图片和视频条目，最多 3 个请求、60 个排队项，缓存最多 60 张、24 MiB。缓存按本次连接隔离，键含文件 ID、修订号、修改时间和大小。隐藏行与退后台会取消请求；回前台可重新读取仍可见的行。失败不随滚动自动重试，用户刷新才重试。
- 切换账号后清空展示与缓存，拒绝迟到响应。缓存清理失败保留错误并停止新增缓存；失败缩略图显示文件图标。列表沿用现有行尺寸、导航、滚动和材质，增加正式失败提示。

本机证据保存在忽略目录 `work/drive-probe/`：`client-config.json`、`synodrive_common.js`、`synowebapi.min.js`、`thumbnail-contract-evidence.json`。不提交网页源文件或任何账号数据。

### 验证与交付

- 核心测试 **698/698 通过，0 skipped**，新增 13 项，覆盖参数、修订精度、权限、伪图片/错误响应、取消、限流、账号切换、后台恢复、完整解码及缓存预算。既有传输、连接、Photos 与遥测测试同步核验。证据：`work/drive-p2-complete-tests.log`。
- API 26 `assembleHap --no-daemon` 签名构建成功，27.077 秒，50 个 ArkTS 警告，其中新增 2 个位于缩略图私有目录的文件 I/O；异常由读取边界捕获并向界面报告。证据：`work/drive-p2-complete-build.log`。编译不证明真机 UI 或 NAS 返回正确。
- Lint **未通过**：有效扫描 67 个文件，27 个文件含诊断，**743 个 Error、0 Warning**；与 §14 的 743 条按文件/规则数量核对无增加，新增缩略图文件没有诊断。既有 `DriveTransferState.ts` 的 8 条及其他诊断仍待处理；不关闭规则或将其全部定性为误报。证据：`work/drive-p2-complete-lint.json`、`.log`。
- 新包及人工步骤：`work/delivery/drive-p2-complete-20261005/entry-default-signed.hap`、`验收说明.md`、`包信息.json`。未安装设备、未请求真实图片、未执行 NAS 上传下载往返。用户手工验收 §14 的传输行为及本节缩略图行为后，才能确认 P2 整体验收完成。

P3 的后续范围是改名、移动预检、复制、删除以及异步任务状态；P4 为分享链接创建与列表。本轮不扩展 P3/P4，后台传输、自动重试、断点续传及完整原图预览也不在本次 P2 前台范围。

## 16. 文件操作与异步任务（2026-10-05）

用户要求继续，真机与 NAS 整体验收统一留到最后。本轮在 P2 提交 `8700f78` 上实现 P3；没有设备安装或实时 NAS 写入。

### 契约依据与行为

- 当前保留抓包 `captures/mitm-2026-10-04T08-37-15-099Z.jsonl` 包含 `Files.update` v2、`move` 预检/提交、`copy`/`delete` 异步任务，以及 `Tasks.get` v1 的字段形状；目标网页静态 `synodrive_common.js` 进一步确认移动和复制均先 `dry_run`，冲突默认 `autorename`，删除传 `permanent=false`。网页与历史抓包支持当前请求实现，不能替代本轮 HAP 的 NAS 验收。
- 文件和普通文件夹的菜单按条目能力提供改名、复制、移动和删除。网页 `synodrive.js` 的复制规则为 `can_read`，移动为 `can_read + can_delete`；不依赖此前推断的 `can_organize`。团队根及共享根按受限入口处理；回收站不提供这些操作。
- 改名使用 `update(path,name)`，返回条目的 ID 与新名称均匹配才确认完成。删除须进入确认页再明确提交，发送非永久删除；不承诺一定能恢复。缺少 `revisions` 时保留未知版本数并拒绝删除，不把缺省数值补成 0；这次将内部 `DriveEntry.revisionCount` 改为可选字段，既有读取与传输不依赖该字段。
- 移动/复制使用完整目标目录页，个人和团队目录独立浏览、翻页和返回。只能选择已返回合法 ID 且可读/写的具体文件夹，不构造可写虚拟根。文件夹先核对目标祖先链以阻止将自身移入/复制到子目录，再预检冲突；提交采用自动改名，不覆盖同名项目。
- `DriveActionStore` 按规范化 NAS 地址和账号隔离，复用原子私有快照。提交先落盘 `unknown` 再发送；响应取得任务 ID 后保存 `accepted`。恢复只加载记录，不重放任何写请求。保存失败暂停新操作；读取失败不以空列表覆盖记录，账号切换拒绝旧响应更新新账号。
- 任务页显示操作、目标、进度和结果；只在应用前台且任务页可见时自动查询 `Tasks.get`，离开页面、后台或查询失败即停止轮询。`finished` 且结果无错误/跳过项才完成；错误或跳过分别标记未完成/需核对，未知状态继续保留“已提交，等待结果”。已结束却缺少结果的数据按协议异常处理，停止轮询并允许人工核对后关闭。查询失效或结果未知，用户须在 NAS 确认操作已结束及结果后明确关闭本机记录；关闭不取消 NAS 任务。
- 进行中或未知的文件操作阻止新的 Drive 传输，进行中或未知的传输阻止文件操作；两类记录读取状态也纳入系统重启/关机的现有任务检查。退出账号等候当前操作收尾，连接忙碌、认证失效、连接实例或代际变化均禁止新请求；退出收尾失败后允许恢复原账号操作。账号切换或页面离开后，旧提交不驱动新页面跳转。认证材料不落入操作快照、页面或日志。
- 页面复用现有 V2 状态、菜单、任务卡、List、语义色与 HDS 标题栏；目录选择页保留既有 `enableComponentSafeArea` 和滚动绑定。构建通过不能证明标题栏材质、菜单、返回、长名称和各窗口宽度的视觉验收通过。

### 当前验证与交付

| 验证 | 实际结果 | 证据 |
| --- | --- | --- |
| 核心严格编译与测试 | **719/719 通过，0 skipped**；相较 P2 新增 21 项，覆盖参数、权限、缺省版本、子目录拒绝、持久化先于发送、保存失败、未知结果、账号切换、前后台、轮询、错误/跳过与结果缺失、退出期间拦截及传输互斥 | `work/drive-p3-complete-tests.log` |
| API 26 签名构建 | **`assembleHap --no-daemon` 成功**，35.339 秒，50 个 ArkTS 警告 | `work/drive-p3-complete-build.log` |
| Lint | **未通过**；有效扫描 73 个文件，30 个文件含诊断，786 个 Error、0 Warning。新增 43 条在 `DriveActionProtocol.ts` / `DriveActionState.ts` / `DriveActionAdapter.ts`，涉及类型导入及 unsafe assignment/call/member-access；其他文件按文件/规则数量与 P2 一致。严格编译不等同于这些诊断全部误报；未关闭规则或过滤报告 | `work/drive-p3-complete-lint.json`、`.log` |
| 差异检查 | `git diff --check` 通过 | 无推送、无 NAS 写入或设备安装 |

签名包、汇总验收说明及包信息保存于 `work/delivery/drive-p3-complete-20261005/`。说明包含 P2 与 P3 的最后人工核验项；当前记录是实现、测试及构建结果，不宣称 lint 或整体验收通过。

### 分享阶段前置核对

P4 尚未实现。当前普通账号成功 `Sharing.create_link` v1 的证据只支持 `path=id:<fileId>` 和 `{url}`。`Share.list_active` v1 成功摘要在不同轮次记录的字段集合不同，没有保留稳定非空条目的完整脱敏响应，不能据此把活动条目等同于可复制的链接。`Settings.list` v2 摘要包含 `enable_normal_user_sharing`、`sharing_level`、`sharing_permission` 与强制密码/有效期等键，但值与类型未保留；网页代码结合 `public_sharing` 等权限及 `sharing_level=disallow` 判断分享，未证实与普通用户开关的优先关系。

P4 继续前须补齐上述只读成功响应及策略语义，再实现入口、确认、持久化未知结果和链接列表。不创建链接来凑证据、不猜测权限开关或列表 URL 字段。P5 配额、通知和客户端备份仍为可选项，不计入本轮 P3 范围。

## 17. Review 问题修复（2026-10-06）

基于 `28a24a4` 修复两处集成问题，不扩展 P4、后台传输或新的文件操作。

- **Tasks 发现遗漏**：`NAS_DISCOVERY_QUERY` 补入 `SYNO.SynologyDrive.Tasks`，保留 Files v2 / Tasks v1 的版本检查。新增真实 `NasConnector` 与 `DriveActionAdapter` 的模拟集成测试，服务端仅返回查询中请求的命名空间；覆盖支持、缺失或版本不兼容，以及登录后使用当前会话查询 Tasks。避免 `supportsDriveApi: () => true` 掩盖真实发现链路。
- **刷新后条目滞留**：主文件列表和目标目录列表统一使用 `driveEntryRenderKey`，以解码后的完整领域条目生成 ForEach 键。仅名称、能力、父目录、路径或版本数变化也重建行与捕获条目的回调；相同内容刷新保持键稳定。缩略图仍使用内容修订键，测试确认纯改名后复用缓存，不重复下载。
- **依据与边界**：本轮核对 API 26 工程、DevEco CLI `1.3.0-stable` 以及本机官方文档 `开发指南/ArkUI_方舟UI框架/UI开发_ArkTS声明式开发范式/学习UI范式渲染控制/ForEach_循环渲染/arkts-rendering-control-foreach` 的“非首次渲染”章节。同键保留组件是文档明确的机制；每页最多 200 项下采用完整条目快照键是本项目选择，不是要求所有列表使用 JSON 键。

### 验证

- 先增加回归测试、保留旧实现运行：64 项中 57 项通过、7 项失败；其中两项直接检出 Tasks 未发现，两项执行页面实际键表达式并检出改名后键未变化，另三项因新键函数尚未实现而失败。
- 修复后使用 §11 所列本机 SDK 运行 `scripts/test-core.ps1 -SdkRoot <SdkRoot>`：**严格核心编译与 728/728 测试通过，0 skipped**，相较基线新增 9 项。页面测试执行真实浏览模型与页面键表达式，模拟同键保留回调的契约；不将 Node 模拟视为 ArkUI 真机渲染验收。
- `hvigorw.bat assembleHap --no-daemon`：**签名构建成功，17.551 秒**；`CompileArkTS` 实际执行 8.892 秒，打包和签名均实际执行。输出 51 条 ArkTS 警告，均位于本轮未修改的源文件；不据构建成功宣称全仓 lint 通过，本轮未重跑 lint。
- `git diff --check` 通过。签名产物：`entry/build/default/outputs/default/entry-default-signed.hap`。
- 未安装设备、未执行真实 NAS 写入、未提交或推送；P2/P3 的真机整体验收仍待完成。

## 18. 移动与复制的目标目录预检修复（2026-10-06）

用户截图显示选择目标目录后报“无法确认目标文件夹的检查结果”，确认按钮不可用。该文案来自 `decodeDrivePreflight`：此前仅接受 `result` 数组，空 JSON 结果也被当作协议异常。

- **依据与边界**：复核 §16 的 NAS 网页源文件 `work/drive-probe/synodrive_common.js`（SHA256 `CB933FBB026880090455150F3EF7CA5AAC8EF3DB1A1A554CF53F40D2884F6AA5`）。`mvcpNode` 对移动和复制使用同一预检逻辑，只在 `result` 存在且长度大于 0 时显示冲突对话框，其余成功空结果继续提交。保留抓包证明 `move` 预检成功响应有 `result` 字段，但未保留其值；本轮未获得截图对应请求的完整响应，不将具体空值形状宣称为实时 NAS 实测。
- **修复**：将 `result: null`、`result: {}` 与空数组统一解码为无同名冲突。缺少 `result`、非空未知对象、错误类型、过长列表和返回异步任务 ID 的响应仍拒绝。目标权限、祖先链检查、明确确认、自动改名和提交前保存待确认记录均沿用原逻辑。
- **回归验证**：先加测试、保留旧实现运行，24 项中 22 项通过、2 项失败，复现相同报错与目标未选定。修复后严格核心编译和 **731/731 测试通过，0 skipped**；新增 3 项覆盖移动/复制的登录会话与实际 JSON 解码链、目标可选定但未确认不写入，以及异常响应拒绝。该验证使用模拟 NAS，不代表真实文件移动/复制已通过。
- **构建与交付**：API 26 `assembleHap --no-daemon` 签名构建成功，34.946 秒，`CompileArkTS`、打包和签名实际执行。日志为 `work/drive-preflight-build.log`，测试日志为 `work/drive-preflight-tests.log`。Hvigor 的 `DEVECO_SDK_HOME` 指向 CLT 的 `sdk` 目录，核心测试的 `-SdkRoot` 指向其下的 `default`；此前将构建环境指向 `sdk/default` 的尝试在执行任务前失败，修正环境后通过，未修改工程 SDK 目标。
- **验收边界**：签名包保存于 `work/delivery/drive-preflight-fix-20261006/entry-default-signed.hap`；本轮未安装设备、未执行真实 NAS 写入、未重跑全仓 lint、未提交或推送。复测需核对无同名项时可选目录、同名项自动改名，以及提交后任务完成与源/目标目录的实际结果。

## 19. 文件链接、通知、原图与后台上传续传（2026-10-06）

用户授权实施文件链接、Drive 通知，以及原图预览 → 后台传输 → 上传续传。在当前 `feat/drive-p0-foundation` 工作区保留 §17–18 的既有修改后扩展；不包含配额、下载 Range 续传、自动照片备份或公共访问权限编辑。

### 已接入行为

- **普通文件链接**：文件菜单进入确认页，调用 `Sharing.create_link` v1，展示并复制返回 URL，保存当前 NAS/账号的本机历史。目标网页把该接口命名为 `get_file_link`，`setFileLink/initQuerySharing` 与保护链接/权限编辑分别处理；因此普通链接入口按读权限控制，不用未知的全局分享开关将其禁用，也不宣称获取链接会开放公共访问。先持久化 `unknown` 再发送，模糊结果不自动重放。域名可使用 NAS 配置的自定义链接域名，凭证 URL 不进入记录或剪贴板。服务端活动列表尚无稳定非空 URL 契约，未实现。
- **Drive 通知**：发现 Notifications v1 并登记 `driveNotifications` 能力，进入页面按目标网页的 `limit=100` 读取列表；提供正式中文消息、名称、发送者、时间、刷新和本次连接的本机已读标记。未知类型提示在 Drive 网页查看，不显示原始枚举，不创建、删除或修改服务器通知。没有实现系统推送；超过当前列表的通知仍在网页查看。非空 fixture 是网页使用字段衍生的模拟数据，不冒充真实 NAS 响应。
- **原图预览**：图片点击和菜单进入原图页，复用普通下载而非 `is_preview` 或缩略图；读、预览和下载权限均满足才开放入口。下载前后用 Files v3 `get` 核对 ID、大小、修改时间、修订号和权限，变化则丢弃。完整文件保存在私有临时目录，ImageKit 按窗口及缩放尺寸解码，支持捏合、拖动、双击和按钮还原。单文件最多 128 MiB，单个 PixelMap 最多 8 百万像素；多帧图片如实提示静态显示。关闭、退后台或切换账号取消并清理；启动只清理本功能拥有的 UUID 目录，清理失败阻止新预览。图片格式实际支持及峰值内存仍待真机验证；前后元数据核对不是指定修订下载合同。
- **系统后台传输**：正常证书 HTTPS 和 HTTP 使用 `request.agent.Mode.BACKGROUND`；忽略证书的 HTTPS 保留 RCP 前台路径。后台仅使用 Wi-Fi 等非计费网络，不使用漫游网络，系统 WAITING 显示为“等待执行”，仍计入待处理任务并支持取消。复用系统传输包装器，关闭代理自动重试与跳转，记录 marker、任务 ID 和启动意图后才启动。恢复搜索、重新绑定原任务，不重放未知上传；进程退出仅解除监听，明确登出/换号/会话失效先停止旧任务，失败则阻止账号清理。上传以响应 `body` 的 DSM 成功与 `uploaded_size` 为业务确认，系统 completed 或发送量不足以确认；回执缺失保留待确认。下载校验 HTTP、响应头、文件大小及错误信封后才允许导出。任务页提供刷新、暂停、继续、取消和核对关闭。
- **保存新版本上传续传**：依目标网页 `SLICEUPLOAD` 协议持久保存私有源、摘要、mtime、原临时标识和进度。空文件探测使用 `X-TMP-FILE`、`X-TYPE-NAME`、`X-FILE-CHUNK-END=false`，取得可信 `uploaded_size` 后只发送剩余内容并设置最终标志。后台使用 SDK 上传文件范围，前台按有界读块生成剩余副本。继续必须由用户明确确认；保留同一标识，过期、新建临时会话、完成歧义、源文件变化及错误偏移都不从头另传。网页固定使用 `version`，自动改名上传不冒充可续传上传。
- **连接整合**：文件链接、通知和原图页面复用 HDS 导航及既有安全区；通知与链接列表绑定实际 Scroller。分享、文件操作与活跃/未知传输纳入现有互斥及系统控制检查。会话失效回调移到操作尾链之外，避免停止任务时等待自身；目标连接的 TLS 策略实际传入传输模型。

### 依据与验证

主要服务端依据为已有目标 NAS 网页 `work/drive-probe/synodrive_common.js`（SHA256 同 §18），以及已保留的脱敏抓包摘要。普通文件下载/链接另参照 [开源 Drive Files 实现](https://github.com/zbjdonald/synology-drive-api/blob/master/synology_drive_api/files.py)；上传续传的产品能力参照 [官方发行说明](https://www.synology.com/en-me/releaseNote/SynologyDrive?model=DS118)。内部接口、公开 REST 与桌面同步协议保持区别，本轮没有真实 NAS 调用。

平台依据为本机 API 26 `@ohos.request.d.ts`、`@ohos.file.fs.d.ts`、`@ohos.multimedia.image.d.ts` 和 CLI 原文 `使用ImageSource完成图片解码/image-decoding`。SDK 的文件读取 offset 是当前 filePointer 的相对偏移；续传副本据此连续读取。上传范围、Progress.extras 响应 body、ImageSource/PixelMap 及释放接口已核对；代理 Config 没有忽略证书校验选项。图像官网页面本轮抓取超时，未将本机原文冒称在线验证。

| 检查 | 当前结果 | 证据 |
| --- | --- | --- |
| 严格核心编译与测试 | **786/786 通过，0 skipped**；覆盖协议、实际发现与会话、先保存再发送、私有记录、任务恢复/等待执行/跨账号、上传偏移/过期/完整回执、原图权限/变化/取消/清理，以及会话失效停止顺序和尾链死锁回归 | `work/drive-next-tests.log` |
| API 26 签名构建 | **成功，32.302 秒，80 条 ArkTS 警告**；CompileArkTS、打包和签名实际执行 | `work/drive-next-build.log` |
| Lint | **未通过**；实际扫描 83 文件，31 文件含诊断，852 Error、0 Warning。比 §16 的 786 多 66，包括实施前预检修复的 1 条。新增集中在协议/状态/连接的类型导入和 unsafe 诊断；目标 SDK TypeChecker 对部分 String/Array/Date 位置确认是具体类型，但未据此将所有诊断判为误报，未关闭规则或改 ACL | `work/drive-next-lint.json`、`.log` |

初次构建发现的 ArkTS 构造器属性、对象展开及进度回调字段问题均已修复；当前成功日志对应最终代码。lint 首次受 SDK 日志目录写入限制，获准执行后完成有效扫描。签名包位于 `work/delivery/drive-services-20261006/entry-default-signed.hap`，附人工验收说明和包信息；未安装设备、执行 NAS 写入、提交或推送。

后续验收须在测试目录确认普通链接保留权限、非空通知字段与已读语义、原图质量/方向/大图资源释放、正常与忽略证书连接的模式选择、后台进程恢复与退出停止，以及同一临时会话的断线续传和最终文件内容。服务端活动链接、保护链接策略与下载 Range 仍是独立契约缺口。

## 20. Review 问题修复与忽略证书后台传输（2026-10-06）

§19 代码经独立只读审查发现 4 处确定问题，并按审查方案为忽略证书的 HTTPS 补上应用自管的后台传输路径。本轮先复现、再修复、后回归；不扩展配额、下载 Range 续传或公共访问权限编辑。

### 修复

- **原图预览无法开始下载（P1）**：`DriveOriginalModel` 先创建临时目录，而 RCP 下载层要求独占创建不存在的目录，实际接线立即报“无法创建下载临时目录”，未发出网络请求。现由下载层独占创建并经 `onDirectoryCreated` 回报所有权，预览层只登记自己拥有的目录；回调失败只丢弃新目录，不清理他方目录。原图测试改为执行真实 RCP 传输接线，不再模拟下载端口。
- **跨账号保护漏掉超过 24 小时的后台任务（P1）**：`guardAccount()` 的 `search()` 未指定 `after`，官方默认只查创建于最近 24 小时内的任务；旧账号任务等待非计费网络超过一天后，新账号可能连同旧凭证任务一起进入。现显式 `after: 0` 覆盖完整时间范围，再按账号归属检查未结束任务。
- **后台下载暂停后恢复误判失败（P2）**：恢复可能收到标准 206 Partial Content，而校验只接受 HTTP 200，并把最后一次响应的 `Content-Length` 与完整文件长度比较。因下载 Range 契约尚未完成，撤下下载的暂停/继续入口：`pause`/`resume` 对 `download` 明确拒绝并提示取消后重新下载，旧的 paused 下载记录仍可取消；“保存新版本”上传的暂停续传保留。
- **进程外完成的后台下载无法确认（P2）**：HTTP 状态只保存在进程内 `response` 回调；应用在响应到达前被终止时，重启后 `refresh()` 只能取到 COMPLETED 和文件，仍以初始状态校验而判失败。现保留文件进入待校验，由用户在任务页明确触发 `DriveDownloadVerification`：重新读取条目元数据核对 ID、大小、修改时间、修订号和权限，全量摘要比对本机副本，再取一次远端内容核对摘要，最后复核条目元数据；任一步不符即拒绝导出。遗留的 206 记录同样要求全量校验，不再以末段长度冒充完整校验。

### 忽略证书的 HTTPS 后台传输

平台依据：本机 API 26 `@ohos.request.d.ts` 的代理 Config 没有跳过证书校验的选项，系统托管后台传输无法继承 RCP 的证书策略；官方长时任务指南把非托管上传下载列为 `dataTransfer` 适用场景。

实现：连接为 `https:` 且忽略证书时，后台执行改用应用自管的 RCP + `dataTransfer` 长时任务（`executor: 'rcpBackground'`），正常证书 HTTPS 与 HTTP 仍用系统托管代理。`module.json5` 增加 `KEEP_BACKGROUND_RUNNING`、`GET_NETWORK_INFO` 权限与 `backgroundModes: ["dataTransfer"]`。长时任务申请、实况窗或网络检查任一失败即中断，不静默回退前台；实况窗按官方 `LIVE_VIEW` 与 `downloadTemplate` 更新进度，用户或系统取消、超过三分钟没有进展都会停止传输。`SdkTransferNetwork` 监听默认路由，要求非计费 Wi-Fi、拒绝蜂窝与 VPN、能力未知即停止，不用网络名称推断是否计费。**进程终止后传输会中断**：任务页与实况窗都标注“应用后台传输 · 进程终止后会中断”，不宣称与系统托管等效。

### 验证

- 严格核心编译与测试：**806/806 通过，0 skipped**（`work/continue-tests.log`）。相对 §19 的 786 新增 21 项、替换 1 项（下载暂停/继续改为拒绝语义）。新增覆盖：目录独占创建与所有权回调失败、原图与真实 RCP 接线一致、24 小时外的账号保护、下载拒绝暂停/继续、缺回执的待校验与 206 全量校验、同 token 续传与过期/完成歧义/源变化的拒绝、网络门禁（计费 Wi-Fi、蜂窝、VPN、未知能力、默认路由缺失）、网络变化与系统取消各只中断一次并释放监听、实况窗获取失败不留未观察任务、进度发布失败不静默保留后台资格、模块仅声明必要运行策略。
- API 26 签名构建：**成功**，`CompileArkTS` 2.129 秒、打包 751 毫秒、签名 233 毫秒均实际执行，86 条 ArkTS 警告（`work/drive-fix-build-final.log`）。相对 §19 的 80 条多 6 条，全部落在本轮改动的后台传输文件（`SdkBackgroundTransfer.ets` 4 条、`DriveBackgroundTransfer.ets` 2 条），其余文件告警分布不变。
- Lint：**未通过**；实际扫描 87 文件，32 文件含诊断，**860 Error、0 Warning**（`work/continue-lint.json`）。相对 §16 基线 786 多 74，相对 §19 的 852 多 8；集中在协议与适配层的 `no-unsafe-*` 与类型导入诊断。本轮未关闭规则、未改 ACL，也未把诊断判为误报。
- `git diff --check` 通过。签名产物 `entry/build/default/outputs/default/entry-default-signed.hap`，4262420 字节，SHA256 `b9170cf9c96026d7195f27ec92b1ff38b5e8bc9c4ef78ce1570042976d72bc41`，交付副本见 `work/delivery/drive-background-cert-20261006/`。
- **未安装设备、未执行真机或真实 NAS 验收**。设备 `192.168.50.188:42347`（VOL-AL00，API 26）已连接，用户本轮要求暂不安装。

后续真机验收：正常证书连接确认走系统托管后台、忽略证书连接确认走应用后台传输且退后台后继续、网络切换与系统取消后停止并保留记录、进程终止后中断且重启不重放、同 token 续传的最终文件内容，以及原图的目录所有权与资源释放。
