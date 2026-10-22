# NAS 界面优化方案

## 2026-10-22 修订与实施状态

原方案的基线诊断保留用于设计追溯。以下修订替代正文中对应的旧布局要求；当前界面、代码片段与运行截图统一见 [界面汇总](current-ui.md)，图片独立存放并以链接提供。

| 范围 | 当前实现与修订 |
| --- | --- |
| 照片列表 | 移除右侧自定义时间滑块、顶部日期胶囊与浮动日期提示，只保留列表内日期分组；使用原生自动滚动条。网格边距 0、圆角 0、间隙 2vp；保留捏合列数、滑动多选与共享元素转场 |
| 空间不可用 | 居中灰色图标、标题、原因及单个重试按钮，替代整屏错误横幅；不混显上一空间内容 |
| 设置 | 设备管理、应用设置两组主卡片，登出独立成卡；外观行右侧显示当前值并打开原生单选菜单；底部避让为底栏高度加 28vp |
| 模块底栏 | 移除模拟预览条与常驻标签，标题右侧显示启用数量；所有项目统一使用开关，常驻项选中禁用 |
| 文件与云盘 | 恢复连续白底列表，移除逐项悬浮卡片和根目录重复路径；排序与视图使用图标；更多按钮使用横向省略号圆圈；底部灰色数量统计 |
| 刷新与深色 | 照片列表支持下拉刷新，更多页移除重复刷新行；深色按压色修订为 `#1FFFFFFF` |
| 连接与首页 | 已接入协议提示、分组登录表单、信任设备凭证、局域网服务发现、历史别名与连通性；首页状态入口、指标圆环、网络速率胶囊与存储水位色已实现 |
| 备份与媒体 | 已实现备份状态看板、禁用态、目录跳转、弹性滚动；媒体操作胶囊、双向双击缩放、全屏系统栏联动与下滑退出 |
| 任务与远程下载 | 已实现手动暂停／继续、速率与剩余时间、失败重试、全局任务胶囊、系统实况窗调用、本地种子提交和卷空间读取；异步请求按会话代际隔离 |
| 双栏与折叠布局 | 已有响应式实现，后续调整与验收暂缓；不列入本轮完成验收项 |

构建通过，977 项回归测试通过。单栏运行截图已覆盖照片、空间异常、更多、底栏配置、设置浅深色、外观菜单、文件和云盘。物理真机触觉／多指手势、半折姿态、系统实况窗授权、双重验证免验证以及真实种子创建仍待相应环境验收，不能由构建或模拟测试替代。

---

- **基线版本**：分支 `feat/drive-photos`（提交 `f0192109713fadcf0aaecb569c83a6cedc5ad683`）
- **目标平台**：HarmonyOS 7（Target & Min API 26，Stage 模型，ArkUI V2，`@kit.UIDesignKit` HDS 组件体系）
- **设计参考**：
  1. **华为官方指南**：HarmonyOS 7 HDS（HarmonyOS Design System）设计规范、“光感与材质（Adaptive Material）”、“智感握姿与悬浮导航（Floating Bar）”、“一多（一次开发，多端部署）”响应式架构规范。
  2. **开源与行业标杆**：Immich（时间线手势、备份状态看板）、Nextcloud（文件列表层级、多选批处理、传输队列状态机）、Alibaba Cloud Drive / Synology Drive & Photos 移动端（空间切换、媒体预览交互）。

---

## 目录

1. [现状诊断与核心痛点审计](#1-现状诊断与核心痛点审计)
2. [设计原则与 HarmonyOS 7 规范对齐](#2-设计原则与-harmonyos-7-规范对齐)
3. [全局信息架构与导航范式重构](#3-全局信息架构与导航范式重构)
4. [视觉设计系统（Design Tokens）与深浅色升级](#4-视觉设计系统design-tokens与深浅色升级)
5. [通用基础组件库（WorkbenchUi）重构方案](#5-通用基础组件库workbenchui重构方案)
6. [分模块 UI/UX 深度优化方案](#6-分模块-uiux-深度优化方案)
   - [6.1 登录、连接恢复与历史地址管理](#61-登录连接恢复与历史地址管理)
   - [6.2 首页（设备中枢与资源遥测看板）](#62-首页设备中枢与资源遥测看板)
   - [6.3 文件浏览（File Station）与 Synology Drive](#63-文件浏览file-station与-synology-drive)
   - [6.4 照片与相册（Synology Photos）](#64-照片与相册synology-photos)
   - [6.5 相册自动备份设置与状态监控](#65-相册自动备份设置与状态监控)
   - [6.6 统一媒体预览器（Image / Video Preview）](#66-统一媒体预览器image--video-preview)
   - [6.7 全局任务中心与 NAS 远程下载（Download Station）](#67-全局任务中心与-nas-远程下载download-station)
   - [6.8 设置、系统控制与协同子页](#68-设置系统控制与协同子页)
7. [折叠屏（Pura X / Mate XT）与多端响应式适配](#7-折叠屏pura-x--mate-xt与多端响应式适配)
8. [动效、触感反馈与无障碍（Accessibility）规范](#8-动效触感反馈与无障碍accessibility规范)
9. [验证补齐清单与研发落地路线图](#9-验证补齐清单与研发落地路线图)

---

## 1. 现状诊断与核心痛点审计

结合 `current-ui.md` 源码摘录与 15 张实测截图，当前实现已初步接入 `HdsNavigation` 与 `HdsTabs` 悬浮底栏，但在**视觉一致性、空间层级、状态反馈、手势完备度及 HDS 规范细节**上存在以下核心问题：

| 审计维度 | 现存问题（附源码/截图依据） | 严重度 | 用户体验影响 |
| :--- | :--- | :---: | :--- |
| **深色模式按压失效** | `base/element/color.json` 定义 `workbench_pressed` 为 `#14000000`（8% 纯黑），而 `dark/element/color.json` **缺失同名覆盖**。在 `#1C1E22` 深色卡片上叠加 8% 黑色完全不可见。 | P0 | 深色模式下所有文件行、设置行丢失按压态视觉反馈。 |
| **容器与边距割裂** | 首页（`01`）、备份页（`05`）采用 `16vp` 边距圆角卡片；Drive（`03`）采用通栏纯白列表；任务页（`08`–`11`）在浅灰背景下方直接铺设**巨大通栏白底半圆角容器**（占满剩余屏幕），导致页面风格严重割裂。 | P1 | 界面缺乏统一的鸿蒙 7 卡片式栅格呼吸感，任务页大面积留白显得简陋。 |
| **滚动裁切生硬** | 备份设置滚动时（`06-backup-bottom.png` 顶部），白色卡片在标题栏下方出现**生硬的水平截断线与局部残影**，未正确打通 `HdsNavigation` 的 `scrollEffectOpts` 毛玻璃延伸与顶部安全区。 | P1 | 破坏 HarmonyOS 7 标志性的“通透光感”沉浸体验。 |
| **任务状态视觉误导** | `10-task-upload.jpeg` 中，任务处于**“已结束”**分组，但 `TaskRecordRow.ets` 仅判断 `this.record.progress === undefined` 决定进度条显隐，导致**已完成任务依然常驻一条 100% 亮蓝色进度条**。此外 `TaskPage.ets` 设置了 `.animationDuration(0)` 和 `.scrollable(false)`。 | P1 | 已完成任务看起来像卡在 100% 传输中；顶部分栏无法左右滑动切换，切换生硬无动画。 |
| **列表分隔线错位** | `WorkbenchEntryRow`（`WorkbenchUi.ets` L229）分隔线固定 `margin({ left: 16, right: 16 })`，直接穿过左侧文件夹/缩略图下方（`03-drive.png`）；而设置页（`Index.ets` L1273）使用 `left: 68`。 | P1 | 违反 HDS 列表规范（带图标列表分隔线应与主文本左边缘对齐，即 `68vp`）。 |
| **备份页禁用态缺失** | `05-backup.png` 中当“相册备份”总开关处于关闭状态时，下方的备份模式、备份位置、目录风格全部保持 100% 亮蓝激活态；且“自定义”目录项使用了单选圆圈而非跳转箭头。 | P2 | 视觉传达与实际运行状态矛盾；点击“自定义”弹出目录选择器的预期不明确。 |
| **滥用 `HdsTabs` 实现预览工具栏** | `ImagePreview.ets`（L185–196）使用单页签 `HdsTabs` 伪装宽度 `224vp` 的底部工具栏，导致操作按钮（分享、收藏、信息、删除）带有页签选中语义，且删除等危险操作无语义色区分。 | P2 | 组件语义错位，无障碍朗读异常（会把操作按钮读作“页签”）。 |

---

## 2. 设计原则与 HarmonyOS 7 规范对齐

本方案全面对齐 **HarmonyOS 7（API 26）HDS 设计规范** 与开源私有云最佳实践：

1. **光感材质与空间分层（Spatial & Material Hierarchy）**
   - 遵循 HDS 三层Z轴体系：**背景层**（`workbench_background`） $\rightarrow$ **内容卡片层**（`workbench_surface`，圆角 `16vp`，边距 `16vp`） $\rightarrow$ **悬浮材质层**（顶部 `HdsNavigation` 动态模糊标题栏 + 底部 `HdsTabs` / `HdsActionBar` 自适应毛玻璃胶囊）。
   - 所有可滚动页面必须开启内容区全屏穿透（`expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])`），由顶部标题栏的 `scrollEffectOpts` 与底部悬浮栏自动处理模糊遮罩，严禁在标题栏下沿硬裁切滚动容器。
2. **状态驱动与即时可感知（State-Driven Feedback）**
   - 区分“进行中（Active）”、“暂停/等待（Paused/Pending）”、“已完成（Completed）”与“异常（Failed）”的视觉形态：已完成项自动收起进度条，展示完成时间或目标路径；异常项内联展示错误原因摘要与“重试”入口，而非仅靠一闪而过的 Toast。
3. **智感握姿与单手可达（Ergonomic Reachability）**
   - 高频筛选、空间切换（个人空间 / 共享空间）、新建/上传入口优先布局在易触达区域或悬浮胶囊内；多选态平滑切换为底部悬浮批处理栏（`HdsActionBar` 风格）。
4. **原生一多自适应（Responsive by Default）** （本阶段可暂缓）
   - 针对直板机（断点 `sm`）、横向折叠屏如 Pura X / Pocket（断点 `sm`/`md`）、大折叠屏及平板（断点 `md`/`lg`），采用栅格断点动态切换 `HdsTabs`（底栏）与 `HdsSideBar`（侧边栏 + 微缩放避让 `scaleContentEnabled: true`）。

---

## 3. 全局信息架构与导航范式重构

### 3.1 解决“原地替换底栏”的心智冲突

当前架构在进入 Synology Drive 或 Synology Photos 时，直接替换根部 `HdsTabs` 的页签数组，导致用户搞不清自己是在二级页面还是根页面。建议重构为**“主工作台（Root Workbench） + 沉浸式子应用容器（Sub-App Container）”**双层清晰架构，或采用**顶部二级胶囊切换 + 固定全局底栏**方案：

#### 方案 A（推荐：保留子模块独立底栏，但明确“子应用切换器”与全局任务胶囊）
1. **常驻“全局传输”**：
   - 当后台存在进行中的上传/下载/备份任务时，通过实况窗等系统能力持续展示，点击以半模态（Sheet）或跳转方式快速呼出当前模块任务列表，解决子模块内丢失任务感知的痛点。
2. **子页入栈统一隐藏悬浮底栏**：
   - 凡是通过 `navStack.pushPath` 进入的二级页面（如“相册备份设置”、“搜索”、“连接历史”、“模块底栏设置”），必须置于独立 `HdsNavDestination` 中，自动隐藏底部 `HdsTabs`，避免底栏在设置子页中错误残留。

### 3.2 模块内固定页签（Pinned Tabs）交互优化

- 在 Drive 与照片模块的“更多”页中，不再强制用户跳转到全局“设置 -> 模块底栏”才能修改常用页签。
- 在“更多”页面的每个功能行右侧直接提供 **“固定到底栏”图钉按钮（`pin` / `pin_fill`）**，或在右上角提供“编辑底栏”快捷入口，实现所见即所得的导航定制。

---

## 4. 视觉设计系统（Design Tokens）与深浅色升级

### 4.1 色彩系统补齐与深色模式修复

修复 `dark/element/color.json` 缺失按压色的问题，并引入语义化状态底色与边框色，确保深色模式下卡片层次分明：

| 资源名 (`color.json`) | 浅色模式 (Light) | 深色模式 (Dark) | 优化说明与用途 |
| :--- | :--- | :--- | :--- |
| `workbench_background` | `#F1F3F5` | `#000000` | 对齐鸿蒙 7 系统级标准背景色（浅色微冷灰，深色纯黑 OLED 省电且凸显卡片） |
| `workbench_surface` | `#FFFFFF` | `#1C1E22` | 一级卡片与列表容器底色 |
| `workbench_surface_elevated` | `#FFFFFF` | `#26292E` | **新增**：半模态内嵌卡片、悬浮弹层底色，解决深色下半模态内卡片撞色 |
| `workbench_secondary_surface` | `#F6F7F9` | `#282B30` | 搜索框、内嵌信息块、输入框底色 |
| `workbench_pressed` | `#0D000000` | `#1AFFFFFF` | **重点修复**：浅色 5% 黑，**深色补齐 10% 白**（或直接绑定 `$r('sys.color.interactive_click')`） |
| `workbench_accent_surface` | `#E8F0FE` | `#172B4D` | 品牌强调浅底（选中项底色、主图标底板） |
| `workbench_success` | `#1E8E3E` | `#81C995` | **新增**：连接成功、备份完成、健康存储池状态色 |
| `workbench_success_surface` | `#E6F4EA` | `#132A1C` | **新增**：成功状态胶囊底色 |
| `workbench_warning` | `#B06000` | `#FDD663` | 警示文本（如证书未校验、非 Wi-Fi 等待备份） |
| `workbench_warning_surface` | `#FEF7E0` | `#33260D` | 警示横幅底色 |
| `workbench_danger` | `#D93025` | `#F28B82` | 危险操作、传输失败、存储空间告警（$\ge 90\%$） |
| `workbench_danger_surface` | `#FCE8E6` | `#3C1917` | **新增**：错误提示块底色、删除按钮高亮底板 |
| `workbench_divider` | `#0D000000` | `#14FFFFFF` | 改用 Alpha 透明色替代实色 `#DFE2E7`，在任何底色上过渡更自然 |

### 4.2 尺寸、栅格与排版梯度（`WorkbenchMetrics` 升级）

针对 `WorkbenchUi.ets` 中的 `WorkbenchMetrics`，建立完整的响应式与对齐规范：

```typescript
export class WorkbenchMetrics {
  // 布局与栅格
  static readonly pageMarginSm: number = 16;      // 手机/窄屏水平边距
  static readonly pageMarginMd: number = 24;      // 折叠屏展开/平板水平边距
  static readonly sheetMargin: number = 24;       // 半模态内容水平边距
  static readonly sectionGap: number = 12;        // 卡片分组垂直间距
  static readonly itemGap: number = 8;            // 紧凑条目间距

  // 圆角体系（遵循鸿蒙 7 连续曲率平滑圆角）
  static readonly cardRadius: number = 16;        // 一级卡片圆角
  static readonly innerRadius: number = 12;       // 卡片内嵌块/缩略图圆角
  static readonly thumbRadius: number = 8;        // 列表小缩略图圆角
  static readonly pillRadius: number = 20;        // 筛选胶囊/状态标签圆角

  // 列表与触控
  static readonly touchSize: number = 48;         // 最小无障碍触控热区
  static readonly rowMinHeight: number = 64;      // 双行文件/任务条目最小高度
  static readonly singleRowHeight: number = 56;   // 单行设置/入口条目标准高度（原 48vp 偏挤，提升至 HDS 推荐 56vp）
  static readonly infoRowHeight: number = 48;     // 纯展示键值对行高

  // 分隔线缩进（核心修复点）
  static readonly dividerInsetText: number = 16;  // 无图标行分隔线左缩进
  static readonly dividerInsetIcon: number = 68;  // 带 40vp 图标行分隔线左缩进 (16 + 40 + 12 = 68vp)
  static readonly dividerInsetCheck: number = 104;// 多选态带复选框 + 图标行左缩进 (16 + 24 + 12 + 40 + 12 = 104vp)
}
```

---

## 5. 通用基础组件库（WorkbenchUi）重构方案

### 5.1 `WorkbenchEntryRow`（文件与通用条目行）优化

1. **卡片化包裹与圆角裁剪**：
   - 废除 Drive（`03-drive.png`）与 File Station（`02-files.jpeg`）直铺屏幕边缘的做法。将文件列表置于 `margin({ left: 16, right: 16 })` 的 `ListItemGroup` 卡片容器中（`borderRadius(16)`，`clip(true)`，`backgroundColor($r('app.color.workbench_surface'))`）。
2. **分隔线精确对齐并移除末行分隔线**：
   - 将 `WorkbenchEntryRow` 内部的硬编码 `Divider().margin({ left: 16, right: 16 })` 改为由 `List({ space: 0 }).divider({ strokeWidth: 0.5, color: $r('app.color.workbench_divider'), startMargin: this.selecting ? 104 : 68, endMargin: 16 })` 统一驱动。这样不仅保证分隔线与文字左对齐，还能自动消除每个分组最后一行的多余底部分隔线。
3. **更多按钮图标视觉降噪**：
   - 当前 `WorkbenchUi.ets` L213 使用 `SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(32)`，圆圈直径过大且双色渲染在密集文件列表中显得突兀。建议改为轻量级 `$r('sys.symbol.dot_grid_1x2')` 或无外圈的 `$r('sys.symbol.ellipsis')`（`fontSize(20)`，颜色 `$r('sys.color.icon_secondary')`），保持 `48vp × 48vp` 透明触控热区不变。

### 5.2 `WorkbenchEmptyState`（统一空状态组件，新增）

针对 `04-photos-empty.png`、`09-task-download.jpeg`、`11-task-processing.jpeg` 空态简陋的问题，封装统一的 `WorkbenchEmptyState` 组件：
- **视觉构成**：`64vp` 柔和双色 `SymbolGlyph`（主色 `$r('sys.color.icon_tertiary')` + 强调点缀色） + `16fp Medium` 标题 + `14fp` 辅助说明（最大宽度 `260vp`，居中换行） + **可选的主/次胶囊操作按钮**。
- **垂直居中计算**：位于 `List` 或 `Tabs` 内时，默认使用 `layoutWeight(1)` 并扣除底部悬浮导航栏安全高度（`padding({ bottom: 72 })`），确保视觉重心处于屏幕黄金分割位，而非紧贴顶部（如 `09-task-download.jpeg`）。

### 5.3 `WorkbenchNotice`（内联通知与错误反馈重构）

- **废除仅用 Toast 截断首句报错的做法**：对于网络异常、权限不足、二步验证失败、Download Station 认证失效等场景，使用内联可展开的 `WorkbenchNotice` 横幅卡片：
  - 左侧：状态语义图标（`exclamationmark_triangle_fill` 或 `xmark_octagon_fill`）；
  - 中部：简明人类可读摘要（如“存储空间读取受限”），支持点击展开原始 API 错误码；
  - 右侧：内联操作按钮（如 **“重试”**、**“重新认证”** 或 **“忽略”**）。

---

## 6. 分模块 UI/UX 深度优化方案

### 6.1 登录、连接恢复与历史地址管理

#### 现状问题（对比 `Index.ets` L1127 与 `14-history-empty.png`、`15-login-historical.png`）
- 移除协议选择器后，地址输入框仅靠后台解析，用户不清楚当前默认走 HTTP 还是 HTTPS，也不知道默认端口（5000/5001）是否生效。
- 三个 `TextInput` 各自独立，缺乏表单分组感；历史地址页（`14-history-empty.png`）不支持手动新增/编辑备注名，也无局域网设备自动发现。

#### 优化方案
1. **地址栏智能协议胶囊（Smart Protocol Prefix Pill）**：
   - 在地址输入框左侧内嵌一个轻量可点击的协议胶囊标签（默认为 `HTTPS ▾` 或根据用户输入自动切换 `HTTP` / `HTTPS` / `QC`）。
   - 当用户输入纯 IP（如 `192.168.1.100`）未带端口时，输入框底部动态浮现一行微字提示：`将通过 https://192.168.1.100:5001 连接（点击切换 5000 端口）`，兼顾极简输入与确定性预期。
2. **一体式分组表单卡片（Grouped Form Card）**：
   - 将“地址、用户名、密码、按需 OTP 六位验证码、忽略证书校验开关”整合进一张圆角 `16vp` 的 `workbench_surface` 卡片内：
     - 账号与密码框使用无边框内嵌样式 + 左侧 `20vp` 语义图标（`person`、`lock`） + `Divider` 分隔；
     - **二步验证（OTP）升级**：当服务端要求动态码时，使用平滑高度过渡（`.transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -8 })))`）展开 6 位验证码输入行，并提供 **“信任此设备（免除下次验证）”** 勾选框。
3. **历史登录与局域网发现（`ConnectionAddressPage`）升级**：
   - **顶部新增“局域网发现在线 NAS”分组**：利用 mDNS / SSDP 扫描局域网内的群晖设备，展示设备型号、IP 与主机名，点击一键填入。
   - **历史记录卡片增强**：每条历史记录展示 **自定义别名（可编辑）**、地址标签（内网 IP / 公网域名 / QuickConnect）、上次登录时间，以及实时的 **延迟与连通性状态点（如 `● 12ms 在线`）**。支持左滑编辑别名或删除。

---

### 6.2 首页（设备中枢与资源遥测看板）

#### 现状问题（参考 `01-home.jpeg` 与 `Index.ets` L1231）
- 应用快捷入口（Synology Drive、照片、NAS 下载）使用 `Flex({ wrap: FlexWrap.Wrap })` 放在白底卡片中，当只有 2~3 个入口时布局松散，缺乏功能状态摘要（例如照片备份是否开启、NAS 下载是否有任务在进行）。
- 设备头部（`deviceHeader`）直接裸露在灰底上，与下方卡片对齐感较弱。

#### 优化方案
1. **设备状态英雄卡片（Device Hero Card）**：
   - 将 `deviceHeader` 升级为带微渐变或轻材质底板的顶部卡片（可选）。
2. **动态宫格工作台（Bento Grid Shortcuts）**：
     - **Synology Drive 磁贴**：主标题 `Drive`；
     - **照片磁贴**：主标题 `照片`；
     - **NAS 下载磁贴**：主标题 `下载`。
3. **遥测与存储卡片视觉升级（`NasTelemetrySummary` & `StorageCard`）**：
   - CPU / 内存采用双圆环仪表盘（`Gauge` 或环形 `Progress`）并列展示，网络上下行速率采用带上下箭头与实时迷你折线/胶囊标展示（`↑ 1.2 MB/s`、`↓ 18.5 MB/s`）。
   - 存储空间进度条增加 **水位线色彩语义**：$< 75\%$ 使用品牌蓝 `$r('sys.color.icon_emphasize')`，75%–90% 自动切换警示橙 `workbench_warning`，$\ge 90\%$ 切换危险红 `workbench_danger`。

---

### 6.3 文件浏览（File Station）与 Synology Drive

#### 现状问题（参考 `02-files.jpeg`、`03-drive.png` 与源码）
- 列表铺满全屏宽度，分隔线切过左侧文件夹图标；底部 `4 / 4 项` 样式简陋。
- 缺少直观的可交互面包屑路径导航栏与排序/视图切换栏（列表视图 vs 网格视图）。
- 进入多选模式后，复选框出现在左侧，但缺少标准的顶部“已选 $N$ 项 / 全选”与底部悬浮批处理动作栏。

#### 优化方案
1. **双层吸顶工具栏（Breadcrumb + Filter/Sort Bar）**：
   - 在标题栏下方固定一条 `40vp` 高的横向可滚动 **交互式面包屑导航栏（Breadcrumb Bar）**：`根目录 > Document > 2026项目`，最后一级高亮加粗，点击任意上级节点直接回退到对应目录层级，进入新目录时自动滚动至最右侧。
   - 面包屑右侧固定 **“排序（按名称/时间/大小）”** 与 **“视图切换（列表 / 网格缩略图）”** 图标按钮。
2. **卡片化文件列表与视觉微调**：
   - 文件列表整体水平内缩 `16vp`，包裹于圆角卡片中；分隔线 `startMargin` 设为 `68vp`。
   - 副标题信息丰富化：由单一的文件大小升级为 `修改时间 · 文件大小`（如 `2026/10/22  -  24.5 MB`），文件夹副标题显示子项数量或修改日期, 时间根据与当时的距离改为显示昨天/今天等。
3. **多选态与批处理栏（Batch Selection Mode）**：
   - 支持 **长按任意文件行直接震动并进入多选模式**（无需先去右上角菜单点“选择”）。
   - 多选模式下：顶部标题栏切换为 `已选择 N 项`（左侧“取消”，右侧“全选/全不选”）；底部平滑升起毛玻璃悬浮动作栏（`下载 / 移动 / 复制 / 分享 / 删除`），禁用项自动降低透明度。

---

### 6.4 照片与相册（Synology Photos）

#### 现状问题（参考 `04-photos-empty.png` 与 `PhotoModulePage.ets`）
- 右上角菜单图标使用了与底栏“更多”一模一样的四宫格图标（`04-photos-empty.png`），含义模糊；且“个人空间 / 共享空间”切换隐藏在二级菜单里，用户不直观（图片副标题提示“当前账号在此空间没有可见的照片或相册”，但界面上根本看不出当前处于哪个空间！）。
- 照片时间线网格左右留有 `16vp` 边距（`PhotoModulePage.ets` L368），单行照片数量少时显得局促，且不支持双指捏合切换列数与滑动多选。

#### 优化方案
1. **顶栏显式与图标纠偏**：
   - 将右上角易混淆的四宫格图标替换为明确的 **`+`（上传照片/新建相册）** 与 **`checkmark_circle`（进入多选）** 两个独立轻量按钮。
2. **空态赋能（Actionable Empty State）**：
   - 在 `04-photos-empty.png` 的空态下方增加两个胶囊按钮：
     - 主按钮（填充强调色）：**“上传照片”**（直接拉起系统 PhotoViewPicker）；
     - 次按钮（描边/浅底色）：**“开启自动备份”**（跳转相册备份设置）或 **“切换至共享空间”**。
3. **沉浸式时间线网格与高阶手势（对标 Immich & 鸿蒙图库）**：
   - **网格边距优化**：时间线照片网格左右边距由 `16vp` 缩减为 `2vp`（或通栏 `0vp`，行内间距 `2vp`），日期分组标题（如 `2026年10月22日 星期四`）保持 `16vp` 左内边距并支持 **吸顶悬浮（Sticky Header）**。
   - **双指缩放列数（Pinch-to-Zoom Grid）**：在网格上绑定 `PinchGesture`，支持在 **3 列（大图预览） $\leftrightarrow$ 4 列（标准日视图） $\leftrightarrow$ 6 列（紧凑月视图）** 之间带 `animateTo` 弹簧动画无缝切换。
   - **侧边快速时间轴滑块（Fast Scroll Scrubber）**：右侧挂载与 `List` 联动的按年月快速拖拽胶囊滑块，解决上万张 NAS 照片快速翻找历史年份的痛点。
   - **照片角标完善**：在缩略图四角精准渲染 **视频时长（右下角半透明胶囊 `01:24`）**、**实况照片（Live Photo 图标）**、**收藏星标（左下角）** 。

---

### 6.5 相册自动备份设置与状态监控

#### 现状问题（参考 `05-backup.png`、`06-backup-bottom.png` 与 `PhotoBackupSettingsPage.ets`）
- 页面向上滚动时，卡片在标题栏下沿被生硬截断（`06-backup-bottom.png`）。
- 备份关闭时（`05-backup.png`），下方所有单选框依然呈高亮蓝色可点击状态；且“备份已关闭”状态块样式苍白。
- “自定义”备份位置使用单选圆圈，缺乏目录跳转引导。

#### 优化方案
1. **修复滚动穿透与标题栏毛玻璃模糊**：
   - 移除 `PhotoBackupSettingsPage` 外层容器在标题栏下方的硬裁剪，为 `Scroll` 开启顶底安全区延伸，并在外层 `HdsNavDestination` 启用 `scrollEffectOpts: { enableScrollEffect: true }`，确保卡片向上滚动时柔和地隐入标题栏毛玻璃背板之后。
2. **新增顶部“备份实时看板卡（Backup Status Dashboard）”**：
   - 将首屏的单行开关 + 简陋的 `WorkbenchNotice` 整合为一张富有视觉层次的 **状态看板卡**：
     - **当备份关闭时**：显示灰色休眠图标 + “自动备份未开启” + 简短说明（“开启后将在后台自动将手机新增照片安全同步至 NAS”）。同时，**下方所有配置分组卡片（备份模式、备份位置、目录风格、上传设置）整体设置 `.opacity(0.45)` 与 `.enabled(false)`**（或折叠收起），消除“开关已关但选项全亮”的视觉悖论。
     - **当备份开启时**：动态显示当前状态机（`● 全部照片已备份` / `↻ 正在扫描并上传 (12/48)...` / `⏸ 等待连接 Wi-Fi` / `⚠ 备份暂停：目标文件夹不存在`），并展示上次成功备份时间与剩余待备份张数。
3. **“备份位置”交互控件修正**：
   - 将“自定义”行的右侧控件改为 **单选指示 + 路径预览 + 右向箭头（`>`）** 组合：当用户点击“自定义”时，清晰传达“将打开 NAS 目录选择器”的预期；选定后在副标题高亮展示完整 NAS 目标路径（如 `/photo/MyPhoneBackup`），并在右侧提供“更改目录”微按钮。

---

### 6.6 统一媒体预览器（Image / Video Preview）

#### 现状问题（参考 `07-photo-preview.png` 与 `ImagePreview.ets`）
- 底部工具栏使用 `HdsTabs` 伪装，语义不正确且宽度固定死为 `224vp`。
- 截图备注提到“图片是否充分延伸至系统状态栏仍未验收”，全屏沉浸态（隐藏控件时连同系统状态栏/导航条一起淡出）尚未闭环。
- 缩放体验：`scaleValue` 在 `onActionEnd` 重置时缺少阻尼回弹动画，且双击仅支持“恢复到 1 倍”，不支持在 1 倍状态下“双击放大到 2.5 倍”。

#### 优化方案
1. **替换为真正的悬浮材质工具栏（Floating Glass Action Capsule）**：
   - 弃用 `HdsTabs` 伪装方案，改用 `Row` 容器配合 `.backgroundEffect({ radius: 40, saturation: 1.5, color: $r('app.color.workbench_glass_surface') })`（或 HDS 原生 `systemMaterialEffect`）构建自适应宽度的悬浮胶囊栏：
     - 每个操作项使用独立 `Button`（`48vp × 48vp`），支持点击水波纹与缩放按压反馈；
     - **收藏按钮**：根据 `isFavorite` 动态切换 `$r('sys.symbol.heart')` 与红色的 `$r('sys.symbol.heart_fill')`，并触发轻触觉震动；
     - **删除按钮**：图标染色为 `$r('app.color.workbench_danger')`，点击弹出底部确认框。
2. **双向双击缩放与物理弹簧回弹**：
   - 修改 `TapGesture({ count: 2 })` 逻辑：当 `this.scaleValue === 1` 时，以用户双击坐标为中心，通过 `animateTo({ curve: curves.springMotion(0.35, 0.8) })` **平滑放大至 `2.5` 倍**；当 `this.scaleValue > 1` 时，双击平滑恢复至 `1.0` 倍并归零偏移量。
   - 新增 **下滑退出预览手势（Pull-down to Dismiss）**：当 `scaleValue === 1` 时，单指垂直向下滑动图片，图片跟随手指缩小并降低背景不透明度，松手后平滑返回相册网格。
3. **全屏沉浸联动系统状态栏**：
   - 当用户单击图片触发 `onToggleControls()` 隐藏顶部标题栏与底部悬浮栏时，同步调用窗口接口 `windowClass.setSpecificSystemBarEnabled('status', false)`（带淡入淡出动画），且背景切换为纯黑 `#000000`，实现真正的零干扰看图体验。

---

### 6.7 全局任务中心与 NAS 远程下载（Download Station）

#### 现状问题（参考 `08`–`12` 截图与 `TaskPage.ets`、`TaskRecordRow.ets`、`DownloadStationPage.ets`）
- **最明显视觉缺陷（`10-task-upload.jpeg`）**：已结束的任务依然显示 100% 蓝色进度条！
- **容器布局问题（`08`–`11`）**：`SubTabBarStyle` 下方直接是一个撑满全屏宽度的白色大容器，与设置页、首页的 `16vp` 边距卡片风格严重不符；`08-task-other.jpeg` 中“下载到 NAS”孤零零地放在这一整页大白板顶部。
- **交互受限**：`TaskPage.ets` L289 设置了 `.scrollable(false).animationDuration(0)`，导致用户无法左右滑动切换“文件下载 / 文件上传 / 文件处理 / 其他”，点击切换也毫无过渡动画。
- **信息架构割裂**：“其他”分类里目前只有一项“下载到 NAS”（`08-task-other.jpeg`），为了一个入口单独占一个顶部分栏显得空洞。
- **NAS 下载认证页（`12-nas-download-auth.jpeg`）**：当需要重新认证时，密码框和提示直接嵌在空列表的 `ListItem` 中，缺乏结构化的认证引导卡片。

#### 优化方案
1. **修复任务行进度条与状态机表达（`TaskRecordRow.ets`）**：
   - **仅在活跃/暂停状态展示进度条**：将进度条显隐条件修改为：
     ```typescript
     .visibility(this.record.progress !== undefined && !taskEnded(this.record.state) ? Visibility.Visible : Visibility.None)
     ```
     注意使用 `Visibility.None`（而非 `Visibility.Hidden`），这样当任务完成后，进度条不仅隐藏，还会释放其占用的垂直高度，让“文件名 + 文件大小/完成时间”紧凑居中排列！
   - **进行中任务增强**：展示 `已传输 / 总大小`（如 `42.5 MB / 128 MB`）的同时，在右侧展示 **实时传输速率与预计剩余时间**（如 `4.2 MB/s · 剩余 20秒`）。
   - **失败任务增强**：进度条变更为红色或隐藏，副标题直接以 `workbench_danger` 红色展示失败原因摘要（如 `上传失败：磁盘空间不足`），右侧主按钮直接变为 **重试图标（`arrow_clockwise`）**。
2. **重构任务页卡片化布局与分栏交互（`TaskPage.ets`）**：
   - 废除全屏通栏大白底，恢复标准 `workbench_background` 页面底色。將“进行中 $N$”和“已结束 $M$”分别渲染为带有 `16vp` 左右边距的圆角卡片组（`borderRadius(16)`），分组标题（`进行中 2` + 右侧 `全部暂停`；`已结束 5` + 右侧 `清理记录`）置于卡片上方或卡片首行。
   - 开启页签滑动与动画：将 `HdsTabs` 的 `.scrollable(true)` 打开，`.animationDuration(300)` 恢复为标准 300ms 阻尼曲线动画。
3. **重构“其他 / 下载到 NAS”信息架构**：
   - **消除空洞的“其他”分栏**：提供带实时活跃任务数统计的丰富功能卡片，加设“相册自动备份队列”快捷入口，彻底消灭 `08-task-other.jpeg` 中整屏只有一个跳转链接的尴尬局面。
4. **NAS 下载重新认证卡片与新建任务优化（`DownloadStationPage.ets`）**：
   - 针对 `12-nas-download-auth.jpeg`，当 `downloadAuthenticationRequired` 为真时，居中渲染一张带锁盾图标的 **结构化认证卡片**：说明为何需要二次认证（如“Download Station 会话已过期，请验证密码以继续管理远程下载任务”），支持一键复用当前登录密码重试。
   - 右下角或顶栏提供醒目的 **`+ 新建下载`** 按钮，半模态支持粘贴 HTTP/FTP/磁力链（Magnet）及选择手机本地 `.torrent` 种子文件，并在选择保存目录时展示该卷的**可用剩余空间**。

---

### 6.8 设置、系统控制与协同子页

#### 现状问题（参考 `13-module-tabs.png` 与 `Index.ets` L1264）
- “设置”页中，“模块底栏”和“登出 NAS”被合并在同一个白色卡片里，且中间**漏掉了 `Divider` 分隔线**（见 `Index.ets` L1281–1286），导致普通设置项与危险的红色“登出 NAS”紧密贴合！
- `13-module-tabs.png`（模块底栏设置）中，顶部提示文本直接裸露在页面上，固定项（如“我的文件”、“照片”）的开关呈灰色禁用态，但未解释为何不可关闭及最多可开启几项。

#### 优化方案
1. **危险操作独立成卡（Destructive Action Isolation）**：
   - 在 `settingsView()` 中，将“模块底栏”、“外观与深浅色模式（新增：跟随系统 / 浅色 / 深色）”、“缓存清理（缩略图与临时预览缓存大小统计及一键清理）”归入 **“应用偏好”** 卡片；
   - 将 **“登出当前 NAS”** 独立拆分到页面最底部的单独圆角卡片（或居中警示胶囊按钮），与上方常规设置项拉开 `24vp` 安全间距，防止误触。
2. **模块底栏配置页（`13-module-tabs.png`）视觉增强**：
   - 在卡片顶部增加微型“底栏实时预览条（Live Preview Bar）”，当用户切换下方开关时，顶部预览条实时带动画增减图标，并显示配额计数徽章（如 `已固定 1 / 2 个扩展视图`）。
   - 对于常驻不可关闭的核心项（如“我的文件”、“照片”、“相册”），右侧不显示灰色的禁用 `Toggle` 开关，而是显示一枚 **`常驻`** 浅色文本标签，避免用户误以为是权限受限导致开关无法点击。

---

## 7. 折叠屏（Pura X / Mate XT）与多端响应式适配

鉴于现有验证截图大量采集自 **Pura X View 模拟器**，且 HarmonyOS 7 强推“一多”体验，建议解除 `module.json5` 仅限 `phone` 的束缚，引入三档响应式断点（`sm`: $<600\text{vp}$，`md`: $600\sim840\text{vp}$，`lg`: $\ge 840\text{vp}$）：

| 屏幕形态与断点 | 导航架构 (`HdsNavigation` / `HdsTabs` / `HdsSideBar`) | 核心页面布局自适应策略 |
| :--- | :--- | :--- |
| **直板机 / 竖向小折叠展开 (`sm`)** | 底部悬浮胶囊 `HdsTabs`（`barFloatingStyle`） + 单栏 `NavigationMode.Stack` | 保持 `16vp` 边距卡片；照片网格默认 4 列；首页指标单列堆叠。 |
| **横向小折叠外屏 / 悬停态 (Pura X 外屏)** | 紧凑底栏或顶部单行胶囊导航 | 登录页与预览工具栏自动收紧垂直间距；媒体预览在半折悬停态（Flex Mode）下，**上半屏显示照片/视频，下半屏显示操作栏与 EXIF 详情面板**。 |
| **大折叠展开 / 平板 (`md` / `lg`)** | 切换为左侧 `HdsSideBar`（启用 API 23+ `scaleContentEnabled: true` 物理微缩放避让） + 双栏 `NavigationMode.Split` | **首页**：双列瀑布流看板（左侧设备与快捷入口，右侧实时遥测与存储池）；<br>**文件/Drive**：左栏目录树/文件列表（40% 宽），右栏文件详情或图片实时预览（60% 宽）；<br>**任务页**：双列卡片网格展示进行中与已结束任务。 |

---

## 8. 动效、触感反馈与无障碍（Accessibility）规范

1. **共享元素一镜到底转场（`geometryTransition`）**：
   - 在照片时间线网格（`PhotoModulePage`）及文件缩略图点击进入 `ImagePreview` 时，为缩略图与大图绑定相同的 `.geometryTransition('media_' + item.id)` 标识，配合 `animateTo({ curve: curves.interpolatingSpring(0, 1, 328, 36) })` 实现鸿蒙 7 原生图库级的一镜到底展开与收起动效。
2. **微交互与触觉反馈（`@kit.SensorServiceKit` `vibrator`）**：
   - 在以下关键节点补充轻量级系统触感反馈（`vibrator.HapticFeedback.EFFECT_SOFT` / `EFFECT_TICK`）：
     - 长按文件/照片触发多选模式的瞬间；
     - 照片预览双指缩放触及 `1.0x` 或 `4.0x` 边界、或双击缩放时；
     - 时间线侧边滑块跨过月份分组节点时。
3. **无障碍（Accessibility）持续巩固**：
   - 保持现有代码中良好的 `.accessibilityText` 习惯；
   - 修复 `ImagePreview` 中 `HdsTabs` 伪装工具栏导致的屏幕朗读角色错误；
   - 为自定义整行单选（`PhotoBackupSettingsPage` 中的 `mode` / `choice` / `layout`）显式声明 `.accessibilitySelected(selected)`，确保屏幕朗读器能准确播报“已选中 / 未选中”状态。

---

## 9. 实施与验收清单

勾选项表示代码已实现；运行证据和外部能力验收分别记录，不能互相替代。

- [x] 深色按压、浮层底色、已结束任务隐藏进度条、分隔线与备份禁用态。
- [x] 照片空间切换、空态上传入口、媒体操作胶囊、双击缩放、全屏系统栏联动与下滑退出。
- [x] 协议提示、分组登录、设备信任凭证、局域网发现及历史登录管理。
- [x] 首页状态摘要、遥测指标圆环、网络速率胶囊及存储水位色。
- [x] 文件与云盘排序、视图切换、面包屑、多选和批量操作。
- [x] 照片 3／4／6 列手势、滑动多选、媒体角标与共享元素标识；日期快滑条按修订取消。
- [x] 备份状态看板、上次成功时间、已知待备份数量和自定义目录入口。
- [x] 任务暂停／继续、速率与剩余时间、失败重试、其他分类整合、全局传输胶囊。
- [x] 系统实况窗调用、下载套件独立认证、本地种子文件提交与目标卷可用空间读取。
- [x] 设置两组主卡片、原生外观菜单、缓存管理、统一底栏开关与配额。
- [x] API 26 调试构建与 977 项回归测试。
- [x] 单栏照片、异常态、更多、底栏配置、设置浅深色、外观菜单、文件和云盘运行画面归档。
- [ ] 物理真机多指手势、触觉及半折姿态验收。
- [ ] 系统实况窗授权、系统回执及点击返回应用验收。
- [ ] 双重验证设备信任与下次登录免验证验收。
- [ ] 真实下载套件种子创建及卷可用空间验收。
- [ ] 双栏与折叠屏后续调整和完整验收，暂缓。
