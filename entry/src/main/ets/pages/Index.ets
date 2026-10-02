import { common } from '@kit.AbilityKit';
import { SymbolGlyphModifier, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileUri } from '@kit.CoreFileKit';
import { HdsNavigation, HdsNavigationTitleMode, HdsNavDestination, HdsTabs, HdsTabsController, hdsMaterial, ScrollEffectType } from '@kit.UIDesignKit';
import { NasFailure, NasFileEntry } from '../core/domain/DsmProtocol';
import { NasPhotoItem, NasPhotoAlbum, PhotosSpace } from '../core/domain/PhotosProtocol';
import { PhotoBackup } from '../features/backup/PhotoBackup';
import { TransferUploadSource } from '../features/transfers/TransferQueue';
import { TransferQueueItem } from '../core/domain/TransferQueueState';
import { ConnectionViewModel, FileTaskItem } from '../features/connection/ConnectionViewModel';
import { NasConnectionAddressPage } from '../features/connection/ConnectionAddressPage';
import { NasConnectionAddress } from '../core/domain/ConnectionRoutes';
import { NasSystemControlPage } from '../features/control/SystemControlPage';
import { NasTelemetrySummary, NasTelemetryDashboard } from '../features/telemetry/TelemetryDashboard';
import { WorkbenchBreadcrumb, PhotoTimelineRow, photoGridColumns, photoTimelineRows, photoTakenDate, photoMediaLabel, workbenchBreadcrumbs, workbenchBytes,
  workbenchCanUseDestination, workbenchBottomInset, workbenchShortcutColumns, photoAlbumColumns, photoAlbumRows, PhotoAlbumRow } from '../features/workbench/WorkbenchPresentation';

import { WorkbenchMetrics, WorkbenchSectionTitle, WorkbenchInfoRow, WorkbenchNotice, WorkbenchChoice, WorkbenchActionRow } from '../features/workbench/WorkbenchUi';

@Entry
@ComponentV2
struct Index {
  @Local private model: ConnectionViewModel = new ConnectionViewModel();
  @Local private activeTab: number = 0;
  @Local private navigationInset: number = 0;
  private mainWindow: window.Window | undefined = undefined;
  private pageActive: boolean = false;
  private foreground: boolean = true;
  private abilityContext: common.UIAbilityContext | undefined = undefined;
  @Local private telemetryOpened: boolean = false;
  @Local private addressBookOpened: boolean = false;
  @Local private systemControlOpened: boolean = false;
  private telemetryScroller: Scroller = new Scroller();
  private addressBookScroller: Scroller = new Scroller();
  private systemControlScroller: Scroller = new Scroller();
  private foregroundChanged = (foreground: boolean): void => {
    this.foreground = foreground;
    if (!foreground) { this.model.addressBook.cancelProbe(); this.model.systemControl.deactivate(); }
    else if (this.systemControlOpened) { this.model.openSystemControl(); }
    this.updateTelemetryMode();
  };
  private navigationAreaChanged = (options: window.AvoidAreaOptions): void => {
    if (options.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
      this.navigationInset = this.getUIContext().px2vp(options.area.bottomRect.height);
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
  @Local private choosingBackupTarget: boolean = false;
  @Local private photosInitialized: boolean = false;
  @Local private contentWidth: number = 360;
  @Local private windowWidth: number = 360;
  @Local private deviceInfo: string[] = [];
  @Local private selectedTaskId: string = '';
  @Local private taskFilter: string = 'all';
  @Local private taskSection: string = 'transfers';
  @Local private mediaDecodeFailed: boolean = false;
  private navStack: NavPathStack = new NavPathStack();
  private homeScroller: Scroller = new Scroller();
  private filesScroller: Scroller = new Scroller();
  private photosScroller: Scroller = new Scroller();
  private tasksScroller: Scroller = new Scroller();
  private detailScroller: Scroller = new Scroller();
  private tabsController: HdsTabsController = new HdsTabsController();

  aboutToAppear(): void {
    this.pageActive = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.abilityContext = context;
    context.eventHub.on('nas-foreground-change', this.foregroundChanged);
    this.updateTelemetryMode();
    this.model.restore(context);
    window.getLastWindow(context).then((mainWindow: window.Window): void => {
      if (!this.pageActive) { return; }
      this.mainWindow = mainWindow;
      this.navigationInset = this.getUIContext().px2vp(mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height);
      mainWindow.on('avoidAreaChange', this.navigationAreaChanged);
    }).catch((): void => { hilog.error(0x0000, 'NasLayout', 'operation=navigation_avoid_area result=failed'); });
  }
  aboutToDisappear(): void {
    this.pageActive = false;
    this.updateTelemetryMode();
    this.abilityContext?.eventHub.off('nas-foreground-change', this.foregroundChanged);
    this.abilityContext = undefined;
    this.mainWindow?.off('avoidAreaChange', this.navigationAreaChanged);
    this.mainWindow = undefined;
    this.backup.reset();
    this.model.dispose();
  }

  onBackPress(): boolean {
    if (this.sheetVisible) { if (!this.formSubmitting) { this.sheetVisible = false; } return true; }
    if (this.navStack.size() > 0) { this.navStack.pop(); return true; }
    if (this.choosingBackupTarget) { this.choosingBackupTarget = false; this.switchTab(2); return true; }
    if (this.pendingEntry !== undefined) {
      this.pendingEntry = undefined;
      this.pendingOperation = '';
      return true;
    }
    if (this.model.authenticated && this.activeTab === 1 && this.model.directory.length > 0) {
      if (!this.model.busy) { this.model.goBack(); }
      return true;
    }
    if (this.model.authenticated && this.activeTab === 2 && this.model.photoLibrary.selectedAlbum !== undefined) {
      if (!this.model.photoLibrary.busy) { this.model.photoLibrary.backToLibrary(); }
      return true;
    }
    if (this.model.authenticated && this.activeTab !== 0) { this.switchTab(0); return true; }
    return false;
  }

  @Monitor('model.authenticated')
  private authenticationChanged(): void {
    this.updateTelemetryMode();
    if (!this.model.authenticated) {
      this.backup.reset();
      this.choosingBackupTarget = false;
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
      this.activeTab = 0;
      this.tabsController.changeIndex(0);
    }
  }

  @Monitor('model.busy')
  private pageLoadFinished(): void {
    if (!this.model.busy && this.model.authenticated && this.activeTab === 2) { this.ensurePhotosOpen(); }
  }

  private pageTitle(): string {
    return this.model.authenticated ? ['首页', '文件', '相册', '任务'][this.activeTab] : 'NAS 工作台';
  }

  @Monitor('activeTab')
  private activeTabChanged(): void {
    this.updateTelemetryMode();
  }

  private updateTelemetryMode(): void {
    this.model.telemetry.setMode(!this.pageActive || !this.foreground || !this.model.authenticated || this.addressBookOpened || this.systemControlOpened ? 'hidden' :
      this.telemetryOpened ? 'detail' : this.activeTab === 0 ? 'home' : 'hidden');
  }

  private ensurePhotosOpen(): void {
    if (this.photosInitialized || !this.supportsPhotos() || this.model.busy) { return; }
    this.photosInitialized = true;
    this.model.photoLibrary.open(this.model.supports('SYNO.Foto.Browse.Item') ? PhotosSpace.Personal :
      this.model.supports('SYNO.FotoTeam.Browse.Item') ? PhotosSpace.Shared : PhotosSpace.WithMe);
  }

  private switchTab(index: number): void {
    this.activeTab = index;
    this.tabsController.changeIndex(index);
    if (index === 2) { this.ensurePhotosOpen(); }
  }

  private supportsPhotos(): boolean {
    return this.model.supports('SYNO.Foto.Browse.Item') || this.model.supports('SYNO.FotoTeam.Browse.Item') ||
      this.model.supports('SYNO.Foto.Sharing.Misc');
  }

  private activeScrollers(): Scroller[] {
    if (!this.model.authenticated) { return [this.homeScroller]; }
    return [this.homeScroller, this.filesScroller, this.photosScroller, this.tasksScroller].slice(this.activeTab, this.activeTab + 1);
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
    if (this.backup.sources.length === 0) { this.choosingBackupTarget = false; this.taskSection = 'transfers'; this.switchTab(3); }
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
    this.model.addressBook.setDraftOrigin(this.model.address);
    this.model.addressBook.draftName = saved?.name ?? (this.model.authenticated ? '我的 NAS' : '');
    this.model.addressBook.draftKind = saved?.kind ?? 'lan';
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
    if (this.sheetKind === 'backup') { return '备份内容'; }
    if (this.sheetKind === 'device') { return '设备与账号'; }
    if (this.sheetKind === 'actions') { return '文件操作'; }
    if (this.sheetKind === 'task') { return '任务详情'; }
    return '文件详情';
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
        this.model.deleteEntry(entry).then((result): void => { if (result === 'pending') { this.taskSection = 'files'; this.switchTab(3); } });
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
    this.choosingBackupTarget = false;
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
    if (result === 'pending') { this.taskSection = 'files'; this.switchTab(3); }
  }

  private sortLabel(): string {
    const field = this.model.fileSort === 'size' ? '大小' : this.model.fileSort === 'mtime' ? '修改时间' : '名称';
    return field + (this.model.sortDescending ? ' · 降序' : ' · 升序');
  }

  private fileCountText(): string {
    return this.model.total === 0 ? '0 项' : (this.model.pageOffset + 1).toString() + '–' +
      (this.model.pageOffset + this.model.entries.length).toString() + ' / ' + this.model.total.toString() + ' 项';
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
    if (this.activeTab === 3) {
      return this.model.queue.errorText.length > 0 ? this.model.queue.errorText : this.transferErrorText;
    }
    return this.model.errorText.length > 0 ? this.model.errorText :
      this.activeTab === 1 && this.model.directoryErrorText.length > 0 ? this.model.directoryErrorText : this.transferErrorText;
  }

  @Builder
  notices() {
    WorkbenchNotice({ text: this.visibleError(), warning: true })
    if (this.visibleError().length === 0 && this.model.actionNotice.length > 0) {
      WorkbenchNotice({ text: this.model.actionNotice })
    }
  }

  @Builder
  emptyState(icon: Resource, title: string, description: string) {
    Column({ space: 12 }) {
      SymbolGlyph(icon).fontSize(40).fontColor([$r('sys.color.font_tertiary')])
      Text(title).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
      Text(description).fontSize(14).fontColor($r('sys.color.font_secondary')).textAlign(TextAlign.Center)
    }.width('100%').padding({ top: 40, bottom: 40, left: 24, right: 24 })
  }

  @Builder
  connectionForm() {
    Scroll(this.homeScroller) {
      Column({ space: 20 }) {
        Column({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.externaldrive')).fontSize(36).padding(14).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_accent_surface')).fontColor([$r('sys.color.icon_emphasize')])
          Text(this.model.savedSession ? '重新连接设备' : this.model.connected ? '登录你的 NAS' : '连接你的 NAS')
            .fontSize(28).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary'))
          Text(this.model.savedSession ? '已保存的账号会在连接后恢复。' : '安全访问文件、相册和传输任务。')
            .fontSize(16).fontColor($r('sys.color.font_secondary'))
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 8 })
        Column({ space: 16 }) {
          Text('设备地址').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
          TextInput({ text: this.model.address, placeholder: 'https://nas.example.com:5001' })
            .constraintSize({ minHeight: 52 }).enabled(!this.model.connected && !this.model.busy && !this.model.savedSession)
            .onChange((text: string): void => { this.model.address = text; }).accessibilityText('NAS HTTPS 地址')
          if (this.model.savedSession) {
            Text(this.model.account).fontSize(16).width('100%').fontColor($r('sys.color.font_primary'))
            Button(this.model.busy ? '正在连接…' : '重试连接').width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).enabled(!this.model.busy)
              .onClick((): void => { this.model.restore(); })
            Button('重新登录').width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.busy)
              .onClick((): void => { this.model.disconnect(); })
          } else if (!this.model.connected) {
            Button(this.model.busy ? '正在连接…' : '连接 NAS').width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .enabled(!this.model.busy && this.model.address.trim().length > 0).onClick((): void => { this.model.connect(); })
          } else {
            TextInput({ text: this.model.account, placeholder: 'NAS 账号' }).constraintSize({ minHeight: 52 }).enabled(!this.model.busy)
              .onChange((text: string): void => { this.model.account = text; }).accessibilityText('NAS 账号')
            TextInput({ text: this.model.password, placeholder: '密码' }).constraintSize({ minHeight: 52 })
              .type(InputType.Password).enabled(!this.model.busy)
              .onChange((text: string): void => { this.model.password = text; }).accessibilityText('NAS 密码')
            if (this.model.needsOtp) {
              TextInput({ text: this.model.otp, placeholder: '6 位动态码' }).constraintSize({ minHeight: 52 })
                .type(InputType.Number).maxLength(6).enabled(!this.model.busy)
                .onChange((text: string): void => { this.model.otp = text; }).accessibilityText('双重验证动态码')
            }
            Button(this.model.busy ? '正在登录…' : '登录').width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .enabled(!this.model.busy && this.model.account.trim().length > 0 && this.model.password.length > 0)
              .onClick((): void => { this.model.login(); })
            Button('更换设备').width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.busy)
              .onClick((): void => { this.model.disconnect(); })
          }
        }.width('100%').padding(20).borderRadius(WorkbenchMetrics.cardRadius)
          .backgroundColor($r('app.color.workbench_surface')).alignItems(HorizontalAlign.Start)
        Button('连接地址').width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.busy)
          .onClick((): void => { this.openConnectionAddresses(); })
        this.notices()
      }.width('100%').constraintSize({ maxWidth: 560 }).padding({ left: 16, right: 16, top: 16, bottom: 32 }).alignItems(HorizontalAlign.Start)
    }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Auto)
  }

  @Builder
  shortcut(icon: Resource, label: string, action: () => void) {
    Button() {
      Column({ space: 10 }) {
        SymbolGlyph(icon).fontSize(28).fontColor([$r('sys.color.icon_emphasize')])
          .width(48).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).borderRadius(16).backgroundColor($r('app.color.workbench_accent_surface'))
        Text(label).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).textAlign(TextAlign.Center)
      }.width('100%').padding({ top: 16, bottom: 16, left: 8, right: 8 })
    }.width(workbenchShortcutColumns(this.windowWidth) === 4 ? '25%' : '50%')
      .type(ButtonType.Normal).backgroundColor(Color.Transparent).enabled(!this.model.busy)
      .onClick(action).accessibilityText(label)
  }

  @Builder
  homeView() {
    Scroll(this.homeScroller) {
      Column({ space: WorkbenchMetrics.sectionGap }) {
        Row({ space: 16 }) {
          SymbolGlyph($r('sys.symbol.externaldrive')).fontSize(32).fontColor([$r('sys.color.icon_emphasize')])
            .width(56).height(56).borderRadius(18).backgroundColor($r('app.color.workbench_accent_surface'))
          Column({ space: 6 }) {
            Text(this.model.telemetry.system.data?.model ?? '我的 NAS').fontSize(22).fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
            Text(this.model.account).fontSize(14).fontColor($r('sys.color.font_secondary'))
            Text('已连接 · HTTPS').fontSize(13).fontColor($r('sys.color.font_emphasize'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding(20).borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        Flex({ wrap: FlexWrap.Wrap }) {
          this.shortcut($r('sys.symbol.folder'), '文件', (): void => { this.switchTab(1); })
          if (this.supportsPhotos()) {
            this.shortcut($r('sys.symbol.picture'), '照片', (): void => { this.switchTab(2); })
          }
          if (this.model.supports('SYNO.FileStation.Upload')) {
            this.shortcut($r('sys.symbol.arrow_up_circle'), '照片备份', (): void => { this.switchTab(2); this.selectBackup(); })
          }
          this.shortcut($r('sys.symbol.arrow_down_circle'), '传输任务', (): void => { this.switchTab(3); })
        }.width('100%').padding(4).borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        NasTelemetrySummary({ monitor: this.model.telemetry, onOpen: (): void => { this.navStack.pushPath({ name: 'telemetry' }); } })
        Column() {
          WorkbenchActionRow({ icon: $r('sys.symbol.arrow_down_circle'), label: '任务进展',
            description: this.model.queue.ready ?
              this.model.queue.items.filter((item: TransferQueueItem): boolean => !['completed', 'cancelled', 'failed', 'closed', 'clearing'].includes(item.state)).length.toString() + ' 项待处理' :
              '任务记录尚未加载，点此处理', onAction: (): void => { this.switchTab(3); } })
        }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        Column({ space: 12 }) {
          WorkbenchSectionTitle({ title: '设备管理' })
          Column() {
            WorkbenchActionRow({ icon: $r('sys.symbol.externaldrive'), label: '设备与账号', description: this.model.account,
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
        this.notices()
      }.width('100%').constraintSize({ maxWidth: 840 })
        .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin, top: 16, bottom: this.bottomInset() })
    }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Auto)
  }

  @Builder
  breadcrumbBar() {
    Scroll() {
      Row({ space: 4 }) {
        ForEach(workbenchBreadcrumbs(this.model.directory), (crumb: WorkbenchBreadcrumb): void => {
          Button(crumb.title).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontColor(crumb.path === this.model.directory ? $r('sys.color.font_primary') : $r('sys.color.font_emphasize'))
            .enabled(!this.model.busy && crumb.path !== this.model.directory)
            .onClick((): void => { this.navigateBreadcrumb(crumb.path); })
          if (crumb.path !== this.model.directory) { Text('›').fontSize(18).fontColor($r('sys.color.font_tertiary')) }
        }, (crumb: WorkbenchBreadcrumb): string => crumb.path)
      }
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
  }

  @Builder
  fileActions(entry: NasFileEntry) {
    Column() {
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
            this.switchTab(3);
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

  @Builder
  filePageActions() {
    Menu() {
      MenuItem({ content: '刷新目录' }).onClick((): void => { this.model.refresh(); })
      if (this.model.directory.length > 0) {
        MenuItem({ content: '排序：' + this.sortLabel() }).onClick((): void => { this.openForm('sort'); })
        if (this.model.supports('SYNO.FileStation.CreateFolder')) {
          MenuItem({ content: '新建文件夹' }).onClick((): void => { this.openForm('create'); })
        }
      }
    }
  }

  @Builder
  backupDestinationBar() {
    if (this.choosingBackupTarget && this.backup.sources.length > 0) {
      Column({ space: 12 }) {
        Text('确认备份位置').fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
        Text(this.model.directory.length === 0 ? '请进入一个可上传的文件夹。' : '目标：' + this.model.directory)
          .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        Text(this.backup.sources.length.toString() + ' 项照片与视频。所选内容重名时已添加序号；与 NAS 文件重名时会拒绝上传。')
          .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
        if (this.backup.errorText.length > 0) {
          Text(this.backup.errorText).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
        }
        Flex({ wrap: FlexWrap.Wrap }) {
          Button(this.backup.submitting ? '正在准备…' : '备份到此处').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .enabled(this.model.directory.length > 0 && this.model.queue.ready && !this.model.queue.busy && !this.model.busy && !this.backup.submitting)
            .onClick((): void => { this.submitBackup(); })
          Button('返回相册').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.backup.submitting)
            .onClick((): void => { this.choosingBackupTarget = false; this.switchTab(2); })
        }.width('100%')
      }.width('100%').padding(16).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
    }
  }

  @Builder
  destinationBar() {
    if (this.pendingEntry !== undefined) {
      Column({ space: 10 }) {
        Text((this.pendingOperation === 'copy' ? '复制：' : '移动：') + this.pendingEntry.name)
          .fontSize(16).fontWeight(FontWeight.Medium).width('100%').fontColor($r('sys.color.font_primary'))
        Text(this.model.directory.length === 0 ? '请选择目标文件夹。' : '目标：' + this.model.directory)
          .fontSize(13).width('100%').fontColor($r('sys.color.font_secondary'))
        Row({ space: 12 }) {
          Button(this.pendingOperation === 'copy' ? '复制到此处' : '移动到此处').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).layoutWeight(1)
            .enabled(!this.model.busy && this.destinationAllowed()).onClick((): void => { this.applyDestination(); })
          Button('取消').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.busy)
            .onClick((): void => { this.pendingEntry = undefined; this.pendingOperation = ''; })
        }.width('100%')
      }.width('100%').padding(16).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
    }
  }

  @Builder
  filesView() {
    Column() {
      List({ space: 0, scroller: this.filesScroller }) {
        ListItem() {
          Column({ space: 8 }) {
            this.breadcrumbBar()
            Row({ space: 8 }) {
              if (this.model.directory.length > 0) {
                Button(this.sortLabel()).constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL)
                  .enabled(!this.model.busy).onClick((): void => { this.openForm('sort'); })
              } else {
                Text('共享文件夹').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
              }
              Blank().layoutWeight(1)
              if (this.model.directory.length > 0 && this.model.supports('SYNO.FileStation.Upload')) {
                Button('上传').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.NORMAL)
                  .enabled(this.model.queue.ready && !this.model.busy && !this.model.queue.busy && !this.transferSubmitting)
                  .onClick((): void => { this.runTransfer(async (): Promise<void> => { await this.model.uploadFiles(); }); })
              }
              Button() { SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(24).fontColor([$r('sys.color.icon_primary')]) }
                .width(48).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).type(ButtonType.Circle).backgroundColor(Color.Transparent)
                .enabled(!this.model.busy).bindMenu(this.filePageActions()).accessibilityText('文件页面，更多操作')
            }.width('100%')
            this.backupDestinationBar()
            this.destinationBar()
            this.notices()
            if (this.model.busy) {
              Row({ space: 12 }) {
                LoadingProgress().width(24).height(24)
                Text('正在处理…').fontSize(14).fontColor($r('sys.color.font_secondary'))
              }.width('100%').padding(12)
            }
          }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 12 })
        }
        if (!this.model.busy && this.model.entries.length === 0 && this.model.errorText.length === 0) {
          ListItem() { this.emptyState($r('sys.symbol.folder'), '此位置为空', '此文件夹没有可显示的项目。') }
        }
        ForEach(this.model.entries, (entry: NasFileEntry): void => {
          ListItem() {
            Column() {
              Row({ space: 4 }) {
                Button() {
                  Row({ space: 14 }) {
                    SymbolGlyph(entry.isDirectory ? $r('sys.symbol.folder') : $r('sys.symbol.doc'))
                      .fontSize(28).fontColor([entry.isDirectory ? $r('sys.color.icon_emphasize') : $r('sys.color.font_secondary')])
                      .width(44).height(44).borderRadius(12).backgroundColor($r('app.color.workbench_subtle'))
                    Column({ space: 6 }) {
                      Text(entry.name).fontSize(16).fontWeight(FontWeight.Medium).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                        .fontColor($r('sys.color.font_primary')).width('100%')
                      Text(entry.isDirectory ? '文件夹' : workbenchBytes(entry.bytes))
                        .fontSize(13).fontColor($r('sys.color.font_secondary'))
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  }.width('100%').padding({ left: 16, top: 12, bottom: 12, right: 8 })
                }.layoutWeight(1).type(ButtonType.Normal).backgroundColor(Color.Transparent).enabled(!this.model.busy)
                  .onClick((): void => {
                    if (entry.isDirectory) { this.model.openDirectory(entry); }
                    else { this.openForm('detail', entry); }
                  }).accessibilityText((entry.isDirectory ? '文件夹，' : '文件，') + entry.name)
                Button() { SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(22).fontColor([$r('sys.color.font_secondary')]) }
                  .width(48).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).type(ButtonType.Circle).backgroundColor(Color.Transparent)
                  .enabled(!this.model.busy).onClick((): void => { this.openForm('actions', entry); })
                  .accessibilityText(entry.name + '，更多操作').margin({ right: 8 })
              }.width('100%')
              Divider().color($r('app.color.workbench_divider')).margin({ left: 74, right: 16 })
            }.width('100%').backgroundColor($r('app.color.workbench_surface'))
          }
        }, (entry: NasFileEntry): string => this.model.address + ':' + this.model.account + ':' + entry.path)
        ListItem() {
          Row({ space: 8 }) {
            Button('上一页').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(!this.model.busy && this.model.pageOffset > 0).onClick((): void => { this.model.previousPage(); })
            Text(this.fileCountText()).fontSize(13).fontColor($r('sys.color.font_secondary'))
              .layoutWeight(1).textAlign(TextAlign.Center)
            Button('下一页').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(!this.model.busy && this.model.pageOffset + this.model.entries.length < this.model.total)
              .onClick((): void => { this.model.nextPage(); })
          }.width('100%').padding({ top: 16, bottom: 16 })
        }
      }.width('100%').height('100%').scrollBar(BarState.Auto).contentEndOffset(this.bottomInset())
    }.width('100%').constraintSize({ maxWidth: 960 }).height('100%')
      .backgroundColor($r('app.color.workbench_surface'))
  }

  @Builder
  backupCard() {
    if (this.model.supports('SYNO.FileStation.Upload')) {
      if (this.backup.sources.length === 0) {
        Column() {
          WorkbenchActionRow({ icon: $r('sys.symbol.arrow_up_circle'), label: '备份照片与视频',
            description: this.backup.selecting ? '正在选择…' : '选择本机内容，确认位置后上传',
            available: !this.backup.selecting && !this.backup.submitting && !this.model.busy,
            onAction: (): void => { this.selectBackup(); } })
          WorkbenchNotice({ text: this.backup.errorText, warning: true })
          WorkbenchNotice({ text: this.backup.status })
        }.width('100%').borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
      } else {
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.arrow_up_circle')).fontSize(28).fontColor([$r('sys.color.icon_emphasize')])
          Column({ space: 4 }) {
            Text('备份照片与视频').fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
            Text(this.backup.sources.length === 0 ? '选择要备份的内容，由你确认上传位置' :
              '已选择 ' + this.backup.sources.length.toString() + ' 项，等待确认')
              .fontSize(13).fontColor($r('sys.color.font_secondary'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%')
        if (this.backup.errorText.length > 0) {
          Text(this.backup.errorText).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
        }
        if (this.backup.status.length > 0) {
          Text(this.backup.status).fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
        }
        Flex({ wrap: FlexWrap.Wrap }) {
          Button(this.backup.selecting ? '正在选择…' : this.backup.sources.length > 0 ? '继续选择' : '选择照片与视频')
            .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).enabled(!this.backup.selecting && !this.backup.submitting && !this.model.busy)
            .onClick((): void => { this.selectBackup(); })
          if (this.backup.sources.length > 0) {
            Button('选择备份位置').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.backup.submitting && !this.backup.selecting)
              .onClick((): void => {
                this.pendingEntry = undefined; this.pendingOperation = '';
                this.choosingBackupTarget = true; this.switchTab(1);
              })
            Button('清空选择').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.backup.submitting)
              .onClick((): void => { this.backup.clear(); })
          }
        }.width('100%')
        if (this.backup.sources.length > 0) {
          Text(this.backup.sources.map((item: TransferUploadSource): string => item.name).join('、'))
            .fontSize(13).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('sys.color.font_secondary')).width('100%')
          Button('查看所选内容').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .onClick((): void => { this.openForm('backup'); })
        }
      }.width('100%').padding(16).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
      }
    }
  }

  @Builder
  photoSpaceButton(space: PhotosSpace, label: string) {
    WorkbenchChoice({ label: label, selected: this.model.photoLibrary.space === space, available: !this.model.photoLibrary.busy,
      onSelect: (): void => { this.photosScroller.scrollTo({ xOffset: 0, yOffset: 0 }); this.model.photoLibrary.open(space); } })
  }

  @Builder
  photoCard(item: NasPhotoItem) {
    Button() {
      Stack({ alignContent: Alignment.BottomStart }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.picture')).fontSize(32).fontColor([$r('sys.color.font_tertiary')])
          if (this.model.photoLibrary.thumbnailPath(item).length > 0) {
            Image(fileUri.getUriFromPath(this.model.photoLibrary.thumbnailPath(item))).width('100%').height('100%').objectFit(ImageFit.Cover)
              .sourceSize({ width: 320, height: 320 }).accessibilityLevel('no')
          }
        }.width('100%').height('100%').backgroundColor($r('app.color.workbench_subtle'))
        if (item.mediaType !== 'photo') {
          Text(photoMediaLabel(item)).fontSize(12).fontColor(Color.White).padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor('#99000000').borderRadius(8).margin(6)
        }
      }.width('100%').aspectRatio(1).borderRadius(14).clip(true)
    }.layoutWeight(1).type(ButtonType.Normal).backgroundColor(Color.Transparent).borderRadius(14)
      .onClick((): void => { this.openPhoto(item); })
      .accessibilityText(photoMediaLabel(item) + '，' + item.filename + '，' + photoTakenDate(item))
  }

  @Builder
  albumCard(album: NasPhotoAlbum) {
    Button() {
      Column({ space: 10 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.picture')).fontSize(40).fontColor([$r('sys.color.icon_emphasize')])
        }.width('100%').aspectRatio(1).borderRadius(WorkbenchMetrics.innerRadius)
          .backgroundColor($r('app.color.workbench_accent_surface'))
        Text(album.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
          .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(album.itemCount.toString() + ' 项').fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
    }.layoutWeight(1).type(ButtonType.Normal).backgroundColor(Color.Transparent)
      .enabled(!this.model.photoLibrary.busy)
      .onClick((): void => { this.photosScroller.scrollTo({ xOffset: 0, yOffset: 0 }); this.model.photoLibrary.openAlbum(album); })
      .accessibilityText(album.name + '，' + album.itemCount.toString() + ' 项')
  }

  @Builder
  photosView() {
    Column() {
      List({ space: 12, scroller: this.photosScroller }) {
        ListItem() {
          Column({ space: 12 }) {
            Flex({ wrap: FlexWrap.Wrap }) {
              if (this.model.supports('SYNO.Foto.Browse.Item')) { this.photoSpaceButton(PhotosSpace.Personal, '个人空间') }
              if (this.model.supports('SYNO.FotoTeam.Browse.Item')) { this.photoSpaceButton(PhotosSpace.Shared, '共享空间') }
              if (this.model.supports('SYNO.Foto.Sharing.Misc')) { this.photoSpaceButton(PhotosSpace.WithMe, '与我共享') }
            }.width('100%')
            if (this.model.photoLibrary.selectedAlbum !== undefined) {
              Row({ space: 8 }) {
                Button('返回相册').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.photoLibrary.busy)
                  .onClick((): void => { this.model.photoLibrary.backToLibrary(); })
                Text(this.model.photoLibrary.selectedAlbum.name).fontSize(20).fontWeight(FontWeight.Bold)
                  .fontColor($r('sys.color.font_primary')).layoutWeight(1)
              }.width('100%')
            } else if (this.model.photoLibrary.space !== PhotosSpace.WithMe) {
              Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
                WorkbenchChoice({ label: '时间线', selected: this.model.photoLibrary.section === 'timeline',
                  available: !this.model.photoLibrary.busy,
                  onSelect: (): void => { this.model.photoLibrary.open(this.model.photoLibrary.space, 'timeline'); } })
                WorkbenchChoice({ label: '相册', selected: this.model.photoLibrary.section === 'albums',
                  available: !this.model.photoLibrary.busy,
                  onSelect: (): void => { this.model.photoLibrary.open(this.model.photoLibrary.space, 'albums'); } })
                Button('刷新').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.photoLibrary.busy)
                  .onClick((): void => { this.model.photoLibrary.refresh(); })
              }.width('100%')
            } else {
              Row({ space: 8 }) {
                Text('与你共享的相册').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).layoutWeight(1)
                Button('刷新').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.photoLibrary.busy)
                  .onClick((): void => { this.model.photoLibrary.refresh(); })
              }.width('100%')
            }
            this.backupCard()
            if (this.model.photoLibrary.thumbnailErrorText.length > 0) {
              Text(this.model.photoLibrary.thumbnailErrorText).fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
            }
            if (this.model.photoLibrary.errorText.length > 0) {
              Text(this.model.photoLibrary.errorText).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%').padding(16)
                .borderRadius(16).backgroundColor($r('app.color.workbench_surface')).accessibilityText('照片读取未完成，' + this.model.photoLibrary.errorText)
              Button('重试读取').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.photoLibrary.busy)
                .onClick((): void => { this.model.photoLibrary.refresh(); })
            }
            if (this.model.photoLibrary.busy) {
              Row({ space: 12 }) {
                LoadingProgress().width(24).height(24)
                Text('正在读取照片…').fontSize(14).fontColor($r('sys.color.font_secondary'))
              }.width('100%').padding(12)
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 8 })
        }
        if (!this.supportsPhotos()) {
          ListItem() { this.emptyState($r('sys.symbol.picture'), '相册暂不可用', '当前设备未提供可用的相册服务。仍可选择本机照片备份到文件夹。') }
        } else if (!this.model.photoLibrary.busy && this.model.photoLibrary.items.length === 0 &&
          (this.model.photoLibrary.selectedAlbum !== undefined || this.model.photoLibrary.albums.length === 0) && this.model.photoLibrary.errorText.length === 0) {
          ListItem() { this.emptyState($r('sys.symbol.picture'), '没有可见项目', '当前账号在此空间没有可见的照片或相册。') }
        }
        Repeat<PhotoAlbumRow>(photoAlbumRows(this.model.photoLibrary.selectedAlbum === undefined ?
          this.model.photoLibrary.albums : [], photoAlbumColumns(this.contentWidth))).each((row: RepeatItem<PhotoAlbumRow>): void => {
          ListItem() {
            Row({ space: 12 }) {
              ForEach(row.item.albums, (album: NasPhotoAlbum): void => { this.albumCard(album) },
                (album: NasPhotoAlbum): string => album.space.toString() + ':' + album.id.toString())
              ForEach([0, 1, 2, 3].slice(0, photoAlbumColumns(this.contentWidth) - row.item.albums.length),
                (slot: number): void => { Blank().layoutWeight(1) }, (slot: number): string => slot.toString())
            }.width('100%').alignItems(VerticalAlign.Top).padding({ top: 8, bottom: 8 })
          }
        }).key((row: PhotoAlbumRow): string => row.key).virtualScroll()
        Repeat<PhotoTimelineRow>(photoTimelineRows(this.model.photoLibrary.items, photoGridColumns(this.contentWidth))).each((row: RepeatItem<PhotoTimelineRow>): void => {
          ListItem() {
            Column({ space: 12 }) {
              if (row.item.title.length > 0) {
                Text(row.item.title).fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary')).width('100%').padding({ top: 12 })
              }
              Row({ space: 6 }) {
                ForEach(row.item.items, (item: NasPhotoItem): void => { this.photoCard(item) },
                  (item: NasPhotoItem): string => item.space.toString() + ':' + item.id.toString())
                if (row.item.items.length < photoGridColumns(this.contentWidth)) {
                  ForEach([0, 1, 2, 3, 4, 5].slice(0, photoGridColumns(this.contentWidth) - row.item.items.length),
                    (slot: number): void => { Blank().layoutWeight(1) }, (slot: number): string => slot.toString())
                }
              }.width('100%')
            }.width('100%').alignItems(HorizontalAlign.Start)
          }
        }).key((row: PhotoTimelineRow): string => row.key).virtualScroll()
        if (this.supportsPhotos() && this.model.photoLibrary.errorText.length === 0) {
          ListItem() {
            Column({ space: 8 }) {
              if (this.model.photoLibrary.hasMore) {
                Button(this.model.photoLibrary.busy ? '正在加载…' : '加载更多').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).width('100%')
                  .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.photoLibrary.busy)
                  .onClick((): void => { this.model.photoLibrary.loadMore(); })
              } else if (this.model.photoLibrary.items.length > 0 || this.model.photoLibrary.albums.length > 0) {
                Text('已显示全部可见项目').fontSize(13).fontColor($r('sys.color.font_secondary')).padding(16)
              }
            }.width('100%').padding({ top: 8, bottom: 8 })
          }
        }
      }.width('100%').height('100%').scrollBar(BarState.Auto).contentEndOffset(this.bottomInset())
    }.width('100%').constraintSize({ maxWidth: 960 }).height('100%').padding({ left: 16, right: 16 })
      .onAreaChange((oldArea: Area, newArea: Area): void => { this.contentWidth = Number(newArea.width); })
  }

  @Builder
  photoDetailView() {
    Scroll(this.detailScroller) {
      Column({ space: 20 }) {
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
          Column({ space: 10 }) {
            Text(this.model.photoLibrary.detail.filename).fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary')).width('100%')
            Text(photoTakenDate(this.model.photoLibrary.detail)).fontSize(15).fontColor($r('sys.color.font_secondary')).width('100%')
            Text(photoMediaLabel(this.model.photoLibrary.detail) + ' · ' + workbenchBytes(this.model.photoLibrary.detail.bytes))
              .fontSize(15).fontColor($r('sys.color.font_secondary')).width('100%')
            if (this.model.photoLibrary.detail.width !== undefined && this.model.photoLibrary.detail.height !== undefined) {
              Text(this.model.photoLibrary.detail.width.toString() + ' × ' + this.model.photoLibrary.detail.height.toString())
                .fontSize(15).fontColor($r('sys.color.font_secondary')).width('100%')
            }
            if (this.model.photoLibrary.detail.mediaType === 'live') {
              Text('当前展示静态预览。动态照片的组合播放暂不可用。').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
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
          Text('原文件在此页面读取，离开页面会结束读取。较大文件请使用文件页的持久下载任务。')
            .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
        }
      }.width('100%').constraintSize({ maxWidth: 840 }).padding({ left: 16, right: 16, top: 16, bottom: 32 })
        .alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto)
  }

  @Builder
  destinationBuilder(name: string, parameter: Object) {
    if (name === 'telemetry') {
      HdsNavDestination() { NasTelemetryDashboard({ monitor: this.model.telemetry, scroller: this.telemetryScroller }) }
        .backgroundColor($r('app.color.workbench_background'))
        .titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: '运行状态' } } })
        .bindToScrollable([this.telemetryScroller])
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
          }.width('100%').padding({ top: 8 })
        }
        if (this.taskSection === 'files') {
        ListItem() {
          Column({ space: 8 }) {
            Row({ space: 12 }) {
              Text('文件整理').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary')).layoutWeight(1)
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
            Column({ space: 8 }) {
              Text(task.item.label).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
              Text(this.fileTaskStateText(task.item)).fontSize(15).fontColor($r('sys.color.font_primary')).width('100%')
              if (task.item.errorText.length > 0) {
                WorkbenchNotice({ text: task.item.errorText, warning: true })
              }
              if (task.item.state === 'pending' || task.item.state === 'unknown') {
                Button('查询结果').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.busy)
                  .onClick((): void => { this.model.checkFileTask(task.item.id); })
              }
            }.width('100%').padding(20).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
          }
        }).key((item: FileTaskItem): string => item.id).virtualScroll()
        } else {
        ListItem() {
          Column({ space: 8 }) {
            Row({ space: 12 }) {
              Text('传输队列').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary')).layoutWeight(1)
              Button(this.model.queue.ready ? '刷新状态' : '重新加载').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
                .enabled(!this.model.queue.busy && !this.model.busy && !this.transferSubmitting)
                .onClick((): void => { this.runTransfer(async (): Promise<void> => { await this.model.queue.reconcile(); }); })
              Button() { SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(22).fontColor([$r('sys.color.icon_primary')]) }
                .width(48).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).type(ButtonType.Circle).backgroundColor(Color.Transparent)
                .enabled(!this.model.queue.busy && !this.model.busy && !this.transferSubmitting)
                .bindMenu(this.taskPageMenu()).accessibilityText('任务，更多操作')
            }.width('100%')
            Text('上传到 NAS · 下载到此设备').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
            Text('通过非计费网络传输。').fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
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
            Column({ space: 12 }) {
              Row({ space: 8 }) {
                Button() {
                  Row({ space: 12 }) {
                    SymbolGlyph(task.item.direction === 'upload' ? $r('sys.symbol.arrow_up_circle') : $r('sys.symbol.arrow_down_circle'))
                      .fontSize(24).fontColor([$r('sys.color.icon_emphasize')])
                      .width(44).height(44).borderRadius(12).backgroundColor($r('app.color.workbench_accent_surface'))
                    Column({ space: 4 }) {
                      Text(task.item.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
                        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(task.item.stateText).fontSize(13).fontColor($r('sys.color.font_secondary'))
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  }.width('100%')
                }.type(ButtonType.Normal).backgroundColor(Color.Transparent).layoutWeight(1).constraintSize({ minHeight: 48 })
                  .onClick((): void => { this.openTask(task.item); }).accessibilityText(task.item.name + '，' + task.item.stateText + '，查看详情')
                Button() { SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(22).fontColor([$r('sys.color.font_secondary')]) }
                  .width(48).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).type(ButtonType.Circle).backgroundColor(Color.Transparent)
                  .enabled(!this.model.queue.busy && !this.model.busy && !this.transferSubmitting)
                  .bindMenu(this.taskMenu(task.item)).accessibilityText(task.item.name + '，更多操作')
              }.width('100%')
              if (task.item.state === 'running' || task.item.state === 'waiting') {
                if (task.item.bytes > 0) {
                  Progress({ value: this.taskProgress(task.item), total: 100, type: ProgressType.Linear }).width('100%')
                    .accessibilityText('已传输 ' + this.taskProgress(task.item).toFixed(0) + '%')
                }
                Text(workbenchBytes(task.item.processed) + ' / ' + workbenchBytes(task.item.bytes))
                  .fontSize(13).fontColor($r('sys.color.font_secondary'))
              } else { Text(workbenchBytes(task.item.bytes)).fontSize(13).fontColor($r('sys.color.font_secondary')) }
              if (task.item.errorText.length > 0) {
                WorkbenchNotice({ text: task.item.errorText, warning: true })
              }
              this.taskPrimaryActions(task.item)
            }.width('100%').padding(20).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
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
        .backgroundColor($r('app.color.workbench_surface')).margin({ left: 16, right: 16, bottom: 8 })
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

  @Builder
  deviceSheet() {
    Column() {
      WorkbenchInfoRow({ label: '账号', value: this.model.account })
      WorkbenchInfoRow({ label: '连接地址', value: this.model.address })
      WorkbenchInfoRow({ label: '连接方式', value: 'HTTPS 安全连接' })
      if (this.deviceInfo.length > 0) {
        Divider().color($r('app.color.workbench_divider'))
        WorkbenchInfoRow({ label: '设备型号', value: this.deviceInfo[0] })
        WorkbenchInfoRow({ label: 'DSM 版本', value: this.deviceInfo[1] })
        WorkbenchInfoRow({ label: '文件服务', value: this.deviceInfo[2] })
        WorkbenchInfoRow({ label: '照片服务', value: this.deviceInfo[3] })
        WorkbenchInfoRow({ label: '文件权限', value: this.deviceInfo[4] })
      } else if (this.model.busy) {
        LoadingProgress().width(32).height(32).margin(12)
      } else {
        Button('重新读取设备信息').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => { this.showDeviceInfo(); })
      }
    }.width('100%').padding(16).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_subtle'))
    Button('退出当前账号').constraintSize({ minHeight: 48 }).width('100%').buttonStyle(ButtonStyleMode.TEXTUAL)
      .fontColor($r('app.color.workbench_danger')).enabled(!this.model.busy).onClick((): void => { this.confirmLogout(); })
  }

  @Builder
  fileSheet() {
    Scroll() {
      Column({ space: 20 }) {
        if (this.sheetKind === 'device') {
          this.deviceSheet()
        } else if (this.sheetKind === 'task') {
          if (this.selectedTask() !== undefined) { this.taskDetail(this.selectedTask()!) }
          else { WorkbenchNotice({ text: '此任务记录已清理。' }) }
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
            .constraintSize({ minHeight: 52 }).enabled(!this.formSubmitting && !this.model.busy)
            .onChange((text: string): void => { this.formName = text; }).accessibilityText('名称')
          Text('名称不能包含斜杠、冒号或控制字符。').fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
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
          Row({ space: 16 }) {
            SymbolGlyph(this.selectedEntry.isDirectory ? $r('sys.symbol.folder') : $r('sys.symbol.doc'))
              .fontSize(32).fontColor([$r('sys.color.icon_emphasize')])
              .width(48).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).borderRadius(16).backgroundColor($r('app.color.workbench_accent_surface'))
            Text(this.selectedEntry.name).fontSize(20).fontWeight(FontWeight.Medium)
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
              Text('下载完成后，可在任务页另存到系统文件。').fontSize(13).fontColor($r('sys.color.font_secondary'))
            }
          }
        }
        this.notices()
      }.width('100%').padding({ left: 24, right: 24, top: 16, bottom: 32 }).alignItems(HorizontalAlign.Start)
    }.width('100%').scrollBar(BarState.Auto)
  }

  build() {
    Column() {
      HdsNavigation(this.navStack) {
        Column() {
          this.sharedInboxCard()
          if (this.model.authenticated) {
            HdsTabs({ controller: this.tabsController, index: this.activeTab }) {
              TabContent() { this.homeView() }
                .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier($r('sys.symbol.house')) }, '首页'))
              TabContent() { this.filesView() }
                .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier($r('sys.symbol.folder')) }, '文件'))
              TabContent() { this.photosView() }
                .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier($r('sys.symbol.picture')) }, '相册'))
              TabContent() { this.tasksView() }
                .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier($r('sys.symbol.arrow_down_circle')) }, '任务'))
            }.width('100%').layoutWeight(1).barPosition(BarPosition.End).scrollable(false)
              .barOverlap(true).vertical(false)
              .barFloatingStyle({ barBottomMargin: this.navigationInset, systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE,
                materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE }, thermoCtrl: true })
              .onTabBarClick((index: number): void => {
                if (index === this.activeTab) { this.activeScrollers()[0].scrollTo({ xOffset: 0, yOffset: 0 }); }
              })
              .onChange((index: number): void => { this.activeTab = index; if (index === 2) { this.ensurePhotosOpen(); } })
          } else { this.connectionForm() }
        }.width('100%').height('100%')
      }.width('100%').height('100%').backgroundColor($r('app.color.workbench_background')).mode(NavigationMode.Stack).hideBackButton(true)
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
        .navDestination(this.destinationBuilder).bindToScrollable(this.activeScrollers())
        .titleMode(HdsNavigationTitleMode.MINI).titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: this.pageTitle() } },
          style: { scrollEffectOpts: { scrollEffectType: ScrollEffectType.GRADIENT_BLUR },
            originalStyle: { contentStyle: { titleStyle: { mainTitleColor: $r('sys.color.font_primary') } } },
            scrollEffectStyle: { contentStyle: { titleStyle: { mainTitleColor: $r('sys.color.font_primary') } } } } })
    }.width('100%').height('100%').backgroundColor($r('app.color.workbench_background'))
      .onAreaChange((oldArea: Area, newArea: Area): void => { this.windowWidth = Number(newArea.width); })
      .bindSheet($$this.sheetVisible, this.fileSheet(), {
        height: this.sheetKind === 'backup' || this.sheetKind === 'device' || this.sheetKind === 'task' ? SheetSize.LARGE : SheetSize.FIT_CONTENT,
        preferType: this.windowWidth < 600 ? SheetType.BOTTOM : SheetType.CENTER, showClose: true,
        backgroundColor: $r('app.color.workbench_surface'),
        title: { title: this.sheetTitle() }, keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL
      })
  }
}
