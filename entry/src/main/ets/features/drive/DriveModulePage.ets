import { fileUri } from '@kit.CoreFileKit';
import { uiMaterial } from '@kit.ArkUI';
import { DriveEntry, DriveEntryKind, DriveView, driveViewLabel, driveEntryRenderKey } from '../../core/domain/DriveProtocol';
import { driveActionAllowed } from '../../core/domain/DriveActionProtocol';
import type { DriveAction } from '../../core/domain/DriveActionProtocol';
import { canPreviewDriveOriginal, canPreviewDriveMedia } from '../../core/domain/DriveOriginalProtocol';
import { telemetryTimestamp } from '../../core/domain/TelemetryProtocol';
import { driveFileLinkAllowed } from '../../core/domain/DriveCollaborationProtocol';
import { ConnectionViewModel } from '../connection/ConnectionViewModel';
import { WorkbenchMetrics, WorkbenchNotice, WorkbenchActionRow, WorkbenchEmptyState,
  WorkbenchEntryRow, WorkbenchInfoRow } from '../workbench/WorkbenchUi';
import { workbenchBytes, workbenchRelativeDate } from '../workbench/WorkbenchPresentation';
import type { DriveTrailItem } from './DriveBrowserModel';

/** Drive 页签内容；页面导航与底栏由根页面统一管理。 */
@ComponentV2
export struct DriveModulePage {
  @Param model: ConnectionViewModel = new ConnectionViewModel();
  @Param tabId: string = 'mydrive';
  @Param expectedView: DriveView = DriveView.MyDrive;
  @Param scroller: Scroller = new Scroller();
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param active: boolean = true;
  @Param searchPage: boolean = false;
  @Param moreView: string = '';
  @Param moreViews: DriveView[] = [];
  @Event onSelectMore: (view: DriveView) => void = (_view: DriveView): void => {};
  @Event onExitSearch: () => void = (): void => {};
  @Event onOpenTransfers: () => void = (): void => {};
  @Event onDownload: (entry: DriveEntry, open: boolean) => void = (): void => {};
  @Event onUploadTo: (entry: DriveEntry) => void = (_entry: DriveEntry): void => {};
  @Event onOpenAction: (action: DriveAction, entry?: DriveEntry) => void =
    (_action: DriveAction, _entry?: DriveEntry): void => {};
  @Event onOpenOriginal: (entry: DriveEntry) => void = (_entry: DriveEntry): void => {};
  @Event onOpenLinks: (entry?: DriveEntry) => void = (_entry?: DriveEntry): void => {};
  @Event onCustomize: () => void = (): void => {};
  @Local private detailVisible: boolean = false;
  @Local private detailEntry: DriveEntry | undefined = undefined;
  @Local private refreshing: boolean = false;
  @Local private refreshedCount: number | undefined = undefined;
  private sheetMaterial: uiMaterial.Material =
    new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THICK });
  private sheetMaterialAvailable: boolean = uiMaterial.isImmersiveMaterialSupported();
  private driveSearchController: SearchController = new SearchController();

  private canRenderEntries(): boolean {
    return this.active && this.model.drive.view === this.expectedView;
  }

  @Computed
  private get listBusy(): boolean { return this.model.drive.busy; }

  @Monitor('active', 'listBusy')
  private clearRefreshedCount(): void {
    if (!this.active || this.model.drive.busy) { this.refreshedCount = undefined; }
  }

  /** 计数仅在下拉刷新成功后显示；未知总数不能用当前页长度代替。 */
  private async refreshFiles(): Promise<void> {
    this.refreshedCount = undefined;
    this.model.driveThumbnails.retryVisible();
    await this.model.drive.reload();
    this.refreshing = false;
    if (this.canRenderEntries() && this.model.drive.errorText.length === 0) {
      if (this.model.drive.total !== undefined) { this.refreshedCount = this.model.drive.total; }
      else if (!this.model.drive.hasMore) { this.refreshedCount = this.model.drive.entries.length; }
    }
  }

  private supportedMoreViews(): DriveView[] {
    return this.moreViews.filter((view: DriveView): boolean =>
      [DriveView.Recent, DriveView.Starred, DriveView.SharedWithMe, DriveView.SharedWithOthers,
        DriveView.Trash].includes(view) && this.model.drive.supportsView(view));
  }

  private exitDriveSearch(): void {
    this.driveSearchController.stopEditing();
    this.onExitSearch();
  }

  @Builder
  driveSearch() {
    Row({ space: 8 }) {
      Search({ value: this.model.drive.searchText, placeholder: this.model.drive.searchPlaceholder(),
        controller: this.driveSearchController })
        .searchButton('搜索').maxLength(256).layoutWeight(1).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
        .enabled(!this.model.busy && !this.model.drive.busy && this.model.drive.supportsView(DriveView.Search))
        .onChange((value: string): void => { this.model.drive.searchText = value; })
        .onSubmit((value: string): void => {
          this.driveSearchController.stopEditing(); this.model.drive.search(value);
        })
      Button('取消').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
        .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.busy)
        .onClick((): void => { this.exitDriveSearch(); }).accessibilityText('取消搜索')
    }.width('100%')
  }

  /** 面包屑直接使用浏览模型的导航栈。 */
  @Builder
  driveBreadcrumb() {
    Scroll() {
      Row({ space: 4 }) {
        ForEach(this.model.drive.trail, (item: DriveTrailItem, index: number): void => {
          Button(index === 0 && this.model.drive.view === DriveView.Search ?
            this.model.drive.searchScopeName + ' · “' + this.model.drive.searchKeyword + '”' : item.name)
            .type(ButtonType.Normal).constraintSize({ minHeight: 40 }).fontSize(14)
            .padding({ left: 0, right: 0, top: 8, bottom: 8 }).backgroundColor(Color.Transparent)
            .fontColor(index === this.model.drive.trail.length - 1 ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
            .enabled(!this.model.busy && !this.model.drive.busy && index < this.model.drive.trail.length - 1)
            .onClick((): void => { this.model.drive.goToTrail(index); })
          if (index < this.model.drive.trail.length - 1) {
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('sys.color.font_tertiary')])
          }
        }, (item: DriveTrailItem): string =>
          this.model.drive.view + ':' + (item.fileId ?? 'root') + ':' + item.name)
      }.justifyContent(FlexAlign.Start)
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
  }

  @Builder
  driveNotices() {
    WorkbenchNotice({ text: this.model.errorText, warning: true })
    WorkbenchNotice({ text: this.model.drive.errorText, warning: true })
    WorkbenchNotice({ text: this.model.drive.notice })
    WorkbenchNotice({ text: this.model.driveThumbnails.errorText })
    WorkbenchNotice({ text: this.model.driveTransfers.errorText, warning: true })
    WorkbenchNotice({ text: this.model.driveActions.errorText, warning: true })
    WorkbenchNotice({ text: this.model.driveSharing.errorText, warning: true })
  }

  @Builder
  emptyState(icon: Resource, title: string, description: string) {
    WorkbenchEmptyState({ icon: icon, title: title, description: description })
  }

  @Builder
  driveFileList() {
    Stack({ alignContent: Alignment.Center }) {
      Refresh({ refreshing: $$this.refreshing }) {
      List({ space: 0, scroller: this.scroller }) {
        ListItem() {
          Column({ space: 4 }) {
            if (this.refreshedCount !== undefined) {
              Text(this.refreshedCount.toString() + ' 项').fontSize(12).fontColor($r('sys.color.font_secondary'))
                .width('100%').height(32).textAlign(TextAlign.Center)
            }
            if (this.searchPage) { this.driveSearch() }
            if (this.canRenderEntries() && (this.model.drive.trail.length > 1 || this.searchPage)) {
              this.driveBreadcrumb()
            }
            this.driveNotices()
          }.width('100%').alignItems(HorizontalAlign.Start)
            .padding({ top: 4, bottom: 4 })
        }
        if (this.canRenderEntries()) {
          if (!this.model.drive.busy && this.model.drive.entries.length === 0) {
            ListItem() {
              if (this.model.drive.errorText.length > 0) {
                this.emptyState($r('sys.symbol.exclamationmark_circle'), 'Drive 内容未能读取', '请下拉刷新重试。')
              } else if (this.model.drive.view === DriveView.Search && this.model.drive.trail.length === 1) {
                this.emptyState($r('sys.symbol.magnifyingglass'), '没有搜索结果', '请尝试其他关键词。')
              } else {
                this.emptyState($r('sys.symbol.folder'), '此位置为空', '当前列表没有可显示的项目。')
              }
            }
          }
          ForEach(this.model.drive.entries, (entry: DriveEntry, index: number): void => {
            ListItem() {
              WorkbenchEntryRow({ title: entry.name, subtitle: this.driveRowSubtitle(entry),
                  thumbnail: this.model.driveThumbnails.path(entry).length > 0 ?
                    fileUri.getUriFromPath(this.model.driveThumbnails.path(entry)) : '',
                  icon: entry.kind === DriveEntryKind.Folder ? $r('sys.symbol.folder') : $r('sys.symbol.doc'),
                  iconColor: entry.kind === DriveEntryKind.Folder ? $r('sys.color.icon_emphasize') : $r('sys.color.font_secondary'),
                  available: !this.model.busy && !this.model.drive.busy && entry.capabilities.canRead &&
                    this.model.drive.view !== DriveView.Trash &&
                    (entry.kind === DriveEntryKind.Folder || entry.capabilities.canDownload &&
                      this.model.driveTransfers.ready && !this.model.driveTransfers.busy),
                  menu: this.driveEntryMenu(entry), menuAvailable: !this.model.busy && !this.model.drive.busy,
                  showDivider: index < this.model.drive.entries.length - 1,
                  onOpen: (): void => { this.openDriveEntry(entry); } })
            }.borderRadius({ topLeft: index === 0 ? WorkbenchMetrics.cardRadius : 0,
              topRight: index === 0 ? WorkbenchMetrics.cardRadius : 0,
              bottomLeft: index === this.model.drive.entries.length - 1 ? WorkbenchMetrics.cardRadius : 0,
              bottomRight: index === this.model.drive.entries.length - 1 ? WorkbenchMetrics.cardRadius : 0 }).clip(true)
            .onVisibleAreaChange([0], (visible: boolean, ratio: number): void => {
              this.model.driveThumbnails.setVisible(entry, visible && ratio > 0 && this.canRenderEntries() &&
                this.model.drive.view !== DriveView.Trash);
            })
            .onDisAppear((): void => { this.model.driveThumbnails.setVisible(entry, false); })
          }, (entry: DriveEntry): string => driveEntryRenderKey(entry))
          if (this.model.drive.listLoading === 'more') {
            ListItem() {
              Row({ space: 8 }) {
                LoadingProgress().width(24).height(24).accessibilityText($r('app.string.file_list_loading'))
              }.width('100%').height(50).justifyContent(FlexAlign.Center)
            }
          }
        } else if (!this.model.drive.busy && !this.searchPage) {
          ListItem() {
            Column({ space: 8 }) {
              this.emptyState($r('sys.symbol.folder'), '此入口尚未打开', '请重试读取此入口的内容。')
              if (this.model.drive.supportsView(this.expectedView)) {
                Button('重新读取').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
                  .enabled(!this.model.busy).onClick((): void => { this.model.drive.selectView(this.expectedView); })
              }
            }.width('100%')
          }
        }
      }.width('100%').height('100%').scrollBar(BarState.Auto)
        .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin })
        .contentEndOffset(this.bottomInset).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource): void => {
          if (offset > 0 && (source === ScrollSource.DRAG || source === ScrollSource.FLING)) {
            this.refreshedCount = undefined;
          }
        })
        .onReachEnd((): void => {
          if (this.canRenderEntries() && !this.model.busy && this.model.drive.errorText.length === 0) { this.model.drive.loadMore(); }
        })
      }.width('100%').height('100%').padding({ top: this.topInset })
        .pullToRefresh(this.canRenderEntries() && !this.model.busy && !this.model.drive.busy)
        .onRefreshing((): void => { this.refreshFiles(); })
      if (this.active && this.model.drive.listLoading === 'content' && !this.refreshing) {
        Column() {
          LoadingProgress().width(40).height(40).accessibilityText($r('app.string.file_list_loading'))
        }.width('100%').height('100%').padding({ top: this.topInset, bottom: this.bottomInset })
          .justifyContent(FlexAlign.Center).hitTestBehavior(HitTestMode.None)
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.workbench_background'))
  }

  @Builder
  driveMore() {
    Scroll(this.scroller) {
      Column({ space: WorkbenchMetrics.sectionGap }) {
        if (this.supportedMoreViews().length > 0) {
          Column() {
            ForEach(this.supportedMoreViews(), (view: DriveView, index: number): void => {
              Column() {
                WorkbenchActionRow({ label: driveViewLabel(view), icon: this.driveViewIcon(view),
                  available: !this.model.busy && !this.model.drive.busy,
                  onAction: (): void => { this.onSelectMore(view); } })
                if (index < this.supportedMoreViews().length - 1) {
                  Divider().color($r('app.color.workbench_divider')).margin({ left: 68, right: 16 })
                }
              }.width('100%')
            }, (view: DriveView): string => view)
          }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
        }
        Column() {
          WorkbenchActionRow({ label: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.task_records').id),
            icon: $r('sys.symbol.clock'), onAction: this.onOpenTransfers })
          Divider().color($r('app.color.workbench_divider')).margin({ left: 68, right: 16 })
          WorkbenchActionRow({ label: '底栏设置', icon: $r('sys.symbol.slider_horizontal_2'), onAction: this.onCustomize })
        }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
        this.driveNotices()
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin,
          top: this.topInset + 8, bottom: this.bottomInset })
    }.width('100%').height('100%').scrollBar(BarState.Auto).align(Alignment.Top)
  }

  private driveRowSubtitle(entry: DriveEntry): string {
    const modified = workbenchRelativeDate(entry.modifiedAt);
    if (entry.kind === DriveEntryKind.Folder) {
      return modified.length > 0 ? '文件夹 · ' + modified : '文件夹';
    }
    const size = workbenchBytes(entry.sizeBytes);
    return modified.length > 0 && size.length > 0 ? modified + ' · ' + size :
      modified.length > 0 ? modified : size;
  }

  private driveViewIcon(view: DriveView): Resource {
    switch (view) {
      case DriveView.Recent: return $r('sys.symbol.clock');
      case DriveView.Starred: return $r('sys.symbol.star');
      case DriveView.SharedWithMe: return $r('sys.symbol.person_2');
      case DriveView.SharedWithOthers: return $r('sys.symbol.arrowshape_turn_up_right');
      case DriveView.Trash: return $r('sys.symbol.trash');
      default: return $r('sys.symbol.folder');
    }
  }

  private driveEntryMenu(entry: DriveEntry): MenuElement[] {
    const menu: MenuElement[] = [{ value: '查看详情', action: (): void => {
      this.detailEntry = entry; this.detailVisible = true;
    } }];
    if (this.model.drive.view === DriveView.Trash) { return menu; }
    if (!this.model.driveActions.ready || !this.model.driveTransfers.ready || this.model.driveTransfers.busy ||
      this.model.driveActions.busy || this.model.driveActions.hasPending) { return menu; }
    if (this.model.driveSharing.available && driveFileLinkAllowed(entry)) {
      menu.push({ value: '获取文件链接', action: (): void => { this.openDriveLinks(entry); } });
    }
    if (canPreviewDriveOriginal(entry)) {
      menu.push({ value: '查看原图', action: (): void => { this.openDriveOriginal(entry); } });
    }
    if (entry.kind === DriveEntryKind.File && entry.capabilities.canRead && entry.capabilities.canDownload) {
      menu.push({ value: '下载到本机', action: (): void => { this.detailVisible = false; this.onDownload(entry, false); } });
    }
    if (this.model.driveTransfers.available && entry.kind === DriveEntryKind.Folder &&
      entry.capabilities.canRead && entry.capabilities.canWrite) {
      menu.push({ value: '上传到此文件夹', action: (): void => { this.onUploadTo(entry); } });
    }
    if (!this.model.driveActions.available) { return menu; }
    const rootRestricted = this.model.drive.trail.length === 1 && [DriveView.TeamFolders, DriveView.SharedWithMe,
      DriveView.SharedWithOthers].includes(this.model.drive.view);
    if (!rootRestricted && driveActionAllowed(entry, 'rename')) {
      menu.push({ value: '改名', action: (): void => { this.prepareDriveAction(entry, 'rename'); } });
    }
    if (driveActionAllowed(entry, 'copy') && !(this.model.drive.view === DriveView.TeamFolders && this.model.drive.trail.length === 1)) {
      menu.push({ value: '复制到…', action: (): void => { this.prepareDriveAction(entry, 'copy'); } });
    }
    if (!rootRestricted && driveActionAllowed(entry, 'move')) {
      menu.push({ value: '移动到…', action: (): void => { this.prepareDriveAction(entry, 'move'); } });
    }
    if (!rootRestricted && driveActionAllowed(entry, 'delete')) {
      menu.push({ value: '删除', action: (): void => { this.prepareDriveAction(entry, 'delete'); } });
    }
    return menu;
  }

  private prepareDriveAction(entry: DriveEntry, action: DriveAction): void {
    this.onOpenAction(action, entry);
  }

  private openDriveEntry(entry: DriveEntry): void {
    if (this.model.drive.busy || !entry.capabilities.canRead) { return; }
    if (entry.kind === DriveEntryKind.Folder) { this.model.drive.openFolder(entry); return; }
    if (this.model.drive.view === DriveView.Trash) { return; }
    if (canPreviewDriveMedia(entry)) { this.openDriveOriginal(entry); return; }
    if (!entry.capabilities.canDownload) { return; }
    if (this.model.driveTransfers.canPreview(entry)) { this.onDownload(entry, true); }
    else { this.detailEntry = entry; this.detailVisible = true; }
  }

  private openDriveOriginal(entry: DriveEntry): void { this.onOpenOriginal(entry); }

  private openDriveLinks(entry?: DriveEntry): void { this.onOpenLinks(entry); }

  @Builder
  entryDetails() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.detailEntry !== undefined) {
          WorkbenchInfoRow({ label: $r('app.string.file_info_title'), value: this.detailEntry.name,
            labelWidth: 64, valueAlign: TextAlign.Start })
          WorkbenchInfoRow({ label: $r('app.string.file_info_type'),
            value: this.detailEntry.kind === DriveEntryKind.Folder ? $r('app.string.file_info_folder') :
              this.detailEntry.name.lastIndexOf('.') > 0 && this.detailEntry.name.lastIndexOf('.') < this.detailEntry.name.length - 1 ?
                this.detailEntry.name.slice(this.detailEntry.name.lastIndexOf('.') + 1).toLowerCase() : $r('app.string.file_info_file'),
            labelWidth: 64, valueAlign: TextAlign.Start })
          WorkbenchInfoRow({ label: $r('app.string.file_info_created'), value: this.detailEntry.createdAt === undefined ?
            $r('app.string.file_info_unavailable') : telemetryTimestamp(Math.trunc(this.detailEntry.createdAt * 1000)),
            labelWidth: 64, valueAlign: TextAlign.Start })
          WorkbenchInfoRow({ label: $r('app.string.file_info_modified'), value: this.detailEntry.modifiedAt === undefined ?
            $r('app.string.file_info_unavailable') : telemetryTimestamp(Math.trunc(this.detailEntry.modifiedAt * 1000)),
            labelWidth: 64, valueAlign: TextAlign.Start })
          WorkbenchInfoRow({ label: $r('app.string.file_info_owner'),
            value: this.detailEntry.owner?.name ?? this.detailEntry.owner?.displayName ?? this.detailEntry.owner?.nickname ??
              $r('app.string.file_info_unavailable'), labelWidth: 64, valueAlign: TextAlign.Start })
          if (this.detailEntry.kind !== DriveEntryKind.Folder) {
            WorkbenchInfoRow({ label: $r('app.string.file_info_size'), value: this.detailEntry.sizeBytes === undefined ?
              $r('app.string.file_info_unavailable') : workbenchBytes(this.detailEntry.sizeBytes),
              labelWidth: 64, valueAlign: TextAlign.Start })
          }
          WorkbenchInfoRow({ label: $r('app.string.file_info_location'),
            value: this.detailEntry.displayPath ?? $r('app.string.file_info_unavailable'),
            labelWidth: 64, valueAlign: TextAlign.Start })
        }
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto).align(Alignment.TopStart)
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
  }

  build() {
    Column() {
      if (!this.active) {
        Blank().width('100%').height('100%')
      } else if (this.tabId === 'more' && this.moreView.length === 0) {
        this.driveMore()
      } else {
        this.driveFileList()
      }
    }.width('100%').constraintSize({ maxWidth: 960 }).height('100%')
      .backgroundColor($r('app.color.workbench_background'))
      .bindSheet($$this.detailVisible, this.entryDetails(), {
        height: SheetSize.MEDIUM, detents: [SheetSize.MEDIUM, SheetSize.LARGE], title: { title: '文件详情' },
        showClose: true, backgroundColor: this.sheetMaterialAvailable ? Color.Transparent : $r('app.color.workbench_surface_elevated'),
        systemMaterial: this.sheetMaterial
      })
  }
}
