import { NasFileEntry } from '../../core/domain/DsmProtocol';
import { ConnectionViewModel } from '../connection/ConnectionViewModel';
import { WorkbenchBreadcrumb, workbenchBreadcrumbs, workbenchBytes, workbenchRelativeDate,
  workbenchFileGridColumns, workbenchFileGridMetadata } from '../workbench/WorkbenchPresentation';
import { interactionFeedback } from '../../platform/InteractionFeedback';
import { ImagePreview } from '../workbench/ImagePreview';
import { WorkbenchMetrics, WorkbenchEmptyState, WorkbenchEntryRow, WorkbenchNotice, WorkbenchInfoRow, WorkbenchServiceError } from '../workbench/WorkbenchUi';

/** File Station 列表复用于文件页和独立的目录选择页，页面级工具由宿主标题栏承载。 */
@ComponentV2
export struct FileStationPage {
  @Param model: ConnectionViewModel = new ConnectionViewModel();
  @Param scroller: ListScroller = new ListScroller();
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param active: boolean = true;
  @Param wide: boolean = false;
  @Local private inspected: NasFileEntry | undefined = undefined;
  private detailStack: NavPathStack = new NavPathStack();
  @Param errorText: string = '';
  @Param pendingEntries: NasFileEntry[] = [];
  @Param selecting: boolean = false;
  @Param selectedPaths: string[] = [];
  @Param pendingOperation: string = '';
  @Param canUseDestination: boolean = false;
  @Param pickerMode: string = '';
  @Param selectionCount: number = 0;
  @Param pickerBusy: boolean = false;
  @Param pickerError: string = '';
  @Param canConfirm: boolean = false;
  @Event onOpenForm: (kind: string, entry?: NasFileEntry) => void = (): void => {};
  @Event onOpenImage: (entry: NasFileEntry) => void = (): void => {};
  @Event onNavigateBreadcrumb: (path: string) => void = (): void => {};
  @Event onApplyDestination: () => void = (): void => {};
  @Event onCancelDestination: () => void = (): void => {};
  @Event onConfirm: () => void = (): void => {};
  @Event onCancel: () => void = (): void => {};
  @Event onToggleSelection: (entry: NasFileEntry) => void = (): void => {};
  @Param menuForEntry: (entry: NasFileEntry) => MenuElement[] = (_entry: NasFileEntry): MenuElement[] => [];
  @Event onBeginSelection: (entry: NasFileEntry) => void = (): void => {};
  @Event onSort: () => void = (): void => {};
  @Local private grid: boolean = false;
  @Local private listWidth: number = 360;
  private firstVisibleItem: number = 0;
  private resizeTimer: number = -1;
  private breadcrumbScroller: Scroller = new Scroller();
  @Local private refreshing: boolean = false;
  @Local private refreshedCount: number | undefined = undefined;

  aboutToDisappear(): void { clearTimeout(this.resizeTimer); this.resizeTimer = -1; }

  @Monitor('model.directory')
  private revealBreadcrumb(): void { setTimeout((): void => { this.breadcrumbScroller.scrollEdge(Edge.End); }, 0); }

  @Monitor('active', 'model.busy')
  private clearRefreshedCount(): void {
    if (!this.active || this.model.busy) { this.refreshedCount = undefined; }
  }

  /** 目录选择页只统计文件夹，尚有未加载分页时不显示不完整计数。 */
  private async refreshFiles(): Promise<void> {
    this.refreshedCount = undefined;
    await this.model.refresh();
    this.refreshing = false;
    if (this.active && this.model.directoryErrorText.length === 0) {
      if (this.pickerMode.length === 0) { this.refreshedCount = this.model.total; }
      else if (!this.model.filesMore) { this.refreshedCount = this.visibleEntries().length; }
    }
  }

  @Builder
  breadcrumbBar() {
    Scroll(this.breadcrumbScroller) {
      Row({ space: 4 }) {
        ForEach(workbenchBreadcrumbs(this.model.directory), (crumb: WorkbenchBreadcrumb): void => {
          Button(crumb.title).type(ButtonType.Normal).constraintSize({ minHeight: 40 }).fontSize(14)
            .padding({ left: 0, right: 0, top: 8, bottom: 8 }).backgroundColor(Color.Transparent)
            .fontColor(crumb.path === this.model.directory ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
            .enabled(!this.model.busy && crumb.path !== this.model.directory)
            .onClick((): void => { this.onNavigateBreadcrumb(crumb.path); })
          if (crumb.path !== this.model.directory) {
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('sys.color.font_tertiary')])
              .accessibilityLevel('no')
          }
        }, (crumb: WorkbenchBreadcrumb): string => crumb.path)
      }.justifyContent(FlexAlign.Start)
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
      .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).align(Alignment.Start)
  }

  @Builder
  destinationBar() {
    if (this.pendingEntries.length > 0) {
      Column({ space: 4 }) {
        Text(this.pendingEntries.length === 1 ?
          (this.pendingOperation === 'copy' ? '复制“' : '移动“') + this.pendingEntries[0].name + '”' :
          this.pendingOperation === 'copy' ? $r('app.string.file_copy_selected', this.pendingEntries.length) :
          $r('app.string.file_move_selected', this.pendingEntries.length))
          .fontSize(14).width('100%').fontColor($r('sys.color.font_secondary')).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.model.directory.length === 0) {
          Text('请选择目标文件夹').fontSize(12).width('100%').fontColor($r('sys.color.font_tertiary'))
        }
        Row({ space: 12 }) {
          Button(this.pendingOperation === 'copy' ? '复制到此处' : '移动到此处').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).layoutWeight(1)
            .enabled(!this.model.busy && this.canUseDestination).onClick((): void => { this.onApplyDestination(); })
          Button('取消').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.busy)
            .onClick((): void => { this.onCancelDestination(); })
        }.width('100%')
      }.width('100%').padding(12).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_subtle'))
        .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  pickerBar() {
    if (this.pickerMode.length > 0) {
      Column({ space: 4 }) {
        if (this.model.directory.length === 0) {
          Text('请进入目标文件夹').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        }
        if (this.pickerMode === 'backup') {
          Text('已选择 ' + this.selectionCount.toString() + ' 项照片与视频').fontSize(14)
            .fontColor($r('sys.color.font_secondary')).width('100%')
        }
        WorkbenchNotice({ text: this.pickerError, warning: true })
        Row({ space: 12 }) {
          Button(this.pickerBusy ? '正在准备…' : this.pickerMode === 'backup' ? '备份到此处' : '保存到此目录')
            .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).layoutWeight(1).enabled(this.canConfirm && !this.pickerBusy)
            .onClick((): void => { this.onConfirm(); })
          Button('取消').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(!this.pickerBusy).onClick((): void => { this.onCancel(); })
        }.width('100%')
      }.width('100%').padding(12).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_subtle'))
        .alignItems(HorizontalAlign.Start)
    }
  }

  private visibleEntries(): NasFileEntry[] {
    return this.pickerMode.length > 0 ? this.model.entries.filter((entry: NasFileEntry): boolean => entry.isDirectory) : this.model.entries;
  }

  private resizeList(width: number): void {
    const columns = workbenchFileGridColumns(this.listWidth);
    const anchor = this.visibleEntries()[this.firstVisibleItem];
    this.listWidth = width;
    if (!this.grid || columns === workbenchFileGridColumns(width) || anchor === undefined || this.firstVisibleItem === 0) { return; }
    clearTimeout(this.resizeTimer);
    this.resizeTimer = setTimeout((): void => {
      this.resizeTimer = -1;
      const index = this.visibleEntries().findIndex((entry: NasFileEntry): boolean => entry.path === anchor.path);
      if (this.active && this.grid && index >= 0) { this.scroller.scrollToItemInGroup(0, index, false, ScrollAlign.START); }
    }, 0);
  }

  @Builder
  emptyState(icon: Resource, title: string, description: string = '') {
    WorkbenchEmptyState({ icon: icon, title: title, description: description })
  }

  @Builder
  listHeader() {
    Column({ space: 8 }) {
      Row() {
        this.breadcrumbBar()
        if (this.pickerMode.length === 0 && !this.selecting) {
          Divider().vertical(true).height(20).color($r('app.color.workbench_divider')).margin({ left: 8, right: 8 })
          Button() { SymbolGlyph($r('sys.symbol.slider_horizontal_2')).fontSize(20).fontColor([$r('sys.color.icon_secondary')]) }
            .width(48).height(48).type(ButtonType.Normal).buttonStyle(ButtonStyleMode.TEXTUAL).padding(0)
            .accessibilityText($r('app.string.file_sort')).onClick(this.onSort)
          Button() { SymbolGlyph(this.grid ? $r('sys.symbol.list_bullet') : $r('sys.symbol.square_grid_2x2'))
            .fontSize(20).fontColor([$r('sys.color.icon_secondary')]) }
            .width(48).height(48).type(ButtonType.Normal).buttonStyle(ButtonStyleMode.TEXTUAL).padding(0)
            .accessibilityText(this.grid ? $r('app.string.view_list') : $r('app.string.view_grid'))
            .onClick((): void => { this.grid = !this.grid; })
        }
      }.width('100%').constraintSize({ minHeight: 48 })
        .padding({ left: this.grid ? 0 : 16, right: this.grid ? 0 : 16 })
      if (this.refreshedCount !== undefined) {
        Text(this.refreshedCount.toString() + ' 项').fontSize(12).fontColor($r('sys.color.font_secondary'))
          .width('100%').height(32).textAlign(TextAlign.Center)
      }
      this.destinationBar()
      this.pickerBar()
      if (this.active && this.model.directoryErrorText.length > 0) {
        WorkbenchServiceError({ message: this.model.directoryErrorText, title: $r('app.string.file_list_unavailable'),
          retainedContent: this.visibleEntries().length > 0, managementAvailable: false,
          available: !this.model.busy && !this.pickerBusy, onRetry: (): void => { this.refreshFiles(); } })
      }
      if (this.errorText !== this.model.directoryErrorText) { WorkbenchNotice({ text: this.errorText, warning: true }) }
      if (this.errorText.length === 0) { WorkbenchNotice({ text: this.model.actionNotice }) }
    }.width('100%').padding({ top: 4, bottom: 8 }).alignItems(HorizontalAlign.Start)
  }

  @Builder
  listFooter() {
    if (this.model.listLoading === 'more') {
      Row() { LoadingProgress().width(24).height(24).accessibilityText($r('app.string.file_list_loading')) }
        .width('100%').height(50).justifyContent(FlexAlign.Center)
    } else if (!this.model.filesMore && this.errorText.length === 0 && this.visibleEntries().length > 0) {
      Text($r('app.string.file_total_count', this.pickerMode.length > 0 ? this.visibleEntries().length : this.model.total))
        .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%').height(40).textAlign(TextAlign.Center)
    }
  }

  @Builder
  fileList() {
    Column() {
    Stack({ alignContent: Alignment.Bottom }) {
      Refresh({ refreshing: $$this.refreshing }) {
      List({ space: 0, scroller: this.scroller }) {
        ListItemGroup({ header: this.listHeader, footer: this.listFooter, space: this.grid && this.pickerMode.length === 0 ? 12 : 0 }) {
        if (!this.model.busy && this.visibleEntries().length === 0 && this.model.errorText.length === 0 && this.errorText.length === 0) {
          ListItem() {
            this.emptyState($r('sys.symbol.folder'), this.pickerMode.length > 0 ? '没有可浏览的文件夹' : '此位置为空',
              this.pickerMode.length > 0 ? '当前目录下没有可选择的子文件夹。' : '当前目录没有可显示的文件或文件夹。')
          }
        }
        Repeat<NasFileEntry>(this.visibleEntries()).each((row: RepeatItem<NasFileEntry>): void => {
          ListItem() {
              WorkbenchEntryRow({ title: row.item.name, grid: this.grid && this.pickerMode.length === 0,
                gridMetadata: workbenchFileGridMetadata(row.item.isDirectory,
                  row.item.modifiedAt === undefined ? undefined : row.item.modifiedAt / 1000, row.item.bytes),
                selecting: this.selecting, selected: this.selectedPaths.includes(row.item.path), selectionAvailable: !this.model.busy,
                onSelect: (): void => { this.onToggleSelection(row.item); },
                subtitle: (row.item.isDirectory ? '文件夹' : workbenchBytes(row.item.bytes)) +
                  (row.item.modifiedAt === undefined ? '' : '，' + workbenchRelativeDate(row.item.modifiedAt / 1000)),
                icon: row.item.isDirectory ? $r('sys.symbol.folder') : $r('sys.symbol.doc'),
                iconColor: row.item.isDirectory ? $r('sys.color.icon_emphasize') : $r('sys.color.font_secondary'),
                available: !this.model.busy, menuAvailable: !this.model.busy,
                contentInset: this.selecting ? 12 : 16, showDivider: row.index < this.visibleEntries().length - 1,
                menu: this.pickerMode.length === 0 && !this.selecting ? this.menuForEntry(row.item) : [],
                onLongPress: (): void => {
                  if (this.pickerMode.length === 0 && !this.selecting) { interactionFeedback(); this.onBeginSelection(row.item); }
                },
                onOpen: (): void => {
                  if (this.selecting) { this.onToggleSelection(row.item); }
                  else if (row.item.isDirectory) { this.model.openDirectory(row.item); }
                  else if (this.wide && this.pickerMode.length === 0) {
                    this.inspected = row.item;
                    this.detailStack.replacePathByName('detail', undefined);
                    if (/\.(?:jpe?g|png|gif|webp|bmp|heic|heif|tiff?|dng|avif|avis)$/i.test(row.item.name)) { this.model.fileOriginal.openFile(row.item); }
                  }
                  else if (/\.(?:jpe?g|png|gif|webp|bmp|heic|heif|tiff?|dng|avif|avis)$/i.test(row.item.name)) { this.onOpenImage(row.item); }
                  else { this.onOpenForm('detail', row.item); }
                } }).width('100%')
          }
        }).key((entry: NasFileEntry): string => this.model.address + ':' + this.model.account + ':' + entry.path).virtualScroll()
        }
      }.width('100%').height('100%').scrollBar(BarState.Auto)
        .contentStartOffset(this.topInset).contentEndOffset(this.bottomInset)
        .lanes(this.grid && this.pickerMode.length === 0 ? workbenchFileGridColumns(this.listWidth) : 1, this.grid ? 12 : 0)
        .padding({ left: this.grid ? WorkbenchMetrics.pageMargin : 0, right: this.grid ? WorkbenchMetrics.pageMargin : 0 })
        .onAreaChange((_old: Area, area: Area): void => { this.resizeList(Number(area.width)); })
        .onScrollVisibleContentChange((start: VisibleListContentInfo): void => { this.firstVisibleItem = start.itemIndexInGroup ?? 0; })
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource): void => {
          if (offset > 0 && (source === ScrollSource.DRAG || source === ScrollSource.FLING)) {
            this.refreshedCount = undefined;
          }
        })
        .onReachEnd((): void => {
          if (this.model.directoryErrorText.length === 0 && !this.pickerBusy) { this.model.nextPage(); }
        })
      }.width('100%').height('100%')
        .pullToRefresh(this.active && !this.model.busy && !this.pickerBusy)
        .onRefreshing((): void => { this.refreshFiles(); })
      if (this.model.listLoading === 'content' && !this.refreshing) {
        Column() {
          LoadingProgress().width(40).height(40).accessibilityText($r('app.string.file_list_loading'))
        }.width('100%').height('100%').padding({ top: this.topInset, bottom: this.bottomInset })
          .justifyContent(FlexAlign.Center).hitTestBehavior(HitTestMode.None)
      }
    }.width('100%').layoutWeight(1)
    }.width('100%').height('100%')
      .backgroundColor($r('app.color.workbench_background'))
  }

  @Builder
  fileDetail(_name: string) {
    NavDestination() {
      Column({ space: 12 }) {
        if (this.inspected !== undefined) {
          Text(this.inspected.name).fontSize(20).fontWeight(FontWeight.Medium).width('100%')
          if (/\.(?:jpe?g|png|gif|webp|bmp|heic|heif|tiff?|dng|avif|avis)$/i.test(this.inspected.name)) {
            ImagePreview({ source: this.model.fileOriginal.pixels ?? '', name: this.inspected.name,
              busy: this.model.fileOriginal.busy, errorText: this.model.fileOriginal.errorText,
              canDownload: false, onViewport: (width: number, height: number): void => { this.model.fileOriginal.setViewport(width, height); },
              onRefine: (scale: number): void => { this.model.fileOriginal.refine(scale); } }).layoutWeight(1)
          } else {
            WorkbenchInfoRow({ label: $r('app.string.file_info_size'), value: workbenchBytes(this.inspected.bytes) })
            WorkbenchInfoRow({ label: $r('app.string.file_info_location'), value: this.inspected.path })
          }
          Button($r('app.string.notice_details')).height(48).onClick((): void => { this.onOpenForm('detail', this.inspected); })
        } else {
          Text($r('app.string.file_detail_hint')).fontColor($r('sys.color.font_secondary'))
        }
      }.width('100%').height('100%').padding({ top: this.topInset, left: 24, right: 24, bottom: this.bottomInset })
    }.hideTitleBar(true)
  }

  build() {
    if (this.wide && this.pickerMode.length === 0) {
      Navigation(this.detailStack) { this.fileList() }.mode(NavigationMode.Auto).navBarWidth('40%')
        .hideTitleBar(true).hideToolBar(true).navDestination(this.fileDetail).width('100%').height('100%')
    } else { this.fileList() }
  }
}
