import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { ComponentContent, curves, DrawableDescriptor, LengthMetrics, SymbolGlyphModifier, uiMaterial, window,
  ToolBarV2, ToolBarV2Item, ToolBarV2ItemText, ToolBarV2ItemState, ToolBarV2SymbolGlyph } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileUri } from '@kit.CoreFileKit';
import { HdsNavigation, HdsSideBar, HdsNavigationTitleMode, HdsNavDestination, HdsTabs, HdsTabsController, hdsMaterial, SystemMaterialParams, IconStyleMode, TextStyleMode, ScrollEffectType, HdsNavigationMenuItemOptions, HdsSnackBar, SnackBarOperationType } from '@kit.UIDesignKit';
import { NasFailure, NasFileEntry } from '../core/domain/DsmProtocol';
import { DriveEntry, DriveEntryKind, DriveView, driveViewLabel } from '../core/domain/DriveProtocol';
import { DriveUploadReview, DriveTransferModePicker } from '../features/drive/DriveTransferUi';
import type { DriveAction } from '../core/domain/DriveActionProtocol';
import { DriveActionPage } from '../features/drive/DriveActionUi';
import { DriveOriginalPage } from '../features/drive/DriveOriginalUi';
import { ImagePreview, PreviewInformation } from '../features/workbench/ImagePreview';
import { telemetryTimestamp } from '../core/domain/TelemetryProtocol';
import { driveActionAllowed } from '../core/domain/DriveActionProtocol';
import { canPreviewDriveOriginal } from '../core/domain/DriveOriginalProtocol';
import { driveFileLinkAllowed } from '../core/domain/DriveCollaborationProtocol';
import { ExtensionStatusPanel } from '../features/extensions/ExtensionStatusPanel';
import { PhotoAction, PhotoActionInput, PhotoFolder } from '../core/domain/PhotoActions';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { takeAllTransferIntent, takeDriveTransferIntent } from '../features/drive/DriveTransferIntent';
import { DriveSharingPage, DriveNotificationsPage } from '../features/drive/DriveCollaborationUi';
import { NasPhotoAlbum, NasPhotoItem, PhotosSpace } from '../core/domain/PhotosProtocol';
import { PhotoUpload } from '../features/photos/PhotoUpload';
import { PhotoBackupSettingsPage } from '../features/backup/PhotoBackupSettingsPage';
import { TransferQueue, TransferUploadSource } from '../features/transfers/TransferQueue';
import { DriveTransferModel } from '../features/drive/DriveTransferModel';
import { TransferLiveView } from '../features/tasks/TransferLiveView';
import { TaskScope, taskRecords, taskEnded } from '../core/domain/TaskPresentation';
import { DownloadSubmitResult } from '../core/domain/DownloadSubmitResult';
import { TaskPage } from '../features/tasks/TaskPage';
import { TaskPageState } from '../features/tasks/TaskPageState';
import { ConnectionViewModel } from '../features/connection/ConnectionViewModel';
import { NasConnectionAddressPage } from '../features/connection/ConnectionAddressPage';
import { NasConnectionAddress } from '../core/domain/ConnectionRoutes';
import { NasSystemControlPage } from '../features/control/SystemControlPage';
import { ShareLinksPage } from '../features/fileSharing/ShareLinksPage';
import { DownloadStationPage } from '../features/downloadStation/DownloadStationPage';
import { PackageCatalogPage, PackageDetailPage } from '../features/packages/PackageCatalogPage';
import { OfficialWebPage } from '../features/packages/OfficialWebPage';
import { InstalledPackage, PackageNativeTarget } from '../features/packages/PackageProtocol';
import { MoreFeaturesPage } from '../features/workbench/MoreFeaturesPage';
import { ContainerPage } from '../features/containers/ContainerPage';
import { CloudSyncPage } from '../features/cloudsync/CloudSyncPage';
import { SystemLogPage } from '../features/systemlogs/SystemLogPage';
import { NoteStationPage } from '../features/notes/NoteStationPage';
import { NasTelemetrySummary, NasTelemetryStorageCard, NasTelemetryDashboard } from '../features/telemetry/TelemetryDashboard';
import { photoTakenDate, workbenchBytes,
  workbenchCanUseDestination, workbenchBottomInset,
  connectionRouteLabel, workbenchProtocolHint } from '../features/workbench/WorkbenchPresentation';
import { bundledDeviceArtwork, fallbackDeviceArtwork, hasModelArtwork, deviceArtworkPath } from '../features/workbench/NasDeviceArtwork';

import { WorkbenchMetrics, WorkbenchIconTile, WorkbenchSectionTitle, WorkbenchInfoRow, WorkbenchNotice, WorkbenchChoice, WorkbenchActionRow, WorkbenchEmptyState } from '../features/workbench/WorkbenchUi';

import { ModuleTab, WorkbenchModule, ModuleTabSettings, rootTabs, driveTabs, driveMoreViews, photoTabs,
  moduleTabIndex, rootReturnIndex, ROOT_TASK_TAB, ROOT_SETTINGS_TAB, DRIVE_MORE_VIEWS, supportsPhotoSharing,
  supportsPhotos, supportsPhotoBackup } from '../features/workbench/ModuleNavigation';
import { ModuleTabStore } from '../features/workbench/ModuleTabStore';
import { WorkbenchSettings } from '../features/workbench/WorkbenchSettings';
import { FileStationPage } from '../features/files/FileStationPage';
import { DriveModulePage } from '../features/drive/DriveModulePage';
import { DriveBrowserModel } from '../features/drive/DriveBrowserModel';
import { PhotoModulePage } from '../features/photos/PhotoModulePage';
import type { PhotoLibrarySection } from '../features/photos/PhotoLibrary';

type FileSelectionAction = 'share' | 'copy' | 'move' | 'delete' | 'download';

class TitleMenuItem {
  id: string;
  label: string;
  enabled: boolean;
  action: () => void;
  constructor(label: string, enabled: boolean, action: () => void, id: string = '') {
    this.label = label; this.enabled = enabled; this.action = action; this.id = id;
  }
}

@Builder
function titleMenu(items: TitleMenuItem[]) {
  Menu() {
    ForEach(items, (item: TitleMenuItem): void => {
      MenuItem({ content: item.label }).enabled(item.enabled).onClick(item.action)
    }, (item: TitleMenuItem): string => item.label)
  }
}

@Entry
@ComponentV2
struct Index {
  @Local private model: ConnectionViewModel = new ConnectionViewModel();
  @Local private observedQueue: TransferQueue = this.model.queue;
  @Local private observedDriveTransfers: DriveTransferModel = this.model.driveTransfers;
  @Local private observedDriveBrowser: DriveBrowserModel = this.model.drive;
  @Local private transferLiveView: TransferLiveView = new TransferLiveView();
  @Local private activeTab: number = 0;
  @Local private module: WorkbenchModule = 'root';
  @Local private rootTab: number = 0;
  @Local private driveTabId: string = 'mydrive';
  @Local private photoTabId: string = 'photos';
  @Local private driveMoreView: string = '';
  private driveSearchScroller: ListScroller = new ListScroller();
  private photoBackupScroller: Scroller = new Scroller();
  @Local private photoBackupViewportTop: number = 0;
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
  @Local private preferences: WorkbenchSettings = new WorkbenchSettings();
  @Local private appearanceMenuVisible: boolean = false;
  @Local private pickerMode: string = '';
  @Local private navigationInset: number = 0;
  @Local private statusInset: number = 0;
  /** 启动恢复期间只呈现加载页；恢复结束后才显示登录表单或主界面。 */
  @Local private bootPending: boolean = true;
  @Local private bootEscapable: boolean = false;
  private bootTimer: number = -1;
  private mainWindow: window.Window | undefined = undefined;
  @Local private photoPreviewOpened: boolean = false;
  @Local private photoControlsVisible: boolean = true;
  private normalWindowFullScreen: boolean = false;
  private photoWindowUpdate: Promise<void> = Promise.resolve();
  private pageActive: boolean = false;
  private foreground: boolean = true;
  private abilityContext: common.UIAbilityContext | undefined = undefined;
  @Local private applicationIcon: DrawableDescriptor | undefined = undefined;
  @Local private telemetryOpened: boolean = false;
  @Local private addressBookOpened: boolean = false;
  @Local private systemControlOpened: boolean = false;
  @Local private extensionsOpened: boolean = false;
  @Local private packageDestination: string = '';
  @Local private downloadsVisible: boolean = false;
  @Local private downloadsRefreshRevision: number = 0;
  /** 半模态内容滚动控制器：既供嵌套滚动使用，也绑定给 HDS 半模态标题栏。 */
  private sheetScroller: Scroller = new Scroller();
  private sharesScroller: Scroller = new Scroller();
  private downloadsScroller: Scroller = new Scroller();
  private packagesScroller: Scroller = new Scroller();
  private packageDetailScroller: Scroller = new Scroller();
  private moreFeaturesScroller: Scroller = new Scroller();
  private containersScroller: Scroller = new Scroller();
  private cloudSyncScroller: Scroller = new Scroller();
  private systemLogsScroller: Scroller = new Scroller();
  private notesScroller: Scroller = new Scroller();
  private telemetryScroller: Scroller = new Scroller();
  private addressBookScroller: Scroller = new Scroller();
  private systemControlScroller: Scroller = new Scroller();
  private driveActionScroller: Scroller = new Scroller();
  private driveLinksScroller: Scroller = new Scroller();
  private driveNotificationsScroller: Scroller = new Scroller();
  private transferNotificationOpened = (): void => {
    if (takeAllTransferIntent()) { this.showAllTasks(); }
    else if (takeDriveTransferIntent()) { this.openDriveTransfers(); }
  };
  private foregroundChanged = (foreground: boolean): void => {
    this.foreground = foreground;
    this.model.driveTransfers.setForeground(foreground);
    this.model.driveThumbnails.setForeground(foreground);
    this.model.driveActions.setForeground(foreground);
    this.model.driveOriginal.setForeground(foreground);
    this.model.fileOriginal.setForeground(foreground);
    this.updatePackageVisibility();
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
  @Local private pendingEntries: NasFileEntry[] = [];
  @Local private fileSelecting: boolean = false;
  @Local private driveSelecting: boolean = false;
  @Local private selectedDriveIds: string[] = [];
  @Local private driveDetailEntry: DriveEntry | undefined = undefined;
  @Local private driveDetailVisible: boolean = false;
  @Local private selectionMenuVisible: boolean = false;
  @Local private selectedFiles: NasFileEntry[] = [];
  @Local private pendingOperation: string = '';
  @Local private transferSubmitting: boolean = false;
  @Local private transferErrorText: string = '';
  private titleMenuContent: ComponentContent<TitleMenuItem[]> | undefined = undefined;
  @Local private backup: PhotoUpload = new PhotoUpload();
  @Local private contentWidth: number = 360;
  @Local private windowWidth: number = 360;
  @Local private windowHeight: number = 800;
  @Local private deviceInfo: string[] = [];
  @Local private rootTasks: TaskPageState = new TaskPageState('root');
  @Local private fileTasks: TaskPageState = new TaskPageState('files');
  @Local private photoTasks: TaskPageState = new TaskPageState('photos');
  @Local private driveTasks: TaskPageState = new TaskPageState('drive');
  @Local private taskDestination: string = '';
  @Local private taskOverlayVisible: boolean = false;
  private fileTasksScroller: Scroller = new Scroller();
  private driveTasksScroller: Scroller = new Scroller();
  private photoTasksScroller: Scroller = new Scroller();
  private downloadSnackBar: HdsSnackBar | undefined = undefined;
  /**
   * 半模态背板的沉浸式系统材质。官方《开启沉浸光感》给半模态/弹窗的推荐档位就是 ULTRA_THICK。
   * 注意材质层在 backgroundColor 之下，所以背板要设成透明色，否则材质被不透明背景盖住看不见。
   */
  private sheetMaterial: uiMaterial.Material =
    new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THICK });
  /** 设备是否支持 ImmersiveMaterial；不支持时退回不透明背板，避免得到一块全透明的弹层。 */
  private sheetMaterialAvailable: boolean = uiMaterial.isImmersiveMaterialSupported();
  @Local private photoDestinationMode: 'album' | 'copy' | 'move' | 'backup' = 'album';
  @Local private photoBatchDestination: boolean = false;
  @Local private photoFolderTrail: PhotoFolder[] = [];
  /** 未收录型号联网取回的产品图路径；为空时用内置图。 */
  @Local private deviceArtworkPath: string = '';
  private readonly artworkSize: number = 64;
  private navStack: NavPathStack = new NavPathStack();
  private homeScroller: Scroller = new Scroller();
  private filesScroller: ListScroller = new ListScroller();
  private driveScrollers: ListScroller[] = [new ListScroller(), new ListScroller(), new ListScroller(), new ListScroller(),
    new ListScroller(), new ListScroller(), new ListScroller(), new ListScroller()];
  private photoScrollers: Scroller[] = [new Scroller(), new Scroller(), new Scroller(), new Scroller(), new Scroller(), new Scroller()];
  private settingsScroller: Scroller = new Scroller();
  private tabSettingsScroller: Scroller = new Scroller();
  private pickerScroller: ListScroller = new ListScroller();
  private taskCategoryScrollers: Scroller[] = [new Scroller(), new Scroller(), new Scroller(), new Scroller()];
  private tabsController: HdsTabsController = new HdsTabsController();
  /** 不支持沉浸材质时交由导航组件呈现默认背景。 */
  private navigationMaterial: SystemMaterialParams | undefined = undefined;

  aboutToAppear(): void {
    this.pageActive = true;
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (hdsMaterial.getSystemMaterialTypes().includes(hdsMaterial.MaterialType.IMMERSIVE)) {
        this.navigationMaterial = { materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE };
      } else {
        this.navigationMaterial = undefined;
      }
    } else {
      this.navigationMaterial = undefined;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.abilityContext = context;
    this.preferences.load(context);
    this.applicationIcon = context.resourceManager.getDrawableDescriptor(context.applicationInfo.iconId);
    this.loadTabSettings();
    context.eventHub.on('nas-foreground-change', this.foregroundChanged);
    context.eventHub.on('nas-open-drive-transfers', this.transferNotificationOpened);
    this.transferNotificationOpened();
    this.updateTelemetryMode();
    this.restoreSession(context);
    window.getLastWindow(context).then((mainWindow: window.Window): void => {
      if (!this.pageActive) { return; }
      this.mainWindow = mainWindow;
      this.normalWindowFullScreen = mainWindow.getWindowProperties().isLayoutFullScreen;
      this.navigationInset = this.getUIContext().px2vp(mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height);
      this.statusInset = this.getUIContext().px2vp(mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height);
      mainWindow.on('avoidAreaChange', this.navigationAreaChanged);
      if (this.photoPreviewOpened) { this.updatePhotoPreviewWindow(); }
    }).catch((): void => { hilog.error(0x0000, 'NasLayout', 'operation=navigation_avoid_area result=failed'); });
  }
  aboutToDisappear(): void {
    this.closeTitleMenu();
    if (this.photoPreviewOpened) { this.photoPreviewOpened = false; this.updatePhotoPreviewWindow(); }
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
    if (this.selectionMenuVisible) { this.selectionMenuVisible = false; return true; }
    if (this.driveDetailVisible) { this.driveDetailVisible = false; return true; }
    if (this.titleMenuContent !== undefined) { this.closeTitleMenu(); return true; }
    if (this.bootPending) { this.leaveBootScreen(); return true; }
    if (this.sheetVisible) { if (!this.formSubmitting && !this.backup.submitting) { this.sheetVisible = false; } return true; }
    if (this.navStack.size() > 0) {
      if (this.navStack.getAllPathName().slice(-1)[0] === 'drive-search' && this.driveSelecting) { this.cancelDriveSelection(); return true; }
      if (this.navStack.getAllPathName().slice(-1)[0] === 'drive-search') { this.exitDriveSearch(); return true; }
      if (this.pickerMode.length > 0 && this.navStack.getAllPathName().slice(-1)[0] === 'directory-picker') {
        if (this.backup.submitting) { return true; }
        if (this.model.directory.length > 0) { if (!this.model.busy) { this.model.goBack(); } return true; }
        this.cancelDirectoryPicker(); return true;
      }
      this.navStack.pop(); return true;
    }
    if (this.module === 'root' && this.activeTab === 1 && this.fileSelecting) { this.cancelFileSelection(); return true; }
    if (this.module === 'root' && this.activeTab === 1 && this.pendingEntries.length > 0) { this.pendingEntries = []; this.pendingOperation = ''; return true; }
    if (this.model.authenticated && this.module === 'drive') {
      if (this.driveSelecting) { this.cancelDriveSelection(); return true; }
      if (this.driveViewMatches() && this.model.drive.trail.length > 1 && this.model.drive.canGoUp()) { if (!this.model.drive.busy) { this.model.drive.goUp(); } return true; }
      if (this.driveTabId === 'more' && this.driveMoreView.length > 0) { this.backToDriveMore(); return true; }
      this.exitModule(); return true;
    }
    if (this.model.authenticated && this.module === 'photos') {
      if (this.model.photoLibrary.selecting) { if (!this.model.photoLibrary.selectionBusy) { this.model.photoLibrary.endSelection(); } return true; }
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
      this.driveMoreView = ''; this.photoMoreShared = false;
      this.photoSpace = PhotosSpace.Personal; this.albumSpace = PhotosSpace.Personal; this.sharedSpace = PhotosSpace.Shared;
      this.backup.reset();
      this.pickerMode = '';
      this.extensionsOpened = false; this.downloadsVisible = false;
      this.packageDestination = '';
      this.rootTasks = new TaskPageState('root'); this.fileTasks = new TaskPageState('files');
      this.photoTasks = new TaskPageState('photos'); this.driveTasks = new TaskPageState('drive');
      this.taskDestination = ''; this.downloadSnackBar?.dismiss();
      this.navStack.clear();
      this.sheetVisible = false;
      this.selectedEntry = undefined;
      this.deviceInfo = [];
      this.pendingEntries = [];
      this.cancelFileSelection();
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

  @Monitor('model.directory', 'module', 'activeTab')
  private fileSelectionLocationChanged(): void { this.cancelFileSelection(); }

  @Monitor('model.entries')
  private fileSelectionEntriesChanged(): void {
    this.selectedFiles = this.model.entries.filter((entry: NasFileEntry): boolean =>
      this.selectedFiles.some((selected: NasFileEntry): boolean => selected.path === entry.path));
  }

  private cancelFileSelection(): void { this.fileSelecting = false; this.selectedFiles = []; this.selectionMenuVisible = false; }

  private toggleFileSelection(entry: NasFileEntry): void {
    this.selectedFiles = this.selectedFiles.some((selected: NasFileEntry): boolean => selected.path === entry.path) ?
      this.selectedFiles.filter((selected: NasFileEntry): boolean => selected.path !== entry.path) : this.selectedFiles.concat([entry]);
  }

  /** 批量动作复用文件任务流程，确认删除前保留选择。 */
  private async selectedFileAction(kind: string): Promise<void> {
    if (this.model.busy || this.selectedFiles.length === 0) { return; }
    if (kind === 'share') {
      this.model.extensions.shareDraftPaths = this.selectedFiles.map((entry: NasFileEntry): string => entry.path);
      this.model.extensions.selectedShare = undefined;
      this.navStack.pushPathByName('share-links', undefined); this.cancelFileSelection(); return;
    }
    if (kind === 'download') {
      for (const entry of this.selectedFiles.slice()) {
        const result = await this.model.downloadFile(entry);
        if (result.status !== 'created' && result.status !== 'duplicate') { this.transferErrorText = result.message; return; }
      }
      this.cancelFileSelection(); this.openModuleTasks('files'); return;
    }
    if (kind === 'delete') {
      const entries = this.selectedFiles.slice();
      this.getUIContext().showAlertDialog({ title: $r('app.string.file_delete_selected'),
        message: $r('app.string.file_delete_selected_confirm', entries.length),
        primaryButton: { value: $r('app.string.action_cancel'), action: (): void => {} },
        secondaryButton: { value: $r('app.string.file_delete'), action: (): void => {
          this.model.deleteEntries(entries).then((result): void => {
            if (result !== 'failed') { this.cancelFileSelection(); }
            if (result === 'pending') { this.fileTasks.locate(''); this.openModuleTasks('files'); }
          });
        } } });
    } else {
      this.pendingEntries = this.selectedFiles.slice();
      this.pendingOperation = kind;
      this.cancelFileSelection();
    }
  }

  @Monitor('model.deviceModel')
  private deviceModelChanged(): void { this.resolveDeviceArtwork(); }

  @Monitor('observedDriveBrowser.trail', 'module', 'driveTabId', 'driveMoreView', 'model.authenticated', 'model.address', 'model.account')
  private driveSelectionLocationChanged(): void {
    this.cancelDriveSelection(); this.driveDetailVisible = false; this.driveDetailEntry = undefined;
  }

  @Monitor('observedDriveBrowser.entries')
  private driveSelectionEntriesChanged(): void {
    this.selectedDriveIds = this.model.drive.entries.filter((entry: DriveEntry): boolean =>
      this.selectedDriveIds.includes(entry.fileId)).map((entry: DriveEntry): string => entry.fileId);
  }

  private cancelDriveSelection(): void {
    this.driveSelecting = false; this.selectedDriveIds = []; this.selectionMenuVisible = false;
  }

  private fileSelectionActive(): boolean {
    if (!this.model.authenticated) { return false; }
    const paths = this.navStack.getAllPathName();
    if (paths.length > 0 && paths[paths.length - 1] !== 'drive-search') { return false; }
    return this.module === 'drive' ? this.driveSelecting : this.module === 'root' && this.activeTab === 1 && this.fileSelecting;
  }

  private selectedDriveEntries(): DriveEntry[] {
    return this.model.drive.entries.filter((entry: DriveEntry): boolean => this.selectedDriveIds.includes(entry.fileId));
  }

  private selectionCount(): number { return this.module === 'drive' ? this.selectedDriveEntries().length : this.selectedFiles.length; }

  private fileSelectionTitle(): string {
    return this.selectionCount() === 0 ? this.previewText($r('app.string.file_selection_empty')) :
      this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.file_selected_count').id, this.selectionCount());
  }

  private selectLoadedFiles(): void {
    if (this.model.busy || this.module === 'drive' && this.model.drive.busy) { return; }
    if (this.module === 'drive') { this.selectedDriveIds = this.model.drive.entries.map((entry: DriveEntry): string => entry.fileId); }
    else { this.selectedFiles = this.model.entries.slice(); }
  }

  /** 两种文件协议各自判断权限，工具栏和更多菜单复用同一结果。 */
  private fileSelectionActionAllowed(action: FileSelectionAction | 'more'): boolean {
    if (!this.fileSelectionActive() || this.selectionCount() === 0 || this.model.busy) { return false; }
    if (action === 'more') { return this.module !== 'drive' || !this.model.drive.busy; }
    if (this.module !== 'drive') {
      if (action === 'share') { return this.model.supports('SYNO.FileStation.Sharing') && this.model.extensions.canWrite('fileSharing'); }
      if (action === 'download') { return this.model.supports('SYNO.FileStation.Download') && this.model.queue.ready &&
        !this.model.queue.busy && this.selectedFiles.every((entry: NasFileEntry): boolean => !entry.isDirectory); }
      return this.model.supports(action === 'delete' ? 'SYNO.FileStation.Delete' : 'SYNO.FileStation.CopyMove');
    }
    const entries = this.selectedDriveEntries();
    if (this.model.drive.busy || entries.length !== this.selectedDriveIds.length) { return false; }
    if (action === 'share') { return this.model.driveSharing.available && !this.model.driveSharing.hasPending && entries.every(driveFileLinkAllowed); }
    if (action === 'download') { return this.model.driveTransfers.ready && !this.model.driveTransfers.busy &&
      entries.every((entry: DriveEntry): boolean => entry.kind === DriveEntryKind.File && entry.capabilities.canDownload); }
    const rootRestricted = this.model.drive.trail.length === 1 && (action === 'copy' ? this.model.drive.view === DriveView.TeamFolders :
      [DriveView.TeamFolders, DriveView.SharedWithMe, DriveView.SharedWithOthers].includes(this.model.drive.view));
    return !rootRestricted && this.model.driveActions.available && this.model.driveActions.ready &&
      !this.model.driveActions.busy && !this.model.driveActions.hasPending &&
      entries.every((entry: DriveEntry): boolean => driveActionAllowed(entry, action));
  }

  private async fileSelectionAction(action: FileSelectionAction): Promise<void> {
    if (!this.fileSelectionActionAllowed(action)) { return; }
    if (this.module !== 'drive') { await this.selectedFileAction(action); return; }
    const entries = this.selectedDriveEntries();
    if (action === 'share') {
      if (this.model.driveSharing.prepare(entries[0], entries)) { this.navStack.pushPathByName('drive-links', undefined); }
    } else if (action === 'download') {
      const generation = this.model.sessionGeneration;
      for (const entry of entries) {
        if (generation !== this.model.sessionGeneration) { return; }
        await this.model.driveTransfers.download(entry);
        if (generation !== this.model.sessionGeneration || this.model.driveTransfers.errorText.length > 0) { return; }
      }
      this.cancelDriveSelection(); this.openDriveTransfers();
    } else { await this.prepareDriveAction(entries[0], action, entries); }
  }

  private selectionToolbarItem(label: Resource, icon: Resource, action: FileSelectionAction | 'more'): ToolBarV2Item {
    return new ToolBarV2Item({ content: new ToolBarV2ItemText({ text: label }),
      icon: new ToolBarV2SymbolGlyph({ normal: new SymbolGlyphModifier(icon) }),
      state: this.fileSelectionActionAllowed(action) ? ToolBarV2ItemState.ENABLE : ToolBarV2ItemState.DISABLE,
      action: (_index: number): void => {
        if (action === 'more') { this.selectionMenuVisible = true; }
        else { this.fileSelectionAction(action); }
      } });
  }

  @Builder
  fileSelectionToolbar() {
    ToolBarV2({ toolBarList: [
      this.selectionToolbarItem($r('app.string.file_selection_share'), $r('sys.symbol.share'), 'share'),
      this.selectionToolbarItem($r('app.string.file_selection_copy'), $r('sys.symbol.square_and_square'), 'copy'),
      this.selectionToolbarItem($r('app.string.preview_delete'), $r('sys.symbol.trash'), 'delete'),
      this.selectionToolbarItem($r('app.string.file_selection_more'), $r('sys.symbol.more'), 'more')
    ] }).bindMenu(this.selectionMenuVisible, this.fileSelectionMenu(), {
      placement: Placement.TopRight, onDisappear: (): void => { this.selectionMenuVisible = false; }
    })
  }

  @Builder
  fileSelectionMenu() { titleMenu(this.fileSelectionMenuItems()) }

  private fileSelectionMenuItems(): TitleMenuItem[] {
    const items = [new TitleMenuItem(this.previewText($r('app.string.preview_move')), this.fileSelectionActionAllowed('move'),
      (): void => { this.fileSelectionAction('move'); }),
      new TitleMenuItem(this.previewText($r('app.string.preview_download')), this.fileSelectionActionAllowed('download'),
        (): void => { this.fileSelectionAction('download'); })];
    if (this.selectionCount() === 1) {
      const single = this.module === 'drive' ? this.driveEntryActions(this.selectedDriveEntries()[0]) : this.fileEntryActions(this.selectedFiles[0]);
      items.push(...single.filter((item: TitleMenuItem): boolean => !['share', 'copy', 'move', 'delete', 'download'].includes(item.id)));
    }
    return items;
  }

  /** 列表菜单与选中后的单项操作共用，避免入口变化带来权限差异。 */
  private fileEntryActions(entry: NasFileEntry): TitleMenuItem[] {
    const items = [new TitleMenuItem(this.previewText($r('app.string.notice_details')), true,
      (): void => { this.fileEntryAction('detail', entry); }, 'detail')];
    if (this.model.supports('SYNO.FileStation.Sharing') && this.model.extensions.canWrite('fileSharing')) {
      items.push(new TitleMenuItem(this.previewText($r('app.string.file_action_share_link')), true, (): void => { this.fileEntryAction('share', entry); }, 'share'));
    }
    if (!entry.isDirectory && this.model.supports('SYNO.FileStation.Download') && this.model.queue.ready && !this.model.queue.busy) {
      items.push(new TitleMenuItem(this.previewText($r('app.string.file_action_download')), true, (): void => { this.fileEntryAction('download', entry); }, 'download'));
    }
    if (this.model.directory.length > 0) {
      if (this.model.supports('SYNO.FileStation.CopyMove')) {
        items.push(new TitleMenuItem(this.previewText($r('app.string.preview_copy')), true, (): void => { this.fileEntryAction('copy', entry); }, 'copy'));
        items.push(new TitleMenuItem(this.previewText($r('app.string.preview_move')), true, (): void => { this.fileEntryAction('move', entry); }, 'move'));
      }
      if (this.model.supports('SYNO.FileStation.Rename')) {
        items.push(new TitleMenuItem(this.previewText($r('app.string.file_selection_rename')), true,
          (): void => { this.fileEntryAction('rename', entry); }, 'rename'));
      }
      if (this.model.supports('SYNO.FileStation.Delete')) {
        items.push(new TitleMenuItem(this.previewText($r('app.string.preview_delete')), true,
          (): void => { this.fileEntryAction('delete', entry); }, 'delete'));
      }
    }
    return items;
  }

  private driveEntryActions(entry: DriveEntry): TitleMenuItem[] {
    const items = [new TitleMenuItem(this.previewText($r('app.string.notice_details')), true,
      (): void => { this.driveDetailEntry = entry; this.driveDetailVisible = true; }, 'detail')];
    if (this.model.drive.view === DriveView.Trash) { return items; }
    if (!this.model.driveActions.ready || !this.model.driveTransfers.ready || this.model.driveTransfers.busy ||
      this.model.driveActions.busy || this.model.driveActions.hasPending) { return items; }
    if (this.model.driveSharing.available && driveFileLinkAllowed(entry)) {
      items.push(new TitleMenuItem(this.previewText($r('app.string.file_action_get_link')), true, (): void => { this.openDriveLinks(entry); }, 'share'));
    }
    if (canPreviewDriveOriginal(entry)) {
      items.push(new TitleMenuItem(this.previewText($r('app.string.preview_original')), true,
        (): void => { this.openDriveOriginal(entry); }, 'original'));
    }
    if (entry.kind === DriveEntryKind.File && entry.capabilities.canRead && entry.capabilities.canDownload) {
      items.push(new TitleMenuItem(this.previewText($r('app.string.file_action_download')), true,
        (): void => { this.driveDetailVisible = false; this.submitDriveDownload(entry, '', false); }, 'download'));
    }
    if (this.model.driveTransfers.available && entry.kind === DriveEntryKind.Folder && entry.capabilities.canRead && entry.capabilities.canWrite) {
      items.push(new TitleMenuItem(this.previewText($r('app.string.file_action_upload_folder')), true, (): void => { this.prepareDriveUpload(entry); }, 'upload'));
    }
    if (!this.model.driveActions.available) { return items; }
    const rootRestricted = this.model.drive.trail.length === 1 && [DriveView.TeamFolders, DriveView.SharedWithMe, DriveView.SharedWithOthers].includes(this.model.drive.view);
    const actions: DriveAction[] = ['rename', 'copy', 'move', 'delete'];
    for (const action of actions) {
      if (driveActionAllowed(entry, action) && (action === 'copy' ?
        !(this.model.drive.view === DriveView.TeamFolders && this.model.drive.trail.length === 1) : !rootRestricted)) {
        const label = action === 'rename' ? $r('app.string.file_selection_rename') : action === 'copy' ? $r('app.string.preview_copy') :
          action === 'move' ? $r('app.string.preview_move') : $r('app.string.preview_delete');
        items.push(new TitleMenuItem(this.previewText(label), true, (): void => { this.prepareDriveAction(entry, action); }, action));
      }
    }
    return items;
  }

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
    if (this.fileSelectionActive()) { return this.fileSelectionTitle(); }
    if (this.module === 'photos' && this.model.photoLibrary.selecting) {
      return this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.photos_selected_count').id, this.model.photoLibrary.selectedKeys.length);
    }
    if (!this.model.authenticated) { return 'NAS 工作台'; }
    if (this.module === 'drive') {
      if (this.driveTabId === DriveView.MyDrive) { return 'Synology Drive'; }
      if (this.driveTabId === 'more') {
        return this.driveMoreView.length > 0 ? driveViewLabel(this.driveMoreView as DriveView) :
          this.visibleTabs()[this.activeTab].label;
      }
      return driveViewLabel(this.driveTabId as DriveView);
    }
    if (this.module === 'photos') {
      if (this.photoTabId === 'more' && !this.photoMoreShared) { return this.visibleTabs()[this.activeTab].label; }
      return this.photoTabId === 'transfers' ? '照片传输' : '照片';
    }
    return rootTabs()[this.activeTab].label;
  }

  @Monitor('module', 'activeTab', 'taskDestination', 'taskOverlayVisible', 'sheetVisible', 'rootTasks.categoryIndex')
  private activeTabChanged(): void {
    this.updateTelemetryMode();
  }

  private updateTelemetryMode(): void {
    this.model.driveActions.setPolling(this.pageActive && this.foreground && this.model.authenticated &&
      !this.taskOverlayVisible && !this.sheetVisible && (this.taskDestination === 'drive' ||
        this.module === 'root' && this.activeTab === ROOT_TASK_TAB && this.rootTasks.categoryIndex === 2 && this.navStack.size() === 0));
    this.model.telemetry.setMode(!this.pageActive || !this.foreground || !this.model.authenticated || this.addressBookOpened || this.systemControlOpened || this.extensionsOpened || this.packageDestination.length > 0 ? 'hidden' :
      this.telemetryOpened ? 'detail' : this.module === 'root' && this.activeTab === 0 ? 'home' : 'hidden');
  }

  private ensurePhotosOpen(): void {
    const id = this.effectivePhotoTab();
    if (this.module !== 'photos' || !['photos', 'albums', 'shared'].includes(id) || this.navigationBusy()) { return; }
    const space = this.expectedPhotoSpace(id);
    const section = this.expectedPhotoSection(id, space);
    this.model.photoLibrary.activateTab(id, space, section);
  }

  private switchTab(index: number): void {
    this.module = 'root'; this.activeTab = rootReturnIndex(index); this.rootTab = this.activeTab;
    this.tabsController.changeIndex(this.activeTab);
    this.updateTelemetryMode();
  }

  private supportsPhotos(): boolean {
    return supportsPhotos((api: string): boolean => this.model.supports(api));
  }

  /** 首页「资源监控」与「存储空间」卡片整卡可点，进入同一张只读监控详情页。 */
  private openTelemetry(): void {
    this.navStack.pushPath({ name: 'telemetry' });
  }

  private openNasDownloads(): void {
    if (this.model.extensions.downloadDestination.length === 0 && this.model.directory.length > 0) {
      this.model.extensions.setDownloadDestination(this.model.directory.slice(1));
    }
    this.navStack.pushPathByName('nas-downloads', undefined);
    this.updateTelemetryMode();
  }

  private updatePackageVisibility(): void {
    this.model.containers.setVisible(this.pageActive && this.foreground && this.model.authenticated && this.packageDestination === 'containers');
    this.model.cloudSync.setVisible(this.pageActive && this.foreground && this.model.authenticated && this.packageDestination === 'cloud-sync');
    this.model.systemLogs.setVisible(this.pageActive && this.foreground && this.model.authenticated && this.packageDestination === 'system-logs');
    this.model.notes.setVisible(this.pageActive && this.foreground && this.model.authenticated && this.packageDestination === 'notes');
    if (!this.pageActive || !this.foreground || !this.model.authenticated) {
      this.model.packages.hideList(); this.model.packages.hideDetail(); return;
    }
    if (this.packageDestination === 'packages') { this.model.packages.showList(); }
    else if (this.packageDestination === 'package-detail') { this.model.packages.showDetail(); }
  }

  private openPackageDetail(item: InstalledPackage): void {
    this.model.packages.select(item);
    this.navStack.pushPathByName('package-detail', undefined);
  }

  private openPackageNative(target: PackageNativeTarget): void {
    if (!this.model.authenticated || this.navigationBusy()) { return; }
    const available = target === 'notes' ? this.model.supports('SYNO.NoteStation.Note') : target === 'system-logs' ? this.model.supports('SYNO.Core.SyslogClient.Log') : target === 'cloud-sync' ? this.model.supports('SYNO.CloudSync') : target === 'containers' ? this.model.supports('SYNO.Docker.Container') : target === 'files' ? this.model.supports('SYNO.FileStation.List') : target === 'downloads' ?
      this.model.supports('SYNO.DownloadStation.Task') : target === 'photos' ? this.supportsPhotos() :
      driveTabs((view: DriveView): boolean => this.model.drive.supportsView(view), this.drivePinned).length > 0;
    if (!available) { this.showTitleMenuError(this.previewText($r('app.string.package_native_unavailable'))); return; }
    this.model.packages.hideList(); this.model.packages.hideDetail();
    this.packageDestination = ''; this.navStack.clear();
    if (target === 'containers' || target === 'cloud-sync' || target === 'system-logs' || target === 'notes') { this.navStack.pushPathByName(target, undefined); }
    else if (target === 'files') { this.switchTab(1); }
    else if (target === 'downloads') { this.openNasDownloads(); }
    else if (target === 'drive') { this.driveTabId = 'mydrive'; this.driveMoreView = ''; this.enterModule('drive'); }
    else { this.photoTabId = 'photos'; this.photoMoreShared = false; this.enterModule('photos'); }
    this.updateTelemetryMode();
  }

  private openPackageManagement(): void {
    if (!this.model.authenticated || this.navigationBusy()) { return; }
    this.model.officialWeb.open();
    this.navStack.pushPathByName('official-web', undefined);
  }

  private remoteDownloadMenus(): HdsNavigationMenuItemOptions[] {
    return [{ content: { icon: $r('sys.symbol.arrow_clockwise'), label: this.previewText($r('app.string.task_refresh')), type: IconStyleMode.SMALL,
      isEnabled: !this.model.extensions.busy, action: (): void => { this.downloadsRefreshRevision++; } } },
      { content: { icon: $r('sys.symbol.plus'), label: this.previewText($r('app.string.task_create')), type: IconStyleMode.SMALL,
        isEnabled: !this.model.extensions.busy, action: (): void => { this.model.extensions.downloadFormRequested = true; } } }];
  }

  private async savePhotoOriginal(): Promise<void> {
    if (await this.model.photoLibrary.exportOriginal()) { this.showTitleMenuError(this.previewText($r('app.string.task_saved'))); }
  }

  private chooseDownloadDirectory(): void {
    if (this.model.busy || this.model.drive.busy) { return; }
    this.model.extensions.downloadFormRequested = true;
    this.pickerMode = 'download';
    this.navStack.pushPathByName('directory-picker', 'download');
  }

  private useDownloadDirectory(): void {
    if (this.model.busy || this.model.directory.length === 0) { return; }
    this.model.extensions.setDownloadDestination(this.model.directory.slice(1));
    this.pickerMode = ''; this.navStack.pop();
  }

  private activeScrollers(): Scroller[] {
    if (!this.model.authenticated) { return [this.homeScroller]; }
    if (this.module === 'drive') { return [this.driveScrollerFor(this.driveTabId)]; }
    if (this.module === 'photos') { return [this.photoTabId === 'transfers' ? this.photoTasksScroller : this.photoScrollerFor(this.photoTabId)]; }
    return [this.activeTab === 1 ? this.filesScroller : this.activeTab === ROOT_TASK_TAB ? this.taskCategoryScrollers[this.rootTasks.categoryIndex] :
      this.activeTab === ROOT_SETTINGS_TAB ? this.settingsScroller : this.homeScroller];
  }

  private openPhoto(item: NasPhotoItem): void {
    this.model.photoLibrary.openDetail(item);
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 328, 36) }, (): void => {
      this.navStack.pushPathByName('photo-detail', item.id);
    });
  }

  private async selectBackup(): Promise<void> {
    if (!supportsPhotoBackup((api: string): boolean => this.model.supports(api)) || !this.model.queue.ready || this.model.busy ||
      this.backup.selecting || this.backup.submitting) { return; }
    this.backup.clear();
    await this.backup.select(this.getUIContext().getHostContext() as common.UIAbilityContext, this.model.queue);
    let errorText = this.backup.errorText;
    if (this.backup.sources.length > 0) {
      await this.model.submitPhotoUpload(this.backup);
      if (this.backup.errorText.length > 0 && this.backup.errorText !== errorText) {
        errorText += (errorText.length > 0 ? ' ' : '') + this.backup.errorText;
      }
    }
    if (errorText.length > 0) { this.showTitleMenuError(errorText); }
  }


  private showDeviceInfo(): void {
    this.deviceInfo = [];
    this.openForm('device');
    this.model.serverInfo().then((info: string): void => {
      if (info.length > 0 && this.model.authenticated) { this.deviceInfo = info.split('\n'); }
    });
  }

  private bottomInset(): number {
    if (this.fileSelectionActive()) { return 16; }
    if (this.module === 'photos' && this.model.photoLibrary.selecting) { return 16; }
    return this.windowWidth >= 600 ? this.navigationInset + 16 : workbenchBottomInset(this.floatingBarBottomMargin());
  }

  /** 页签位置与滚动末尾占位共用底距，避免无导航指示条时互相脱节。 */
  private floatingBarBottomMargin(): number {
    return this.navigationInset > 0 ? this.navigationInset :
      this.getUIContext().getHostContext()!.resourceManager.getNumber($r('sys.float.padding_level8').id);
  }

  /** 内容区延伸到标题栏之下，首项需要让出状态栏与单行标题栏的高度。 */
  private contentTopInset(): number {
    return this.statusInset + 56 + (this.activeTransferCount() > 0 ? 44 : 0);
  }

  private activeTransferCount(): number {
    return taskRecords('root', this.model.queue.items, this.model.driveTransfers.items, this.model.fileTasks, this.model.driveActions.items)
      .filter((record): boolean => !taskEnded(record.state)).length;
  }

  @Monitor('observedQueue.items', 'observedDriveTransfers.items', 'model.authenticated')
  private transferCountChanged(): void {
    if (this.abilityContext !== undefined) {
      this.transferLiveView.update(this.abilityContext, this.model.authenticated ?
        taskRecords('root', this.observedQueue.items, this.observedDriveTransfers.items, [], [])
          .filter((record): boolean => !taskEnded(record.state)).length : 0);
    }
  }

  @Builder
  sideBarPanel() {
    Column({ space: 8 }) {
      if (this.module !== 'root') {
        Button($r('app.string.workspace_root')).height(48).width('100%').buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => { this.onBackPress(); })
      }
      ForEach(this.visibleTabs(), (tab: ModuleTab, index: number): void => {
        Button() {
          Column({ space: 6 }) {
            SymbolGlyph(this.tabIcon(tab.id)).fontSize(24)
            Text(tab.label).fontSize(14).maxLines(1)
          }.width('100%').padding(12)
        }.width('100%').type(ButtonType.Normal).backgroundColor(index === this.activeTab ?
          $r('app.color.workbench_accent_surface') : Color.Transparent).borderRadius(16)
          .enabled(!this.navigationBusy()).onClick((): void => { this.selectModuleTab(index); })
      }, (tab: ModuleTab): string => this.module + ':' + tab.id)
    }.width('100%').height('100%').padding({ top: this.contentTopInset(), left: 8, right: 8, bottom: this.navigationInset })
  }

  @Builder
  sideBarContent() {
    this.modulePage(this.visibleTabs()[this.activeTab])
  }

  @Builder
  transferCapsule() {
    Row() {
    if (this.model.authenticated && this.activeTransferCount() > 0) {
      Button($r('app.string.global_transfer_count', this.activeTransferCount()))
        .height(40).buttonStyle(ButtonStyleMode.TEXTUAL).borderRadius(20)
        .backgroundColor($r('app.color.workbench_accent_surface'))
        .onClick((): void => { this.showAllTasks(); })
    }
    }.width('100%').height(this.model.authenticated && this.activeTransferCount() > 0 ? 40 : 0)
      .justifyContent(FlexAlign.Center).hitTestBehavior(HitTestMode.Transparent)
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
    if (this.sheetKind === 'drive-upload') { return '确认上传'; }
    if (this.sheetKind === 'drive-transfer-settings') { return '传输方式'; }
    if (this.sheetKind === 'create') { return '新建文件夹'; }
    if (this.sheetKind === 'rename') { return '重命名'; }
    if (this.sheetKind === 'sort') { return '排序'; }
    if (this.sheetKind === 'backup') { return '备份内容'; }
    if (this.sheetKind === 'device') { return '设备信息'; }
    return '文件详情';
  }

  /**
   * 只有内容可能很长、用 SheetSize.LARGE 的弹层才挂 HDS 半模态标题栏：
   * HdsNavigation 需要有确定高度，FIT_CONTENT 的小弹层给不出来。
   */
  private sheetUsesModalTitleBar(): boolean {
    return ['device', 'task', 'backup', 'drive-upload', 'drive-transfer-settings'].includes(this.sheetKind);
  }

  /** 连接方式按当前实际连接策略呈现，避免 http 连接被写死成“HTTPS 安全连接”。 */
  private connectionSecurityText(): string {
    if (!this.model.useHttps) { return 'HTTP 明文连接'; }
    return this.model.insecureTls ? 'HTTPS 未校验证书' : 'HTTPS 安全连接';
  }

  /** 风险连接在当前登录页确认，不要求先建立地址记录。 */
  private submitLogin(): void {
    if (this.model.busy || this.model.authenticated || this.model.address.trim().length === 0 ||
      this.model.account.trim().length === 0 || this.model.password.length === 0) { return; }
    let origin: string | undefined;
    try { origin = this.model.connectionRiskOrigin(); }
    catch (error) {
      this.model.errorText = error instanceof NasFailure ? error.message : '连接地址格式不正确。';
      return;
    }
    if (origin === undefined) { this.model.submitLogin(); return; }
    const confirmedOrigin = origin;
    const insecureTls = this.model.insecureTls;
    this.getUIContext().showAlertDialog({ title: $r('app.string.connection_risk_title'),
      message: this.model.useHttps ? $r('app.string.connection_tls_risk', origin) : $r('app.string.connection_http_risk', origin),
      primaryButton: { value: $r('app.string.action_cancel'), action: (): void => {} },
      secondaryButton: { value: $r('app.string.connection_accept_login_risk'), action: (): void => {
        try { this.model.confirmConnectionRisk(confirmedOrigin, insecureTls); }
        catch (error) {
          this.model.errorText = error instanceof NasFailure ? error.message : '连接方式确认失败，请重试。';
          return;
        }
        this.model.submitLogin();
      } } });
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

  private confirmDelete(entry: NasFileEntry, preview: boolean = false): void {
    this.getUIContext().showAlertDialog({ title: entry.isDirectory ? '删除文件夹' : '删除文件',
      message: '确认删除“' + entry.name + '”？' + (entry.isDirectory ? '文件夹内的内容也会被删除。' : ''),
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', action: (): void => {
        this.sheetVisible = false;
        this.model.deleteEntry(entry).then((result): void => {
          if (preview) {
            if (this.model.fileOriginal.fileEntry !== entry) { return; }
            if (result !== 'failed' && this.navStack.getAllPathName().slice(-1)[0] === 'file-preview') { this.navStack.pop(); }
          }
          if (result === 'pending') { this.fileTasks.locate(''); this.openModuleTasks('files'); }
        });
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
    this.pendingEntries = [entry];
    this.pendingOperation = operation;
  }

  private destinationAllowed(): boolean {
    return this.pendingEntries.length > 0 && this.pendingEntries.every((entry: NasFileEntry): boolean =>
      workbenchCanUseDestination(entry.path, entry.isDirectory, this.model.directory));
  }

  private async applyDestination(): Promise<void> {
    if (this.model.busy || !this.destinationAllowed()) { return; }
    const result = this.pendingOperation === 'copy' ? await this.model.copyEntries(this.pendingEntries, this.model.directory) :
      await this.model.moveEntries(this.pendingEntries, this.model.directory);
    if (result !== 'failed') { this.pendingEntries = []; this.pendingOperation = ''; }
    if (result === 'pending') { this.fileTasks.locate(''); this.openModuleTasks('files'); }
  }

  private sortLabel(): string {
    const field = this.model.fileSort === 'size' ? '大小' : this.model.fileSort === 'mtime' ? '修改时间' : '名称';
    return '按' + field + (this.model.sortDescending ? '降序' : '升序');
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

  private driveScrollerFor(id: string): ListScroller {
    return this.driveScrollers[Math.max(0, ['mydrive', 'teamFolders', 'recent', 'starred', 'sharedWithMe', 'sharedWithOthers', 'trash', 'more'].indexOf(id))];
  }

  private photoScrollerFor(id: string): Scroller {
    return this.photoScrollers[Math.max(0, ['photos', 'albums', 'shared', 'backup', 'transfers', 'more'].indexOf(id))];
  }

  private navigationBusy(): boolean { return this.model.sessionTransition; }

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
      if (view !== undefined) { this.model.drive.activateView(view); }
    } else if (this.module === 'photos') {
      this.photoTabId = tab.id;
      this.ensurePhotosOpen();
    } else { this.rootTab = index; }
  }

  private selectDriveMore(view: DriveView): void {
    if (this.navigationBusy() || !this.model.drive.supportsView(view)) { return; }
    this.driveMoreView = view;
    this.model.drive.activateView(view);
  }

  private backToDriveMore(): void { this.driveMoreView = ''; }

  private driveViewMatches(): boolean {
    const tab = this.visibleTabs().find((item: ModuleTab): boolean => item.id === this.driveTabId);
    const view = tab?.view ?? (this.driveMoreView.length > 0 ? this.driveMoreView as DriveView : undefined);
    return this.model.drive.loaded && view !== undefined && this.model.drive.view === view;
  }

  private refreshDriveView(): void {
    if (this.navigationBusy()) { return; }
    const tab = this.visibleTabs().find((item: ModuleTab): boolean => item.id === this.driveTabId);
    const view = tab?.view ?? (this.driveMoreView.length > 0 ? this.driveMoreView as DriveView : undefined);
    this.model.driveThumbnails.retryVisible();
    if (view !== undefined && this.model.drive.view !== view) {
      this.model.drive.selectView(view);
    } else { this.model.drive.reload(); }
  }

  private showDriveSearch(): void {
    if (this.navigationBusy() || !this.driveViewMatches() || !this.model.drive.supportsView(DriveView.Search)) { return; }
    this.model.drive.beginSearch();
    this.navStack.pushPathByName('drive-search', undefined);
  }

  private async exitDriveSearch(): Promise<void> {
    await this.model.drive.exitSearch();
    this.navStack.pop();
  }

  private expectedPhotoSpace(id: string): PhotosSpace {
    const preferred = id === 'shared' ? this.sharedSpace : id === 'albums' ? this.albumSpace : this.photoSpace;
    if (preferred === PhotosSpace.Personal && this.model.supports(id === 'shared' ? 'SYNO.Foto.Browse.Album' : 'SYNO.Foto.Browse.Item') ||
      preferred === PhotosSpace.Shared && this.model.supports('SYNO.FotoTeam.Browse.Item') ||
      preferred === PhotosSpace.WithMe && this.model.supports('SYNO.Foto.Sharing.Misc')) { return preferred; }
    if (id !== 'shared' && this.model.supports('SYNO.Foto.Browse.Item')) { return PhotosSpace.Personal; }
    if (this.model.supports('SYNO.FotoTeam.Browse.Item')) { return PhotosSpace.Shared; }
    return this.model.supports('SYNO.Foto.Sharing.Misc') ? PhotosSpace.WithMe : PhotosSpace.Personal;
  }

  private expectedPhotoSection(id: string, space: PhotosSpace): PhotoLibrarySection {
    if (id === 'shared' && space === PhotosSpace.Personal) { return 'sharedByMe'; }
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
    if (this.navigationBusy() || !supportsPhotoBackup((api: string): boolean => this.model.supports(api))) { return; }
    this.photoMoreShared = false;
    this.photoTabId = photoTabs((api: string): boolean => this.model.supports(api), this.showPhotoShared, this.photoPinned)
      .some((tab: ModuleTab): boolean => tab.id === 'backup') ? 'backup' : 'more';
    this.enterModule('photos');
    if (this.photoTabId === 'more') { this.navStack.pushPathByName('photo-backup', undefined); }
  }

  private openPhotoShared(): void {
    if (this.navigationBusy() || !supportsPhotoSharing((api: string): boolean => this.model.supports(api))) { return; }
    this.photoMoreShared = true;
    this.ensurePhotosOpen();
  }

  private chooseBackupDirectory(): void {
    if (this.navigationBusy() || this.model.photoBackup.busy) { return; }
    this.openPhotoDestination('backup');
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
    if (this.fileSelectionActive()) {
      return [{ content: { label: this.previewText($r('app.string.file_select_loaded')), type: TextStyleMode.NORMAL,
        isEnabled: !this.model.busy && (this.module !== 'drive' || !this.model.drive.busy),
        action: (): void => { this.selectLoadedFiles(); } } }];
    }
    if (this.module === 'drive') {
      const items: HdsNavigationMenuItemOptions[] = [];
      if (this.driveTabId === 'mydrive' && this.model.drive.supportsView(DriveView.Search)) {
        items.push({ content: { label: '搜索', icon: $r('sys.symbol.magnifyingglass'), type: IconStyleMode.SMALL,
          isEnabled: !this.navigationBusy() && this.driveViewMatches(), action: (): void => { this.showDriveSearch(); } } });
      }
      if (this.driveTabId !== 'more') {
        items.push({ content: { label: '新增与工具', icon: $r('sys.symbol.plus'), componentId: 'drive-add-menu', type: IconStyleMode.SMALL,
          isEnabled: !this.navigationBusy(), action: (): void => { this.openDriveTitleMenu(); } } });
      }
      return items;
    }
    if (this.module === 'photos' && ['photos', 'albums', 'shared'].includes(this.effectivePhotoTab()) &&
      (this.effectivePhotoTab() === 'photos' || this.model.photoLibrary.section === 'timeline' || this.model.photoLibrary.selectedAlbum !== undefined)) {
      if (this.model.photoLibrary.selecting) {
        return [{ content: { label: this.previewText($r('app.string.action_cancel')), type: TextStyleMode.NORMAL,
          isEnabled: !this.model.photoLibrary.selectionBusy, action: (): void => { this.model.photoLibrary.endSelection(); } } }];
      }
      const photoActions: HdsNavigationMenuItemOptions[] = [];
      if (supportsPhotoBackup((api: string): boolean => this.model.supports(api))) {
        photoActions.push({ content: { label: this.previewText($r('app.string.photos_upload')), icon: $r('sys.symbol.plus'),
          type: IconStyleMode.SMALL, isEnabled: !this.navigationBusy() && this.model.queue.ready && !this.model.busy &&
            !this.backup.selecting && !this.backup.submitting, action: (): void => { this.selectBackup(); } } });
      }
      photoActions.push({ content: { label: this.previewText($r('app.string.photos_select')), icon: $r('sys.symbol.checkmark_circle'),
        type: IconStyleMode.SMALL, isEnabled: !this.navigationBusy() && this.model.photoLibrary.items.length > 0,
        action: (): void => { this.model.photoLibrary.beginSelection(); } } });
      return photoActions;
    }
    if (this.module === 'photos' && ['albums', 'shared'].includes(this.effectivePhotoTab()) &&
      this.model.photoLibrary.selectedAlbum === undefined) {
      return [{ content: { label: '刷新', icon: $r('sys.symbol.arrow_clockwise'), type: IconStyleMode.SMALL,
        isEnabled: !this.navigationBusy(), action: (): void => { this.model.photoLibrary.refresh(); } } }];
    }
    if (this.module === 'root' && this.activeTab === 1) {
      const items: HdsNavigationMenuItemOptions[] = [];
      if (!this.fileSelecting && (this.model.supports('SYNO.FileStation.Upload') || this.model.supports('SYNO.FileStation.CreateFolder'))) {
        items.push({ content: { label: '上传与新建', icon: $r('sys.symbol.plus'), componentId: 'file-add-menu', type: IconStyleMode.SMALL,
          isEnabled: this.model.directory.length > 0 && !this.model.busy, action: (): void => { this.openFileTitleMenu(true); } } });
      }
      items.push({ content: { label: '目录工具', icon: $r('sys.symbol.more'), componentId: 'file-tools-menu', type: IconStyleMode.SMALL,
        isEnabled: !this.model.busy, action: (): void => { this.openFileTitleMenu(false); } } });
      return items;
    }
    return [];
  }

  private async openTitleMenu(id: string, items: TitleMenuItem[]): Promise<void> {
    if (this.titleMenuContent !== undefined) { return; }
    const content = new ComponentContent<TitleMenuItem[]>(this.getUIContext(), wrapBuilder(titleMenu), items);
    this.titleMenuContent = content;
    try {
      await this.getUIContext().getPromptAction().openMenu(content, { id: id }, {
        placement: Placement.BottomRight,
        onDidDisappear: (): void => {
          if (this.titleMenuContent === content) { this.titleMenuContent = undefined; content.dispose(); }
        }
      });
    } catch (error) {
      if (this.titleMenuContent === content) { this.titleMenuContent = undefined; content.dispose(); }
      this.showTitleMenuError('无法打开操作菜单，请重试。');
    }
  }

  private closeTitleMenu(): void {
    const content = this.titleMenuContent;
    if (content !== undefined) {
      this.getUIContext().getPromptAction().closeMenu(content).catch((): void => {
        this.showTitleMenuError('无法关闭操作菜单，请返回后重试。');
      });
    }
  }

  private showTitleMenuError(message: string): void {
    if (!this.pageActive) { return; }
    try { this.getUIContext().getPromptAction().showToast({ message: message,
      systemMaterial: new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.REGULAR }) }); }
    catch { hilog.error(0x0000, 'NasWorkbench', 'operation=menu_feedback result=failed'); }
  }

  private openFileTitleMenu(adding: boolean): void {
    const items: TitleMenuItem[] = [];
    if (adding) {
      if (this.model.supports('SYNO.FileStation.Upload')) {
        items.push(new TitleMenuItem('上传文件', this.model.queue.ready && !this.model.queue.busy && !this.transferSubmitting,
          (): void => { this.runTransfer(async (): Promise<void> => { await this.model.uploadFiles(); }); }));
      }
      if (this.model.supports('SYNO.FileStation.CreateFolder')) {
        items.push(new TitleMenuItem('新建文件夹', true, (): void => { this.openForm('create'); }));
      }
    } else {
      items.push(new TitleMenuItem(this.previewText(this.fileSelecting ? $r('app.string.file_cancel_selection') : $r('app.string.file_multi_select')),
        this.model.directory.length > 0 && this.pendingEntries.length === 0 && this.model.entries.length > 0,
        (): void => { if (this.fileSelecting) { this.cancelFileSelection(); } else { this.fileSelecting = true; } }));
      if (this.model.directory.length > 0) {
        items.push(new TitleMenuItem(this.sortLabel(), true,
          (): void => { this.openForm('sort'); }));
      }
      if (this.model.supports('SYNO.FileStation.Sharing')) {
        items.push(new TitleMenuItem('我的分享链接', true,
          (): void => { this.navStack.pushPathByName('share-links', undefined); }));
      }
      items.push(new TitleMenuItem(this.previewText($r('app.string.task_records')), true,
        (): void => { this.openModuleTasks('files'); }));
      items.push(new TitleMenuItem('刷新目录', true, (): void => { this.model.refresh(); }));
    }
    this.openTitleMenu(adding ? 'file-add-menu' : 'file-tools-menu', items);
  }

  private openDriveTitleMenu(): void {
    const target = this.driveViewMatches() ? this.model.drive.uploadDestination() : undefined;
    const items: TitleMenuItem[] = [];
    if (this.model.driveTransfers.available) {
      items.push(new TitleMenuItem('上传文件',
        target !== undefined && this.model.driveTransfers.ready && !this.model.driveTransfers.busy,
        (): void => { if (target !== undefined) { this.prepareDriveUpload(target); } }));
    }
    if (this.model.driveActions.available) {
      items.push(new TitleMenuItem(this.previewText($r('app.string.drive_create_folder')),
        target !== undefined && this.model.driveActions.ready && !this.model.driveActions.busy && !this.model.driveActions.hasPending,
        (): void => { if (target !== undefined) { this.prepareDriveAction(target, 'create'); } }));
    }
    items.push(new TitleMenuItem('刷新目录', true, (): void => { this.refreshDriveView(); }));
    items.push(new TitleMenuItem('查看传输记录', true, (): void => { this.openDriveTransfers(); }));
    if (this.model.driveTransfers.available) {
      items.push(new TitleMenuItem('传输方式', !this.model.driveTransfers.busy,
        (): void => { this.openForm('drive-transfer-settings'); }));
    }
    this.openTitleMenu('drive-add-menu', items);
  }

  private async prepareDriveUpload(entry: DriveEntry): Promise<void> {
    if (this.navigationBusy() || this.model.driveTransfers.busy) { return; }
    this.model.driveTransfers.clearDraft();
    await this.model.driveTransfers.prepareUpload(entry);
    if (this.pageActive && this.model.driveTransfers.draft !== undefined) { this.openForm('drive-upload'); }
    else if (this.pageActive && this.model.driveTransfers.errorText.length > 0) { this.openDriveTransfers(); }
  }

  private startDriveUpload(): void {
    if (this.model.driveTransfers.busy || this.model.driveTransfers.draft === undefined) { return; }
    const draft = this.model.driveTransfers.draft;
    this.model.driveTransfers.upload().then((): void => {
      if (!this.sheetVisible && this.model.driveTransfers.draft === draft) { this.model.driveTransfers.clearDraft(); }
    });
    this.sheetVisible = false;
    this.openDriveTransfers();
  }

  @Monitor('sheetVisible')
  private uploadSheetClosed(): void {
    if (!this.sheetVisible && this.sheetKind === 'drive-upload') { this.model.driveTransfers.clearDraft(); }
  }

  private tabIcon(id: string): Resource {
    if (id === 'home') { return $r('sys.symbol.house'); }
    if (['files', 'mydrive'].includes(id)) { return $r('sys.symbol.folder'); }
    if (id === 'teamFolders') { return $r('sys.symbol.person_2'); }
    if (id === 'photos') { return $r('sys.symbol.picture'); }
    if (id === 'albums') { return $r('sys.symbol.picture_2'); }
    if (id === 'settings') { return $r('sys.symbol.gearshape'); }
    if (['tasks', 'transfers'].includes(id)) { return $r('sys.symbol.arrow_down_circle'); }
    if (id === 'backup') { return $r('sys.symbol.arrow_up_circle'); }
    if (id === 'starred') { return $r('sys.symbol.star'); }
    if (id === 'recent') { return $r('sys.symbol.clock'); }
    if (id === 'trash') { return $r('sys.symbol.trash'); }
    if (['shared', 'sharedWithMe', 'sharedWithOthers'].includes(id)) { return $r('sys.symbol.person_2'); }
    return $r('sys.symbol.more');
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
    WorkbenchEmptyState({ icon: icon, title: title, description: description })
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

  /** 登录页按地址识别协议，仅保留证书校验选项。 */
  @Builder
  loginView() {
    Column() {
      Scroll(this.homeScroller) {
        Column({ space: 16 }) {
          Column({ space: 12 }) {
            if (this.applicationIcon !== undefined) {
              Image(this.applicationIcon).width(88).height(88).objectFit(ImageFit.Contain).accessibilityLevel('no')
            }
            Text($r('app.string.connection_device'))
              .fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary'))
          }.width('100%').alignItems(HorizontalAlign.Center).margin({ bottom: 24 })
          Column({ space: 12 }) {
            Column({ space: 6 }) {
              Row() {
                Button(this.model.useHttps ? 'HTTPS' : 'HTTP')
                  .height(32).padding({ left: 10, right: 10 }).margin({ left: 8 })
                  .fontSize(12).fontWeight(FontWeight.Medium)
                  .fontColor(this.model.useHttps ? $r('sys.color.font_emphasize') : $r('app.color.workbench_warning'))
                  .backgroundColor(this.model.useHttps ? $r('app.color.workbench_accent_surface') : $r('app.color.workbench_warning_surface'))
                  .borderRadius(16).type(ButtonType.Normal)
                  .enabled(!this.model.busy && !this.model.authenticated)
                  .onClick((): void => {
                    this.model.setAddress((this.model.useHttps ? 'http://' : 'https://') +
                      this.model.address.trim().replace(/^https?:\/\//i, ''));
                  })
                  .accessibilityText('切换连接协议，当前为 ' + (this.model.useHttps ? 'HTTPS' : 'HTTP'))
                TextInput({ text: this.model.address, placeholder: '地址或域名' })
                  .maxLength(512).constraintSize({ minHeight: 48 }).layoutWeight(1).enabled(!this.model.busy && !this.model.authenticated)
                  .backgroundColor(Color.Transparent)
                  .onChange((text: string): void => { this.model.setAddress(text); }).accessibilityText('NAS 服务器地址')
                Button() {
                  SymbolGlyph($r('sys.symbol.arrow_counterclockwise_clock')).fontSize(20).fontWeight(FontWeight.Medium)
                    .fontColor([$r('sys.color.icon_primary')])
                }.width(48).height(48).type(ButtonType.Normal).backgroundColor(Color.Transparent).padding(0)
                  .enabled(!this.model.busy).accessibilityText($r('app.string.connection_addresses'))
                  .onClick((): void => { this.openConnectionAddresses(); })
              }.width('100%').borderRadius(24).backgroundColor($r('sys.color.comp_background_tertiary'))
                .alignItems(VerticalAlign.Center)
              Text(workbenchProtocolHint(this.model.address, this.model.useHttps))
                .fontSize(12).fontColor($r('sys.color.font_tertiary')).padding({ left: 8, right: 8 })
            }.width('100%').alignItems(HorizontalAlign.Start)
            Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.person')).fontSize(20).fontColor([$r('sys.color.icon_secondary')]).margin({ left: 8 })
            TextInput({ text: this.model.account, placeholder: $r('app.string.connection_account') })
              .backgroundColor(Color.Transparent).layoutWeight(1)
              .maxLength(128).constraintSize({ minHeight: 48 }).enabled(!this.model.busy)
              .onChange((text: string): void => { this.model.account = text; }).accessibilityText('NAS 用户名')
            }.width('100%')
            Divider().color($r('app.color.workbench_divider')).margin({ left: 36 })
            Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.lock')).fontSize(20).fontColor([$r('sys.color.icon_secondary')]).margin({ left: 8 })
            TextInput({ text: this.model.password, placeholder: $r('app.string.connection_password') })
              .backgroundColor(Color.Transparent).layoutWeight(1)
              .constraintSize({ minHeight: 48 }).type(InputType.Password).enabled(!this.model.busy)
              .enterKeyType(EnterKeyType.Go).onSubmit((): void => { this.submitLogin(); })
              .onChange((text: string): void => { this.model.password = text; }).accessibilityText('NAS 密码')
            }.width('100%')
            if (this.model.authActionRequired) {
              Button($r('app.string.official_account_verification')).buttonStyle(ButtonStyleMode.TEXTUAL)
                .enabled(!this.model.busy).onClick((): void => { this.model.openAccountVerification(); })
            }
            if (this.model.needsOtp) {
              TextInput({ text: this.model.otp, placeholder: '6 位动态码' }).constraintSize({ minHeight: 48 })
                .type(InputType.Number).maxLength(6).enabled(!this.model.busy)
                .onChange((text: string): void => { this.model.otp = text; }).accessibilityText('双重验证动态码')
              Row({ space: 8 }) {
                Checkbox().select(this.model.trustDevice).enabled(!this.model.busy)
                  .onChange((selected: boolean): void => { this.model.trustDevice = selected; })
                  .accessibilityText($r('app.string.connection_trust_device'))
                Text($r('app.string.connection_trust_device')).fontSize(16).fontColor($r('sys.color.font_primary'))
              }.width('100%').constraintSize({ minHeight: 48 })
                .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -8 })))
            }
            Row({ space: 12 }) {
              Text($r('app.string.connection_ignore_certificate')).fontSize(16).fontColor($r('sys.color.font_primary')).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.model.insecureTls }).enabled(!this.model.busy && this.model.useHttps)
                .onChange((checked: boolean): void => { this.model.setInsecureTls(checked); })
                .accessibilityText($r('app.string.connection_ignore_certificate'))
            }.width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            if (!this.model.addressBook.ready) {
              Button($r('app.string.connection_reload')).buttonStyle(ButtonStyleMode.TEXTUAL)
                .constraintSize({ minHeight: 48 }).enabled(!this.model.busy && !this.model.addressBook.busy)
                .onClick((): void => { this.model.reloadAddressBook(); })
            }
          }.width('100%').padding(16).borderRadius(WorkbenchMetrics.cardRadius)
            .backgroundColor($r('app.color.workbench_surface')).alignItems(HorizontalAlign.Start)
          Button(this.model.busy ? '正在登录…' : '登录')
            .width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .margin({ top: 16 })
            .enabled(!this.model.busy && this.model.address.trim().length > 0 &&
              this.model.account.trim().length > 0 && this.model.password.length > 0)
            .onClick((): void => { this.submitLogin(); })
          this.notices()
        }.width('100%').constraintSize({ maxWidth: 560, minHeight: Math.max(0, this.loginMinHeight() - 112) })
          .justifyContent(FlexAlign.Center)
          .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin, top: 16, bottom: 16 })
          .alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
    }.width('100%').height('100%')
      .padding({ top: this.loginTopInset(), bottom: this.loginBottomInset() })
  }

  @Builder
  shortcut(icon: Resource, label: Resource, action: () => void) {
    Button() {
      Column({ space: 8 }) {
        WorkbenchIconTile({ icon: icon, iconSize: 26, tileSize: 48, tileRadius: 12,
          iconColor: $r('sys.color.icon_emphasize'), tileColor: $r('app.color.workbench_accent_surface') })
        Text(label).fontSize(14).fontColor($r('sys.color.font_primary')).textAlign(TextAlign.Center)
          .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').padding({ top: 12, bottom: 12, left: 4, right: 4 })
    }.width('20%').constraintSize({ minWidth: '64fp' }).flexGrow(1).flexShrink(0)
      .type(ButtonType.Normal).padding(0).backgroundColor(Color.Transparent).enabled(!this.navigationBusy())
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
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(WorkbenchMetrics.rowArrowSize)
            .fontColor([$r('sys.color.font_secondary')]).opacity(WorkbenchMetrics.rowArrowOpacity)
        }.width('100%').alignItems(VerticalAlign.Center)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      this.deviceArtwork()
    }.width('100%').padding({ left: 8, top: 4, bottom: 12 }).enabled(!this.model.busy)
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
  homeDeviceColumn() {
    Column({ space: WorkbenchMetrics.sectionGap }) {
        this.deviceHeader()
        Flex({ wrap: FlexWrap.Wrap }) {
          if (driveTabs((view: DriveView): boolean => this.model.drive.supportsView(view), this.drivePinned).length > 0) {
            this.shortcut($r('sys.symbol.folder'), $r('app.string.home_drive'), (): void => {
              this.driveTabId = 'mydrive'; this.driveMoreView = ''; this.enterModule('drive');
            })
          }
          if (this.supportsPhotos()) {
            this.shortcut($r('sys.symbol.picture'), $r('app.string.home_photos'), (): void => {
              this.photoTabId = 'photos'; this.photoMoreShared = false; this.enterModule('photos');
            })
          }
          if (this.model.supports('SYNO.DownloadStation.Task')) {
            this.shortcut($r('sys.symbol.arrow_down_circle'), $r('app.string.home_downloads'),
              (): void => { this.openNasDownloads(); })
          }
          this.shortcut($r('sys.symbol.square_grid_2x2'), $r('app.string.package_catalog'),
            (): void => { this.navStack.pushPathByName('packages', undefined); })
          this.shortcut($r('sys.symbol.ellipsis_circle'), $r('app.string.more_features'),
            (): void => { this.navStack.pushPathByName('more-features', undefined); })
        }.width('100%')
    }.width('100%')
  }

  @Builder
  homeMonitorColumn() {
    Column({ space: WorkbenchMetrics.sectionGap }) {
        if (!this.model.telemetry.utilization.permissionDenied) {
          NasTelemetrySummary({ monitor: this.model.telemetry, onOpen: (): void => { this.openTelemetry(); } })
        }
        if (!this.model.telemetry.storage.permissionDenied) {
          NasTelemetryStorageCard({ monitor: this.model.telemetry, onOpen: (): void => { this.openTelemetry(); } })
        }
    }.width('100%')
  }

  @Builder
  homeView() {
    Scroll(this.homeScroller) {
      Column({ space: WorkbenchMetrics.sectionGap }) {
        if (this.windowWidth >= 600) {
          Row({ space: 16 }) {
            Column() { this.homeDeviceColumn() }.layoutWeight(1)
            Column() { this.homeMonitorColumn() }.layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Top)
        } else {
          this.homeDeviceColumn()
          this.homeMonitorColumn()
        }
        this.notices()
      }.width('100%').constraintSize({ maxWidth: 1280 })
        .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin, top: this.contentTopInset(), bottom: this.bottomInset() })
    }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Off)
  }


  @Builder
  settingsDeviceHeading() {
    WorkbenchSectionTitle({ title: this.previewText($r('app.string.settings_device_group')) })
  }

  @Builder
  settingsAppHeading() {
    WorkbenchSectionTitle({ title: this.previewText($r('app.string.app_settings_title')) })
  }

  @Builder
  settingsView() {
    List({ scroller: this.settingsScroller, space: WorkbenchMetrics.sectionGap }) {
        ListItem() { this.settingsDeviceHeading() }
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() {
            WorkbenchActionRow({ icon: $r('sys.symbol.externaldrive'), label: '设备信息', description: this.model.account,
              available: !this.model.busy, onAction: (): void => { this.showDeviceInfo(); } })
          }
          ListItem() {
            WorkbenchActionRow({ icon: $r('sys.symbol.arrow_counterclockwise_clock'), label: '历史登录', description: this.model.address,
              available: !this.model.busy, onAction: (): void => { this.openConnectionAddresses(); } })
          }
          if (this.model.supports('SYNO.Core.System')) {
            ListItem() {
              WorkbenchActionRow({ icon: $r('sys.symbol.power'), label: '系统控制',
                available: !this.model.busy, onAction: (): void => { this.navStack.pushPath({ name: 'system-control' }); } })
            }
          }
        }.divider({ strokeWidth: 1, color: $r('app.color.workbench_divider'), startMargin: 68, endMargin: 16 })
          .width('100%').margin({ left: 0, right: 0 })
        ListItem() { this.settingsAppHeading() }
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() {
            WorkbenchActionRow({ icon: $r('sys.symbol.rectangle_split_3x1'), label: '模块底栏',
              description: this.previewText($r('app.string.settings_module_tabs_hint')),
              onAction: (): void => { this.navStack.pushPathByName('module-tabs', 'root'); } })
          }
          ListItem() {
            WorkbenchActionRow({ icon: $r('sys.symbol.moon'), label: this.previewText($r('app.string.appearance_title')),
              value: this.appearanceLabel(this.preferences.appearance), available: !this.preferences.busy,
              onAction: (): void => { this.appearanceMenuVisible = true; } })
              .bindMenu(this.appearanceMenuVisible, this.appearanceMenu(), {
                onDisappear: (): void => { this.appearanceMenuVisible = false; } })
          }
          ListItem() {
            WorkbenchActionRow({ icon: $r('sys.symbol.trash'), label: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.cache_title').id),
              description: workbenchBytes(this.preferences.cacheBytes), available: !this.preferences.busy,
              onAction: (): void => {
                this.getUIContext().showAlertDialog({ title: $r('app.string.cache_clear'), message: $r('app.string.cache_confirm'),
                  primaryButton: { value: $r('app.string.action_cancel'), action: (): void => {} },
                  secondaryButton: { value: $r('app.string.action_confirm'), action: (): void => { this.clearMediaCache(); } } });
              } })
          }
        }.divider({ strokeWidth: 1, color: $r('app.color.workbench_divider'), startMargin: 68, endMargin: 16 })
          .width('100%').margin({ left: 0, right: 0 })
        if (this.preferences.errorText.length > 0) {
          ListItem() { WorkbenchNotice({ text: this.preferences.errorText, warning: true }) }
        }
        if (this.transferLiveView.errorText.length > 0) {
          ListItem() { WorkbenchNotice({ text: this.transferLiveView.errorText, warning: true }) }
        }
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() {
            WorkbenchActionRow({ icon: $r('sys.symbol.arrow_right_and_square'), label: '登出 NAS', destructive: true, showChevron: false,
              available: !this.model.busy, onAction: (): void => { this.confirmLogout(); } })
          }
        }.width('100%').margin({ left: 0, right: 0 })
          .borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        if (this.visibleError().length > 0 || this.model.actionNotice.length > 0) {
          ListItem() { Column() { this.notices() }.width('100%') }
        }
    }.width('100%').constraintSize({ maxWidth: 840 }).height('100%').scrollBar(BarState.Auto)
      .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin })
      .contentStartOffset(this.contentTopInset() + 8).contentEndOffset(this.bottomInset())
  }

  private appearanceLabel(mode: number): string {
    return this.previewText(mode === 0 ? $r('app.string.appearance_system') : mode === 1 ?
      $r('app.string.appearance_light') : $r('app.string.appearance_dark'));
  }

  @Builder
  appearanceMenu() {
    Menu() {
      ForEach([0, 1, 2], (mode: number): void => {
        MenuItem({ content: this.appearanceLabel(mode) }).selected(this.preferences.appearance === mode).selectIcon(true)
          .enabled(!this.preferences.busy).onClick((): void => {
            this.appearanceMenuVisible = false; this.preferences.setAppearance(mode);
          })
      }, (mode: number): string => mode.toString())
    }
  }

  private async clearMediaCache(): Promise<void> {
    this.preferences.busy = true;
    try {
      this.model.photoLibrary.clearCache();
      this.model.driveThumbnails.clearCache();
      await this.model.driveOriginal.close();
      await this.model.fileOriginal.close();
      await this.preferences.measureCache();
    } catch (error) { this.preferences.errorText = (error as Error).message; }
    finally { this.preferences.busy = false; }
  }

  @Builder
  tabSettingRow(label: string, selected: boolean, enabled: boolean, onToggle: (selected: boolean) => void,
    permanent: boolean = false, showDivider: boolean = true) {
    Column() {
      Row({ space: 12 }) {
        Text(label).fontSize(16).fontColor($r('sys.color.font_primary')).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: selected })
            .enabled(!permanent && enabled && this.tabSettingsReady && !this.tabSettingsBusy && !this.navigationBusy())
            .onChange(onToggle).accessibilityText(label + '，显示在底栏')
      }.width('100%').constraintSize({ minHeight: WorkbenchMetrics.rowMinHeight }).padding({ left: 16, right: 16 })
      if (showDivider) {
        Divider().color($r('app.color.workbench_divider')).margin({ left: 16, right: 16 })
      }
    }.width('100%')
  }

  @Builder
  tabSettingsView(module: WorkbenchModule) {
    Scroll(this.tabSettingsScroller) {
      Column({ space: WorkbenchMetrics.sectionGap }) {
        if (module !== 'photos' &&
          driveTabs((view: DriveView): boolean => this.model.drive.supportsView(view), this.drivePinned).length > 0) {
          WorkbenchSectionTitle({ title: 'Synology Drive', trailing: $r('app.string.tabs_enabled_count',
            driveTabs((view: DriveView): boolean => this.model.drive.supportsView(view), this.drivePinned).length) })
          Column() {
            ForEach([DriveView.MyDrive, DriveView.TeamFolders].filter((view: DriveView): boolean => this.model.drive.supportsView(view)),
              (view: DriveView): void => {
                this.tabSettingRow(driveViewLabel(view), true, false, (_selected: boolean): void => {}, true, true)
              }, (view: DriveView): string => view)
            ForEach(DRIVE_MORE_VIEWS.filter((view: DriveView): boolean => this.model.drive.supportsView(view)), (view: DriveView): void => {
              this.tabSettingRow(driveViewLabel(view), this.drivePinned.includes(view), this.drivePinned.includes(view) || this.drivePinned.length < 2,
                (selected) => { this.toggleDriveTab(view, selected); }, false, true)
            }, (view: DriveView): string => view)
            this.tabSettingRow('更多', true, false, (_selected: boolean): void => {}, true, false)
          }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
        }
        if (module !== 'drive' && this.supportsPhotos()) {
          WorkbenchSectionTitle({ title: '照片', trailing: $r('app.string.tabs_enabled_count',
            photoTabs((api: string): boolean => this.model.supports(api), this.showPhotoShared, this.photoPinned).length) })
          Column() {
            this.tabSettingRow('照片', true, false, (_selected: boolean): void => {}, true, true)
            this.tabSettingRow('相册', true, false, (_selected: boolean): void => {}, true, true)
            if (supportsPhotoSharing((api: string): boolean => this.model.supports(api))) {
              this.tabSettingRow('共享', this.showPhotoShared, !this.showPhotoShared ?
                photoTabs((api: string): boolean => this.model.supports(api), false, this.photoPinned).length < 5 : true,
                (selected: boolean): void => { this.togglePhotoTab('shared', selected); }, false, true)
            }
            if (supportsPhotoBackup((api: string): boolean => this.model.supports(api))) {
              this.tabSettingRow('照片备份', this.photoPinned.includes('backup'), this.photoCanPin('backup'),
                (selected: boolean): void => { this.togglePhotoTab('backup', selected); }, false, true)
            }
            this.tabSettingRow('传输任务', this.photoPinned.includes('transfers'), this.photoCanPin('transfers'),
              (selected: boolean): void => { this.togglePhotoTab('transfers', selected); }, false, true)
            this.tabSettingRow('更多', true, false, (_selected: boolean): void => {}, true, false)
          }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
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
  modulePage(tab: ModuleTab) {
    if (this.module === 'drive') {
      DriveModulePage({ model: this.model, wide: this.windowWidth >= 600, tabId: tab.id, active: tab.id === this.driveTabId,
        selecting: tab.id === this.driveTabId && this.driveSelecting,
        selectedIds: tab.id === this.driveTabId ? this.selectedDriveIds : [],
        onSelectionChange: (selecting: boolean, ids: string[]): void => {
          if (this.module === 'drive' && tab.id === this.driveTabId && this.navStack.size() === 0) { this.driveSelecting = selecting; this.selectedDriveIds = ids; }
        },
        detailEntry: this.driveDetailEntry, detailVisible: tab.id === this.driveTabId && this.driveDetailVisible && this.navStack.size() === 0,
        onInspectEntry: (entry: DriveEntry | undefined, visible: boolean): void => {
          if (this.module === 'drive' && tab.id === this.driveTabId && this.navStack.size() === 0) { this.driveDetailEntry = entry; this.driveDetailVisible = visible; }
        },
        menuForEntry: (entry: DriveEntry): MenuElement[] => this.driveEntryActions(entry).map((item: TitleMenuItem): MenuElement => ({ value: item.label, action: item.action })),
        expectedView: tab.view ?? (this.driveMoreView.length > 0 ? this.driveMoreView as DriveView : DriveView.MyDrive),
        scroller: this.driveScrollerFor(tab.id), topInset: this.contentTopInset(), bottomInset: this.bottomInset(),
        moreView: this.driveMoreView, moreViews: this.driveMoreViews(),
        onSelectMore: (view: DriveView): void => { this.selectDriveMore(view); },
        onOpenTransfers: (): void => { this.openDriveTransfers(); },
        onDownload: (entry: DriveEntry, open: boolean): void => { this.submitDriveDownload(entry, '', open); },
        onOpenOriginal: (entry: DriveEntry): void => { this.openDriveOriginal(entry); },
        onCustomize: (): void => { this.navStack.pushPathByName('module-tabs', 'drive'); } })
    } else if (this.module === 'photos') {
      if (tab.id === 'transfers') { this.taskPage(this.photoTasks, this.photoTasksScroller, this.contentTopInset(), this.bottomInset()) }
      else {
        Column() {
          if (tab.id === 'more' && this.photoMoreShared) {
            Button() {
              SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(24).fontColor([$r('sys.color.font_primary')])
            }.type(ButtonType.Normal).backgroundColor(Color.Transparent).width(48).padding(0)
              .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).accessibilityText('返回更多')
              .onClick((): void => { this.photoMoreShared = false; }).margin({ top: this.contentTopInset() + 8 })
          }
          PhotoModulePage({ model: this.model, tabId: tab.id === 'more' && this.photoMoreShared ? 'shared' : tab.id,
            active: tab.id === this.photoTabId, scroller: this.photoScrollerFor(tab.id),
            topInset: tab.id === 'more' && this.photoMoreShared ? 0 : this.contentTopInset(), bottomInset: this.bottomInset(),
            expectedSpace: this.expectedPhotoSpace(tab.id === 'more' && this.photoMoreShared ? 'shared' : tab.id),
            expectedSection: this.expectedPhotoSection(tab.id === 'more' && this.photoMoreShared ? 'shared' : tab.id,
              this.expectedPhotoSpace(tab.id === 'more' && this.photoMoreShared ? 'shared' : tab.id)),
            showBackupInMore: !this.visibleTabs().some((item: ModuleTab): boolean => item.id === 'backup'),
            showSharedInMore: !this.showPhotoShared,
            showTransfersInMore: !this.visibleTabs().some((item: ModuleTab): boolean => item.id === 'transfers'),
            onSelectSpace: (space: PhotosSpace): void => { this.selectPhotoSpace(this.effectivePhotoTab(), space); },
            onOpenPhoto: (item: NasPhotoItem): void => { this.openPhoto(item); },
            onChooseBackupDirectory: (): void => { this.chooseBackupDirectory(); },
            onOpenBackup: (): void => { this.navStack.pushPathByName('photo-backup', undefined); },
            onOpenTransfers: (): void => { this.openPhotoTransfers(); },
            onOpenShared: (): void => { this.openPhotoShared(); },
            onCustomize: (): void => { this.navStack.pushPathByName('module-tabs', 'photos'); },
            onUpload: (): void => { this.selectBackup(); } })
        }.width('100%').height('100%')
      }
    } else if (tab.id === 'home') { this.homeView() }
    else if (tab.id === 'files') {
      FileStationPage({ model: this.model, wide: this.windowWidth >= 600, scroller: this.filesScroller, topInset: this.contentTopInset(), bottomInset: this.bottomInset(),
        active: this.module === 'root' && this.activeTab === 1,
        errorText: this.visibleError(), pendingEntries: this.pendingEntries, pendingOperation: this.pendingOperation, canUseDestination: this.destinationAllowed(),
        selecting: this.fileSelecting, selectedPaths: this.selectedFiles.map((entry: NasFileEntry): string => entry.path),
        onToggleSelection: (entry: NasFileEntry): void => { this.toggleFileSelection(entry); },
        onBeginSelection: (entry: NasFileEntry): void => { this.fileSelecting = true; this.selectedFiles = [entry]; },
        onSort: (): void => { this.openForm('sort'); },
        menuForEntry: (entry: NasFileEntry): MenuElement[] => this.fileEntryActions(entry).map((item: TitleMenuItem): MenuElement => ({ value: item.label, action: item.action })),
        onOpenForm: (kind: string, entry?: NasFileEntry): void => { this.fileEntryAction(kind, entry); },
        onOpenImage: (entry: NasFileEntry): void => { this.navStack.pushPathByName('file-preview', undefined); this.model.fileOriginal.openFile(entry); },
        onNavigateBreadcrumb: (target: string): void => { this.navigateBreadcrumb(target); },
        onApplyDestination: (): void => { this.applyDestination(); }, onCancelDestination: (): void => { this.pendingEntries = []; this.pendingOperation = ''; } })
    } else if (tab.id === 'tasks') { this.taskPage(this.rootTasks, this.taskCategoryScrollers[this.rootTasks.categoryIndex], this.contentTopInset(), this.bottomInset()) }
    else { this.settingsView() }
  }

  /** 原生文件菜单与详情页共用动作，避免两处权限和导航行为分叉。 */
  private fileEntryAction(kind: string, entry?: NasFileEntry): void {
    if (entry === undefined) { this.openForm(kind); return; }
    if (kind === 'share') {
      this.sheetVisible = false;
      this.model.extensions.shareDraftPaths = [entry.path];
      this.model.extensions.selectedShare = undefined;
      this.navStack.pushPathByName('share-links', undefined);
    } else if (kind === 'download') {
      this.sheetVisible = false;
      this.submitFileDownload(entry);
    } else if (kind === 'copy' || kind === 'move') { this.chooseDestination(entry, kind); }
    else if (kind === 'delete') { this.confirmDelete(entry); }
    else { this.openForm(kind, entry); }
  }

  @Builder
  fileActions(entry: NasFileEntry) {
    Column() {
      if (this.model.supports('SYNO.FileStation.Sharing')) {
        WorkbenchActionRow({ icon: $r('sys.symbol.link'), label: '创建分享链接', compact: true, showChevron: false, available: this.model.extensions.canWrite('fileSharing'),
          onAction: (): void => { this.fileEntryAction('share', entry); } })
      }
      if (!entry.isDirectory && this.model.supports('SYNO.FileStation.Download')) {
        WorkbenchActionRow({ icon: $r('sys.symbol.arrow_down_circle'), label: '下载到应用', compact: true, showChevron: false,
          available: this.model.queue.ready && !this.model.busy && !this.model.queue.busy && !this.transferSubmitting,
          onAction: (): void => { this.fileEntryAction('download', entry); } })
      }
      if (this.model.directory.length > 0) {
        if (this.model.supports('SYNO.FileStation.CopyMove')) {
          WorkbenchActionRow({ icon: $r('sys.symbol.folder'), label: '复制到…', compact: true, showChevron: false, available: !this.model.busy,
            onAction: (): void => { this.fileEntryAction('copy', entry); } })
          WorkbenchActionRow({ icon: $r('sys.symbol.arrowshape_turn_up_right'), label: '移动到…', compact: true, showChevron: false, available: !this.model.busy,
            onAction: (): void => { this.fileEntryAction('move', entry); } })
        }
        if (this.model.supports('SYNO.FileStation.Rename')) {
          WorkbenchActionRow({ icon: $r('sys.symbol.pencil_line'), label: '重命名', compact: true, showChevron: false, available: !this.model.busy,
            onAction: (): void => { this.fileEntryAction('rename', entry); } })
        }
        if (this.model.supports('SYNO.FileStation.Delete')) {
          Divider().color($r('app.color.workbench_divider')).margin({ left: 16, right: 16 })
          WorkbenchActionRow({ icon: $r('sys.symbol.trash'), label: '删除', destructive: true, compact: true, showChevron: false, available: !this.model.busy,
            onAction: (): void => { this.fileEntryAction('delete', entry); } })
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

  private async prepareDriveAction(entry: DriveEntry, action: DriveAction, entries?: DriveEntry[]): Promise<void> {
    if (await this.model.driveActions.prepare(entry, action, entries)) { this.navStack.pushPathByName('drive-action', undefined); }
  }

  private async submitDriveAction(): Promise<void> {
    const creating = this.model.driveActions.draft?.action === 'create';
    if (await this.model.driveActions.submit()) {
      const paths: string[] = this.navStack.getAllPathName();
      if (!this.pageActive || paths[paths.length - 1] !== 'drive-action') { return; }
      this.navStack.pop(); this.model.driveActions.clearDraft();
      if (creating && this.model.driveActions.items[0].state === 'completed') {
        this.model.drive.reload();
      } else { this.driveTasks.locate(''); this.openModuleTasks('drive'); }
      this.updateTelemetryMode();
    }
  }

  private returnDriveFiles(): void { this.navStack.clear(); this.enterModule('drive'); this.model.drive.reload(); }

  private openDriveTransfers(): void { this.openModuleTasks('drive'); }

  private openModuleTasks(scope: TaskScope): void {
    this.navStack.pushPathByName(scope + '-tasks', undefined);
  }

  private openPhotoTransfers(): void {
    const index = this.visibleTabs().findIndex((tab: ModuleTab): boolean => tab.id === 'transfers');
    if (this.module === 'photos' && index >= 0) { this.selectModuleTab(index); this.tabsController.changeIndex(index); }
    else { this.openModuleTasks('photos'); }
  }

  private showAllTasks(): void { this.navStack.clear(); this.switchTab(ROOT_TASK_TAB); }

  @Builder
  taskPage(state: TaskPageState, scroller: Scroller, top: number, bottom: number) {
    TaskPage({ model: this.model, wide: this.windowWidth >= 600, state, scroller, rootScrollers: this.taskCategoryScrollers, topInset: top, bottomInset: bottom,
      onAllTasks: (): void => { this.showAllTasks(); }, onRemoteDownloads: (): void => { this.openNasDownloads(); },
      onPhotoBackup: (): void => { this.openPhotoBackup(); },
      onDriveFiles: (): void => { this.returnDriveFiles(); },
      onOverlay: (visible: boolean): void => { this.taskOverlayVisible = visible; } })
  }

  /** 反馈绑定提交时的账号，执行器接管后保留浏览位置。 */
  private downloadFeedback(result: DownloadSubmitResult, scope: TaskScope, preview: string, generation: number): void {
    if (!this.pageActive || !this.model.authenticated || this.model.sessionGeneration !== generation) { return; }
    if (result.taskId === undefined) { this.showTitleMenuError(result.message); return; }
    this.downloadSnackBar?.dismiss();
    const bar = new HdsSnackBar(this.getUIContext()); this.downloadSnackBar = bar;
    bar.show({}, { content: result.status === 'created' ? $r('app.string.task_download_created') : result.status === 'duplicate' ?
      $r('app.string.task_download_duplicate') : $r('app.string.task_download_unconfirmed') }, { operationType: SnackBarOperationType.TEXT_ONLY, content: $r('app.string.task_view'),
      onContentClick: (): void => {
        bar.dismiss();
        if (this.model.sessionGeneration !== generation || !this.model.authenticated) { return; }
        const paths = this.navStack.getAllPathName();
        if (preview.length > 0 && paths[paths.length - 1] === preview) {
          this.navStack.pop();
          if (preview === 'file-preview') { this.model.fileOriginal.close(); }
          else if (preview === 'drive-original') { this.model.driveOriginal.close(); }
        }
        const state = scope === 'drive' ? this.driveTasks : this.fileTasks;
        state.locate((scope === 'drive' ? 'driveTransfer:' : 'transfer:') + result.taskId!);
        this.openModuleTasks(scope);
      } }, { keyboardDownAvoidHeight: LengthMetrics.vp(this.navStack.size() > 0 ? this.navigationInset + 16 : this.bottomInset()),
      isHeightAdaptive: true });
  }

  private async submitFileDownload(entry: NasFileEntry, preview: string = ''): Promise<void> {
    const generation = this.model.sessionGeneration;
    const result = await this.model.downloadFile(entry);
    this.downloadFeedback(result, 'files', preview, generation);
  }

  private submitDriveDownload(entry: DriveEntry, preview: string = '', open: boolean = false): void {
    const generation = this.model.sessionGeneration;
    this.model.driveTransfers.download(entry, open, (result: DownloadSubmitResult): void => {
      this.downloadFeedback(result, 'drive', preview, generation);
    });
  }


  private openDriveOriginal(entry: DriveEntry): void {
    this.navStack.pushPathByName('drive-original', undefined);
    this.model.driveOriginal.open(entry);
  }

  private openDriveLinks(entry?: DriveEntry): void {
    this.model.driveSharing.clearDraft();
    if (entry !== undefined && !this.model.driveSharing.prepare(entry)) { return; }
    this.navStack.pushPathByName('drive-links', undefined);
  }

  private previewText(resource: Resource): string { return this.abilityContext!.resourceManager.getStringSync(resource.id); }

  private previewMenus(source: 'photos' | 'drive' | 'file'): HdsNavigationMenuItemOptions[] {
    const photo = this.model.photoLibrary.detail;
    const drive = this.model.driveOriginal.entry;
    const file = this.model.fileOriginal.fileEntry;
    const video = source === 'photos' ? photo?.mediaType === 'video' : source === 'drive' && /\.(?:mp4|mov|mkv|avi|m4v)$/i.test(drive?.name ?? '');
    const enabled = source === 'photos' ? photo !== undefined && !this.model.photoLibrary.loadingMedia && !this.model.photoLibrary.originalPath :
      source === 'drive' ? drive !== undefined && drive.capabilities.canDownload && !this.model.driveOriginal.originalLoaded :
        file !== undefined && this.model.supports('SYNO.FileStation.Download') && !this.model.fileOriginal.originalLoaded;
    const menu = source === 'photos' ? this.photoPreviewMenu() : source === 'drive' ? this.drivePreviewMenu() : this.filePreviewMenu();
    const id = source + '-preview-menu';
    const actions: HdsNavigationMenuItemOptions[] = [{ content: { label: this.previewText(video ? $r('app.string.preview_play_video') : source === 'photos' ?
        $r('app.string.preview_original_loaded') : $r('app.string.preview_original')),
      icon: video ? $r('sys.symbol.play') : source === 'photos' ? undefined :
        $r('sys.symbol.arrow_up_left_and_arrow_down_right'),
      type: source === 'photos' && !video ? TextStyleMode.NORMAL : source === 'photos' ? IconStyleMode.NORMAL : IconStyleMode.SMALL,
      isEnabled: enabled, action: (): void => {
        if (source === 'photos') { this.model.photoLibrary.loadOriginal(); }
        else if (source === 'drive' && drive !== undefined) {
          if (video) { this.submitDriveDownload(drive, 'drive-original', true); } else { this.model.driveOriginal.open(drive, true); }
        } else if (source === 'file' && file !== undefined) { this.model.fileOriginal.openFile(file, true); }
      } } }, { content: { label: this.previewText($r('app.string.preview_more')),
        icon: $r('sys.symbol.more'),
        type: source === 'photos' ? IconStyleMode.NORMAL : IconStyleMode.SMALL,
        componentId: id, isEnabled: menu.length > 0, action: (): void => {
          this.openTitleMenu(id, menu.map((item: MenuElement): TitleMenuItem => new TitleMenuItem(
            typeof item.value === 'string' ? item.value : this.previewText(item.value), true, (): void => { item.action?.(); })));
        } } }];
    return source === 'photos' && !video && this.model.photoLibrary.originalPath.length > 0 ? actions.slice(1) : actions;
  }

  private drivePreviewInfo(): PreviewInformation[] {
    const entry = this.model.driveOriginal.entry;
    if (entry === undefined) { return []; }
    return [{ label: $r('app.string.file_info_title'), value: entry.name },
      { label: $r('app.string.file_info_type'), value: entry.name.slice(entry.name.lastIndexOf('.') + 1).toLowerCase() },
      { label: $r('app.string.file_info_created'), value: entry.createdAt === undefined ? $r('app.string.file_info_unavailable') : telemetryTimestamp(Math.trunc(entry.createdAt * 1000)) },
      { label: $r('app.string.file_info_modified'), value: entry.modifiedAt === undefined ? $r('app.string.file_info_unavailable') : telemetryTimestamp(Math.trunc(entry.modifiedAt * 1000)) },
      { label: $r('app.string.file_info_owner'), value: entry.owner?.name ?? entry.owner?.displayName ?? entry.owner?.nickname ?? $r('app.string.file_info_unavailable') },
      { label: $r('app.string.file_info_size'), value: workbenchBytes(entry.sizeBytes) },
      { label: $r('app.string.file_info_location'), value: entry.displayPath ?? $r('app.string.file_info_unavailable') }];
  }

  private drivePreviewMenu(): MenuElement[] {
    const entry = this.model.driveOriginal.entry;
    if (entry === undefined) { return []; }
    const menu: MenuElement[] = [];
    if (entry.capabilities.canDownload) { menu.push({ value: this.previewText($r('app.string.preview_download')), action: (): void => { this.submitDriveDownload(entry, 'drive-original'); } }); }
    for (const action of ['copy', 'move'] as DriveAction[]) {
      if (driveActionAllowed(entry, action) && this.model.driveActions.available) {
        menu.push({ value: this.previewText(action === 'copy' ? $r('app.string.preview_copy') : $r('app.string.preview_move')),
          action: (): void => { this.prepareDriveAction(entry, action); } });
      }
    }
    return menu;
  }

  private deleteDrivePreview(): void {
    const entry = this.model.driveOriginal.entry;
    if (entry === undefined) { return; }
    this.getUIContext().showAlertDialog({ title: $r('app.string.preview_delete'), message: entry.name,
      primaryButton: { value: $r('app.string.action_cancel'), action: (): void => {} },
      secondaryButton: { value: $r('app.string.preview_delete'), action: (): void => {
        this.model.driveActions.prepare(entry, 'delete').then(async (prepared: boolean): Promise<void> => {
          if (this.model.driveOriginal.entry !== entry) { return; }
          if (prepared && await this.model.driveActions.submit() && this.model.driveOriginal.entry === entry) {
            this.model.driveActions.clearDraft();
            if (this.navStack.getAllPathName().slice(-1)[0] === 'drive-original') { this.navStack.pop(); }
            this.model.drive.reload();
          }
        });
      } } });
  }

  private filePreviewInfo(): PreviewInformation[] {
    const entry = this.model.fileOriginal.fileEntry;
    if (entry === undefined) { return []; }
    return [{ label: $r('app.string.file_info_title'), value: entry.name },
      { label: $r('app.string.file_info_type'), value: entry.name.slice(entry.name.lastIndexOf('.') + 1).toLowerCase() },
      { label: $r('app.string.file_info_size'), value: workbenchBytes(entry.bytes) },
      { label: $r('app.string.file_info_location'), value: entry.path }];
  }

  private filePreviewMenu(): MenuElement[] {
    const entry = this.model.fileOriginal.fileEntry;
    if (entry === undefined) { return []; }
    const menu: MenuElement[] = [{ value: this.previewText($r('app.string.preview_download')), action: (): void => { this.submitFileDownload(entry, 'file-preview'); } }];
    if (this.model.supports('SYNO.FileStation.CopyMove')) {
      menu.push({ value: this.previewText($r('app.string.preview_copy')), action: (): void => { this.navStack.pop(); this.chooseDestination(entry, 'copy'); } },
        { value: this.previewText($r('app.string.preview_move')), action: (): void => { this.navStack.pop(); this.chooseDestination(entry, 'move'); } });
    }
    return menu;
  }

  private photoPreviewInfo(): PreviewInformation[] {
    const item = this.model.photoLibrary.detail;
    if (item === undefined) { return []; }
    const rows: PreviewInformation[] = [{ label: $r('app.string.file_info_title'), value: item.filename },
      { label: $r('app.string.preview_date'), value: photoTakenDate(item) },
      { label: $r('app.string.file_info_size'), value: workbenchBytes(item.bytes) }];
    if (item.width !== undefined && item.height !== undefined) {
      rows.push({ label: $r('app.string.preview_resolution'), value: item.width.toString() + ' × ' + item.height.toString() });
    }
    if (item.description) { rows.push({ label: $r('app.string.preview_description'), value: item.description }); }
    if (item.location) { rows.push({ label: $r('app.string.file_info_location'), value: item.location }); }
    if (item.address) { rows.push({ label: $r('app.string.preview_location'), value: item.address }); }
    if (item.exif?.camera) { rows.push({ label: $r('app.string.preview_camera'), value: item.exif.camera }); }
    if (item.tags && item.tags.length > 0) { rows.push({ label: $r('app.string.preview_tags'), value: item.tags.join('，') }); }
    return rows;
  }

  private photoExifInfo(): PreviewInformation[] {
    const values: Record<string, string> = this.model.photoLibrary.detail?.exif ?? {};
    const rows: PreviewInformation[] = [];
    const names: string[] = ['camera', 'aperture', 'exposure_time', 'focal_length', 'iso', 'lens'];
    const labels: Resource[] = [$r('app.string.preview_camera'), $r('app.string.preview_aperture'), $r('app.string.preview_exposure'),
      $r('app.string.preview_focal_length'), $r('app.string.preview_iso'), $r('app.string.preview_lens')];
    names.forEach((name: string, index: number): void => { if (values[name]?.length > 0) { rows.push({ label: labels[index], value: values[name] }); } });
    const exifLabels: Record<string, Resource> = { 'ImageWidth': $r('app.string.exif_image_width'), 'ImageLength': $r('app.string.exif_image_height'),
      'ImageDescription': $r('app.string.preview_description'), 'Make': $r('app.string.exif_manufacturer'), 'Model': $r('app.string.preview_camera'),
      'Orientation': $r('app.string.exif_orientation'), 'XResolution': $r('app.string.exif_x_resolution'), 'YResolution': $r('app.string.exif_y_resolution'),
      'ResolutionUnit': $r('app.string.exif_resolution_unit'), 'DateTimeOriginal': $r('app.string.preview_date'), 'DateTimeDigitized': $r('app.string.exif_digitized'),
      'YCbCrPositioning': $r('app.string.exif_positioning'), 'ExposureTime': $r('app.string.preview_exposure'), 'FNumber': $r('app.string.preview_aperture'),
      'ExposureProgram': $r('app.string.exif_exposure_program'), 'ISOSpeedRatings': $r('app.string.preview_iso'), 'ExifVersion': $r('app.string.exif_version'),
      'FocalLength': $r('app.string.preview_focal_length'), 'LensMake': $r('app.string.exif_lens_manufacturer'), 'LensModel': $r('app.string.preview_lens') };
    for (const key of Object.keys(this.model.photoLibrary.originalExif)) {
      rows.push({ label: exifLabels[key], value: this.model.photoLibrary.originalExif[key] });
    }
    return rows;
  }

  private photoCan(action: PhotoAction): boolean {
    const item = this.model.photoLibrary.detail ?? this.model.photoLibrary.selectedItems()[0];
    if (item === undefined || item.space === PhotosSpace.WithMe) { return false; }
    return this.model.extensions.canPhotoAction({ action, item, items: this.model.photoLibrary.selecting ? this.model.photoLibrary.selectedItems() : undefined,
      favorite: !item.favorite, targetId: 0 });
  }

  private async photoAction(action: PhotoAction, targetId?: number): Promise<void> {
    const batch = this.model.photoLibrary.selecting;
    const item = this.model.photoLibrary.detail ?? this.model.photoLibrary.selectedItems()[0];
    if (item === undefined) { return; }
    const input: PhotoActionInput = { action, item, items: batch ? this.model.photoLibrary.selectedItems() : undefined, targetId, favorite: !item.favorite };
    const confirmed = await this.model.extensions.performPhotoAction(input);
    if (!batch && this.model.photoLibrary.detail !== item) { return; }
    if (confirmed && action === 'favorite') { this.model.photoLibrary.confirmFavorite(item, input.favorite!); }
    if (confirmed && action === 'album' && this.navStack.getAllPathName().slice(-1)[0] === 'photo-actions') { this.navStack.pop(); }
    if (confirmed && action === 'share') {
      try {
        const data = new systemShare.SharedData({ utd: uniformTypeDescriptor.UniformDataType.HYPERLINK,
          content: this.model.extensions.photoShare, title: item.filename });
        await new systemShare.ShareController(data).show(this.abilityContext!, { selectionMode: systemShare.SelectionMode.SINGLE,
          previewMode: systemShare.SharePreviewMode.DEFAULT });
      } catch { this.showTitleMenuError(this.previewText($r('app.string.preview_share_failed'))); }
    }
    if (action === 'delete' || action === 'copy' || action === 'move') {
      this.photoBatchDestination = batch;
      if (!confirmed && !this.model.extensions.hasPending('photos')) {
        this.showTitleMenuError(this.model.extensions.photoError); return;
      }
      await this.refreshPhotoPreviewTask();
      if (!batch && this.model.photoLibrary.detail !== item) { return; }
      if (this.model.extensions.hasPending('photos') && this.navStack.getAllPathName().slice(-1)[0] !== 'photo-actions') {
        this.navStack.pushPathByName('photo-actions', undefined);
      }
    } else if (this.model.extensions.photoError.length > 0) { this.showTitleMenuError(this.model.extensions.photoError); }
  }

  private async refreshPhotoPreviewTask(): Promise<void> {
    const record = this.model.extensions.pending.find((row): boolean => row.feature === 'photos');
    const item = this.model.photoLibrary.detail;
    await this.model.extensions.refreshPhotoTask();
    if (record === undefined || this.model.extensions.hasPending('photos') || this.model.photoLibrary.detail !== item) { return; }
    if (this.navStack.getAllPathName().slice(-1)[0] === 'photo-actions') { this.navStack.pop(); }
    if (this.photoBatchDestination) {
      this.photoBatchDestination = false;
      if (record.operation === 'delete' || record.operation === 'move') { await this.model.photoLibrary.refresh(); }
      else { this.model.photoLibrary.selectionNotice = this.model.extensions.photoNotice; }
      return;
    }
    if (record.operation === 'delete' && item !== undefined && item.id === record.photoId && item.space === record.photoSpace) {
      if (this.navStack.getAllPathName().slice(-1)[0] === 'photo-detail') { this.navStack.pop(); }
      this.model.photoLibrary.refresh();
    }
  }

  private deletePhotoPreview(): void {
    const item = this.model.photoLibrary.detail;
    if (item === undefined) { return; }
    this.getUIContext().showAlertDialog({ title: $r('app.string.preview_delete'), message: item.filename,
      primaryButton: { value: $r('app.string.action_cancel'), action: (): void => {} },
      secondaryButton: { value: $r('app.string.preview_delete'), action: (): void => { this.photoAction('delete'); } } });
  }

  private photoPreviewMenu(): MenuElement[] {
    const menu: MenuElement[] = [{ value: this.previewText($r('app.string.preview_download')), action: (): void => { this.savePhotoOriginal(); } }];
    if (this.photoCan('album')) { menu.push({ value: this.previewText($r('app.string.preview_album')), action: (): void => { this.openPhotoDestination('album'); } }); }
    if (this.photoCan('copy')) { menu.push({ value: this.previewText($r('app.string.preview_copy')), action: (): void => { this.openPhotoDestination('copy'); } }); }
    return menu;
  }

  private deletePhotoSelection(): void {
    this.getUIContext().showAlertDialog({ title: $r('app.string.preview_delete'),
      message: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.photos_delete_count').id, this.model.photoLibrary.selectedKeys.length),
      primaryButton: { value: $r('app.string.action_cancel'), action: (): void => {} },
      secondaryButton: { value: $r('app.string.preview_delete'), action: (): void => { this.photoAction('delete'); } } });
  }

  private openPhotoSelectionMenu(): void {
    const items = [
      new TitleMenuItem(this.previewText($r('app.string.photos_move')), this.photoCan('move'), (): void => { this.openPhotoDestination('move'); }),
      new TitleMenuItem(this.previewText($r('app.string.preview_copy')), this.photoCan('copy'), (): void => { this.openPhotoDestination('copy'); }),
      new TitleMenuItem(this.previewText($r('app.string.preview_download')), !this.model.photoLibrary.selectionBusy,
        (): void => { this.model.photoLibrary.downloadSelection(); })];
    this.openTitleMenu('photos-selection-menu', items);
  }

  @Builder
  photoSelectionBar() {
    Row({ space: 4 }) {
      Button($r('app.string.preview_share')).layoutWeight(1).buttonStyle(ButtonStyleMode.TEXTUAL)
        .enabled(this.photoCan('share')).onClick((): void => { this.photoAction('share'); })
      Button($r('app.string.preview_album')).layoutWeight(1).buttonStyle(ButtonStyleMode.TEXTUAL)
        .enabled(this.photoCan('album')).onClick((): void => { this.openPhotoDestination('album'); })
      Button($r('app.string.preview_delete')).layoutWeight(1).buttonStyle(ButtonStyleMode.TEXTUAL)
        .enabled(this.photoCan('delete')).onClick((): void => { this.deletePhotoSelection(); })
      Button($r('app.string.photos_more')).layoutWeight(1).buttonStyle(ButtonStyleMode.TEXTUAL).id('photos-selection-menu')
        .enabled(this.model.photoLibrary.selectedKeys.length > 0 && !this.model.photoLibrary.selectionBusy && !this.model.extensions.busy)
        .onClick((): void => { this.openPhotoSelectionMenu(); })
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 8, right: 8, bottom: this.navigationInset })
      .backgroundColor($r('app.color.workbench_surface'))
  }

  private openPhotoDestination(mode: 'album' | 'copy' | 'move' | 'backup'): void {
    this.photoBatchDestination = this.model.photoLibrary.selecting;
    this.photoDestinationMode = mode; this.photoFolderTrail = [];
    this.navStack.pushPathByName('photo-actions', undefined); this.model.photoLibrary.loadActionTargets(mode);
  }

  @Builder
  photoActionsView() {
    Column({ space: 12 }) {
      if (this.model.extensions.hasPending('photos') || this.model.extensions.recordsError.length > 0) {
        ExtensionStatusPanel({ model: this.model.extensions, feature: 'photos' })
      }
      if (this.model.extensions.hasPending('photos')) {
        Button($r('app.string.preview_check_task')).enabled(!this.model.extensions.busy)
          .onClick((): void => { this.refreshPhotoPreviewTask(); })
      } else if (this.model.photoLibrary.detail !== undefined || this.model.photoLibrary.selecting || this.photoDestinationMode === 'backup') {
        WorkbenchNotice({ text: this.model.photoLibrary.targetsError, warning: true })
        if (this.model.photoLibrary.targetsBusy) { LoadingProgress().width(32).height(32) }
        List() {
          if (this.photoDestinationMode === 'album') {
            ForEach(this.model.photoLibrary.actionAlbums, (album: NasPhotoAlbum): void => {
              ListItem() { Button(album.name).width('100%').buttonStyle(ButtonStyleMode.TEXTUAL)
                .enabled(!this.model.extensions.busy).onClick((): void => { this.photoAction('album', album.id); }) }
            })
          } else {
            ForEach(this.model.photoLibrary.actionFolders, (folder: PhotoFolder): void => {
              ListItem() { Button(folder.name).width('100%').buttonStyle(ButtonStyleMode.TEXTUAL)
                .onClick((): void => { this.photoFolderTrail = [...this.photoFolderTrail, folder]; this.model.photoLibrary.loadActionTargets(this.photoDestinationMode, folder.id); }) }
            })
          }
        }.width('100%').layoutWeight(1)
        if (this.photoDestinationMode !== 'album') {
          Text(this.photoFolderTrail.map((folder: PhotoFolder): string => folder.name).join(' / ')).width('100%')
          Button($r('app.string.photos_use_folder')).enabled(!this.model.photoLibrary.targetsBusy && !this.model.extensions.busy &&
            (this.photoDestinationMode !== 'backup' || this.photoFolderTrail.length > 0))
            .onClick((): void => {
              if (this.photoDestinationMode === 'backup') {
                this.model.photoBackup.configure(this.model.photoBackup.settings.mode, true,
                  this.photoFolderTrail.map((folder: PhotoFolder): string => folder.name.split('/').filter((name: string): boolean => name.length > 0).slice(-1)[0]).join('/'))
                  .then((): void => { if (this.model.photoBackup.errorText.length === 0) { this.navStack.pop(); } });
              } else { this.photoAction(this.photoDestinationMode, this.photoFolderTrail[this.photoFolderTrail.length - 1]?.id ?? 0); }
            })
          Button($r('app.string.preview_parent')).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(this.photoFolderTrail.length > 0).onClick((): void => { this.photoFolderTrail = this.photoFolderTrail.slice(0, -1); this.model.photoLibrary.loadActionTargets(this.photoDestinationMode, this.photoFolderTrail[this.photoFolderTrail.length - 1]?.id ?? 0); })
        }
      }
    }.width('100%').height('100%').padding(16)
  }

  @Builder
  photoDetailView() {
    ImagePreview({ source: this.model.photoLibrary.originalPath.length > 0 ? fileUri.getUriFromPath(this.model.photoLibrary.originalPath) :
        this.model.photoLibrary.previewPath.length > 0 ? fileUri.getUriFromPath(this.model.photoLibrary.previewPath) : '',
      name: this.model.photoLibrary.detail?.filename ?? '', photos: true, video: this.model.photoLibrary.detail?.mediaType === 'video',
      controlsVisible: this.photoControlsVisible, navigationInset: this.navigationInset,
      onDismiss: (): void => { this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 328, 36) }, (): void => { this.navStack.pop(); }); },
      onToggleControls: (): void => {
        this.photoControlsVisible = !this.photoControlsVisible;
        this.updatePhotoPreviewWindow();
      },
      itemKey: this.model.photoLibrary.detail === undefined ? '' :
        this.model.photoLibrary.detail.space.toString() + ':' + this.model.photoLibrary.detail.id.toString(),
      canNavigate: !this.model.extensions.busy && !this.model.extensions.hasPending('photos'),
      onNavigate: (direction: number): void => { this.model.photoLibrary.switchDetail(direction); },
      busy: this.model.photoLibrary.loadingMedia, original: this.model.photoLibrary.originalPath.length > 0,
      favorite: this.model.photoLibrary.detail?.favorite === true,
      canShare: this.photoCan('share'), canDelete: this.photoCan('delete'),
      information: this.photoPreviewInfo(), exif: this.photoExifInfo(),
      errorText: this.model.photoLibrary.mediaErrorText || this.model.extensions.photoError,
      onDownload: (): void => { this.savePhotoOriginal(); },
      onFavorite: (): void => { this.photoAction('favorite'); }, onShare: (): void => { this.photoAction('share'); },
      onDelete: (): void => { this.deletePhotoPreview(); },
      onDecodeError: (): void => { this.showTitleMenuError(this.previewText($r('app.string.preview_decode_failed'))); } })
  }

  /** 照片预览始终占满窗口；顺序恢复系统栏，避免返回后留下隐藏状态。 */
  private updatePhotoPreviewWindow(): void {
    const mainWindow = this.mainWindow;
    if (mainWindow === undefined) { return; }
    const opened = this.photoPreviewOpened;
    const visible = !opened || this.photoControlsVisible;
    this.photoWindowUpdate = this.photoWindowUpdate.then(async (): Promise<void> => {
      await mainWindow.setSpecificSystemBarEnabled('status', visible, true);
      await mainWindow.setSpecificSystemBarEnabled('navigation', visible, true);
      await mainWindow.setSpecificSystemBarEnabled('navigationIndicator', visible, true);
      await mainWindow.setWindowLayoutFullScreen(opened || this.normalWindowFullScreen);
    }).catch((error: BusinessError): void => {
      hilog.error(0x0000, 'NasLayout', 'operation=photo_preview_window result=failed code=%{public}d', error.code);
      if (this.pageActive) { this.showTitleMenuError(this.previewText($r('app.string.preview_display_failed'))); }
    });
  }

  /** 返回箭头保留系统模板尺寸，颜色交由标题栏适配材质。 */
  private navigationBackSymbol(): SymbolGlyphModifier {
    return new SymbolGlyphModifier(this.fileSelectionActive() ? $r('sys.symbol.xmark') : $r('sys.symbol.chevron_left')).fontSize(24);
  }

  @Builder
  destinationBuilder(name: string, parameter: Object) {
    if (name === 'module-tabs') {
      HdsNavDestination() { this.tabSettingsView(parameter as WorkbenchModule) }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL }, title: { mainTitle: '模块底栏' } } })
        .bindToScrollable([this.tabSettingsScroller])
    } else if (name === 'directory-picker') {
      HdsNavDestination() {
        FileStationPage({ model: this.model, scroller: this.pickerScroller, topInset: 0, bottomInset: this.navigationInset + 16,
          pickerMode: this.pickerMode, errorText: this.visibleError(),
          canConfirm: this.model.directory.length > 0 && !this.model.busy,
          onNavigateBreadcrumb: (target: string): void => { this.navigateBreadcrumb(target); },
          onConfirm: (): void => { this.useDownloadDirectory(); },
          onCancel: (): void => { this.cancelDirectoryPicker(); } })
      }.backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL }, title: { mainTitle: '下载保存目录' } } })
        .bindToScrollable([this.pickerScroller])
        .onBackPressed((): boolean => {
          if (this.backup.submitting) { return true; }
          if (this.model.directory.length > 0) { if (!this.model.busy) { this.model.goBack(); } return true; }
          this.cancelDirectoryPicker(); return true;
        })
        .onDisAppear((): void => { this.pickerMode = ''; })
    } else if (name === 'drive-search') {
      HdsNavDestination() {
        DriveModulePage({ model: this.model, tabId: 'search', expectedView: DriveView.Search, searchPage: true,
          selecting: this.driveSelecting, selectedIds: this.selectedDriveIds,
          onSelectionChange: (selecting: boolean, ids: string[]): void => {
            if (this.module === 'drive' && this.navStack.getAllPathName().slice(-1)[0] === 'drive-search') {
              this.driveSelecting = selecting; this.selectedDriveIds = ids;
            }
          },
          detailEntry: this.driveDetailEntry, detailVisible: this.driveDetailVisible,
          onInspectEntry: (entry: DriveEntry | undefined, visible: boolean): void => {
            if (this.module === 'drive' && this.navStack.getAllPathName().slice(-1)[0] === 'drive-search') {
              this.driveDetailEntry = entry; this.driveDetailVisible = visible;
            }
          },
          menuForEntry: (entry: DriveEntry): MenuElement[] => this.driveEntryActions(entry).map((item: TitleMenuItem): MenuElement => ({ value: item.label, action: item.action })),
          scroller: this.driveSearchScroller, bottomInset: this.navigationInset + 16,
          onExitSearch: (): void => { this.exitDriveSearch(); },
          onOpenTransfers: (): void => { this.openDriveTransfers(); },
          onDownload: (entry: DriveEntry, open: boolean): void => { this.submitDriveDownload(entry, '', open); },
          onOpenOriginal: (entry: DriveEntry): void => { this.openDriveOriginal(entry); } })
      }.backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL,
          action: (): void => { if (this.driveSelecting) { this.cancelDriveSelection(); } else { this.exitDriveSearch(); } } },
          title: { mainTitle: this.driveSelecting ? this.fileSelectionTitle() : $r('app.string.drive_search_title') },
          menu: { value: this.driveSelecting ? this.pageMenu() : [] } },
          style: { systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE },
            scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: ScrollEffectType.GRADIENT_BLUR } } })
        .bindToScrollable([this.driveSearchScroller])
        .toolbarConfiguration(this.fileSelectionToolbar, { barStyle: BarStyle.STANDARD }).hideToolBar(!this.driveSelecting)
        .onBackPressed((): boolean => { return this.onBackPress(); })
    } else if (name === 'drive-links') {
      HdsNavDestination() {
        DriveSharingPage({ model: this.model.driveSharing, scroller: this.driveLinksScroller,
          onCancel: (): void => { this.navStack.pop(); } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL }, title: { mainTitle: 'Drive 文件链接' } } })
        .bindToScrollable([this.driveLinksScroller])
        .onHidden((): void => { this.model.driveSharing.clearDraft(); })
    } else if (name === 'drive-notifications') {
      HdsNavDestination() { DriveNotificationsPage({ model: this.model.driveNotifications, scroller: this.driveNotificationsScroller }) }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL }, title: { mainTitle: 'Drive 通知' } } })
        .bindToScrollable([this.driveNotificationsScroller])
        .onShown((): void => { this.model.driveNotifications.refresh(); })
    } else if (name === 'drive-original') {
      HdsNavDestination() { DriveOriginalPage({ model: this.model.driveOriginal, information: this.drivePreviewInfo(),
        fullscreen: true, controlsVisible: this.photoControlsVisible, navigationInset: this.navigationInset,
        onToggleControls: (): void => { this.photoControlsVisible = !this.photoControlsVisible; this.updatePhotoPreviewWindow(); },
        onDismiss: (): void => { this.navStack.pop(); },
        canDelete: this.model.driveOriginal.entry !== undefined && driveActionAllowed(this.model.driveOriginal.entry, 'delete') &&
          this.model.driveActions.available && this.model.driveActions.ready && !this.model.driveActions.busy && !this.model.driveActions.hasPending,
        canShare: this.model.driveOriginal.entry !== undefined && driveFileLinkAllowed(this.model.driveOriginal.entry) &&
          this.model.driveSharing.available && this.model.driveSharing.ready && !this.model.driveSharing.busy && !this.model.driveSharing.hasPending,
        onDownload: (): void => { const entry = this.model.driveOriginal.entry; if (entry !== undefined) { this.submitDriveDownload(entry, 'drive-original'); } },
        onDelete: (): void => { this.deleteDrivePreview(); },
        onShare: (): void => { const entry = this.model.driveOriginal.entry; if (entry !== undefined) { this.openDriveLinks(entry); } } }) }
        .backgroundColor(Color.Transparent).hideTitleBar(!this.photoControlsVisible)
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL }, title: { mainTitle: this.model.driveOriginal.entry?.name || '原图' },
          menu: { value: this.previewMenus('drive'), maxCount: 2 } },
          style: { systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE, materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE } } })
        .onHidden((): void => {
          this.photoPreviewOpened = false; this.photoControlsVisible = true; this.updatePhotoPreviewWindow();
          if (!this.navStack.getAllPathName().includes('drive-original')) { this.model.driveOriginal.close(); }
        })
        .onShown((): void => { this.photoPreviewOpened = true; this.photoControlsVisible = true; this.updatePhotoPreviewWindow(); })
    } else if (name === 'file-preview') {
      HdsNavDestination() {
        ImagePreview({ source: this.model.fileOriginal.pixels ?? '', name: this.model.fileOriginal.fileEntry?.name ?? '',
          fullscreen: true, controlsVisible: this.photoControlsVisible, navigationInset: this.navigationInset,
          onToggleControls: (): void => { this.photoControlsVisible = !this.photoControlsVisible; this.updatePhotoPreviewWindow(); },
          onDismiss: (): void => { this.navStack.pop(); },
          busy: this.model.fileOriginal.busy, original: this.model.fileOriginal.originalLoaded, errorText: this.model.fileOriginal.errorText,
          information: this.filePreviewInfo(),
          canDelete: this.model.supports('SYNO.FileStation.Delete'), canShare: this.model.extensions.canWrite('fileSharing'),
          canDownload: this.model.supports('SYNO.FileStation.Download'),
          onDownload: (): void => { const entry = this.model.fileOriginal.fileEntry; if (entry !== undefined) { this.submitFileDownload(entry, 'file-preview'); } },
          onShare: (): void => { const entry = this.model.fileOriginal.fileEntry; if (entry !== undefined) { this.fileEntryAction('share', entry); } },
          onDelete: (): void => { const entry = this.model.fileOriginal.fileEntry; if (entry !== undefined) { this.confirmDelete(entry, true); } },
          onViewport: (width: number, height: number): void => { this.model.fileOriginal.setViewport(width, height); },
          onRefine: (scale: number): void => { this.model.fileOriginal.refine(scale); } })
      }.backgroundColor(Color.Transparent).hideTitleBar(!this.photoControlsVisible)
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL }, title: { mainTitle: this.model.fileOriginal.fileEntry?.name ?? '' },
          menu: { value: this.previewMenus('file'), maxCount: 2 } },
          style: { systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE, materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE } } })
        .onShown((): void => { this.photoPreviewOpened = true; this.photoControlsVisible = true; this.updatePhotoPreviewWindow(); })
        .onHidden((): void => {
          this.photoPreviewOpened = false; this.photoControlsVisible = true; this.updatePhotoPreviewWindow();
          if (!this.navStack.getAllPathName().includes('file-preview')) { this.model.fileOriginal.close(); }
        })
    } else if (name === 'drive-action') {
      HdsNavDestination() {
        DriveActionPage({ model: this.model.driveActions, scroller: this.driveActionScroller,
          onSubmit: (): void => { this.submitDriveAction(); },
          onCancel: (): void => { this.model.driveActions.clearDraft(); this.navStack.pop(); } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL }, title: { mainTitle: 'Drive 文件操作' } } })
        .bindToScrollable([this.driveActionScroller])
        .onHidden((): void => { this.model.driveActions.clearDraft(); })
    } else if (name === 'more-features') {
      HdsNavDestination() {
        MoreFeaturesPage({ scroller: this.moreFeaturesScroller, bottomInset: this.navigationInset + 16,
          onManagement: (): void => { this.openPackageManagement(); },
          onOpen: (destination: string): void => {
            if (destination === 'nas-downloads') { this.openNasDownloads(); }
            else if (['containers', 'cloud-sync', 'system-logs', 'notes'].includes(destination)) { this.navStack.pushPathByName(destination, undefined); }
          } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL },
          title: { mainTitle: $r('app.string.more_features') } },
          style: { systemMaterialEffect: this.navigationMaterial } })
        .bindToScrollable([this.moreFeaturesScroller])
        .onShown((): void => { this.packageDestination = 'more-features'; this.updateTelemetryMode(); })
        .onHidden((): void => { if (this.packageDestination === 'more-features') { this.packageDestination = ''; } this.updateTelemetryMode(); })
    } else if (name === 'containers') {
      HdsNavDestination() {
        ContainerPage({ model: this.model.containers, scroller: this.containersScroller, bottomInset: this.navigationInset + 16,
          onManagement: (): void => { this.openPackageManagement(); } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL },
          title: { mainTitle: $r('app.string.more_feature_containers') } } })
        .bindToScrollable([this.containersScroller])
        .onBackPressed((): boolean => this.model.containers.back())
        .onShown((): void => { this.packageDestination = 'containers'; this.updatePackageVisibility(); this.updateTelemetryMode(); })
        .onHidden((): void => { this.model.containers.setVisible(false); if (this.packageDestination === 'containers') { this.packageDestination = ''; } this.updateTelemetryMode(); })
    } else if (name === 'cloud-sync') {
      HdsNavDestination() {
        CloudSyncPage({ model: this.model.cloudSync, scroller: this.cloudSyncScroller, bottomInset: this.navigationInset + 16,
          onManagement: (): void => { this.openPackageManagement(); } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL },
          title: { mainTitle: $r('app.string.more_feature_cloud_sync') } } })
        .bindToScrollable([this.cloudSyncScroller])
        .onBackPressed((): boolean => this.model.cloudSync.back())
        .onShown((): void => { this.packageDestination = 'cloud-sync'; this.updatePackageVisibility(); this.updateTelemetryMode(); })
        .onHidden((): void => { this.model.cloudSync.setVisible(false); if (this.packageDestination === 'cloud-sync') { this.packageDestination = ''; } this.updateTelemetryMode(); })
    } else if (name === 'system-logs') {
      HdsNavDestination() {
        SystemLogPage({ model: this.model.systemLogs, scroller: this.systemLogsScroller, bottomInset: this.navigationInset + 16,
          onManagement: (): void => { this.openPackageManagement(); } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL },
          title: { mainTitle: $r('app.string.more_feature_system_logs') } } })
        .bindToScrollable([this.systemLogsScroller])
        .onBackPressed((): boolean => this.model.systemLogs.back())
        .onShown((): void => { this.packageDestination = 'system-logs'; this.updatePackageVisibility(); this.updateTelemetryMode(); })
        .onHidden((): void => { this.model.systemLogs.setVisible(false); if (this.packageDestination === 'system-logs') { this.packageDestination = ''; } this.updateTelemetryMode(); })
    } else if (name === 'notes') {
      HdsNavDestination() {
        NoteStationPage({ model: this.model.notes, scroller: this.notesScroller, bottomInset: this.navigationInset + 16,
          onManagement: (): void => { this.openPackageManagement(); } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL },
          title: { mainTitle: $r('app.string.more_feature_notes') } } })
        .bindToScrollable([this.notesScroller])
        .onBackPressed((): boolean => this.model.notes.back())
        .onShown((): void => { this.packageDestination = 'notes'; this.updatePackageVisibility(); this.updateTelemetryMode(); })
        .onHidden((): void => { this.model.notes.setVisible(false); if (this.packageDestination === 'notes') { this.packageDestination = ''; } this.updateTelemetryMode(); })
    } else if (name === 'official-web') {
      HdsNavDestination() { OfficialWebPage({ model: this.model.officialWeb }) }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL },
          title: { mainTitle: $r('app.string.official_web') } } })
        .onBackPressed((): boolean => this.model.officialWeb.onBack())
        .onHidden((): void => { this.model.officialWeb.close(); })
    } else if (name === 'packages') {
      HdsNavDestination() {
        PackageCatalogPage({ model: this.model.packages, scroller: this.packagesScroller, bottomInset: this.navigationInset + 16,
          onDetail: (item: InstalledPackage): void => { this.openPackageDetail(item); } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL },
          title: { mainTitle: $r('app.string.package_catalog') } } })
        .bindToScrollable([this.packagesScroller])
        .onShown((): void => { this.packageDestination = 'packages'; this.updatePackageVisibility(); this.updateTelemetryMode(); })
        .onHidden((): void => { this.model.packages.hideList(); if (this.packageDestination === 'packages') { this.packageDestination = ''; } this.updateTelemetryMode(); })
    } else if (name === 'package-detail') {
      HdsNavDestination() {
        PackageDetailPage({ model: this.model.packages, scroller: this.packageDetailScroller, bottomInset: this.navigationInset + 16,
          onNative: (target: PackageNativeTarget): void => { this.openPackageNative(target); },
          onManagement: (): void => { this.openPackageManagement(); } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL },
          title: { mainTitle: $r('app.string.package_detail') } } })
        .bindToScrollable([this.packageDetailScroller])
        .onShown((): void => { this.packageDestination = 'package-detail'; this.updatePackageVisibility(); this.updateTelemetryMode(); })
        .onHidden((): void => { this.model.packages.hideDetail(); if (this.packageDestination === 'package-detail') { this.packageDestination = ''; } this.updateTelemetryMode(); })
    } else if (name === 'share-links') {
      HdsNavDestination() { ShareLinksPage({ model: this.model.extensions, scroller: this.sharesScroller }) }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL }, title: { mainTitle: '我的分享' } } })
        .bindToScrollable([this.sharesScroller])
        .onShown((): void => { this.extensionsOpened = true; this.updateTelemetryMode(); this.model.extensions.refreshShares(); })
        .onHidden((): void => { this.extensionsOpened = false; this.updateTelemetryMode(); })
    } else if (name === 'files-tasks' || name === 'drive-tasks' || name === 'photos-tasks') {
      HdsNavDestination() {
        this.taskPage(name === 'files-tasks' ? this.fileTasks : name === 'drive-tasks' ? this.driveTasks : this.photoTasks,
          name === 'files-tasks' ? this.fileTasksScroller : name === 'drive-tasks' ? this.driveTasksScroller : this.photoTasksScroller, 0, this.navigationInset + 16)
      }.backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL },
          title: { mainTitle: name === 'files-tasks' ? $r('app.string.task_file_title') : name === 'drive-tasks' ? $r('app.string.task_drive_title') : $r('app.string.task_photo_title') } } })
        .bindToScrollable([name === 'files-tasks' ? this.fileTasksScroller : name === 'drive-tasks' ? this.driveTasksScroller : this.photoTasksScroller])
        .onShown((): void => { this.taskDestination = name === 'drive-tasks' ? 'drive' : name === 'files-tasks' ? 'files' : 'photos'; this.updateTelemetryMode(); })
        .onHidden((): void => { this.taskDestination = ''; this.taskOverlayVisible = false; this.updateTelemetryMode(); })
    } else if (name === 'nas-downloads') {
      HdsNavDestination() {
        DownloadStationPage({ model: this.model.extensions, scroller: this.downloadsScroller, visible: this.downloadsVisible,
          refreshRevision: this.downloadsRefreshRevision, bottomInset: this.navigationInset + 16,
          onChooseDirectory: (): void => { this.chooseDownloadDirectory(); } })
      }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL },
          title: { mainTitle: $r('app.string.task_remote_title'), subTitle: this.model.extensions.downloadsLoaded ? $r('app.string.task_remote_total', this.model.extensions.downloadTotal) : '' },
          menu: { value: this.remoteDownloadMenus() } } })
        .bindToScrollable([this.downloadsScroller])
        .onShown((): void => { this.downloadsVisible = true; this.extensionsOpened = true; this.updateTelemetryMode();
          if (!this.model.extensions.downloadsLoaded) { this.model.extensions.refreshDownloads(); } })
        .onHidden((): void => { this.downloadsVisible = false; this.extensionsOpened = false; this.model.extensions.deactivateDownloads(); this.updateTelemetryMode(); })
    } else if (name === 'telemetry') {
      HdsNavDestination() {
        NasTelemetryDashboard({ monitor: this.model.telemetry, scroller: this.telemetryScroller,
          topInset: this.contentTopInset(), bottomInset: this.navigationInset })
      }
        .backgroundColor($r('app.color.workbench_background'))
        // 内容需滚入标题栏下方，供沉浸材质取样；首项让位由详情页按实际视口位置计算。
        .titleBar({ enableComponentSafeArea: false, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL }, title: { mainTitle: '资源监控' } },
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
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL }, title: { mainTitle: $r('app.string.connection_addresses') } },
          style: { systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE },
            scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: ScrollEffectType.GRADIENT_BLUR } } })
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
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL }, title: { mainTitle: '系统控制' } } })
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
        .backgroundColor(Color.Transparent)
        .hideTitleBar(!this.photoControlsVisible)
        .titleBar({ enableComponentSafeArea: false, avoidLayoutSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL },
          menu: { value: this.previewMenus('photos'), maxCount: 2 } },
          style: { scrollEffectOpts: { enableScrollEffect: false, scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR },
            systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE, materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE },
            originalStyle: { backgroundStyle: { blurRadius: 12, maskExtraHeight: 16 },
              contentStyle: { menuStyle: { textColor: $r('sys.color.font_primary'), iconColor: $r('sys.color.font_primary') } } } } })
        .onShown((): void => {
          this.photoPreviewOpened = true;
          this.photoControlsVisible = true;
          this.updatePhotoPreviewWindow();
        })
        .onHidden((): void => {
          this.photoPreviewOpened = false;
          this.photoControlsVisible = true;
          this.updatePhotoPreviewWindow();
          if (!this.navStack.getAllPathName().includes('photo-detail')) { this.model.photoLibrary.closeDetail(); }
        })
    } else if (name === 'photo-backup') {
      HdsNavDestination() {
        Scroll(this.photoBackupScroller) {
          PhotoBackupSettingsPage({ backup: this.model.photoBackup, onChooseDirectory: (): void => { this.chooseBackupDirectory(); } })
            .padding({ left: 16, right: 16, top: Math.max(0, this.contentTopInset() - this.photoBackupViewportTop) + 16,
              bottom: this.navigationInset + 16 })
        }.width('100%').height('100%').edgeEffect(EdgeEffect.Spring)
          .onAreaChange((_oldArea: Area, newArea: Area): void => {
            this.photoBackupViewportTop = Number(newArea.globalPosition.y);
          })
      }.backgroundColor($r('app.color.workbench_background'))
        // 滚动内容延伸到标题材质下方，首项仅补足视口尚未让出的标题区域。
        .titleBar({ enableComponentSafeArea: false, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL }, title: { mainTitle: $r('app.string.photos_album_backup') } },
          style: { systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE, materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE },
            scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: ScrollEffectType.GRADIENT_BLUR } } })
        .bindToScrollable([this.photoBackupScroller])
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    } else if (name === 'photo-actions') {
      HdsNavDestination() { this.photoActionsView() }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { backIcon: { icon: this.navigationBackSymbol(), type: IconStyleMode.SMALL }, title: { mainTitle: this.model.extensions.hasPending('photos') ?
          $r('app.string.preview_photo_task') : this.photoDestinationMode === 'album' ? $r('app.string.preview_album') :
            this.photoDestinationMode === 'backup' ? $r('app.string.photos_backup_location') :
              this.photoDestinationMode === 'move' ? $r('app.string.photos_move') : $r('app.string.preview_copy') } },
          style: { systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE, materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE } } })
    }
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
      if (this.sheetKind === 'sort') {
        Select([{ value: $r('app.string.sort_ascending') }, { value: $r('app.string.sort_descending') }])
          .selected(this.model.sortDescending ? 1 : 0)
          .value(this.model.sortDescending ? $r('app.string.sort_descending') : $r('app.string.sort_ascending'))
          .font({ size: 16, weight: FontWeight.Medium }).controlSize(ControlSize.SMALL).backgroundColor(Color.Transparent)
          .enabled(!this.model.busy).accessibilityText($r('app.string.sort_direction'))
          .onSelect((index: number): void => {
            this.model.setSort(this.model.fileSort as 'name' | 'size' | 'mtime', index === 1);
          })
          .systemMaterial(uiMaterial.Material.empty)
          .menuSystemMaterial(new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK }))
      } else {
        Row().width(WorkbenchMetrics.touchSize).height(32)
      }
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
        if (this.sheetKind === 'drive-upload') {
          DriveUploadReview({ model: this.model.driveTransfers,
            onStart: (): void => { this.startDriveUpload(); }, onCancel: (): void => { this.sheetVisible = false; } })
        } else if (this.sheetKind === 'drive-transfer-settings') {
          DriveTransferModePicker({ model: this.model.driveTransfers })
        } else if (this.sheetKind === 'device') {
          this.deviceSheet()
        } else if (this.sheetKind === 'sort') {
          Column() {
            this.sortOption('name', '名称')
            Divider().color($r('app.color.workbench_divider')).margin({ left: 16, right: 16 })
            this.sortOption('size', '大小')
            Divider().color($r('app.color.workbench_divider')).margin({ left: 16, right: 16 })
            this.sortOption('mtime', '修改时间')
          }.width('100%').borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_subtle'))
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
              if (this.windowWidth >= 600 && !(this.module === 'photos' && this.model.photoLibrary.selecting)) {
                ForEach([this.module + ':' + this.activeTab.toString()], (_key: string): void => {
                HdsSideBar({ isShowSideBar: true, sideBarWidth: this.windowWidth >= 840 ? 200 : 88,
                  minSideBarWidth: 88, maxSideBarWidth: 200, minContentWidth: 360,
                  autoHide: false, scaleContentEnabled: true, sideBarContainerType: SideBarContainerType.Embed,
                  sideBarColor: $r('app.color.workbench_surface'), contentColor: $r('app.color.workbench_background'),
                  sideBarPanelBuilder: (): void => { this.sideBarPanel(); },
                  contentPanelBuilder: (): void => { this.sideBarContent(); } }).width('100%').layoutWeight(1)
                }, (key: string): string => key)
              } else if (this.module === 'photos' && this.model.photoLibrary.selecting) {
                Column() {
                  this.modulePage(this.visibleTabs()[this.activeTab])
                }.width('100%').layoutWeight(1)
                this.photoSelectionBar()
              } else {
                HdsTabs({ controller: this.tabsController, index: this.activeTab }) {
                ForEach(this.visibleTabs(), (tab: ModuleTab): void => {
                  TabContent() { this.modulePage(tab) }
                    .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier(this.tabIcon(tab.id)) }, tab.label))
                }, (tab: ModuleTab): string => this.module + ':' + tab.id)
              }.width('100%').layoutWeight(1).barPosition(BarPosition.End).scrollable(false)
                .barHeight(this.fileSelectionActive() ? 0 : 56)
                .barOverlap(true).vertical(false)
                .barFloatingStyle({ barBottomMargin: this.floatingBarBottomMargin(),
                  systemMaterialEffect: this.navigationMaterial, thermoCtrl: true })
                .onContentWillChange((current: number, target: number): boolean => target === this.activeTab || !this.navigationBusy())
                .onTabBarClick((index: number): void => {
                  if (index === this.activeTab) { this.activeScrollers()[0].scrollTo({ xOffset: 0, yOffset: 0 }); }
                })
                .onChange((index: number): void => { this.selectModuleTab(index); })
              }
            } else { this.loginView() }
          }
        }.width('100%').height('100%')
          .overlay(this.transferCapsule(), { align: Alignment.Top, offset: { y: this.statusInset + 56 } })
      }.width('100%').height('100%').backgroundColor($r('app.color.workbench_background')).mode(NavigationMode.Stack)
        .hideBackButton(this.module === 'root' && !this.fileSelectionActive())
        .hideTitleBar(!this.model.authenticated)
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .navDestination(this.destinationBuilder).bindToScrollable(this.activeScrollers())
        .toolbarConfiguration(this.fileSelectionToolbar, { barStyle: BarStyle.STANDARD }).hideToolBar(!this.fileSelectionActive())
        .titleMode(HdsNavigationTitleMode.MINI).titleBar({ enableComponentSafeArea: false,
          content: { title: { mainTitle: this.pageTitle() },
            backIcon: this.module === 'root' && !this.fileSelectionActive() ? undefined : { icon: this.navigationBackSymbol(),
              action: (): void => { this.onBackPress(); }, type: IconStyleMode.SMALL },
            menu: { value: this.pageMenu(), maxCount: 2 } },
          style: { scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: ScrollEffectType.GRADIENT_BLUR },
            systemMaterialEffect: this.navigationMaterial } })
    }.width('100%').height('100%').backgroundColor($r('app.color.workbench_background'))
      .onAreaChange((oldArea: Area, newArea: Area): void => {
        this.windowWidth = Number(newArea.width);
        this.windowHeight = Number(newArea.height);
      })
      .bindSheet($$this.sheetVisible, this.fileSheet(), {
        height: this.sheetUsesModalTitleBar() ? SheetSize.LARGE : SheetSize.FIT_CONTENT,
        preferType: this.windowWidth < 600 ? SheetType.BOTTOM : SheetType.CENTER,
        // 关闭按钮由 sheetTitleBar() 自绘，系统关闭图标关闭，避免出现两个关闭入口。
        // HDS 半模态标题栏自带关闭按钮时关掉系统的那个，避免两个关闭入口。
        showClose: !this.sheetUsesModalTitleBar() && this.sheetKind !== 'sort',
        backgroundColor: this.sheetMaterialAvailable ? Color.Transparent : $r('app.color.workbench_surface_elevated'),
        systemMaterial: this.sheetMaterial,
        // 不给 title：传任何 builder 系统都会按标题栏占位，HDS 弹层的标题由 HdsNavigation 提供，
        // 小弹层的标题画在内容首行（sheetPlainTitle）。
        title: undefined,
        keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL
      })
  }
}
