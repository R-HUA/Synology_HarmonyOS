import { common } from '@kit.AbilityKit';
import { LengthMetrics, SymbolGlyphModifier, uiMaterial, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileUri } from '@kit.CoreFileKit';
import { HdsNavigation, HdsNavigationTitleMode, HdsNavDestination, HdsTabs, HdsTabsController, hdsMaterial, IconStyleMode, ScrollEffectType, TextStyleMode, HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { NasFailure, NasFileEntry } from '../core/domain/DsmProtocol';
import { DriveEntry, DriveView, driveViewLabel } from '../core/domain/DriveProtocol';
import { DriveTransferRecord } from '../core/domain/DriveTransferState';
import { DriveTransferSummary, DriveTransferCard } from '../features/drive/DriveTransferUi';
import type { DriveAction } from '../core/domain/DriveActionProtocol';
import type { DriveActionRecord } from '../core/domain/DriveActionState';
import { DriveActionPage, DriveActionSummary, DriveActionCard } from '../features/drive/DriveActionUi';
import { DriveOriginalPage } from '../features/drive/DriveOriginalUi';
import { takeDriveTransferIntent } from '../features/drive/DriveTransferIntent';
import { DriveSharingPage, DriveNotificationsPage } from '../features/drive/DriveCollaborationUi';
import { NasPhotoItem, PhotosSpace } from '../core/domain/PhotosProtocol';
import { PhotoBackup } from '../features/backup/PhotoBackup';
import { TransferUploadSource } from '../features/transfers/TransferQueue';
import { TransferQueueItem } from '../core/domain/TransferQueueState';
import { ConnectionViewModel, FileTaskItem } from '../features/connection/ConnectionViewModel';
import { NasConnectionAddressPage } from '../features/connection/ConnectionAddressPage';
import { NasConnectionAddress } from '../core/domain/ConnectionRoutes';
import { NasSystemControlPage } from '../features/control/SystemControlPage';
import { ShareLinksPage } from '../features/fileSharing/ShareLinksPage';
import { DownloadStationPage } from '../features/downloadStation/DownloadStationPage';
import { NasTelemetrySummary, NasTelemetryStorageCard, NasTelemetryDashboard } from '../features/telemetry/TelemetryDashboard';
import { photoTakenDate, photoMediaLabel, workbenchBytes,
  workbenchCanUseDestination, workbenchBottomInset, workbenchShortcutColumns,
  connectionRouteLabel } from '../features/workbench/WorkbenchPresentation';
import { bundledDeviceArtwork, fallbackDeviceArtwork, hasModelArtwork, deviceArtworkPath } from '../features/workbench/NasDeviceArtwork';

import { WorkbenchMetrics, WorkbenchIconTile, WorkbenchSectionTitle, WorkbenchInfoRow, WorkbenchNotice, WorkbenchChoice, WorkbenchActionRow } from '../features/workbench/WorkbenchUi';

import { ModuleTab, WorkbenchModule, ModuleTabSettings, rootTabs, driveTabs, driveMoreViews, photoTabs,
  moduleTabIndex, rootReturnIndex, ROOT_TASK_TAB, ROOT_SETTINGS_TAB, DRIVE_MORE_VIEWS, supportsPhotoSharing } from '../features/workbench/ModuleNavigation';
import { ModuleTabStore } from '../features/workbench/ModuleTabStore';
import { FileStationPage } from '../features/files/FileStationPage';
import { DriveModulePage } from '../features/drive/DriveModulePage';
import { PhotoModulePage } from '../features/photos/PhotoModulePage';
import type { PhotoLibrarySection } from '../features/photos/PhotoLibrary';

@Entry
@ComponentV2
struct Index {
  @Local private model: ConnectionViewModel = new ConnectionViewModel();
  @Local private activeTab: number = 0;
  @Local private module: WorkbenchModule = 'root';
  @Local private rootTab: number = 0;
  @Local private driveTabId: string = 'mydrive';
  @Local private photoTabId: string = 'photos';
  @Local private driveMoreView: string = '';
  @Local private driveSearchVisible: boolean = false;
  @Local private photoMoreShared: boolean = false;
  @Local private photoSpace: PhotosSpace = PhotosSpace.Personal;
  @Local private albumSpace: PhotosSpace = PhotosSpace.Personal;
  @Local private sharedSpace: PhotosSpace = PhotosSpace.Shared;
  @Local private drivePinned: string[] = [];
  @Local private photoPinned: string[] = [];
  @Local private showPhotoShared: boolean = true;
  @Local private tabSettingsReady: boolean = false;
  @Local private tabSettingsBusy: boolean = false;
  @Local private tabSettingsError: string = '';
  private tabStore: ModuleTabStore = new ModuleTabStore();
  @Local private pickerMode: string = '';
  @Local private navigationInset: number = 0;
  @Local private statusInset: number = 0;
  /** 启动恢复期间只呈现加载页；恢复结束后才显示登录表单或主界面。 */
  @Local private bootPending: boolean = true;
  @Local private bootEscapable: boolean = false;
  private bootTimer: number = -1;
  private mainWindow: window.Window | undefined = undefined;
  private pageActive: boolean = false;
  private foreground: boolean = true;
  private abilityContext: common.UIAbilityContext | undefined = undefined;
  @Local private telemetryOpened: boolean = false;
  @Local private addressBookOpened: boolean = false;
  @Local private systemControlOpened: boolean = false;
  @Local private extensionsOpened: boolean = false;
  @Local private downloadsVisible: boolean = false;
  /** 半模态内容滚动控制器：既供嵌套滚动使用，也绑定给 HDS 半模态标题栏。 */
  private sheetScroller: Scroller = new Scroller();
  private sharesScroller: Scroller = new Scroller();
  private downloadsScroller: Scroller = new Scroller();
  private telemetryScroller: Scroller = new Scroller();
  private addressBookScroller: Scroller = new Scroller();
  private systemControlScroller: Scroller = new Scroller();
  private driveActionScroller: Scroller = new Scroller();
  private driveLinksScroller: Scroller = new Scroller();
  private driveNotificationsScroller: Scroller = new Scroller();
  private transferNotificationOpened = (): void => { if (takeDriveTransferIntent()) { this.openDriveTransfers(); } };
  private foregroundChanged = (foreground: boolean): void => {
    this.foreground = foreground;
    this.model.driveTransfers.setForeground(foreground);
    this.model.driveThumbnails.setForeground(foreground);
    this.model.driveActions.setForeground(foreground);
    this.model.driveOriginal.setForeground(foreground);
    this.model.driveSharing.setForeground(foreground);
    if (!foreground) { this.model.addressBook.cancelProbe(); this.model.systemControl.deactivate(); }
    else if (this.systemControlOpened) { this.model.openSystemControl(); }
    this.updateTelemetryMode();
  };
  private navigationAreaChanged = (options: window.AvoidAreaOptions): void => {
    if (options.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
      this.navigationInset = this.getUIContext().px2vp(options.area.bottomRect.height);
    } else if (options.type === window.AvoidAreaType.TYPE_SYSTEM) {
      this.statusInset = this.getUIContext().px2vp(options.area.topRect.height);
    }
  };
  @Local private sheetVisible: boolean = false;
  @Local private sheetKind: string = 'detail';
  @Local private selectedEntry: NasFileEntry | undefined = undefined;
  @Local private formName: string = '';
  @Local private formSubmitting: boolean = false;
  @Local private pendingEntry: NasFileEntry | undefined = undefined;
  @Local private pendingOperation: string = '';
  @Local private transferSubmitting: boolean = false;
  @Local private transferErrorText: string = '';
  @Local private backup: PhotoBackup = new PhotoBackup();
  @Local private photosInitialized: boolean = false;
  @Local private contentWidth: number = 360;
  @Local private windowWidth: number = 360;
  @Local private windowHeight: number = 800;
  @Local private deviceInfo: string[] = [];
  @Local private selectedTaskId: string = '';
  @Local private taskFilter: string = 'all';
  /**
   * 半模态背板的沉浸式系统材质。官方《开启沉浸光感》给半模态/弹窗的推荐档位就是 ULTRA_THICK。
   * 注意材质层在 backgroundColor 之下，所以背板要设成透明色，否则材质被不透明背景盖住看不见。
   */
  private sheetMaterial: uiMaterial.Material =
    new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THICK });
  /** 设备是否支持 ImmersiveMaterial；不支持时退回不透明背板，避免得到一块全透明的弹层。 */
  private sheetMaterialAvailable: boolean = uiMaterial.isImmersiveMaterialSupported();
  @Local private taskSection: string = 'transfers';
  @Local private mediaDecodeFailed: boolean = false;
  /** 未收录型号联网取回的产品图路径；为空时用内置图。 */
  @Local private deviceArtworkPath: string = '';
  private readonly artworkSize: number = 64;
  private navStack: NavPathStack = new NavPathStack();
  private homeScroller: Scroller = new Scroller();
  private filesScroller: Scroller = new Scroller();
  private driveScrollers: Scroller[] = [new Scroller(), new Scroller(), new Scroller(), new Scroller(),
    new Scroller(), new Scroller(), new Scroller(), new Scroller()];
  private photoScrollers: Scroller[] = [new Scroller(), new Scroller(), new Scroller(), new Scroller(), new Scroller(), new Scroller()];
  private settingsScroller: Scroller = new Scroller();
  private tabSettingsScroller: Scroller = new Scroller();
  private pickerScroller: Scroller = new Scroller();
  private tasksScroller: Scroller = new Scroller();
  private detailScroller: Scroller = new Scroller();
  private tabsController: HdsTabsController = new HdsTabsController();

  aboutToAppear(): void {
    this.pageActive = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.abilityContext = context;
    this.loadTabSettings();
    context.eventHub.on('nas-foreground-change', this.foregroundChanged);
    context.eventHub.on('nas-open-drive-transfers', this.transferNotificationOpened);
    this.transferNotificationOpened();
    this.updateTelemetryMode();
    this.restoreSession(context);
    window.getLastWindow(context).then((mainWindow: window.Window): void => {
      if (!this.pageActive) { return; }
      this.mainWindow = mainWindow;
      this.navigationInset = this.getUIContext().px2vp(mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height);
      this.statusInset = this.getUIContext().px2vp(mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height);
      mainWindow.on('avoidAreaChange', this.navigationAreaChanged);
    }).catch((): void => { hilog.error(0x0000, 'NasLayout', 'operation=navigation_avoid_area result=failed'); });
  }
  aboutToDisappear(): void {
    this.pageActive = false;
    this.stopBootTimer();
    this.updateTelemetryMode();
    this.abilityContext?.eventHub.off('nas-foreground-change', this.foregroundChanged);
    this.abilityContext?.eventHub.off('nas-open-drive-transfers', this.transferNotificationOpened);
    this.abilityContext = undefined;
    this.mainWindow?.off('avoidAreaChange', this.navigationAreaChanged);
    this.mainWindow = undefined;
    this.backup.reset();
    this.model.dispose();
  }

  /** 启动先恢复上次会话；期间用户只看到加载页，不会先看到登录表单。 */
  private async restoreSession(context: common.UIAbilityContext): Promise<void> {
    this.bootEscapable = false;
    if (this.bootTimer === -1) { this.bootTimer = setTimeout((): void => { this.bootEscapable = true; }, 3000); }
    try { await this.model.restore(context); }
    finally {
      this.stopBootTimer();
      if (this.pageActive) { this.bootPending = false; this.bootEscapable = false; }
    }
  }

  private stopBootTimer(): void {
    if (this.bootTimer !== -1) { clearTimeout(this.bootTimer); this.bootTimer = -1; }
  }

  private leaveBootScreen(): void {
    this.stopBootTimer();
    this.model.cancelRestore();
    this.bootPending = false;
    this.bootEscapable = false;
  }

  onBackPress(): boolean {
    if (this.bootPending) { this.leaveBootScreen(); return true; }
    if (this.sheetVisible) { if (!this.formSubmitting && !this.backup.submitting) { this.sheetVisible = false; } return true; }
    if (this.navStack.size() > 0) {
      if (this.pickerMode.length > 0 && this.navStack.getAllPathName().slice(-1)[0] === 'directory-picker') {
        if (this.backup.submitting) { return true; }
        if (this.model.directory.length > 0) { if (!this.model.busy) { this.model.goBack(); } return true; }
        this.cancelDirectoryPicker(); return true;
      }
      this.navStack.pop(); return true;
    }
    if (this.module === 'root' && this.activeTab === 1 && this.pendingEntry !== undefined) { this.pendingEntry = undefined; this.pendingOperation = ''; return true; }
    if (this.model.authenticated && this.module === 'drive') {
      if (this.driveViewMatches() && this.model.drive.trail.length > 1 && this.model.drive.canGoUp()) { if (!this.model.drive.busy) { this.model.drive.goUp(); } return true; }
      if (this.driveTabId === 'mydrive' && (this.driveSearchVisible || this.model.drive.view === DriveView.Search)) {
        if (!this.model.drive.busy) { this.exitDriveSearch(); } return true;
      }
      if (this.driveTabId === 'more' && this.driveMoreView.length > 0) { this.backToDriveMore(); return true; }
      this.exitModule(); return true;
    }
    if (this.model.authenticated && this.module === 'photos') {
      if (this.model.photoLibrary.selectedAlbum !== undefined && ['photos', 'albums', 'shared'].includes(this.effectivePhotoTab())) {
        if (!this.model.photoLibrary.busy) { this.model.photoLibrary.backToLibrary(); } return true;
      }
      if (this.photoMoreShared && this.photoTabId === 'more') { this.photoMoreShared = false; return true; }
      this.exitModule(); return true;
    }
    if (this.model.authenticated && this.activeTab === 1 && this.model.directory.length > 0) {
      if (!this.model.busy) { this.model.goBack(); } return true;
    }
    if (this.model.authenticated && this.activeTab !== 0) { this.switchTab(0); return true; }
    return false;
  }

  @Monitor('model.authenticated')
  private authenticationChanged(): void {
    this.updateTelemetryMode();
    if (!this.model.authenticated) {
      this.module = 'root'; this.rootTab = 0;
      this.driveTabId = 'mydrive'; this.photoTabId = 'photos';
      this.driveMoreView = ''; this.driveSearchVisible = false; this.photoMoreShared = false;
      this.photoSpace = PhotosSpace.Personal; this.albumSpace = PhotosSpace.Personal; this.sharedSpace = PhotosSpace.Shared;
      this.backup.reset();
      this.pickerMode = '';
      this.extensionsOpened = false; this.downloadsVisible = false;
      this.photosInitialized = false;
      this.taskSection = 'transfers';
      this.taskFilter = 'all';
      this.navStack.clear();
      this.sheetVisible = false;
      this.selectedEntry = undefined;
      this.selectedTaskId = '';
      this.deviceInfo = [];
      this.pendingEntry = undefined;
      this.pendingOperation = '';
      this.formName = '';
      this.transferErrorText = '';
      this.deviceArtworkPath = '';
      this.activeTab = 0;
      this.tabsController.changeIndex(0);
    }
  }

  @Monitor('model.busy')
  private pageLoadFinished(): void {
    if (!this.model.busy && this.model.authenticated && this.module === 'photos') { this.ensurePhotosOpen(); }
  }

  @Monitor('model.deviceModel')
  private deviceModelChanged(): void { this.resolveDeviceArtwork(); }

  /** 连接方式文案：优先用地址簿登记的类型，否则按地址判断内网/公网。 */
  private routeLabel(): string {
    const saved = this.model.addressBook.addresses.find((address: NasConnectionAddress): boolean =>
      address.origin === this.model.address);
    return connectionRouteLabel(this.model.address, saved?.kind);
  }

  /** 未收录的型号才联网取官方产品图；取不到就保持内置图，不报错、不占位闪烁。 */
  private async resolveDeviceArtwork(): Promise<void> {
    const model = this.model.deviceModel;
    this.deviceArtworkPath = '';
    const context = this.abilityContext;
    if (context === undefined || model.length === 0) { return; }
    const path = await deviceArtworkPath(context, model);
    if (this.pageActive && this.model.deviceModel === model && path.length > 0) { this.deviceArtworkPath = path; }
  }

  private pageTitle(): string {
    if (!this.model.authenticated) { return 'NAS 工作台'; }
    if (this.module === 'drive') { return 'Synology Drive'; }
    if (this.module === 'photos') { return this.photoTabId === 'transfers' ? '照片传输' : '照片'; }
    return rootTabs()[this.activeTab].label;
  }

  @Monitor('module', 'activeTab', 'taskSection')
  private activeTabChanged(): void {
    this.updateTelemetryMode();
  }

  private updateTelemetryMode(): void {
    this.model.driveActions.setPolling(this.pageActive && this.foreground && this.model.authenticated &&
      this.module === 'root' && this.activeTab === ROOT_TASK_TAB && this.taskSection === 'drive-actions' && this.navStack.size() === 0);
    this.model.telemetry.setMode(!this.pageActive || !this.foreground || !this.model.authenticated || this.addressBookOpened || this.systemControlOpened || this.extensionsOpened ? 'hidden' :
      this.telemetryOpened ? 'detail' : this.module === 'root' && this.activeTab === 0 ? 'home' : 'hidden');
  }

  private ensurePhotosOpen(): void {
    const id = this.effectivePhotoTab();
    if (this.module !== 'photos' || !['photos', 'albums', 'shared'].includes(id) || this.model.busy || this.model.photoLibrary.busy) { return; }
    const space = this.expectedPhotoSpace(id);
    const section = this.expectedPhotoSection(id, space);
    if (!this.photosInitialized || this.model.photoLibrary.space !== space || this.model.photoLibrary.section !== section ||
      this.model.photoLibrary.selectedAlbum !== undefined && id === 'photos' && space !== PhotosSpace.WithMe) {
      this.photosInitialized = true;
      this.model.photoLibrary.open(space, section);
    }
  }

  private switchTab(index: number): void {
    this.module = 'root'; this.activeTab = rootReturnIndex(index); this.rootTab = this.activeTab;
    this.tabsController.changeIndex(this.activeTab);
    this.updateTelemetryMode();
  }

  private supportsPhotos(): boolean {
    return this.model.supports('SYNO.Foto.Browse.Item') || this.model.supports('SYNO.FotoTeam.Browse.Item') ||
      this.model.supports('SYNO.Foto.Sharing.Misc');
  }

  /** 首页「资源监控」与「存储空间」卡片整卡可点，进入同一张只读监控详情页。 */
  private openTelemetry(): void {
    this.navStack.pushPath({ name: 'telemetry' });
  }

  private openNasDownloads(): void {
    if (this.model.extensions.downloadDestination.length === 0 && this.model.directory.length > 0) {
      this.model.extensions.downloadDestination = this.model.directory.slice(1);
    }
    this.navStack.pushPathByName('nas-downloads', undefined);
  }

  private chooseDownloadDirectory(): void {
    if (this.model.busy || this.model.drive.busy) { return; }
    this.model.extensions.downloadFormRequested = true;
    this.pickerMode = 'download';
    this.navStack.pushPathByName('directory-picker', 'download');
  }

  private useDownloadDirectory(): void {
    if (this.model.busy || this.model.directory.length === 0) { return; }
    this.model.extensions.downloadDestination = this.model.directory.slice(1);
    this.pickerMode = ''; this.navStack.pop();
  }

  private activeScrollers(): Scroller[] {
    if (!this.model.authenticated) { return [this.homeScroller]; }
    if (this.module === 'drive') { return [this.driveScrollerFor(this.driveTabId)]; }
    if (this.module === 'photos') { return [this.photoTabId === 'transfers' ? this.tasksScroller : this.photoScrollerFor(this.photoTabId)]; }
    return [this.activeTab === 1 ? this.filesScroller : this.activeTab === ROOT_TASK_TAB ? this.tasksScroller :
      this.activeTab === ROOT_SETTINGS_TAB ? this.settingsScroller : this.homeScroller];
  }

  private openPhoto(item: NasPhotoItem): void {
    this.mediaDecodeFailed = false;
    this.model.photoLibrary.openDetail(item);
    this.navStack.pushPathByName('photo-detail', item.id);
  }

  private async selectBackup(): Promise<void> {
    await this.backup.select(this.getUIContext().getHostContext() as common.UIAbilityContext, this.model.queue);
  }

  private async submitBackup(): Promise<void> {
    if (this.model.directory.length === 0 || !this.model.queue.ready || this.model.busy) { return; }
    await this.backup.submit(this.model.directory, this.model.queue);
    if (this.backup.sources.length === 0) {
      this.pickerMode = ''; this.navStack.pop(); this.taskSection = 'transfers'; this.switchTab(ROOT_TASK_TAB);
    }
  }

  private filteredTasks(): TransferQueueItem[] {
    return this.model.queue.items.filter((item: TransferQueueItem): boolean => this.taskFilter === 'all' ||
      (this.taskFilter === 'finished' ? ['completed', 'cancelled', 'failed', 'closed', 'clearing'].includes(item.state) :
        !['completed', 'cancelled', 'failed', 'closed', 'clearing'].includes(item.state)));
  }

  private showDeviceInfo(): void {
    this.deviceInfo = [];
    this.openForm('device');
    this.model.serverInfo().then((info: string): void => {
      if (info.length > 0 && this.model.authenticated) { this.deviceInfo = info.split('\n'); }
    });
  }

  private bottomInset(): number {
    return workbenchBottomInset(this.navigationInset);
  }

  /** 内容区延伸到标题栏之下，首项需要让出状态栏与单行标题栏的高度。 */
  private contentTopInset(): number {
    return this.statusInset + 56;
  }

  /** 未登录时隐藏了标题栏，顶部只需让出状态栏。 */
  private loginTopInset(): number {
    return this.statusInset + 8;
  }

  /** 登录页没有悬浮页签，底部不必预留页签高度。 */
  private loginBottomInset(): number {
    return Math.max(0, this.navigationInset) + 16;
  }

  /**
   * 登录页内容的居中基准：视口高度。内容比它矮时被居中，比它高时自动撑开并可滚动，
   * 键盘顶起窗口后仍然成立。
   */
  private loginMinHeight(): number {
    return Math.max(0, this.windowHeight - this.loginTopInset() - this.loginBottomInset());
  }

  private selectedTask(): TransferQueueItem | undefined {
    return this.model.queue.items.find((item: TransferQueueItem): boolean => item.id === this.selectedTaskId);
  }

  private openTask(item: TransferQueueItem): void {
    this.selectedTaskId = item.id;
    this.openForm('task');
  }

  private confirmLogout(): void {
    this.getUIContext().showAlertDialog({ title: '登出 NAS',
      message: '将结束当前账号的连接并停止该账号的传输任务。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '登出', action: (): void => { this.model.disconnect(); } } });
  }

  private openConnectionAddresses(): void {
    if (this.model.busy) { return; }
    const saved = this.model.addressBook.addresses.find((address: NasConnectionAddress): boolean => address.origin === this.model.address);
    this.model.addressBook.beginDraft(this.model.address, saved?.name ?? (this.model.authenticated ? '我的 NAS' : ''),
      saved?.kind ?? 'lan', saved?.insecureTls === true);
    this.navStack.pushPath({ name: 'connection-addresses' });
  }

  private confirmUseAddress(address: NasConnectionAddress): void {
    if (this.model.busy || this.model.addressBook.busy || this.model.addressBook.probing) { return; }
    const apply = (): void => {
      this.model.useSavedAddress(address.origin).then((applied: boolean): void => {
        if (applied) { this.navStack.clear(); }
      });
    };
    if (!this.model.authenticated && !this.model.savedSession && !this.model.connected) { apply(); return; }
    if (this.model.authenticated && this.model.address === address.origin) { this.navStack.pop(); return; }
    this.getUIContext().showAlertDialog({ title: '切换连接地址',
      message: '切换会停止本机传输并清除当前登录。上传结果不确定时将保留待核对状态。新地址需要重新登录，文件和任务记录不会迁移。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '切换', action: apply } });
  }

  private openForm(kind: string, entry?: NasFileEntry): void {
    this.selectedEntry = entry;
    this.sheetKind = kind;
    this.formName = kind === 'rename' && entry !== undefined ? entry.name : '';
    this.sheetVisible = true;
  }

  private sheetTitle(): string {
    if (this.sheetKind === 'create') { return '新建文件夹'; }
    if (this.sheetKind === 'rename') { return '重命名'; }
    if (this.sheetKind === 'sort') { return '排序'; }
    if (this.sheetKind === 'file-add') { return '上传与新建'; }
    if (this.sheetKind === 'file-tools') { return '文件'; }
    if (this.sheetKind === 'backup') { return '备份内容'; }
    if (this.sheetKind === 'device') { return '设备信息'; }
    if (this.sheetKind === 'actions') { return '文件操作'; }
    if (this.sheetKind === 'task') { return '任务详情'; }
    return '文件详情';
  }

  /**
   * 只有内容可能很长、用 SheetSize.LARGE 的弹层才挂 HDS 半模态标题栏：
   * HdsNavigation 需要有确定高度，FIT_CONTENT 的小弹层给不出来。
   */
  private sheetUsesModalTitleBar(): boolean {
    return this.sheetKind === 'device' || this.sheetKind === 'task' || this.sheetKind === 'backup';
  }

  /** 连接方式按当前实际连接策略呈现，避免 http 连接被写死成“HTTPS 安全连接”。 */
  private connectionSecurityText(): string {
    if (!this.model.useHttps) { return 'HTTP 明文连接'; }
    return this.model.insecureTls ? 'HTTPS 未校验证书' : 'HTTPS 安全连接';
  }

  private validName(): boolean {
    return this.formName.trim().length > 0 && this.formName !== '.' && this.formName !== '..' &&
      !/[\/:\\\u0000-\u001f\u007f]/.test(this.formName) &&
      (this.sheetKind !== 'rename' || this.formName !== this.selectedEntry?.name);
  }

  private async submitName(): Promise<void> {
    if (!this.validName() || this.formSubmitting || this.model.busy) { return; }
    this.formSubmitting = true;
    try {
      const result = this.sheetKind === 'create' ? await this.model.createFolder(this.formName) :
        this.selectedEntry !== undefined ? await this.model.renameEntry(this.selectedEntry, this.formName) : 'failed';
      if (result === 'completed') { this.sheetVisible = false; }
    } finally { this.formSubmitting = false; }
  }

  private confirmDelete(entry: NasFileEntry): void {
    this.getUIContext().showAlertDialog({ title: entry.isDirectory ? '删除文件夹' : '删除文件',
      message: '确认删除“' + entry.name + '”？' + (entry.isDirectory ? '文件夹内的内容也会被删除。' : ''),
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', action: (): void => {
        this.sheetVisible = false;
        this.model.deleteEntry(entry).then((result): void => { if (result === 'pending') { this.taskSection = 'files'; this.switchTab(ROOT_TASK_TAB); } });
      } } });
  }

  private async navigateBreadcrumb(path: string): Promise<void> {
    while (!this.model.busy && this.model.directory !== path && this.model.directory.length > 0) {
      const previousPath = this.model.directory;
      await this.model.goBack();
      if (this.model.directory === previousPath) { break; }
    }
  }

  private chooseDestination(entry: NasFileEntry, operation: string): void {
    this.sheetVisible = false;
    this.pendingEntry = entry;
    this.pendingOperation = operation;
  }

  private destinationAllowed(): boolean {
    const entry = this.pendingEntry;
    return entry !== undefined && workbenchCanUseDestination(entry.path, entry.isDirectory, this.model.directory);
  }

  private async applyDestination(): Promise<void> {
    const entry = this.pendingEntry;
    if (entry === undefined || this.model.busy || !this.destinationAllowed()) { return; }
    const result = this.pendingOperation === 'copy' ? await this.model.copyEntry(entry, this.model.directory) :
      await this.model.moveEntry(entry, this.model.directory);
    if (result !== 'failed') { this.pendingEntry = undefined; this.pendingOperation = ''; }
    if (result === 'pending') { this.taskSection = 'files'; this.switchTab(ROOT_TASK_TAB); }
  }

  private sortLabel(): string {
    const field = this.model.fileSort === 'size' ? '大小' : this.model.fileSort === 'mtime' ? '修改时间' : '名称';
    return field + (this.model.sortDescending ? ' · 降序' : ' · 升序');
  }


  private async runTransfer(action: () => Promise<void>): Promise<void> {
    if (this.transferSubmitting || this.model.queue.busy || this.model.busy) { return; }
    this.transferSubmitting = true;
    this.transferErrorText = '';
    try { await action(); }
    catch (error) {
      this.transferErrorText = this.model.queue.errorText.length > 0 ? this.model.queue.errorText :
        error instanceof NasFailure ? error.message : '传输操作未完成，请在任务页核对。';
    } finally { this.transferSubmitting = false; }
  }

  private visibleError(): string {
    if (this.module === 'drive') { return this.model.drive.errorText; }
    if (this.module === 'root' && this.activeTab === ROOT_TASK_TAB || this.module === 'photos' && this.photoTabId === 'transfers') {
      return this.model.queue.errorText.length > 0 ? this.model.queue.errorText : this.transferErrorText;
    }
    return this.model.errorText.length > 0 ? this.model.errorText :
      this.model.directoryErrorText.length > 0 && (this.pickerMode.length > 0 || this.module === 'root' && this.activeTab === 1) ?
        this.model.directoryErrorText : this.transferErrorText;
  }

  private visibleTabs(): ModuleTab[] {
    if (this.module === 'drive') { return driveTabs((view: DriveView): boolean => this.model.drive.supportsView(view), this.drivePinned); }
    if (this.module === 'photos') { return photoTabs((api: string): boolean => this.model.supports(api), this.showPhotoShared, this.photoPinned); }
    return rootTabs();
  }

  private driveMoreViews(): DriveView[] {
    return driveMoreViews((view: DriveView): boolean => this.model.drive.supportsView(view), this.drivePinned);
  }

  private driveScrollerFor(id: string): Scroller {
    return this.driveScrollers[Math.max(0, ['mydrive', 'teamFolders', 'recent', 'starred', 'sharedWithMe', 'sharedWithOthers', 'trash', 'more'].indexOf(id))];
  }

  private photoScrollerFor(id: string): Scroller {
    return this.photoScrollers[Math.max(0, ['photos', 'albums', 'shared', 'backup', 'transfers', 'more'].indexOf(id))];
  }

  private navigationBusy(): boolean { return this.model.busy || this.model.drive.busy || this.model.photoLibrary.busy; }

  private enterModule(module: WorkbenchModule): void {
    if (this.navigationBusy() || !this.model.authenticated) { return; }
    if (module === 'drive' && driveTabs((view: DriveView): boolean => this.model.drive.supportsView(view), this.drivePinned).length === 0) { return; }
    if (module === 'photos' && photoTabs((api: string): boolean => this.model.supports(api), this.showPhotoShared, this.photoPinned).length === 0) { return; }
    if (this.module === 'root') { this.rootTab = this.activeTab; }
    this.module = module;
    const id = module === 'drive' ? this.driveTabId : this.photoTabId;
    this.activeTab = moduleTabIndex(this.visibleTabs(), id);
    this.tabsController.changeIndex(this.activeTab);
    this.selectModuleTab(this.activeTab);
  }

  private exitModule(): void {
    this.module = 'root'; this.activeTab = rootReturnIndex(this.rootTab);
    this.tabsController.changeIndex(this.activeTab); this.updateTelemetryMode();
  }

  private selectModuleTab(index: number): void {
    const tab = this.visibleTabs()[index];
    if (tab === undefined) { return; }
    this.activeTab = index;
    if (this.module === 'drive') {
      this.driveTabId = tab.id;
      const view = tab.view ?? (this.driveMoreView.length > 0 ? this.driveMoreView as DriveView : undefined);
      if (view !== undefined && !(tab.id === 'mydrive' && this.driveSearchVisible && this.model.drive.view === DriveView.Search) &&
        (!this.model.drive.loaded || this.model.drive.view !== view)) { this.model.drive.selectView(view); }
    } else if (this.module === 'photos') {
      this.photoTabId = tab.id;
      if (tab.id === 'transfers') { this.taskSection = 'transfers'; }
      this.ensurePhotosOpen();
    } else { this.rootTab = index; }
  }

  private selectDriveMore(view: DriveView): void {
    if (this.navigationBusy() || !this.model.drive.supportsView(view)) { return; }
    this.driveMoreView = view;
    if (!this.model.drive.loaded || this.model.drive.view !== view) { this.model.drive.selectView(view); }
  }

  private backToDriveMore(): void { this.driveMoreView = ''; }

  private driveViewMatches(): boolean {
    const tab = this.visibleTabs().find((item: ModuleTab): boolean => item.id === this.driveTabId);
    const view = tab?.view ?? (this.driveMoreView.length > 0 ? this.driveMoreView as DriveView : undefined);
    return this.model.drive.loaded && (view !== undefined && this.model.drive.view === view ||
      this.driveTabId === 'mydrive' && this.driveSearchVisible && this.model.drive.view === DriveView.Search);
  }

  private refreshDriveView(): void {
    if (this.navigationBusy()) { return; }
    const tab = this.visibleTabs().find((item: ModuleTab): boolean => item.id === this.driveTabId);
    const view = tab?.view ?? (this.driveMoreView.length > 0 ? this.driveMoreView as DriveView : undefined);
    this.model.driveThumbnails.retryVisible();
    if (view !== undefined && this.model.drive.view !== view && !(this.driveTabId === 'mydrive' && this.driveSearchVisible && this.model.drive.view === DriveView.Search)) {
      this.model.drive.selectView(view);
    } else { this.model.drive.reload(); }
  }

  private showDriveSearch(): void {
    if (this.navigationBusy() || !this.driveViewMatches() || !this.model.drive.supportsView(DriveView.Search)) { return; }
    this.driveSearchVisible = true;
  }

  private async exitDriveSearch(): Promise<void> {
    if (this.model.drive.busy) { return; }
    if (this.model.drive.view === DriveView.Search) {
      await this.model.drive.exitSearch();
      if (this.model.drive.view === DriveView.Search) { return; }
    }
    this.driveSearchVisible = false;
  }

  private expectedPhotoSpace(id: string): PhotosSpace {
    const preferred = id === 'shared' ? this.sharedSpace : id === 'albums' ? this.albumSpace : this.photoSpace;
    if (preferred === PhotosSpace.Personal && id !== 'shared' && this.model.supports('SYNO.Foto.Browse.Item') ||
      preferred === PhotosSpace.Shared && this.model.supports('SYNO.FotoTeam.Browse.Item') ||
      preferred === PhotosSpace.WithMe && this.model.supports('SYNO.Foto.Sharing.Misc')) { return preferred; }
    if (id !== 'shared' && this.model.supports('SYNO.Foto.Browse.Item')) { return PhotosSpace.Personal; }
    return this.model.supports('SYNO.FotoTeam.Browse.Item') ? PhotosSpace.Shared : PhotosSpace.WithMe;
  }

  private expectedPhotoSection(id: string, space: PhotosSpace): PhotoLibrarySection {
    return id === 'photos' && space !== PhotosSpace.WithMe ? 'timeline' : 'albums';
  }

  private selectPhotoSpace(id: string, space: PhotosSpace): void {
    if (this.navigationBusy()) { return; }
    if (id === 'shared') { this.sharedSpace = space; }
    else if (id === 'albums') { this.albumSpace = space; }
    else { this.photoSpace = space; }
    this.ensurePhotosOpen();
  }

  private openPhotoBackup(): void {
    if (this.navigationBusy()) { return; }
    this.photoMoreShared = false;
    this.photoTabId = photoTabs((api: string): boolean => this.model.supports(api), this.showPhotoShared, this.photoPinned)
      .some((tab: ModuleTab): boolean => tab.id === 'backup') ? 'backup' : 'more';
    this.enterModule('photos');
    if (this.module === 'photos') { this.selectBackup(); }
  }

  private openPhotoShared(): void {
    if (this.navigationBusy() || !supportsPhotoSharing((api: string): boolean => this.model.supports(api))) { return; }
    this.photoMoreShared = true;
    this.ensurePhotosOpen();
  }

  private chooseBackupDirectory(): void {
    if (this.navigationBusy() || this.backup.selecting || this.backup.submitting || this.backup.sources.length === 0) { return; }
    this.pendingEntry = undefined; this.pendingOperation = '';
    this.pickerMode = 'backup'; this.navStack.pushPathByName('directory-picker', 'backup');
  }

  private cancelDirectoryPicker(): void {
    if (this.backup.submitting) { return; }
    this.pickerMode = ''; this.navStack.pop();
  }

  private async loadTabSettings(): Promise<void> {
    const context = this.abilityContext;
    if (context === undefined || this.tabSettingsBusy) { return; }
    this.tabSettingsBusy = true; this.tabSettingsError = '';
    try {
      const settings = await this.tabStore.load(context);
      if (!this.pageActive) { return; }
      this.drivePinned = settings.drivePinned; this.photoPinned = settings.photoPinned; this.showPhotoShared = settings.showPhotoShared;
      this.tabSettingsReady = true;
      if (this.module !== 'root') {
        const id = this.module === 'drive' ? this.driveTabId : this.photoTabId;
        this.activeTab = moduleTabIndex(this.visibleTabs(), id); this.tabsController.changeIndex(this.activeTab);
        this.selectModuleTab(this.activeTab);
      }
    } catch (error) {
      this.tabSettingsReady = false;
      this.tabSettingsError = error instanceof NasFailure ? error.message : '无法读取底栏设置，请重试。';
    } finally { this.tabSettingsBusy = false; }
  }

  private async saveTabSettings(settings: ModuleTabSettings): Promise<void> {
    if (!this.tabSettingsReady || this.tabSettingsBusy || this.navigationBusy()) { return; }
    this.tabSettingsBusy = true; this.tabSettingsError = '';
    try {
      await this.tabStore.save(settings);
      if (!this.pageActive) { return; }
      const id = this.module === 'drive' ? this.driveTabId : this.photoTabId;
      this.drivePinned = settings.drivePinned; this.photoPinned = settings.photoPinned; this.showPhotoShared = settings.showPhotoShared;
      if (this.module !== 'root') {
        this.activeTab = moduleTabIndex(this.visibleTabs(), id); this.tabsController.changeIndex(this.activeTab);
        this.selectModuleTab(this.activeTab);
      }
    } catch (error) { this.tabSettingsError = error instanceof NasFailure ? error.message : '无法保存底栏设置，请重试。'; }
    finally { this.tabSettingsBusy = false; }
  }

  private tabSettingsDraft(): ModuleTabSettings {
    const settings = new ModuleTabSettings();
    settings.drivePinned = this.drivePinned.slice(); settings.photoPinned = this.photoPinned.slice(); settings.showPhotoShared = this.showPhotoShared;
    return settings;
  }

  private toggleDriveTab(view: DriveView, selected: boolean): void {
    const settings = this.tabSettingsDraft();
    settings.drivePinned = selected ? settings.drivePinned.concat([view]) : settings.drivePinned.filter((id: string): boolean => id !== view);
    this.saveTabSettings(settings);
  }

  private togglePhotoTab(id: string, selected: boolean): void {
    const settings = this.tabSettingsDraft();
    if (id === 'shared') { settings.showPhotoShared = selected; }
    else { settings.photoPinned = selected ? settings.photoPinned.concat([id]) : settings.photoPinned.filter((value: string): boolean => value !== id); }
    this.saveTabSettings(settings);
  }

  private photoCanPin(id: string): boolean {
    return this.photoPinned.includes(id) || photoTabs((api: string): boolean => this.model.supports(api), this.showPhotoShared, this.photoPinned).length < 5 && this.photoPinned.length < 2;
  }

  private pageMenu(): HdsNavigationMenuItemOptions[] {
    if (this.module === 'drive') {
      const items: HdsNavigationMenuItemOptions[] = [];
      if (this.driveTabId === 'mydrive' && this.model.drive.supportsView(DriveView.Search)) {
        items.push({ content: { label: '搜索', icon: $r('sys.symbol.magnifyingglass'), type: IconStyleMode.SMALL,
          isEnabled: !this.navigationBusy() && this.driveViewMatches(), action: (): void => { this.showDriveSearch(); } } });
      }
      if (this.driveTabId !== 'more' || this.driveMoreView.length > 0) {
        items.push({ content: { label: '刷新', icon: $r('sys.symbol.arrow_clockwise'), type: IconStyleMode.SMALL,
          isEnabled: !this.navigationBusy(), action: (): void => { this.refreshDriveView(); } } });
      }
      return items;
    }
    if (this.module === 'photos' && ['photos', 'albums', 'shared'].includes(this.effectivePhotoTab())) {
      return [{ content: { label: '刷新', icon: $r('sys.symbol.arrow_clockwise'), type: IconStyleMode.SMALL,
        isEnabled: !this.navigationBusy(), action: (): void => { this.model.photoLibrary.refresh(); } } }];
    }
    if (this.module === 'root' && this.activeTab === 1) {
      const items: HdsNavigationMenuItemOptions[] = [];
      if (this.model.supports('SYNO.FileStation.Upload') || this.model.supports('SYNO.FileStation.CreateFolder')) {
        items.push({ content: { label: '上传与新建', icon: $r('sys.symbol.plus'), type: IconStyleMode.SMALL,
          isEnabled: this.model.directory.length > 0 && !this.model.busy, action: (): void => { this.openForm('file-add'); } } });
      }
      items.push({ content: { label: '更多', icon: $r('sys.symbol.ellipsis_circle'), type: IconStyleMode.SMALL,
        isEnabled: !this.model.busy, action: (): void => { this.openForm('file-tools'); } } });
      return items;
    }
    return [];
  }

  private tabIcon(id: string): Resource {
    if (id === 'home') { return $r('sys.symbol.house'); }
    if (['files', 'mydrive', 'teamFolders'].includes(id)) { return $r('sys.symbol.folder'); }
    if (['photos', 'albums'].includes(id)) { return $r('sys.symbol.picture'); }
    if (['tasks', 'transfers'].includes(id)) { return $r('sys.symbol.arrow_down_circle'); }
    if (id === 'backup') { return $r('sys.symbol.arrow_up_circle'); }
    if (id === 'starred') { return $r('sys.symbol.star'); }
    if (id === 'recent') { return $r('sys.symbol.clock'); }
    if (id === 'trash') { return $r('sys.symbol.trash'); }
    if (['shared', 'sharedWithMe', 'sharedWithOthers'].includes(id)) { return $r('sys.symbol.person_2'); }
    return $r('sys.symbol.ellipsis_circle');
  }

  private effectivePhotoTab(): string { return this.photoTabId === 'more' && this.photoMoreShared ? 'shared' : this.photoTabId; }

  @Builder
  notices() {
    WorkbenchNotice({ text: this.visibleError(), warning: true })
    if (this.visibleError().length === 0 && this.model.actionNotice.length > 0) {
      WorkbenchNotice({ text: this.model.actionNotice })
    }
  }

  @Builder
  emptyState(icon: Resource, title: string, description: string) {
    Column({ space: 8 }) {
      SymbolGlyph(icon).fontSize(32).fontColor([$r('sys.color.font_tertiary')])
      Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
      Text(description).fontSize(14).fontColor($r('sys.color.font_secondary')).textAlign(TextAlign.Center)
    }.width('100%').padding({ top: 32, bottom: 32, left: 24, right: 24 })
  }

  /** 启动等待页：只呈现居中的加载指示，不提前暴露表单或半成品状态。 */
  @Builder
  bootView() {
    Column({ space: 16 }) {
      LoadingProgress().width(48).height(48).color($r('sys.color.icon_emphasize'))
        .accessibilityText('正在恢复连接')
      Text('正在恢复上次的连接').fontSize(14).fontColor($r('sys.color.font_secondary'))
      if (this.bootEscapable) {
        Column({ space: 4 }) {
          Text('仍在等待服务器响应。').fontSize(12).fontColor($r('sys.color.font_tertiary'))
          Button('改用其他地址').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => { this.leaveBootScreen(); })
        }.margin({ top: 24 })
      }
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      .padding({ left: WorkbenchMetrics.pageMargin * 2, right: WorkbenchMetrics.pageMargin * 2,
        top: this.statusInset + 8, bottom: this.loginBottomInset() })
  }

  /** 开关设置行：整行标签 + 右侧系统开关，原地生效。 */
  @Builder
  switchRow(label: string, checked: boolean, onToggle: (checked: boolean) => void) {
    Row({ space: 12 }) {
      Text(label).fontSize(16).fontColor($r('sys.color.font_primary')).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: checked }).enabled(!this.model.busy).onChange(onToggle)
        .accessibilityText(label)
    }.width('100%').constraintSize({ minHeight: WorkbenchMetrics.rowMinHeight })
  }

  /** 登录页：地址、用户名、密码与协议开关整体居中。 */
  @Builder
  loginView() {
    Column() {
      Scroll(this.homeScroller) {
        Column({ space: 16 }) {
          Column({ space: 12 }) {
            WorkbenchIconTile({ icon: $r('sys.symbol.externaldrive'), iconSize: 34, tileSize: 72, tileRadius: 20,
              iconColor: $r('sys.color.icon_emphasize'), tileColor: $r('app.color.workbench_accent_surface') })
            Text(this.model.savedSession ? '重新登录你的 NAS' : '连接你的 NAS')
              .fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary'))
          }.width('100%').alignItems(HorizontalAlign.Center)
          Column({ space: 12 }) {
            TextInput({ text: this.model.address, placeholder: '地址或域名' })
              .maxLength(512).constraintSize({ minHeight: 48 }).enabled(!this.model.busy && !this.model.authenticated)
              .onChange((text: string): void => { this.model.setAddress(text); }).accessibilityText('NAS 服务器地址')
            TextInput({ text: this.model.account, placeholder: '用户名' })
              .maxLength(128).constraintSize({ minHeight: 48 }).enabled(!this.model.busy)
              .onChange((text: string): void => { this.model.account = text; }).accessibilityText('NAS 用户名')
            TextInput({ text: this.model.password, placeholder: '密码' })
              .constraintSize({ minHeight: 48 }).type(InputType.Password).enabled(!this.model.busy)
              .enterKeyType(EnterKeyType.Go).onSubmit((): void => { this.model.submitLogin(); })
              .onChange((text: string): void => { this.model.password = text; }).accessibilityText('NAS 密码')
            if (this.model.needsOtp) {
              TextInput({ text: this.model.otp, placeholder: '6 位动态码' }).constraintSize({ minHeight: 48 })
                .type(InputType.Number).maxLength(6).enabled(!this.model.busy)
                .onChange((text: string): void => { this.model.otp = text; }).accessibilityText('双重验证动态码')
            }
            Divider().color($r('app.color.workbench_divider'))
            Column() {
              this.switchRow('HTTPS 安全访问', this.model.useHttps,
                (checked: boolean): void => { this.model.setUseHttps(checked); })
              if (this.model.useHttps) {
                this.switchRow('忽略 SSL 验证', this.model.insecureTls,
                  (checked: boolean): void => { this.model.setInsecureTls(checked); })
              }
            }.width('100%')
          }.width('100%').padding(16).borderRadius(WorkbenchMetrics.cardRadius)
            .backgroundColor($r('app.color.workbench_surface')).alignItems(HorizontalAlign.Start)
          Button(this.model.busy ? '正在登录…' : '登录')
            .width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .enabled(!this.model.busy && this.model.address.trim().length > 0 &&
              this.model.account.trim().length > 0 && this.model.password.length > 0)
            .onClick((): void => { this.model.submitLogin(); })
          if (this.model.savedSession || this.model.connected) {
            Button('清除已保存的登录信息').width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.busy)
              .onClick((): void => { this.model.disconnect(); })
          }
          this.notices()
        }.width('100%').constraintSize({ maxWidth: 560, minHeight: this.loginMinHeight() })
          .justifyContent(FlexAlign.Center)
          .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin, top: 16, bottom: 16 })
          .alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
    }.width('100%').height('100%')
      .padding({ top: this.loginTopInset(), bottom: this.loginBottomInset() })
  }

  @Builder
  shortcut(icon: Resource, label: string, action: () => void) {
    Button() {
      Column({ space: 8 }) {
        WorkbenchIconTile({ icon: icon, iconSize: 26, tileSize: 48, tileRadius: 12,
          iconColor: $r('sys.color.icon_emphasize'), tileColor: $r('app.color.workbench_accent_surface') })
        Text(label).fontSize(14).fontColor($r('sys.color.font_primary')).textAlign(TextAlign.Center)
          .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').padding({ top: 12, bottom: 12, left: 4, right: 4 })
    }.width((100 / workbenchShortcutColumns(this.windowWidth)).toString() + '%')
      .type(ButtonType.Normal).backgroundColor(Color.Transparent).enabled(!this.navigationBusy())
      .onClick(action).accessibilityText(label)
  }

  /** 首页设备区：直接落在页面底色上，不用白底卡片，上下留白压到最小。 */
  @Builder
  deviceHeader() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(this.routeLabel()).fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Text(this.model.deviceTitle).fontSize(24).fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('sys.color.font_tertiary')])
        }.width('100%').alignItems(VerticalAlign.Center)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      this.deviceArtwork()
    }.width('100%').padding({ left: 8, top: 4 }).enabled(!this.model.busy)
      .onClick((): void => { this.showDeviceInfo(); })
      .accessibilityText(this.routeLabel() + '，' + this.model.deviceTitle + '，查看设备信息')
  }

  /** 联网取回的产品图 → 内置型号图 → 官方通用线性图。 */
  @Builder
  deviceArtwork() {
    if (this.deviceArtworkPath.length > 0) {
      Image(fileUri.getUriFromPath(this.deviceArtworkPath)).width(this.artworkSize).height(this.artworkSize)
        .objectFit(ImageFit.Contain).accessibilityLevel('no')
    } else if (hasModelArtwork(this.model.deviceModel)) {
      Image(bundledDeviceArtwork(this.model.deviceModel)).width(this.artworkSize).height(this.artworkSize)
        .objectFit(ImageFit.Contain).accessibilityLevel('no')
    } else {
      // 官方线性 NAS 图按原样渲染：它是描边图，fillColor 只影响填充点，会把图标染成两色。
      Image(fallbackDeviceArtwork()).width(this.artworkSize * 0.72).height(this.artworkSize * 0.72)
        .objectFit(ImageFit.Contain).accessibilityLevel('no')
    }
  }

  @Builder
  homeView() {
    Scroll(this.homeScroller) {
      Column({ space: WorkbenchMetrics.sectionGap }) {
        this.deviceHeader()
        Flex({ wrap: FlexWrap.Wrap }) {
          this.shortcut($r('sys.symbol.folder'), '文件', (): void => { this.switchTab(1); })
          if (driveTabs((view: DriveView): boolean => this.model.drive.supportsView(view), this.drivePinned).length > 0) {
            this.shortcut($r('sys.symbol.folder'), 'Synology Drive', (): void => { this.enterModule('drive'); })
          }
          if (this.supportsPhotos()) {
            this.shortcut($r('sys.symbol.picture'), '照片', (): void => { this.enterModule('photos'); })
          }
          if (this.model.supports('SYNO.FileStation.Upload')) {
            this.shortcut($r('sys.symbol.arrow_up_circle'), '照片备份', (): void => { this.openPhotoBackup(); })
          }
          this.shortcut($r('sys.symbol.arrow_down_circle'), '传输任务', (): void => { this.switchTab(ROOT_TASK_TAB); })
          if (this.model.supports('SYNO.FileStation.Sharing')) {
            this.shortcut($r('sys.symbol.doc'), '我的分享', (): void => { this.navStack.pushPathByName('share-links', undefined); })
          }
          if (this.model.supports('SYNO.DownloadStation.Task')) {
            this.shortcut($r('sys.symbol.arrow_down_circle'), 'NAS 下载', (): void => { this.openNasDownloads(); })
          }
        }.width('100%').padding(4).borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        NasTelemetrySummary({ monitor: this.model.telemetry, onOpen: (): void => { this.openTelemetry(); } })
        NasTelemetryStorageCard({ monitor: this.model.telemetry, onOpen: (): void => { this.openTelemetry(); } })
        this.notices()
      }.width('100%').constraintSize({ maxWidth: 840 })
        .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin, top: this.contentTopInset() + 8, bottom: this.bottomInset() })
    }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Off)
  }


  @Builder
  settingsView() {
    Scroll(this.settingsScroller) {
      Column({ space: WorkbenchMetrics.sectionGap }) {
        Column({ space: 12 }) {
          WorkbenchSectionTitle({ title: '设备管理' })
          Column() {
            WorkbenchActionRow({ icon: $r('sys.symbol.externaldrive'), label: '设备信息', description: this.model.account,
              available: !this.model.busy, onAction: (): void => { this.showDeviceInfo(); } })
            Divider().color($r('app.color.workbench_divider')).margin({ left: 68, right: 16 })
            WorkbenchActionRow({ icon: $r('sys.symbol.externaldrive'), label: '连接地址', description: this.model.address,
              available: !this.model.busy, onAction: (): void => { this.openConnectionAddresses(); } })
            if (this.model.supports('SYNO.Core.System')) {
              Divider().color($r('app.color.workbench_divider')).margin({ left: 68, right: 16 })
              WorkbenchActionRow({ icon: $r('sys.symbol.ellipsis_circle'), label: '系统控制',
                available: !this.model.busy, onAction: (): void => { this.navStack.pushPath({ name: 'system-control' }); } })
            }
          }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        }.width('100%')

        Column() {
          WorkbenchActionRow({ icon: $r('sys.symbol.ellipsis_circle'), label: '模块底栏',
            description: '选择 Drive 与照片的常用功能', onAction: (): void => { this.navStack.pushPathByName('module-tabs', undefined); } })
          WorkbenchActionRow({ icon: $r('sys.symbol.externaldrive'), label: '登出 NAS', destructive: true,
            available: !this.model.busy, onAction: (): void => { this.confirmLogout(); } })
        }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        this.notices()
      }.width('100%').constraintSize({ maxWidth: 840 })
        .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin, top: this.contentTopInset() + 8, bottom: this.bottomInset() })
    }.width('100%').height('100%').scrollBar(BarState.Auto).align(Alignment.Top)
  }

  @Builder
  tabSettingRow(label: string, selected: boolean, enabled: boolean, onToggle: (selected: boolean) => void) {
    Row({ space: 12 }) {
      Text(label).fontSize(16).fontColor($r('sys.color.font_primary')).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: selected }).enabled(enabled && this.tabSettingsReady && !this.tabSettingsBusy && !this.navigationBusy())
        .onChange(onToggle).accessibilityText(label + '，显示在底栏')
    }.width('100%').constraintSize({ minHeight: WorkbenchMetrics.rowMinHeight }).padding({ left: 16, right: 16 })
  }

  @Builder
  tabSettingsView() {
    Scroll(this.tabSettingsScroller) {
      Column({ space: WorkbenchMetrics.sectionGap }) {
        Text('选择常用功能加入底栏，最多显示 5 项。加入后，该功能会从“更多”中移除。')
          .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        if (driveTabs((view: DriveView): boolean => this.model.drive.supportsView(view), this.drivePinned).length > 0) {
          WorkbenchSectionTitle({ title: 'Synology Drive' })
          Text('我的文件、团队文件和更多固定显示，可再加入 2 项。').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
          Column() {
            ForEach(DRIVE_MORE_VIEWS.filter((view: DriveView): boolean => this.model.drive.supportsView(view)), (view: DriveView): void => {
              this.tabSettingRow(driveViewLabel(view), this.drivePinned.includes(view), this.drivePinned.includes(view) || this.drivePinned.length < 2,
                (selected) => { this.toggleDriveTab(view, selected); })
            }, (view: DriveView): string => view)
          }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        }
        if (this.supportsPhotos() || this.model.supports('SYNO.FileStation.Upload')) {
          WorkbenchSectionTitle({ title: '照片' })
          Column() {
            if (supportsPhotoSharing((api: string): boolean => this.model.supports(api))) {
              this.tabSettingRow('共享', this.showPhotoShared, !this.showPhotoShared ?
                photoTabs((api: string): boolean => this.model.supports(api), false, this.photoPinned).length < 5 : true,
                (selected: boolean): void => { this.togglePhotoTab('shared', selected); })
            }
            if (this.model.supports('SYNO.FileStation.Upload')) {
              this.tabSettingRow('照片备份', this.photoPinned.includes('backup'), this.photoCanPin('backup'),
                (selected: boolean): void => { this.togglePhotoTab('backup', selected); })
            }
            this.tabSettingRow('传输任务', this.photoPinned.includes('transfers'), this.photoCanPin('transfers'),
              (selected: boolean): void => { this.togglePhotoTab('transfers', selected); })
          }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        }
        WorkbenchNotice({ text: this.tabSettingsError, warning: true })
        if (!this.tabSettingsReady) {
          Button('重新读取设置').enabled(!this.tabSettingsBusy).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .onClick((): void => { this.loadTabSettings(); })
        }
      }.width('100%').constraintSize({ maxWidth: 840 }).alignItems(HorizontalAlign.Start)
        .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin, top: 16, bottom: this.navigationInset + 16 })
    }.width('100%').height('100%').scrollBar(BarState.Auto).align(Alignment.Top)
  }

  @Builder
  filePageTools() {
    if (this.sheetKind === 'file-add') {
      if (this.model.supports('SYNO.FileStation.Upload')) {
        WorkbenchActionRow({ icon: $r('sys.symbol.arrow_up_circle'), label: '上传文件',
          available: this.model.directory.length > 0 && this.model.queue.ready && !this.model.busy && !this.model.queue.busy && !this.transferSubmitting,
          onAction: (): void => { this.sheetVisible = false; this.runTransfer(async (): Promise<void> => { await this.model.uploadFiles(); }); } })
      }
      if (this.model.supports('SYNO.FileStation.CreateFolder')) {
        WorkbenchActionRow({ icon: $r('sys.symbol.folder'), label: '新建文件夹', available: this.model.directory.length > 0 && !this.model.busy,
          onAction: (): void => { this.openForm('create'); } })
      }
    } else {
      if (this.model.directory.length > 0) {
        WorkbenchActionRow({ icon: $r('sys.symbol.ellipsis_circle'), label: '排序', description: this.sortLabel(),
          onAction: (): void => { this.openForm('sort'); } })
      }
      if (this.model.supports('SYNO.FileStation.Sharing')) {
        WorkbenchActionRow({ icon: $r('sys.symbol.doc'), label: '我的分享链接',
          onAction: (): void => { this.sheetVisible = false; this.navStack.pushPathByName('share-links', undefined); } })
      }
      if (driveTabs((view: DriveView): boolean => this.model.drive.supportsView(view), this.drivePinned).length > 0) {
        WorkbenchActionRow({ icon: $r('sys.symbol.folder'), label: 'Synology Drive',
          onAction: (): void => { this.sheetVisible = false; this.enterModule('drive'); } })
      }
      WorkbenchActionRow({ icon: $r('sys.symbol.arrow_clockwise'), label: '刷新目录', available: !this.model.busy,
        onAction: (): void => { this.sheetVisible = false; this.model.refresh(); } })
    }
  }

  @Builder
  modulePage(tab: ModuleTab) {
    if (this.module === 'drive') {
      DriveModulePage({ model: this.model, tabId: tab.id, active: tab.id === this.driveTabId,
        expectedView: tab.view ?? (this.driveMoreView.length > 0 ? this.driveMoreView as DriveView : DriveView.MyDrive),
        scroller: this.driveScrollerFor(tab.id), topInset: this.contentTopInset(), bottomInset: this.bottomInset(),
        searchVisible: this.driveSearchVisible, moreView: this.driveMoreView, moreViews: this.driveMoreViews(),
        onSelectMore: (view: DriveView): void => { this.selectDriveMore(view); }, onBackToMore: (): void => { this.backToDriveMore(); },
        onExitSearch: (): void => { this.exitDriveSearch(); }, onOpenTransfers: (): void => { this.openDriveTransfers(); },
        onOpenAction: (action: DriveAction, entry?: DriveEntry): void => { if (entry !== undefined) { this.prepareDriveAction(entry, action); } },
        onOpenActionRecords: (): void => { this.taskSection = 'drive-actions'; this.switchTab(ROOT_TASK_TAB); },
        onOpenOriginal: (entry: DriveEntry): void => { this.openDriveOriginal(entry); },
        onOpenLinks: (entry?: DriveEntry): void => { this.openDriveLinks(entry); },
        onOpenNotifications: (): void => { this.navStack.pushPathByName('drive-notifications', undefined); },
        onCustomize: (): void => { this.navStack.pushPathByName('module-tabs', undefined); } })
    } else if (this.module === 'photos') {
      if (tab.id === 'transfers') { this.tasksView() }
      else {
        Column() {
          if (tab.id === 'more' && this.photoMoreShared) {
            Button('返回更多').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .onClick((): void => { this.photoMoreShared = false; }).margin({ top: this.contentTopInset() + 8 })
          }
          PhotoModulePage({ model: this.model, backup: this.backup, tabId: tab.id === 'more' && this.photoMoreShared ? 'shared' : tab.id,
            active: tab.id === this.photoTabId, scroller: this.photoScrollerFor(tab.id),
            topInset: tab.id === 'more' && this.photoMoreShared ? 0 : this.contentTopInset(), bottomInset: this.bottomInset(),
            expectedSpace: this.expectedPhotoSpace(tab.id === 'more' && this.photoMoreShared ? 'shared' : tab.id),
            expectedSection: this.expectedPhotoSection(tab.id === 'more' && this.photoMoreShared ? 'shared' : tab.id,
              this.expectedPhotoSpace(tab.id === 'more' && this.photoMoreShared ? 'shared' : tab.id)),
            showBackupInMore: !this.visibleTabs().some((item: ModuleTab): boolean => item.id === 'backup'),
            showSharedInMore: !this.showPhotoShared,
            showTransfersInMore: !this.visibleTabs().some((item: ModuleTab): boolean => item.id === 'transfers'),
            onSelectSpace: (space: PhotosSpace): void => { this.selectPhotoSpace(this.effectivePhotoTab(), space); },
            onOpenPhoto: (item: NasPhotoItem): void => { this.openPhoto(item); }, onSelectBackup: (): void => { this.selectBackup(); },
            onChooseBackup: (): void => { this.chooseBackupDirectory(); }, onShowBackupContents: (): void => { this.openForm('backup'); },
            onOpenTransfers: (): void => { this.taskSection = 'transfers'; this.switchTab(ROOT_TASK_TAB); },
            onOpenShared: (): void => { this.openPhotoShared(); },
            onCustomize: (): void => { this.navStack.pushPathByName('module-tabs', undefined); } })
        }.width('100%').height('100%')
      }
    } else if (tab.id === 'home') { this.homeView() }
    else if (tab.id === 'files') {
      FileStationPage({ model: this.model, scroller: this.filesScroller, topInset: this.contentTopInset(), bottomInset: this.bottomInset(),
        errorText: this.visibleError(), pendingEntry: this.pendingEntry, pendingOperation: this.pendingOperation, canUseDestination: this.destinationAllowed(),
        onOpenForm: (kind: string, entry?: NasFileEntry): void => { this.openForm(kind, entry); },
        onNavigateBreadcrumb: (target: string): void => { this.navigateBreadcrumb(target); },
        onApplyDestination: (): void => { this.applyDestination(); }, onCancelDestination: (): void => { this.pendingEntry = undefined; this.pendingOperation = ''; } })
    } else if (tab.id === 'tasks') { this.tasksView() }
    else { this.settingsView() }
  }

  @Builder
  fileActions(entry: NasFileEntry) {
    Column() {
      if (this.model.supports('SYNO.FileStation.Sharing')) {
        WorkbenchActionRow({ icon: $r('sys.symbol.doc'), label: '创建分享链接', available: this.model.extensions.canWrite('fileSharing'),
          onAction: (): void => {
            this.sheetVisible = false;
            this.model.extensions.shareDraftPaths = [entry.path];
            this.model.extensions.selectedShare = undefined;
            this.navStack.pushPathByName('share-links', undefined);
          } })
      }
      if (this.sheetKind === 'actions') {
        WorkbenchActionRow({ icon: $r('sys.symbol.doc'), label: '查看详情', available: !this.model.busy,
          onAction: (): void => { this.openForm('detail', entry); } })
      }
      if (!entry.isDirectory && this.model.supports('SYNO.FileStation.Download')) {
        WorkbenchActionRow({ icon: $r('sys.symbol.arrow_down_circle'), label: '下载到应用',
          available: this.model.queue.ready && !this.model.busy && !this.model.queue.busy && !this.transferSubmitting,
          onAction: (): void => {
            this.sheetVisible = false;
            this.runTransfer(async (): Promise<void> => { await this.model.downloadFile(entry); });
            this.switchTab(ROOT_TASK_TAB);
          } })
      }
      if (this.model.directory.length > 0) {
        if (this.model.supports('SYNO.FileStation.CopyMove')) {
          WorkbenchActionRow({ icon: $r('sys.symbol.folder'), label: '复制到…', available: !this.model.busy,
            onAction: (): void => { this.chooseDestination(entry, 'copy'); } })
          WorkbenchActionRow({ icon: $r('sys.symbol.folder'), label: '移动到…', available: !this.model.busy,
            onAction: (): void => { this.chooseDestination(entry, 'move'); } })
        }
        if (this.model.supports('SYNO.FileStation.Rename')) {
          WorkbenchActionRow({ icon: $r('sys.symbol.doc'), label: '重命名', available: !this.model.busy,
            onAction: (): void => { this.openForm('rename', entry); } })
        }
        if (this.model.supports('SYNO.FileStation.Delete')) {
          Divider().color($r('app.color.workbench_divider')).margin({ left: 16, right: 16 })
          WorkbenchActionRow({ icon: $r('sys.symbol.doc'), label: '删除', destructive: true, available: !this.model.busy,
            onAction: (): void => { this.confirmDelete(entry); } })
        }
      }
    }.width('100%').borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_subtle'))
  }

  /** 文件页：按来源在 File Station 与 Synology Drive 之间切换，两侧视图各自独立。 */

  /**
   * 数据来源切换。Drive 不可用时保持 File Station，并把原因写在旁边，
   * 而不是给一个点了没反应的按钮。
   */

  /** Drive 面包屑。直接来自浏览模型自己的导航栈，不会与请求位置不一致。 */

  private async prepareDriveAction(entry: DriveEntry, action: DriveAction): Promise<void> {
    if (await this.model.driveActions.prepare(entry, action)) { this.navStack.pushPathByName('drive-action', undefined); }
  }

  private async submitDriveAction(): Promise<void> {
    if (await this.model.driveActions.submit()) {
      const paths: string[] = this.navStack.getAllPathName();
      if (!this.pageActive || paths[paths.length - 1] !== 'drive-action') { return; }
      this.navStack.pop(); this.model.driveActions.clearDraft(); this.taskSection = 'drive-actions'; this.switchTab(ROOT_TASK_TAB);
      this.updateTelemetryMode();
    }
  }

  private returnDriveFiles(): void { this.enterModule('drive'); this.model.drive.reload(); }

  private openDriveTransfers(): void { this.taskSection = 'drive'; this.switchTab(ROOT_TASK_TAB); }


  private openDriveOriginal(entry: DriveEntry): void {
    this.navStack.pushPathByName('drive-original', undefined);
    this.model.driveOriginal.open(entry);
  }

  private openDriveLinks(entry?: DriveEntry): void {
    this.model.driveSharing.clearDraft();
    if (entry !== undefined && !this.model.driveSharing.prepare(entry)) { return; }
    this.navStack.pushPathByName('drive-links', undefined);
  }

  @Builder
  photoDetailView() {
    Scroll(this.detailScroller) {
      Column({ space: 16 }) {
        if (this.model.photoLibrary.detail !== undefined) {
          Stack() {
            SymbolGlyph($r('sys.symbol.picture')).fontSize(48).fontColor([$r('sys.color.font_tertiary')])
            if (this.model.photoLibrary.detail.mediaType === 'video' && this.model.photoLibrary.originalPath.length > 0) {
              Video({ src: fileUri.getUriFromPath(this.model.photoLibrary.originalPath) }).width('100%').height('100%').autoPlay(false).controls(true)
                .onError((): void => { this.mediaDecodeFailed = true; })
            } else if (this.model.photoLibrary.previewPath.length > 0 || this.model.photoLibrary.originalPath.length > 0) {
              Image(fileUri.getUriFromPath(this.model.photoLibrary.originalPath.length > 0 ? this.model.photoLibrary.originalPath : this.model.photoLibrary.previewPath))
                .width('100%').height('100%').objectFit(ImageFit.Contain).sourceSize({ width: 1440, height: 1440 })
                .onError((): void => { this.mediaDecodeFailed = true; })
            }
            if (this.model.photoLibrary.loadingMedia) { LoadingProgress().width(40).height(40) }
          }.width('100%').height(Math.max(220, Math.min(480, this.contentWidth))).borderRadius(WorkbenchMetrics.innerRadius).clip(true)
            .backgroundColor($r('app.color.workbench_subtle'))
          Column({ space: 6 }) {
            Text(this.model.photoLibrary.detail.filename).fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
            Text(photoTakenDate(this.model.photoLibrary.detail)).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
            Text(photoMediaLabel(this.model.photoLibrary.detail) + ' · ' + workbenchBytes(this.model.photoLibrary.detail.bytes))
              .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
            if (this.model.photoLibrary.detail.width !== undefined && this.model.photoLibrary.detail.height !== undefined) {
              Text(this.model.photoLibrary.detail.width.toString() + ' × ' + this.model.photoLibrary.detail.height.toString())
                .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
            }
            if (this.model.photoLibrary.detail.mediaType === 'live') {
              Text('动态照片仅显示静态预览。').fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%')
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
          if (this.mediaDecodeFailed) {
            Text('此设备无法预览该格式，可将原文件另存后使用支持的应用打开。').fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
          }
          if (this.model.photoLibrary.exportNotice.length > 0) {
            Text(this.model.photoLibrary.exportNotice).fontSize(14).fontColor($r('sys.color.font_emphasize')).width('100%')
          }
          if (this.model.photoLibrary.mediaErrorText.length > 0) {
            Text(this.model.photoLibrary.mediaErrorText).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
          }
          Button(this.model.photoLibrary.loadingMedia ? '正在读取…' : this.model.photoLibrary.originalPath.length > 0 ? '重新读取原文件' :
            this.model.photoLibrary.detail.mediaType === 'video' ? '读取原视频' : '查看原图')
            .width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).enabled(!this.model.photoLibrary.loadingMedia)
            .onClick((): void => { this.mediaDecodeFailed = false; this.model.photoLibrary.loadOriginal(); })
          if (this.model.photoLibrary.originalPath.length > 0) {
            Button('另存原文件').width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.photoLibrary.loadingMedia)
              .onClick((): void => { this.model.photoLibrary.exportOriginal(); })
          }
          Text('原文件在本页读取，离开即结束。')
            .fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%')
        }
      }.width('100%').constraintSize({ maxWidth: 840 }).padding({ left: 16, right: 16, top: 16, bottom: 32 })
        .alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto)
  }

  @Builder
  destinationBuilder(name: string, parameter: Object) {
    if (name === 'module-tabs') {
      HdsNavDestination() { this.tabSettingsView() }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: '模块底栏' } } })
        .bindToScrollable([this.tabSettingsScroller])
    } else if (name === 'directory-picker') {
      HdsNavDestination() {
        FileStationPage({ model: this.model, scroller: this.pickerScroller, topInset: 0, bottomInset: this.navigationInset + 16,
          pickerMode: this.pickerMode, selectionCount: this.backup.sources.length, pickerBusy: this.backup.submitting,
          pickerError: this.pickerMode === 'backup' ? this.backup.errorText : '', errorText: this.visibleError(),
          canConfirm: this.model.directory.length > 0 && !this.model.busy && (this.pickerMode !== 'backup' ||
            this.model.supports('SYNO.FileStation.Upload') && this.backup.sources.length > 0 && this.model.queue.ready && !this.model.queue.busy && !this.backup.submitting),
          onNavigateBreadcrumb: (target: string): void => { this.navigateBreadcrumb(target); },
          onConfirm: (): void => { if (this.pickerMode === 'backup') { this.submitBackup(); } else { this.useDownloadDirectory(); } },
          onCancel: (): void => { this.cancelDirectoryPicker(); } })
      }.backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: this.pickerMode === 'backup' ? '备份位置' : '下载保存目录' } } })
        .bindToScrollable([this.pickerScroller])
        .onBackPressed((): boolean => {
          if (this.backup.submitting) { return true; }
          if (this.model.directory.length > 0) { if (!this.model.busy) { this.model.goBack(); } return true; }
          this.cancelDirectoryPicker(); return true;
        })
        .onDisAppear((): void => { this.pickerMode = ''; })
    } else if (name === 'drive-links') {
      HdsNavDestination() {
        DriveSharingPage({ model: this.model.driveSharing, scroller: this.driveLinksScroller,
          onCancel: (): void => { this.navStack.pop(); } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: 'Drive 文件链接' } } })
        .bindToScrollable([this.driveLinksScroller])
        .onHidden((): void => { this.model.driveSharing.clearDraft(); })
    } else if (name === 'drive-notifications') {
      HdsNavDestination() { DriveNotificationsPage({ model: this.model.driveNotifications, scroller: this.driveNotificationsScroller }) }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: 'Drive 通知' } } })
        .bindToScrollable([this.driveNotificationsScroller])
        .onShown((): void => { this.model.driveNotifications.refresh(); })
    } else if (name === 'drive-original') {
      HdsNavDestination() { DriveOriginalPage({ model: this.model.driveOriginal }) }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: this.model.driveOriginal.entry?.name || '原图' } } })
        .onHidden((): void => {
          if (this.foreground) { this.model.driveOriginal.close(); } else { this.model.driveOriginal.setForeground(false); }
        })
    } else if (name === 'drive-action') {
      HdsNavDestination() {
        DriveActionPage({ model: this.model.driveActions, scroller: this.driveActionScroller,
          onSubmit: (): void => { this.submitDriveAction(); },
          onCancel: (): void => { this.model.driveActions.clearDraft(); this.navStack.pop(); } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: 'Drive 文件操作' } } })
        .bindToScrollable([this.driveActionScroller])
        .onHidden((): void => { this.model.driveActions.clearDraft(); })
    } else if (name === 'share-links') {
      HdsNavDestination() { ShareLinksPage({ model: this.model.extensions, scroller: this.sharesScroller }) }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: '我的分享' } } })
        .bindToScrollable([this.sharesScroller])
        .onShown((): void => { this.extensionsOpened = true; this.updateTelemetryMode(); this.model.extensions.refreshShares(); })
        .onHidden((): void => { this.extensionsOpened = false; this.updateTelemetryMode(); })
    } else if (name === 'nas-downloads') {
      HdsNavDestination() {
        DownloadStationPage({ model: this.model.extensions, scroller: this.downloadsScroller, visible: this.downloadsVisible,
          onChooseDirectory: (): void => { this.chooseDownloadDirectory(); } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: 'NAS 下载' } } })
        .bindToScrollable([this.downloadsScroller])
        .onShown((): void => { this.downloadsVisible = true; this.extensionsOpened = true; this.updateTelemetryMode(); this.model.extensions.refreshDownloads(); })
        .onHidden((): void => { this.downloadsVisible = false; this.extensionsOpened = false; this.updateTelemetryMode(); })
    } else if (name === 'telemetry') {
      HdsNavDestination() {
        NasTelemetryDashboard({ monitor: this.model.telemetry, scroller: this.telemetryScroller,
          topInset: this.contentTopInset(), bottomInset: this.navigationInset })
      }
        .backgroundColor($r('app.color.workbench_background'))
        // 内容需滚入标题栏下方，供沉浸材质取样；首项让位由详情页按实际视口位置计算。
        .titleBar({ enableComponentSafeArea: false, content: { title: { mainTitle: '资源监控' } },
          style: { scrollEffectOpts: { enableScrollEffect: false, scrollEffectType: ScrollEffectType.GRADIENT_BLUR },
            systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE,
              materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE },
            originalStyle: { backgroundStyle: { blurRadius: 12, maskExtraHeight: 16 },
              contentStyle: { titleStyle: { mainTitleColor: $r('sys.color.font_primary') } } } } })
        .bindToScrollable([this.telemetryScroller])
        // 详情页要沉浸到屏幕下沿：内容区不被底部系统安全区（导航条）抬高，否则底边留一条灰带。
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
        .onShown((): void => { this.telemetryOpened = true; this.updateTelemetryMode(); })
        .onHidden((): void => { this.telemetryOpened = false; this.updateTelemetryMode(); })
    } else if (name === 'connection-addresses') {
      HdsNavDestination() {
        NasConnectionAddressPage({ model: this.model, scroller: this.addressBookScroller,
          onUseAddress: (address: NasConnectionAddress): void => { this.confirmUseAddress(address); } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: '连接地址' } } })
        .bindToScrollable([this.addressBookScroller])
        .onShown((): void => { this.addressBookOpened = true; this.updateTelemetryMode(); })
        .onHidden((): void => {
          this.addressBookOpened = false;
          this.model.addressBook.cancelProbe();
          this.updateTelemetryMode();
        })
    } else if (name === 'system-control') {
      HdsNavDestination() {
        NasSystemControlPage({ control: this.model.systemControl, scroller: this.systemControlScroller,
          onRefresh: (): void => { this.model.openSystemControl(); },
          onSubmit: (): void => { this.model.submitSystemControl(); } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: '系统控制' } } })
        .bindToScrollable([this.systemControlScroller])
        .onShown((): void => {
          this.systemControlOpened = true;
          this.updateTelemetryMode();
          this.model.openSystemControl();
        })
        .onHidden((): void => {
          this.systemControlOpened = false;
          this.model.systemControl.deactivate();
          this.updateTelemetryMode();
        })
    } else if (name === 'photo-detail') {
      HdsNavDestination() { this.photoDetailView() }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: '照片详情' } } })
        .bindToScrollable([this.detailScroller])
        .onDisAppear((): void => { if (this.navStack.size() === 0) { this.model.photoLibrary.closeDetail(); } })
    }
  }

  private taskProgress(item: TransferQueueItem): number {
    return item.bytes > 0 ? Math.min(100, Math.max(0, item.processed / item.bytes * 100)) : 0;
  }

  private fileTaskStateText(item: FileTaskItem): string {
    if (item.state === 'completed') { return '已完成'; }
    if (item.state === 'failed') { return '操作失败'; }
    return item.state === 'pending' ? '服务器正在处理' : '结果待确认';
  }

  private confirmCancelTask(item: TransferQueueItem): void {
    this.getUIContext().showAlertDialog({ title: '取消传输', message: '确认取消“' + item.name + '”的传输任务？',
      primaryButton: { value: '继续传输', action: (): void => {} },
      secondaryButton: { value: '取消任务', action: (): void => {
        this.runTransfer(async (): Promise<void> => { await this.model.queue.cancel(item.id); });
      } } });
  }

  private confirmCloseUpload(item: TransferQueueItem): void {
    this.getUIContext().showAlertDialog({ title: '核对后关闭上传',
      message: '请先在 NAS 核对“' + item.remotePath + '”的实际内容。关闭记录会停止原系统任务，但不会标记上传成功或删除 NAS 文件；之后可以重新选择文件上传。',
      primaryButton: { value: '继续核对', action: (): void => {} },
      secondaryButton: { value: '已核对，关闭记录', action: (): void => {
        this.runTransfer(async (): Promise<void> => { await this.model.queue.closeUnknownUpload(item.id); });
      } } });
  }

  private confirmRemoveRecord(item: TransferQueueItem): void {
    this.getUIContext().showAlertDialog({ title: '清理传输记录',
      message: '将清理“' + item.name + '”的本机记录和应用私有副本。已下载的文件请先另存到系统文件。NAS 文件不受影响。',
      primaryButton: { value: '保留', action: (): void => {} },
      secondaryButton: { value: '清理', action: (): void => {
        this.runTransfer(async (): Promise<void> => { await this.model.queue.removeRecord(item.id); });
      } } });
  }

  private confirmClearHistory(): void {
    this.getUIContext().showAlertDialog({ title: '清理传输历史',
      message: '将清理已结束任务的本机记录和应用私有副本。已下载的文件请先另存到系统文件；进行中的任务和待核对的上传将保留。NAS 文件不受影响。',
      primaryButton: { value: '保留', action: (): void => {} },
      secondaryButton: { value: '清理历史', action: (): void => {
        this.runTransfer(async (): Promise<void> => { await this.model.queue.clearHistory(); });
      } } });
  }

  @Builder
  taskPrimaryActions(item: TransferQueueItem) {
              Flex({ wrap: FlexWrap.Wrap }) {
                if (item.canRetry) {
                  Button('重试').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.NORMAL)
                    .enabled(!this.model.queue.busy && !this.model.busy && !this.transferSubmitting)
                    .onClick((): void => { this.runTransfer(async (): Promise<void> => { await this.model.queue.retry(item.id); }); })
                }
                if (item.state === 'unknown') {
                  Button('重新确认').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
                    .enabled(!this.model.queue.busy && !this.model.busy && !this.transferSubmitting)
                    .onClick((): void => { this.runTransfer(async (): Promise<void> => { await this.model.queue.reconcile(); }); })
                }
                if (item.canClose) {
                  Button('核对后关闭').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
                    .enabled(!this.model.queue.busy && !this.model.busy && !this.transferSubmitting)
                    .onClick((): void => { this.confirmCloseUpload(item); })
                }
                if (item.canExport) {
                  Button('另存到系统文件').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.NORMAL)
                    .enabled(!this.model.queue.busy && !this.model.busy && !this.transferSubmitting)
                    .onClick((): void => { this.runTransfer(async (): Promise<void> => { await this.model.queue.exportDownload(item.id); }); })
                }
              }.width('100%')
  }

  @Builder
  taskMenu(item: TransferQueueItem) {
    Menu() {
      MenuItem({ content: '任务详情' }).onClick((): void => { this.openTask(item); })
      if (item.canCancel) {
        MenuItem({ content: '取消任务' }).onClick((): void => { this.confirmCancelTask(item); })
      }
      if (item.canRemove) {
        MenuItem({ content: item.state === 'clearing' ? '重试清理' : '清理记录' })
          .onClick((): void => { this.confirmRemoveRecord(item); })
      }
    }
  }

  @Builder
  taskPageMenu() {
    Menu() {
      MenuItem({ content: '清理已结束的记录' })
        .enabled(this.model.queue.ready && this.model.queue.items.some((item: TransferQueueItem): boolean => item.canRemove))
        .onClick((): void => { this.confirmClearHistory(); })
    }
  }

  @Builder
  tasksView() {
    Column() {
      List({ space: 12, scroller: this.tasksScroller }) {
        ListItem() {
          Flex({ wrap: FlexWrap.Wrap }) {
            WorkbenchChoice({ label: '传输任务', selected: this.taskSection === 'transfers',
              onSelect: (): void => { this.taskSection = 'transfers'; } })
            WorkbenchChoice({ label: '文件整理', selected: this.taskSection === 'files',
              onSelect: (): void => { this.taskSection = 'files'; } })
            if (this.model.drive.available || this.model.driveTransfers.items.length > 0) {
              WorkbenchChoice({ label: 'Drive 传输', selected: this.taskSection === 'drive',
                onSelect: (): void => { this.taskSection = 'drive'; } })
            }
            if (this.model.driveActions.available || this.model.driveActions.items.length > 0) {
              WorkbenchChoice({ label: 'Drive 文件操作', selected: this.taskSection === 'drive-actions',
                onSelect: (): void => { this.taskSection = 'drive-actions'; } })
            }
            if (this.model.supports('SYNO.DownloadStation.Task')) {
              WorkbenchChoice({ label: 'NAS 下载', selected: false, onSelect: (): void => { this.openNasDownloads(); } })
            }
          }.width('100%').padding({ top: this.contentTopInset() + 8 })
        }
        if (this.taskSection === 'drive') {
          ListItem() { DriveTransferSummary({ model: this.model.driveTransfers }) }
          Repeat<DriveTransferRecord>(this.model.driveTransfers.items).each((task: RepeatItem<DriveTransferRecord>): void => {
            ListItem() { DriveTransferCard({ model: this.model.driveTransfers, item: task.item }) }
          }).key((item: DriveTransferRecord): string => item.id).virtualScroll()
        } else if (this.taskSection === 'drive-actions') {
          ListItem() { DriveActionSummary({ model: this.model.driveActions }) }
          Repeat<DriveActionRecord>(this.model.driveActions.items).each((task: RepeatItem<DriveActionRecord>): void => {
            ListItem() { DriveActionCard({ model: this.model.driveActions, item: task.item,
              onFiles: (): void => { this.returnDriveFiles(); } }) }
          }).key((item: DriveActionRecord): string => item.id).virtualScroll()
        } else if (this.taskSection === 'files') {
        ListItem() {
          Column({ space: 8 }) {
            Row({ space: 12 }) {
              Text('文件整理').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).layoutWeight(1)
              if (!this.model.fileTasksReady) {
                Button('重新加载').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.busy)
                  .onClick((): void => { this.model.reloadFileTasks(); })
              }
            }.width('100%')
            if (this.model.fileTasksErrorText.length > 0) {
              Text(this.model.fileTasksErrorText).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
            } else if (this.model.fileTasks.length === 0) {
              Text('复制、移动和删除的处理结果会保存在这里。').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
            }
          }.width('100%').padding({ top: 8, bottom: 8 })
        }
        Repeat<FileTaskItem>(this.model.fileTasks).each((task: RepeatItem<FileTaskItem>): void => {
          ListItem() {
            Column({ space: 6 }) {
              Text(task.item.label).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
              Text(this.fileTaskStateText(task.item)).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
              if (task.item.errorText.length > 0) {
                WorkbenchNotice({ text: task.item.errorText, warning: true })
              }
              if (task.item.state === 'pending' || task.item.state === 'unknown') {
                Button('查询结果').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.busy)
                  .onClick((): void => { this.model.checkFileTask(task.item.id); })
              }
            }.width('100%').padding(16).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
          }
        }).key((item: FileTaskItem): string => item.id).virtualScroll()
        } else {
        ListItem() {
          Column({ space: 8 }) {
            Row({ space: 12 }) {
              Text('传输队列').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).layoutWeight(1)
              Button(this.model.queue.ready ? '刷新状态' : '重新加载').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
                .enabled(!this.model.queue.busy && !this.model.busy && !this.transferSubmitting)
                .onClick((): void => { this.runTransfer(async (): Promise<void> => { await this.model.queue.reconcile(); }); })
              Button() { SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(22).fontColor([$r('sys.color.icon_primary')]) }
                .width(48).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).type(ButtonType.Circle).backgroundColor(Color.Transparent)
                .enabled(!this.model.queue.busy && !this.model.busy && !this.transferSubmitting)
                .bindMenu(this.taskPageMenu()).accessibilityText('任务，更多操作')
            }.width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(['all', 'active', 'finished'], (filter: string): void => {
                WorkbenchChoice({ label: filter === 'all' ? '全部' : filter === 'active' ? '待处理' : '已结束',
                  selected: this.taskFilter === filter, onSelect: (): void => { this.taskFilter = filter; } })
              }, (filter: string): string => filter)
            }.width('100%')
            this.notices()
          }.width('100%').padding({ top: 8, bottom: 8 })
        }
        if (!this.model.queue.ready) {
          ListItem() { this.emptyState($r('sys.symbol.arrow_down_circle'), '队列尚未加载', '已暂停新的传输，请重新加载任务记录。') }
        } else if (this.model.queue.items.length === 0) {
          ListItem() { this.emptyState($r('sys.symbol.arrow_down_circle'), '暂无传输任务', '在文件页选择上传，或打开文件详情进行下载。') }
        }
        if (this.model.queue.ready && this.model.queue.items.length > 0 && this.filteredTasks().length === 0) {
          ListItem() { this.emptyState($r('sys.symbol.arrow_down_circle'), '此分类暂无任务', '切换到“全部”查看其他任务。') }
        }
        Repeat<TransferQueueItem>(this.filteredTasks()).each((task: RepeatItem<TransferQueueItem>): void => {
          ListItem() {
            Row({ space: 4 }) {
              Button() {
                Row({ space: 12 }) {
                  WorkbenchIconTile({ icon: task.item.direction === 'upload' ? $r('sys.symbol.arrow_up_circle') : $r('sys.symbol.arrow_down_circle'),
                    iconSize: 20, tileSize: 40, tileRadius: 12,
                    iconColor: $r('sys.color.icon_emphasize'), tileColor: $r('app.color.workbench_accent_surface') })
                  Column({ space: 4 }) {
                    Text(task.item.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                    Progress({ value: this.taskProgress(task.item), total: 100, type: ProgressType.Linear })
                      .width('100%').height(4).visibility(task.item.bytes > 0 ? Visibility.Visible : Visibility.Hidden)
                      .accessibilityText(task.item.bytes > 0 ? '已传输 ' + this.taskProgress(task.item).toFixed(0) + '%' : '大小未知')
                    Row({ space: 8 }) {
                      Text(workbenchBytes(task.item.processed) + (task.item.bytes > 0 ? ' / ' + workbenchBytes(task.item.bytes) : ' · 大小未知'))
                        .fontSize(12).fontColor($r('sys.color.font_secondary')).layoutWeight(1).maxLines(1)
                      Text(task.item.stateText).fontSize(12).fontColor($r('sys.color.font_secondary')).maxLines(1)
                    }.width('100%')
                    if (task.item.errorText.length > 0) {
                      Text(task.item.errorText).fontSize(12).fontColor($r('app.color.workbench_warning'))
                        .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }.width('100%')
              }.type(ButtonType.Normal).backgroundColor(Color.Transparent).layoutWeight(1).constraintSize({ minHeight: 48 })
                .padding(0).onClick((): void => { this.openTask(task.item); })
                .accessibilityText(task.item.name + '，' + task.item.stateText + '，查看详情')
              if (task.item.canCancel) {
                Button('取消').fontSize(12).width(48).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
                  .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.queue.busy && !this.model.busy && !this.transferSubmitting)
                  .onClick((): void => { this.confirmCancelTask(task.item); }).accessibilityText('取消' + task.item.name)
              }
              Button() { SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(20).fontColor([$r('sys.color.font_secondary')]) }
                .width(48).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).type(ButtonType.Circle).backgroundColor(Color.Transparent)
                .enabled(!this.model.queue.busy && !this.model.busy && !this.transferSubmitting)
                .bindMenu(this.taskMenu(task.item)).accessibilityText(task.item.name + '，更多操作')
            }.width('100%').padding({ left: 10, right: 4, top: 10, bottom: 10 })
              .borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
          }
        }).key((item: TransferQueueItem): string => item.id).virtualScroll()
        }
      }.width('100%').height('100%').scrollBar(BarState.Auto).contentEndOffset(this.bottomInset())
    }.width('100%').constraintSize({ maxWidth: 960 }).height('100%').padding({ left: 16, right: 16 })
  }

  private sharedFileTitle(): string {
    const inbox = this.model.sharedInbox;
    if (inbox.files.length === 0) { return inbox.receiving ? '正在接收分享文件…' : '分享文件'; }
    return inbox.files[0].fileName + (inbox.pendingCount > 1 ? ' 等 ' + inbox.pendingCount.toString() + ' 个文件' : '');
  }

  private confirmSharedUpload(): void {
    this.getUIContext().showAlertDialog({ title: '上传分享文件',
      message: '将 ' + this.model.sharedInbox.pendingCount.toString() + ' 个文件上传到 ' + this.model.directory + '。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '上传', action: (): void => {
        this.runTransfer(async (): Promise<void> => { await this.model.uploadSharedFiles(); });
      } } });
  }

  @Builder
  sharedInboxCard() {
    if (this.model.sharedInbox.receiving || this.model.sharedInbox.pendingCount > 0 || this.model.sharedInbox.errorText.length > 0) {
      Column({ space: 8 }) {
        Text(this.sharedFileTitle()).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
        if (this.model.sharedInbox.errorText.length > 0) {
          Text(this.model.sharedInbox.errorText).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
        }
        if (!this.model.authenticated) {
          Text('登录后选择 NAS 文件夹即可上传。').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        } else {
          Text(this.model.directory.length === 0 ? '请在文件页选择目标文件夹。' : '目标：' + this.model.directory)
            .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        }
        Flex({ wrap: FlexWrap.Wrap }) {
          if (this.model.authenticated) {
            Button(this.model.directory.length === 0 ? '选择目标文件夹' : '上传到此文件夹').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .buttonStyle(ButtonStyleMode.NORMAL)
              .enabled(this.model.queue.ready && !this.model.sharedInbox.receiving && !this.model.queue.busy && !this.model.busy &&
                !this.transferSubmitting && this.model.sharedInbox.pendingCount > 0)
              .onClick((): void => {
                if (this.model.directory.length === 0) { this.switchTab(1); }
                else { this.confirmSharedUpload(); }
              })
          }
          Button('取消接收').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(!this.model.sharedInbox.receiving && !this.model.queue.busy && !this.model.busy)
            .onClick((): void => { this.model.discardSharedFiles(); })
        }.width('100%')
      }.width('100%').constraintSize({ maxWidth: 960 }).padding(16).borderRadius(WorkbenchMetrics.innerRadius)
        .backgroundColor($r('app.color.workbench_surface')).margin({ left: 16, right: 16, top: this.contentTopInset() + 8, bottom: 8 })
    }
  }

  @Builder
  sortOption(field: string, label: string) {
    Button() {
      Row({ space: 12 }) {
        Text(label).fontSize(16).fontColor($r('sys.color.font_primary')).layoutWeight(1)
        Text(this.model.fileSort === field ? '✓' : '').fontSize(20).fontColor($r('sys.color.font_emphasize'))
      }.width('100%').padding(16)
    }.width('100%').constraintSize({ minHeight: 56 }).type(ButtonType.Normal).backgroundColor(Color.Transparent)
      .enabled(!this.model.busy && (field !== 'size' || this.model.directory.length > 0))
      .onClick((): void => { this.model.setSort(field as 'name' | 'size' | 'mtime', this.model.sortDescending); })
      .accessibilityText(label + (this.model.fileSort === field ? '，已选择' : ''))
  }

  @Builder
  taskDetail(item: TransferQueueItem) {
    WorkbenchSectionTitle({ title: item.name, subtitle: item.stateText })
    Column() {
      WorkbenchInfoRow({ label: '方向', value: item.direction === 'upload' ? '上传到 NAS' : '下载到此设备' })
      WorkbenchInfoRow({ label: item.direction === 'upload' ? '目标' : '来源', value: item.remotePath })
      WorkbenchInfoRow({ label: '大小', value: workbenchBytes(item.bytes) })
      if (item.state === 'running' || item.state === 'waiting') {
        WorkbenchInfoRow({ label: '已传输', value: workbenchBytes(item.processed) })
      }
    }.width('100%').padding(16).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_subtle'))
    WorkbenchNotice({ text: item.errorText, warning: true })
    this.taskPrimaryActions(item)
    Button('更多操作').constraintSize({ minHeight: 48 }).width('100%').buttonStyle(ButtonStyleMode.TEXTUAL)
      .enabled(!this.model.queue.busy && !this.model.busy && !this.transferSubmitting).bindMenu(this.taskMenu(item))
  }

  /**
   * 小弹层（FIT_CONTENT）的标题行，放在滚动内容首行。
   * 这类弹层不挂 HDS 半模态标题栏，而 SheetOptions.title 只要传了 builder，
   * 即使里面什么都不画，系统仍会按标题栏占位（实测留出约 72vp 空白带），
   * 所以干脆不给 title，标题由内容自己画。
   */
  @Builder
  sheetPlainTitle() {
    Row() {
      Text(this.sheetTitle()).fontSize(20).fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary')).layoutWeight(1)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      // 给右上角的系统关闭按钮让出宽度，长标题在按钮前省略。
      Row().width(WorkbenchMetrics.touchSize).height(32)
    }.width('100%').constraintSize({ minHeight: 56 })
      .alignItems(VerticalAlign.Center)
  }

  /** 设备信息：按信息类型分成多张卡片区格，卡片内同类信息用细分隔线，卡片外不加分组标题。 */
  @Builder
  deviceSheet() {
    Column({ space: WorkbenchMetrics.sectionGap }) {
      Column() {
        WorkbenchInfoRow({ label: '账号', value: this.model.account })
        this.infoDivider()
        WorkbenchInfoRow({ label: '连接地址', value: this.model.address })
        this.infoDivider()
        WorkbenchInfoRow({ label: '连接方式', value: this.connectionSecurityText() })
      }.width('100%').padding({ left: 16, right: 16, top: WorkbenchMetrics.infoCardPadding, bottom: WorkbenchMetrics.infoCardPadding })
        .borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_subtle'))
      Column() {
        if (this.deviceInfo.length > 0) {
          WorkbenchInfoRow({ label: '设备型号', value: this.deviceInfo[0] })
          this.infoDivider()
          WorkbenchInfoRow({ label: 'DSM 版本', value: this.deviceInfo[1] })
          this.infoDivider()
          WorkbenchInfoRow({ label: '文件服务', value: this.deviceInfo[2] })
          this.infoDivider()
          WorkbenchInfoRow({ label: '照片服务', value: this.deviceInfo[3] })
          this.infoDivider()
          WorkbenchInfoRow({ label: '文件权限', value: this.deviceInfo[4] })
        } else if (this.model.busy) {
          LoadingProgress().width(32).height(32).margin(12)
        } else {
          Button('重新读取设备信息').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .onClick((): void => { this.showDeviceInfo(); })
        }
      }.width('100%').padding({ left: 16, right: 16, top: WorkbenchMetrics.infoCardPadding, bottom: WorkbenchMetrics.infoCardPadding })
        .borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_subtle'))
      Button('退出当前账号').constraintSize({ minHeight: 48 }).width('100%').buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontColor($r('app.color.workbench_danger')).enabled(!this.model.busy).onClick((): void => { this.confirmLogout(); })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 卡片内相邻信息行之间的细分隔线，与信息文字左边缘对齐。 */
  @Builder
  infoDivider() {
    Divider().color($r('app.color.workbench_divider'))
  }

  /** 半模态内容：所有弹层共用的滚动容器。 */
  @Builder
  sheetScroll() {
    Scroll(this.sheetScroller) {
      Column({ space: 16 }) {
        if (!this.sheetUsesModalTitleBar()) {
          this.sheetPlainTitle()
        }
        if (this.sheetKind === 'device') {
          this.deviceSheet()
        } else if (this.sheetKind === 'task') {
          if (this.selectedTask() !== undefined) { this.taskDetail(this.selectedTask()!) }
          else { WorkbenchNotice({ text: '此任务记录已清理。' }) }
        } else if (this.sheetKind === 'file-add' || this.sheetKind === 'file-tools') {
          this.filePageTools()
        } else if (this.sheetKind === 'sort') {
          Column() {
            this.sortOption('name', '名称')
            Divider().color($r('app.color.workbench_divider')).margin({ left: 16, right: 16 })
            this.sortOption('size', '大小')
            Divider().color($r('app.color.workbench_divider')).margin({ left: 16, right: 16 })
            this.sortOption('mtime', '修改时间')
          }.width('100%').borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_subtle'))
          Flex({ wrap: FlexWrap.Wrap }) {
            WorkbenchChoice({ label: '升序', selected: !this.model.sortDescending, available: !this.model.busy,
              onSelect: (): void => { this.model.setSort(this.model.fileSort as 'name' | 'size' | 'mtime', false); } })
            WorkbenchChoice({ label: '降序', selected: this.model.sortDescending, available: !this.model.busy,
              onSelect: (): void => { this.model.setSort(this.model.fileSort as 'name' | 'size' | 'mtime', true); } })
          }.width('100%')
        } else if (this.sheetKind === 'create' || this.sheetKind === 'rename') {
          WorkbenchInfoRow({ label: this.sheetKind === 'create' ? '位置' : '原名称',
            value: this.sheetKind === 'create' ? this.model.directory : (this.selectedEntry?.name ?? '') })
          TextInput({ text: this.formName, placeholder: this.sheetKind === 'create' ? '文件夹名称' : '新名称' })
            .constraintSize({ minHeight: 48 }).enabled(!this.formSubmitting && !this.model.busy)
            .onChange((text: string): void => { this.formName = text; }).accessibilityText('名称')
          Text('名称不能包含斜杠、冒号或控制字符。').fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%')
          Button(this.formSubmitting ? '正在保存…' : '保存').width('100%').constraintSize({ minHeight: 48 })
            .enabled(this.validName() && !this.formSubmitting && !this.model.busy).onClick((): void => { this.submitName(); })
        } else if (this.sheetKind === 'backup') {
          WorkbenchNotice({ text: '重名内容已添加序号。上传完成后，可在任务页核对结果。' })
          ForEach(this.backup.sources, (backupSource: TransferUploadSource): void => {
            Column({ space: 6 }) {
              WorkbenchInfoRow({ label: backupSource.name, value: workbenchBytes(backupSource.bytes) })
              Divider().color($r('app.color.workbench_divider'))
            }.width('100%')
          }, (backupSource: TransferUploadSource): string => backupSource.uri)
        } else if (this.selectedEntry !== undefined) {
          Row({ space: 12 }) {
            WorkbenchIconTile({ icon: this.selectedEntry.isDirectory ? $r('sys.symbol.folder') : $r('sys.symbol.doc'),
              iconSize: 26, tileSize: 48, tileRadius: 12,
              iconColor: $r('sys.color.icon_emphasize'), tileColor: $r('app.color.workbench_accent_surface') })
            Text(this.selectedEntry.name).fontSize(18).fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary')).layoutWeight(1)
          }.width('100%')
          if (this.sheetKind === 'actions') {
            this.fileActions(this.selectedEntry)
          } else {
            Column() {
              WorkbenchInfoRow({ label: '类型', value: this.selectedEntry.isDirectory ? '文件夹' : '文件' })
              WorkbenchInfoRow({ label: '位置', value: this.selectedEntry.path })
              if (!this.selectedEntry.isDirectory) {
                WorkbenchInfoRow({ label: '大小', value: workbenchBytes(this.selectedEntry.bytes) })
              }
            }.width('100%').padding(16).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_subtle'))
            this.fileActions(this.selectedEntry)
            if (!this.selectedEntry.isDirectory && this.model.supports('SYNO.FileStation.Download')) {
              Text('下载完成后，可在任务页另存到系统文件。').fontSize(12).fontColor($r('sys.color.font_tertiary'))
            }
          }
        }
        this.notices()
      }.width('100%').padding({ left: WorkbenchMetrics.sheetMargin, right: WorkbenchMetrics.sheetMargin,
        // HDS 半模态标题栏悬浮在内容之上，内容要按标题栏高度让位，否则首行被盖住。
        top: 16 + (this.sheetUsesModalTitleBar() ? WorkbenchMetrics.sheetTitleBarHeight : 0), bottom: 32 })
        .alignItems(HorizontalAlign.Start)
    }.width('100%').scrollBar(BarState.Auto)
      // 官方《绑定半模态页面》要求：面板内容里自带滚动容器时，必须显式声明嵌套滚动，
      // 否则手势会被内层 Scroll 吞掉，只有标题栏区域能拖动整个半模态。默认 {PARENT_FIRST, SELF_FIRST}。
      .nestedScroll({
        scrollForward: NestedScrollMode.PARENT_FIRST,
        scrollBackward: NestedScrollMode.SELF_FIRST
      })
  }

  /**
   * 官方「半模态样式」：半模态内挂 HdsNavigation、titleMode 用 MODAL，
   * 标题栏按钮的沉浸光感走 TitleBarStyleOptions.systemMaterialEffect。
   */
  @Builder
  sheetWithModalTitleBar() {
    HdsNavigation() {
      this.sheetScroll()
    }.width('100%').height('100%')
      .hideBackButton(true)
      .titleMode(HdsNavigationTitleMode.MODAL)
      .bindToScrollable([this.sheetScroller])
      .titleBar({
        enableComponentSafeArea: false,
        // HDS 半模态标题栏本体没有额外左缩进（实测标题落在 x=0），给 sheetMargin 即与卡片左边缘对齐。
        padding: {
          start: LengthMetrics.vp(WorkbenchMetrics.sheetMargin),
          end: LengthMetrics.vp(WorkbenchMetrics.sheetMargin)
        },
        content: {
          title: { mainTitle: this.sheetTitle() },
          menu: {
            value: [{ content: { icon: $r('sys.symbol.xmark'), type: IconStyleMode.SMALL,
              action: (): void => { this.sheetVisible = false; } } }]
          }
        },
        style: {
          systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE }
        }
      })
  }

  @Builder
  fileSheet() {
    if (this.sheetUsesModalTitleBar()) {
      this.sheetWithModalTitleBar()
    } else {
      this.sheetScroll()
    }
  }

  build() {
    Column() {
      HdsNavigation(this.navStack) {
        Column() {
          if (this.bootPending && !this.model.authenticated) {
            this.bootView()
          } else {
            this.sharedInboxCard()
            if (this.model.authenticated) {
              HdsTabs({ controller: this.tabsController, index: this.activeTab }) {
                ForEach(this.visibleTabs(), (tab: ModuleTab): void => {
                  TabContent() { this.modulePage(tab) }
                    .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier(this.tabIcon(tab.id)) }, tab.label))
                }, (tab: ModuleTab): string => this.module + ':' + tab.id)
              }.width('100%').layoutWeight(1).barPosition(BarPosition.End).scrollable(false)
                .barOverlap(true).vertical(false)
                .barFloatingStyle({ barBottomMargin: this.navigationInset, systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE,
                  materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE }, thermoCtrl: true })
                .onContentWillChange((current: number, target: number): boolean => target === this.activeTab || !this.navigationBusy())
                .onTabBarClick((index: number): void => {
                  if (index === this.activeTab) { this.activeScrollers()[0].scrollTo({ xOffset: 0, yOffset: 0 }); }
                })
                .onChange((index: number): void => { this.selectModuleTab(index); })
            } else { this.loginView() }
          }
        }.width('100%').height('100%')
      }.width('100%').height('100%').backgroundColor($r('app.color.workbench_background')).mode(NavigationMode.Stack).hideBackButton(this.module === 'root')
        .hideTitleBar(!this.model.authenticated)
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .navDestination(this.destinationBuilder).bindToScrollable(this.activeScrollers())
        .titleMode(HdsNavigationTitleMode.MINI).titleBar({ enableComponentSafeArea: false,
          content: { title: { mainTitle: this.pageTitle() },
            backIcon: this.module === 'root' ? undefined : { label: '返回', action: (): void => { this.exitModule(); }, type: TextStyleMode.NORMAL },
            menu: { value: this.pageMenu(), maxCount: 2 } },
          style: { scrollEffectOpts: { enableScrollEffect: false, scrollEffectType: ScrollEffectType.GRADIENT_BLUR },
            systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE, materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE },
            originalStyle: { backgroundStyle: { blurRadius: 12, maskExtraHeight: 16 },
              contentStyle: { titleStyle: { mainTitleColor: $r('sys.color.font_primary') } } } } })
    }.width('100%').height('100%').backgroundColor($r('app.color.workbench_background'))
      .onAreaChange((oldArea: Area, newArea: Area): void => {
        this.windowWidth = Number(newArea.width);
        this.windowHeight = Number(newArea.height);
      })
      .bindSheet($$this.sheetVisible, this.fileSheet(), {
        height: this.sheetKind === 'backup' || this.sheetKind === 'device' || this.sheetKind === 'task' ? SheetSize.LARGE : SheetSize.FIT_CONTENT,
        preferType: this.windowWidth < 600 ? SheetType.BOTTOM : SheetType.CENTER,
        // 关闭按钮由 sheetTitleBar() 自绘，系统关闭图标关闭，避免出现两个关闭入口。
        // HDS 半模态标题栏自带关闭按钮时关掉系统的那个，避免两个关闭入口。
        showClose: !this.sheetUsesModalTitleBar(),
        backgroundColor: this.sheetMaterialAvailable ? Color.Transparent : $r('app.color.workbench_surface'),
        systemMaterial: this.sheetMaterial,
        // 不给 title：传任何 builder 系统都会按标题栏占位，HDS 弹层的标题由 HdsNavigation 提供，
        // 小弹层的标题画在内容首行（sheetPlainTitle）。
        title: undefined,
        keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL
      })
  }
}
