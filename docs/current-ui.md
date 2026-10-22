# NAS 工作台界面设计与代码汇总

更新日期：2026-10-22。平台为 HarmonyOS 7、API 26、Stage 模型、ArkUI V2，界面采用 UIDesignKit。本文描述当前实现，图片独立存放，以链接查看。

## 当前界面规范

| 项目 | 当前实现 |
| --- | --- |
| 主导航 | 首页、文件、任务、设置；云盘与照片保留各自模块底栏，最多五项 |
| 普通页面 | 16vp 水平边距、16vp 卡片圆角，使用系统语义文字与图标色 |
| 文件与云盘列表 | 连续列表底色，列表模式不使用逐项悬浮卡片；带图标分隔线左缩进 68vp，多选时 104vp |
| 照片网格 | 页面水平边距 0，缩略图圆角 0，格间距 2vp；日期只在列表内显示，15fp 加粗主文字色 |
| 深色按压 | `workbench_pressed = #1FFFFFFF`；弹层使用独立浮层底色 |
| 设置 | 设备管理、应用设置两组主卡片，登出独立成卡；内容底部避让为底栏高度加 28vp |
| 错误呈现 | 整个照片空间读取失败使用居中灰色异常态；任务失败在任务行内展示原因与重试 |
| 二级页面 | 独立导航目的地，隐藏主底栏；安全区由实际窗口与底栏尺寸计算 |

通用组件见 [WorkbenchUi.ets](../entry/src/main/ets/features/workbench/WorkbenchUi.ets)，颜色见 [浅色资源](../entry/src/main/resources/base/element/color.json) 与 [深色资源](../entry/src/main/resources/dark/element/color.json)。

## 登录与连接

地址行提供协议切换与实际连接地址提示；账号、密码、动态验证码使用分组表单。动态码按服务器要求展开，支持信任设备。设备凭证按服务器地址和账号分别存储。

历史登录支持别名、连通性检查与删除；局域网发现使用系统服务发现能力，取得候选地址后验证 NAS 接口，再提供选择。发现结果使用实际服务名和地址，不推断未返回的设备型号。

实现：[Index.ets](../entry/src/main/ets/pages/Index.ets)、[历史地址页面](../entry/src/main/ets/features/connection/ConnectionAddressPage.ets)、[局域网发现](../entry/src/main/ets/features/connection/NasLanDiscovery.ets)、[设备凭证](../entry/src/main/ets/features/connection/TrustedDeviceStore.ets)。

## 首页

首页保留设备名称和连接入口，云盘、照片和下载入口按服务器能力显示。照片入口显示自动备份状态，下载入口在已经读取任务后显示活跃数量。处理器与内存使用环形指标，网络上下行使用方向箭头与速率胶囊，存储占用在 75% 和 90% 两级改变颜色。

实现：[首页与导航](../entry/src/main/ets/pages/Index.ets)、[遥测看板](../entry/src/main/ets/features/telemetry/TelemetryDashboard.ets)。当前测试账号无遥测权限，界面不使用虚构数据补齐。

## 文件与云盘

根目录隐藏重复路径，进入子目录才显示可交互面包屑。排序与列表／网格切换使用紧凑图标按钮；行尾更多按钮使用横向省略号圆圈与 48vp 热区。列表底部显示“共 X 项”，日期按实际时间单位转换。

长按进入多选，顶部显示已选数量；底部提供下载、移动、复制、分享和删除，按能力与选中项决定是否可用。搜索结果中的操作保留原目录归属，异步结果不能覆盖新的浏览上下文。

实现：[FileStationPage.ets](../entry/src/main/ets/features/files/FileStationPage.ets)、[DriveModulePage.ets](../entry/src/main/ets/features/drive/DriveModulePage.ets)、[共享条目组件](../entry/src/main/ets/features/workbench/WorkbenchUi.ets)。

截图：[云盘根目录](ui-complete-images/10-drive-root.jpeg)、[文件根目录](ui-complete-images/11-files-root.jpeg)。

## 照片、相册与共享

照片顶部显式区分个人空间和共享空间，使用上传与多选按钮。照片、相册和共享各页保留自己的浏览上下文。照片列表支持下拉刷新；“更多”页保留备份、传输和底栏设置，移除重复刷新入口。

日期胶囊与右侧自定义日期滑块均已移除。日期保留在内容分组标题中，使用原生自动滚动条；不再重复显示日期或用浮层遮挡照片。

网格支持 3、4、6 列捏合切换与选择状态下的横向滑动选择。视频显示服务返回的时长，收藏显示心形标记，实况照片显示专用图标。没有对应媒体数据时不生成标记。

[PhotoModulePage.ets](../entry/src/main/ets/features/photos/PhotoModulePage.ets) 的网格布局摘录：

```typescript
Text(row.item.title).fontSize(15).fontWeight(FontWeight.Bold)
  .fontColor($r('sys.color.font_primary')).width('100%')
  .padding({ top: 12, bottom: 4, left: 16, right: 16 })
Row({ space: 2 }) {
  ForEach(row.item.items, (item: NasPhotoItem): void => { this.photoCard(item) },
    (item: NasPhotoItem): string => item.space.toString() + ':' + item.id.toString())
}
```

空间不可用时，显示居中灰色图标、标题、原因和一个“重试读取”按钮。读取失败时不继续混显上一空间的列表。

截图：[照片列表](ui-complete-images/01-photos.jpeg)、[共享空间异常](ui-complete-images/02-photos-space-unavailable.jpeg)、[照片更多](ui-complete-images/06-photos-more.jpeg)。

## 媒体预览

照片、云盘和文件预览复用 [ImagePreview.ets](../entry/src/main/ets/features/workbench/ImagePreview.ets)。操作栏使用独立按钮组成的浮动胶囊，分享、收藏、信息、删除保持各自按钮语义。照片缩略图与预览图使用相同共享元素标识。

双击围绕点击位置在 1 倍与 2.5 倍之间切换；缩回时归零平移。单击切换控件，隐藏时使用纯黑背景并同步隐藏系统栏。正常比例下向下拖动可退出，退出时恢复系统栏与窗口布局。

```typescript
const nextScale = this.scaleValue > 1 ? 1 : 2.5;
this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 228, 30) }, (): void => {
  if (nextScale === 1) {
    this.resetView();
  } else {
    this.scaleValue = nextScale;
    this.offsetX = (this.viewWidth / 2 - event.fingerList[0].localX) * (nextScale - 1);
    this.offsetY = (this.viewHeight / 2 - event.fingerList[0].localY) * (nextScale - 1);
  }
});
```

系统栏联动位于 [Index.ets](../entry/src/main/ets/pages/Index.ets)：

```typescript
await mainWindow.setSpecificSystemBarEnabled('status', visible, true);
await mainWindow.setSpecificSystemBarEnabled('navigation', visible, true);
await mainWindow.setSpecificSystemBarEnabled('navigationIndicator', visible, true);
await mainWindow.setWindowLayoutFullScreen(opened || this.normalWindowFullScreen);
```

使用风景照片实测了双击放大、再次双击还原、全屏切换和下滑退出；退出后系统栏恢复。截图：[全屏风景照片](ui-complete-images/03-photo-fullscreen.jpeg)、[下滑退出后的列表](ui-complete-images/04-photo-dismiss.jpeg)。浅色预览标题按钮已明确设置语义前景色，最后一版颜色修正通过构建，尚未补拍最终画面。

## 自动备份

备份看板展示启停状态、已知待备份数量及上次成功时间。关闭备份时，下方配置组降低透明度并禁用；自定义目录保留路径和跳转箭头，支持更改目录。实际滚动容器保留弹性回弹与标题栏安全区延伸。

手动选择照片始终作为上传任务，不改写自动备份策略或备份统计。暂停自动备份的条件变化不会擅自恢复用户手动暂停的任务。

实现：[PhotoBackupSettingsPage.ets](../entry/src/main/ets/features/backup/PhotoBackupSettingsPage.ets)、[AutomaticPhotoBackup.ets](../entry/src/main/ets/features/backup/AutomaticPhotoBackup.ets)、[TransferQueue.ets](../entry/src/main/ets/features/transfers/TransferQueue.ets)。

## 任务与远程下载

任务按下载、上传、处理和其他分类；分类支持滑动与动画。进行中和已结束使用卡片分组，提供全部暂停／继续、清理记录。其他分类整合远程下载和相册备份入口。

任务仅在未结束且存在进度时显示进度条。速率来自传输字节变化采样，剩余时间只在总量、进度与正速率均已知时计算。失败原因在任务行内展示，支持重试的任务显示重试按钮。

[TaskRecordRow.ets](../entry/src/main/ets/features/tasks/TaskRecordRow.ets) 摘录：

```typescript
@Computed
private get hasProgress(): boolean {
  return this.record.progress !== undefined && !taskEnded(this.record.state);
}
```

全局传输胶囊显示实际活跃数量，可进入统一任务列表。系统实况窗通过 [TransferLiveView.ets](../entry/src/main/ets/features/tasks/TransferLiveView.ets) 串行创建、更新和结束；权限或业务回执失败会显示错误，不作为系统展示成功。

远程下载支持链接与本地种子文件，种子由系统文件选择器取得并复制到私有临时位置后提交。目标目录显示服务器返回的卷可用空间。下载套件使用独立会话，旧上传响应不能使重新认证后的新会话失效。

实现：[NasExtensionsModel.ets](../entry/src/main/ets/features/extensions/NasExtensionsModel.ets)、[DownloadStationPage.ets](../entry/src/main/ets/features/downloadStation/DownloadStationPage.ets)、[NasConnector.ts](../entry/src/main/ets/core/network/NasConnector.ts)。

## 设置与底栏配置

设备管理卡片包含设备信息、历史登录和系统控制；应用设置卡片包含模块底栏、外观和缓存管理。外观行右侧显示当前值，点击显示原生单选菜单。缓存清理仅释放媒体缩略图和临时预览文件，保留账号与传输源文件。

模块底栏配置移除模拟预览条，标题右侧显示“已启用 N / 5”。所有项目统一使用开关；常驻项保持选中并禁用。普通设置行分隔线左缩进 68vp，纯文字开关行左缩进 16vp。

外观菜单摘录：

```typescript
WorkbenchActionRow({ icon: $r('sys.symbol.moon'), label: this.previewText($r('app.string.appearance_title')),
  value: this.appearanceLabel(this.preferences.appearance), available: !this.preferences.busy,
  onAction: (): void => { this.appearanceMenuVisible = true; } })
  .bindMenu(this.appearanceMenuVisible, this.appearanceMenu(), {
    onDisappear: (): void => { this.appearanceMenuVisible = false; } })
```

实现：[Index.ets](../entry/src/main/ets/pages/Index.ets)、[WorkbenchSettings.ets](../entry/src/main/ets/features/workbench/WorkbenchSettings.ets)。

截图：[底栏配置](ui-complete-images/05-module-tabs.jpeg)、[设置浅色](ui-complete-images/07-settings.jpeg)、[外观菜单](ui-complete-images/08-appearance-menu.jpeg)、[设置深色](ui-complete-images/09-settings-dark.jpeg)。已实测外观切换，登出卡片完整露出且不被底栏遮挡。

## 验证范围

| 证据层级 | 结果与边界 |
| --- | --- |
| 编译 | DevEco API 26 调试构建通过，生成签名安装包 |
| 自动化回归 | 977 项测试通过，失败 0；覆盖协议、队列、暂停、速率、种子上传会话竞态和实况窗异步回执 |
| 当前单栏运行截图 | Pura X View 模拟器，1320 × 2232；本页链接的 11 张截图为实际运行画面，图片未修改 |
| 真实 NAS | 照片列表、风景照片预览、云盘与文件目录读取已运行；共享空间读取受当前套件能力限制，已确认异常态呈现 |
| 设备与权限 | 无物理真机验收；双指手势、触觉、半折姿态、系统实况窗授权与点击回到应用、双重验证免验证凭证仍需对应环境验收 |
| 下载套件 | 种子提交与卷空间读取已有实现和协议／模型验证，当前账号未提供可用于新建任务的下载套件能力，未声称真实创建成功 |
| 双栏与折叠布局 | 已有响应式代码，暂缓继续调整与验收，不计入本轮完成验收项 |
| 最终安装 | 最后一次界面运行验证后，模拟器连接断开；最终的月份代码收敛、种子竞态和宽屏空态修正已通过构建与测试，未重新安装验收 |

历史图片保留在 [current-ui-images](current-ui-images/) 与 [ui-phase-one-images](ui-phase-one-images/)，仅作旧版对照；不代替当前实现截图。设计方案的状态与调整见 [7_nas_ui_ux_design.md](7_nas_ui_ux_design.md)。
