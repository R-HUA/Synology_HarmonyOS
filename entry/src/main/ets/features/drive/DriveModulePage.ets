import { fileUri } from '@kit.CoreFileKit';
import { uiMaterial } from '@kit.ArkUI';
import { ImmersiveMaterials } from '../../platform/ImmersiveMaterials';
import { DriveEntry, DriveEntryKind, DriveView, driveViewLabel, DriveSortBy } from '../../core/domain/DriveProtocol';
import { interactionFeedback } from '../../platform/InteractionFeedback';
import { DriveOriginalPage } from './DriveOriginalUi';
import { canPreviewDriveMedia } from '../../core/domain/DriveOriginalProtocol';
import { telemetryTimestamp } from '../../core/domain/TelemetryProtocol';
import { ConnectionViewModel } from '../connection/ConnectionViewModel';
import { WorkbenchMetrics, WorkbenchNotice, WorkbenchActionRow, WorkbenchEmptyState,
  WorkbenchEntryRow, WorkbenchInfoRow } from '../workbench/WorkbenchUi';
import { workbenchBytes, workbenchRelativeDate, workbenchFileGridColumns, workbenchFileGridMetadata } from '../workbench/WorkbenchPresentation';
import { DriveBrowserModel, DriveTrailItem } from './DriveBrowserModel';

/** Drive 页签内容；页面导航与底栏由根页面统一管理。 */
@ComponentV2
export struct DriveModulePage {
  @Param model: ConnectionViewModel = new ConnectionViewModel();
  @Param tabId: string = 'mydrive';
  @Param expectedView: DriveView = DriveView.MyDrive;
  @Param scroller: ListScroller = new ListScroller();
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param active: boolean = true;
  @Param wide: boolean = false;
  private detailStack: NavPathStack = new NavPathStack();
  @Param searchPage: boolean = false;
  @Param moreView: string = '';
  @Param moreViews: DriveView[] = [];
  @Event onSelectMore: (view: DriveView) => void = (_view: DriveView): void => {};
  @Event onExitSearch: () => void = (): void => {};
  @Event onOpenTransfers: () => void = (): void => {};
  @Event onDownload: (entry: DriveEntry, open: boolean) => void = (): void => {};
  @Event onOpenOriginal: (entry: DriveEntry) => void = (_entry: DriveEntry): void => {};
  @Event onCustomize: () => void = (): void => {};
  @Param detailVisible: boolean = false;
  @Param detailEntry: DriveEntry | undefined = undefined;
  @Event onInspectEntry: (entry: DriveEntry | undefined, visible: boolean) => void = (): void => {};
  @Param menuForEntry: (entry: DriveEntry) => MenuElement[] = (_entry: DriveEntry): MenuElement[] => [];
  @Local private refreshing: boolean = false;
  @Local private refreshedCount: number | undefined = undefined;
  @Local private grid: boolean = false;
  @Param selecting: boolean = false;
  @Param selectedIds: string[] = [];
  @Event onSelectionChange: (selecting: boolean, ids: string[]) => void = (): void => {};
  @Local private listWidth: number = 360;
  @Local private observedBrowser: DriveBrowserModel = this.model.drive;
  private firstVisibleItem: number = 0;
  private resizeTimer: number = -1;
  @Local private sizeSort: boolean = false;
  private breadcrumbScroller: Scroller = new Scroller();

  aboutToAppear(): void { this.observedBrowser = this.model.drive; }

  aboutToDisappear(): void { clearTimeout(this.resizeTimer); this.resizeTimer = -1; }

  @Monitor('model')
  private browserChanged(): void { this.observedBrowser = this.model.drive; }

  @Monitor('observedBrowser.trail', 'expectedView', 'active')
  private revealBreadcrumb(): void {
    setTimeout((): void => { this.breadcrumbScroller.scrollEdge(Edge.End); }, 0);
  }

  private entries(): DriveEntry[] {
    return this.sizeSort ? this.model.drive.entries.slice().sort((left: DriveEntry, right: DriveEntry): number =>
      (left.sizeBytes ?? 0) - (right.sizeBytes ?? 0)) : this.model.drive.entries;
  }

  private toggleSelection(entry: DriveEntry): void {
    this.onSelectionChange(true, this.selectedIds.includes(entry.fileId) ?
      this.selectedIds.filter((id: string): boolean => id !== entry.fileId) : this.selectedIds.concat([entry.fileId]));
  }

  private resizeList(width: number): void {
    const columns = workbenchFileGridColumns(this.listWidth);
    const anchor = this.entries()[this.firstVisibleItem];
    this.listWidth = width;
    if (!this.grid || columns === workbenchFileGridColumns(width) || anchor === undefined || this.firstVisibleItem === 0) { return; }
    clearTimeout(this.resizeTimer);
    this.resizeTimer = setTimeout((): void => {
      this.resizeTimer = -1;
      const index = this.entries().findIndex((entry: DriveEntry): boolean => entry.fileId === anchor.fileId);
      if (this.canRenderEntries() && this.grid && index >= 0) { this.scroller.scrollToItemInGroup(0, index, false, ScrollAlign.START); }
    }, 0);
  }

  private sortMenu(): MenuElement[] {
    return [{ value: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.sort_name').id), action: (): void => {
      this.sizeSort = false; this.model.drive.sort(DriveSortBy.Name, false);
    } }, { value: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.sort_time').id), action: (): void => {
      this.sizeSort = false; this.model.drive.sort(DriveSortBy.ModifiedTime, true);
    } }, { value: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.sort_size_loaded').id), action: (): void => { this.sizeSort = true; } }];
  }
  private sheetMaterial: uiMaterial.Material | undefined = ImmersiveMaterials.SHEET_ULTRA_THICK;
  private sheetMaterialAvailable: boolean = ImmersiveMaterials.supported;
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
        .defaultFocus(false).searchButton('搜索').maxLength(256).layoutWeight(1).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
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
    Scroll(this.breadcrumbScroller) {
      Row({ space: 4 }) {
        ForEach(this.model.drive.trail, (item: DriveTrailItem, index: number): void => {
          Button(index === 0 && this.model.drive.view === DriveView.Search ?
            this.model.drive.searchScopeName + '，“' + this.model.drive.searchKeyword + '”' : item.name)
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
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
      .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).align(Alignment.Start)
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
  listHeader() {
    Column({ space: 4 }) {
      Column() {
        if (this.searchPage) { Column() { this.driveSearch() }.enabled(!this.selecting) }
        Row() {
          if (this.canRenderEntries() && this.model.drive.trail.length > 0) { this.driveBreadcrumb() }
          else { Blank() }
          if (!this.selecting) {
            Divider().vertical(true).height(20).color($r('app.color.workbench_divider')).margin({ left: 8, right: 8 })
            Button() { SymbolGlyph($r('sys.symbol.slider_horizontal_2')).fontSize(20).fontColor([$r('sys.color.icon_secondary')]) }
              .width(48).height(48).type(ButtonType.Normal).buttonStyle(ButtonStyleMode.TEXTUAL).padding(0)
              .bindMenu(this.sortMenu()).accessibilityText($r('app.string.file_sort'))
            Button() { SymbolGlyph(this.grid ? $r('sys.symbol.list_bullet') : $r('sys.symbol.square_grid_2x2'))
              .fontSize(20).fontColor([$r('sys.color.icon_secondary')]) }
              .width(48).height(48).type(ButtonType.Normal).buttonStyle(ButtonStyleMode.TEXTUAL).padding(0)
              .accessibilityText(this.grid ? $r('app.string.view_list') : $r('app.string.view_grid'))
              .onClick((): void => { this.grid = !this.grid; })
          }
        }.width('100%').constraintSize({ minHeight: 48 })
      }.padding({ left: this.grid ? 0 : 16, right: this.grid ? 0 : 16 }).width('100%')
      if (this.refreshedCount !== undefined) {
        Text(this.refreshedCount.toString() + ' 项').fontSize(12).fontColor($r('sys.color.font_secondary'))
          .width('100%').height(32).textAlign(TextAlign.Center)
      }
      this.driveNotices()
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 4, bottom: 4 })
  }

  @Builder
  listFooter() {
    if (this.canRenderEntries()) {
      if (this.model.drive.listLoading === 'more') {
        Row() { LoadingProgress().width(24).height(24).accessibilityText($r('app.string.file_list_loading')) }
          .width('100%').height(50).justifyContent(FlexAlign.Center)
      } else if (!this.model.drive.hasMore && this.model.drive.errorText.length === 0 && this.model.drive.entries.length > 0) {
        Text($r('app.string.file_total_count', this.model.drive.total ?? this.model.drive.entries.length))
          .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%').height(40).textAlign(TextAlign.Center)
      }
    }
  }

  @Builder
  driveFileList() {
    Column() {
    Stack({ alignContent: Alignment.Bottom }) {
      Refresh({ refreshing: $$this.refreshing }) {
      List({ space: 0, scroller: this.scroller }) {
        ListItemGroup({ header: this.listHeader, footer: this.listFooter, space: this.grid ? 12 : 0 }) {
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
          Repeat<DriveEntry>(this.entries()).each((row: RepeatItem<DriveEntry>): void => {
            ListItem() {
              WorkbenchEntryRow({ title: row.item.name, subtitle: this.driveRowSubtitle(row.item), grid: this.grid,
                  gridMetadata: workbenchFileGridMetadata(row.item.kind === DriveEntryKind.Folder, row.item.modifiedAt, row.item.sizeBytes),
                  selecting: this.selecting, selected: this.selectedIds.includes(row.item.fileId),
                  selectionAvailable: !this.model.busy && !this.model.drive.busy,
                  onSelect: (): void => { this.toggleSelection(row.item); }, contentInset: this.selecting ? 12 : 16,
                  transitionId: 'drive-' + row.item.fileId,
                  thumbnail: this.model.driveThumbnails.path(row.item).length > 0 ?
                    fileUri.getUriFromPath(this.model.driveThumbnails.path(row.item)) : '',
                  icon: row.item.kind === DriveEntryKind.Folder ? $r('sys.symbol.folder') : $r('sys.symbol.doc'),
                  iconColor: row.item.kind === DriveEntryKind.Folder ? $r('sys.color.icon_emphasize') : $r('sys.color.font_secondary'),
                  available: !this.model.busy && !this.model.drive.busy && (this.selecting || row.item.capabilities.canRead),
                  menu: this.selecting ? [] : this.menuForEntry(row.item), menuAvailable: !this.model.busy && !this.model.drive.busy,
                  showDivider: row.index < this.model.drive.entries.length - 1,
                  onLongPress: (): void => { interactionFeedback(); this.onSelectionChange(true, [row.item.fileId]); },
                  onOpen: (): void => { if (this.selecting) { this.toggleSelection(row.item); } else { this.openDriveEntry(row.item); } } }).width('100%')
            }
            .onVisibleAreaChange([0], (visible: boolean, ratio: number): void => {
              this.model.driveThumbnails.setVisible(row.item, visible && ratio > 0 && this.canRenderEntries() &&
                this.model.drive.view !== DriveView.Trash);
            })
            .onDisAppear((): void => { this.model.driveThumbnails.setVisible(row.item, false); })
          }).key((entry: DriveEntry): string => this.model.address + ':' + this.model.account + ':' + entry.fileId).virtualScroll()
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
        }
      }.width('100%').height('100%').scrollBar(BarState.Auto)
        .contentStartOffset(this.topInset)
        .lanes(this.grid ? workbenchFileGridColumns(this.listWidth) : 1, this.grid ? 12 : 0)
        .padding({ left: this.grid ? WorkbenchMetrics.pageMargin : 0, right: this.grid ? WorkbenchMetrics.pageMargin : 0 })
        .contentEndOffset(this.bottomInset).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .onAreaChange((_old: Area, area: Area): void => { this.resizeList(Number(area.width)); })
        .onScrollVisibleContentChange((start: VisibleListContentInfo): void => { this.firstVisibleItem = start.itemIndexInGroup ?? 0; })
        .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource): void => {
          if (offset > 0 && (source === ScrollSource.DRAG || source === ScrollSource.FLING)) {
            this.refreshedCount = undefined;
          }
        })
        .onReachEnd((): void => {
          if (this.canRenderEntries() && !this.model.busy && this.model.drive.errorText.length === 0) { this.model.drive.loadMore(); }
        })
      }.width('100%').height('100%')
        .pullToRefresh(this.canRenderEntries() && !this.model.busy && !this.model.drive.busy)
        .onRefreshing((): void => { this.refreshFiles(); })
      if (this.active && this.model.drive.listLoading === 'content' && !this.refreshing) {
        Column() {
          LoadingProgress().width(40).height(40).accessibilityText($r('app.string.file_list_loading'))
        }.width('100%').height('100%').padding({ top: this.topInset, bottom: this.bottomInset })
          .justifyContent(FlexAlign.Center).hitTestBehavior(HitTestMode.None)
      }
    }.width('100%').layoutWeight(1)
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
      return modified.length > 0 ? '文件夹，' + modified : '文件夹';
    }
    const size = workbenchBytes(entry.sizeBytes);
    return modified.length > 0 && size.length > 0 ? modified + '，' + size :
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

  private openDriveEntry(entry: DriveEntry): void {
    if (this.model.drive.busy || !entry.capabilities.canRead) { return; }
    if (entry.kind === DriveEntryKind.Folder) { this.model.drive.openFolder(entry); return; }
    if (this.model.drive.view === DriveView.Trash) { return; }
    if (this.wide) {
      this.onInspectEntry(entry, false); this.detailStack.replacePathByName('detail', undefined);
      if (canPreviewDriveMedia(entry)) { this.model.driveOriginal.open(entry); }
      return;
    }
    if (canPreviewDriveMedia(entry)) { this.openDriveOriginal(entry); return; }
    if (!entry.capabilities.canDownload || !this.model.driveTransfers.ready || this.model.driveTransfers.busy) {
      this.onInspectEntry(entry, true); return;
    }
    if (this.model.driveTransfers.canPreview(entry)) { this.onDownload(entry, true); }
    else { this.onInspectEntry(entry, true); }
  }

  private openDriveOriginal(entry: DriveEntry): void { this.onOpenOriginal(entry); }

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

  @Builder
  wideDetails(_name: string) {
    NavDestination() {
      Column() {
        if (this.detailEntry !== undefined && canPreviewDriveMedia(this.detailEntry)) {
          DriveOriginalPage({ model: this.model.driveOriginal, onDownload: (): void => { this.onDownload(this.detailEntry!, false); } })
        } else { this.entryDetails() }
      }.width('100%').height('100%').padding({ top: this.topInset, bottom: this.bottomInset })
    }.hideTitleBar(true)
  }

  build() {
    Column() {
      if (!this.active) {
        Blank().width('100%').height('100%')
      } else if (this.tabId === 'more' && this.moreView.length === 0) {
        this.driveMore()
      } else {
        if (this.wide) {
          Navigation(this.detailStack) { this.driveFileList() }.mode(NavigationMode.Auto).navBarWidth('40%')
            .hideTitleBar(true).hideToolBar(true).navDestination(this.wideDetails).width('100%').height('100%')
        } else { this.driveFileList() }
      }
    }.width('100%').height('100%')
      .backgroundColor($r('app.color.workbench_background'))
      .bindSheet(this.detailVisible && this.active, this.entryDetails(), {
        height: SheetSize.MEDIUM, detents: [SheetSize.MEDIUM, SheetSize.LARGE], title: { title: '文件详情' },
        showClose: true, backgroundColor: this.sheetMaterialAvailable ? Color.Transparent : $r('app.color.workbench_surface_elevated'),
        systemMaterial: this.sheetMaterial,
        onDisappear: (): void => { this.onInspectEntry(this.detailEntry, false); }
      })
  }
}
