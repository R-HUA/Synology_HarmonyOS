import { NasFileEntry } from '../../core/domain/DsmProtocol';
import { ConnectionViewModel } from '../connection/ConnectionViewModel';
import { WorkbenchBreadcrumb, workbenchBreadcrumbs, workbenchBytes, workbenchRelativeDate } from '../workbench/WorkbenchPresentation';
import { interactionFeedback } from '../../platform/InteractionFeedback';
import { ImagePreview } from '../workbench/ImagePreview';
import { WorkbenchMetrics, WorkbenchEmptyState, WorkbenchEntryRow, WorkbenchNotice, WorkbenchInfoRow } from '../workbench/WorkbenchUi';

/** File Station 列表复用于文件页和独立的目录选择页，页面级工具由宿主标题栏承载。 */
@ComponentV2
export struct FileStationPage {
  @Param model: ConnectionViewModel = new ConnectionViewModel();
  @Param scroller: Scroller = new Scroller();
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
  @Event onSelectAll: () => void = (): void => {};
  @Event onCancelSelection: () => void = (): void => {};
  @Event onSelectionAction: (kind: string) => void = (): void => {};
  @Event onBeginSelection: (entry: NasFileEntry) => void = (): void => {};
  @Event onSort: () => void = (): void => {};
  @Local private grid: boolean = false;
  private breadcrumbScroller: Scroller = new Scroller();
  @Local private refreshing: boolean = false;
  @Local private refreshedCount: number | undefined = undefined;

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
      Row({ space: 8 }) {
        ForEach(workbenchBreadcrumbs(this.model.directory), (crumb: WorkbenchBreadcrumb): void => {
          Button(crumb.title).type(ButtonType.Normal).constraintSize({ minHeight: 40 }).fontSize(14)
            .padding({ left: 0, right: 0, top: 8, bottom: 8 }).backgroundColor(Color.Transparent)
            .fontColor(crumb.path === this.model.directory ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
            .enabled(!this.model.busy && crumb.path !== this.model.directory)
            .onClick((): void => { this.onNavigateBreadcrumb(crumb.path); })
          if (crumb.path !== this.model.directory) {
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(10).fontColor([$r('sys.color.font_tertiary')])
              .accessibilityLevel('no')
          }
        }, (crumb: WorkbenchBreadcrumb): string => crumb.path)
      }
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').height(40).align(Alignment.Start)
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
  selectionBar() {
    if (this.selecting) {
      Column() {
        Row() {
          Text($r('app.string.file_selected_count', this.selectedPaths.length)).layoutWeight(1)
            .fontSize(14).fontColor($r('sys.color.font_secondary'))
          Button($r('app.string.file_select_loaded')).buttonStyle(ButtonStyleMode.TEXTUAL)
            .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).enabled(!this.model.busy).onClick(this.onSelectAll)
          Button($r('app.string.action_cancel')).buttonStyle(ButtonStyleMode.TEXTUAL)
            .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).enabled(!this.model.busy).onClick(this.onCancelSelection)
        }.width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          if (this.model.supports('SYNO.FileStation.Download')) {
            Button($r('app.string.preview_download')).height(48).buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(this.selectedPaths.length > 0 && this.model.entries.filter((entry: NasFileEntry): boolean => this.selectedPaths.includes(entry.path)).every((entry: NasFileEntry): boolean => !entry.isDirectory))
              .onClick((): void => { this.onSelectionAction('download'); })
          }
          if (this.model.supports('SYNO.FileStation.Sharing')) {
            Button($r('app.string.preview_share')).height(48).buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(this.selectedPaths.length > 0 && this.model.extensions.canWrite('fileSharing'))
              .onClick((): void => { this.onSelectionAction('share'); })
          }
          if (this.model.supports('SYNO.FileStation.CopyMove')) {
            Button($r('app.string.file_copy')).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .enabled(!this.model.busy && this.selectedPaths.length > 0).onClick((): void => { this.onSelectionAction('copy'); })
            Button($r('app.string.file_move')).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .enabled(!this.model.busy && this.selectedPaths.length > 0).onClick((): void => { this.onSelectionAction('move'); })
          }
          if (this.model.supports('SYNO.FileStation.Delete')) {
            Button($r('app.string.file_delete')).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .enabled(!this.model.busy && this.selectedPaths.length > 0).onClick((): void => { this.onSelectionAction('delete'); })
          }
        }.width('100%')
      }.width('100%')
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

  private entryMenu(entry: NasFileEntry): MenuElement[] {
    const menu: MenuElement[] = [{ value: '查看详情', action: (): void => { this.onOpenForm('detail', entry); } }];
    if (this.model.supports('SYNO.FileStation.Sharing') && this.model.extensions.canWrite('fileSharing')) {
      menu.push({ value: '创建分享链接', action: (): void => { this.onOpenForm('share', entry); } });
    }
    if (!entry.isDirectory && this.model.supports('SYNO.FileStation.Download') && this.model.queue.ready && !this.model.queue.busy) {
      menu.push({ value: '下载到本机', action: (): void => { this.onOpenForm('download', entry); } });
    }
    if (this.model.directory.length > 0) {
      if (this.model.supports('SYNO.FileStation.CopyMove')) {
        menu.push({ value: '复制到…', action: (): void => { this.onOpenForm('copy', entry); } });
        menu.push({ value: '移动到…', action: (): void => { this.onOpenForm('move', entry); } });
      }
      if (this.model.supports('SYNO.FileStation.Rename')) {
        menu.push({ value: '重命名', action: (): void => { this.onOpenForm('rename', entry); } });
      }
      if (this.model.supports('SYNO.FileStation.Delete')) {
        menu.push({ value: '删除', action: (): void => { this.onOpenForm('delete', entry); } });
      }
    }
    return menu;
  }

  @Builder
  emptyState(icon: Resource, title: string, description: string = '') {
    WorkbenchEmptyState({ icon: icon, title: title, description: description })
  }

  @Builder
  listHeader() {
    Column({ space: 8 }) {
      if (this.refreshedCount !== undefined) {
        Text(this.refreshedCount.toString() + ' 项').fontSize(12).fontColor($r('sys.color.font_secondary'))
          .width('100%').height(32).textAlign(TextAlign.Center)
      }
      this.destinationBar()
      this.pickerBar()
      WorkbenchNotice({ text: this.errorText, warning: true })
      if (this.errorText.length === 0) { WorkbenchNotice({ text: this.model.actionNotice }) }
    }.width('100%').padding({ top: 4, bottom: 8 }).alignItems(HorizontalAlign.Start)
  }

  @Builder
  fileList() {
    Column() {
      Column({ space: 4 }) {
        if (this.model.directory.length > 0 || this.pickerMode.length > 0) { this.breadcrumbBar() }
        if (this.pickerMode.length === 0) {
          Row() {
            Blank()
            Button() { SymbolGlyph($r('sys.symbol.slider_horizontal_2')).fontSize(20).fontColor([$r('sys.color.icon_secondary')]) }
              .width(48).height(40).backgroundColor($r('app.color.workbench_subtle')).margin({ right: 8 })
              .accessibilityText($r('app.string.file_sort')).onClick(this.onSort)
            Button() { SymbolGlyph(this.grid ? $r('sys.symbol.list_bullet') : $r('sys.symbol.square_grid_2x2'))
              .fontSize(20).fontColor([$r('sys.color.icon_secondary')]) }
              .width(48).height(40).backgroundColor($r('app.color.workbench_subtle'))
              .accessibilityText(this.grid ? $r('app.string.view_list') : $r('app.string.view_grid'))
              .onClick((): void => { this.grid = !this.grid; })
          }.width('100%').constraintSize({ minHeight: 48 })
        }
      }.width('100%').padding({ left: 16, right: 16, top: this.topInset })
    Stack({ alignContent: Alignment.Bottom }) {
      Refresh({ refreshing: $$this.refreshing }) {
      List({ space: 0, scroller: this.scroller }) {
        ListItemGroup({ header: this.listHeader }) {
        if (!this.model.busy && this.visibleEntries().length === 0 && this.model.errorText.length === 0 && this.errorText.length === 0) {
          ListItem() {
            this.emptyState($r('sys.symbol.folder'), this.pickerMode.length > 0 ? '没有可浏览的文件夹' : '此位置为空',
              this.pickerMode.length > 0 ? '当前目录下没有可选择的子文件夹。' : '当前目录没有可显示的文件或文件夹。')
          }
        }
        ForEach(this.visibleEntries(), (entry: NasFileEntry, index: number): void => {
          ListItem() {
            Row() {
              if (this.selecting) {
                Checkbox().select(this.selectedPaths.includes(entry.path)).enabled(!this.model.busy)
                  .margin({ left: 16, right: 0 }).width(24).height(24).accessibilityText(entry.name)
                  .onChange((selected: boolean): void => {
                    if (selected !== this.selectedPaths.includes(entry.path)) { this.onToggleSelection(entry); }
                  })
              }
              WorkbenchEntryRow({ title: entry.name, grid: this.grid && this.pickerMode.length === 0,
                subtitle: (entry.isDirectory ? '文件夹' : workbenchBytes(entry.bytes)) +
                  (entry.modifiedAt === undefined ? '' : ' · ' + workbenchRelativeDate(entry.modifiedAt / 1000)),
                icon: entry.isDirectory ? $r('sys.symbol.folder') : $r('sys.symbol.doc'),
                iconColor: entry.isDirectory ? $r('sys.color.icon_emphasize') : $r('sys.color.font_secondary'),
                available: !this.model.busy, menuAvailable: !this.model.busy,
                contentInset: this.selecting ? 12 : 16, showDivider: index < this.visibleEntries().length - 1,
                menu: this.pickerMode.length === 0 && !this.selecting ? this.entryMenu(entry) : [],
                onLongPress: (): void => {
                  if (this.pickerMode.length === 0 && !this.selecting) { interactionFeedback(); this.onBeginSelection(entry); }
                },
                onOpen: (): void => {
                  if (this.selecting) { this.onToggleSelection(entry); }
                  else if (entry.isDirectory) { this.model.openDirectory(entry); }
                  else if (this.wide && this.pickerMode.length === 0) {
                    this.inspected = entry;
                    this.detailStack.replacePathByName('detail', undefined);
                    if (/\.(?:jpe?g|png|gif|webp|bmp|heic|heif|tiff?|dng|avif|avis)$/i.test(entry.name)) { this.model.fileOriginal.openFile(entry); }
                  }
                  else if (/\.(?:jpe?g|png|gif|webp|bmp|heic|heif|tiff?|dng|avif|avis)$/i.test(entry.name)) { this.onOpenImage(entry); }
                  else { this.onOpenForm('detail', entry); }
                } }).layoutWeight(1)
            }.width('100%').backgroundColor($r('app.color.workbench_surface'))
          }.borderRadius(this.grid ? WorkbenchMetrics.cardRadius : 0).clip(true)
        }, (entry: NasFileEntry): string => this.model.address + ':' + this.model.account + ':' + entry.path)
        if (this.model.listLoading === 'more') {
          ListItem() {
            Row({ space: 8 }) {
              LoadingProgress().width(24).height(24).accessibilityText($r('app.string.file_list_loading'))
            }.width('100%').height(50).justifyContent(FlexAlign.Center)
          }
        }
        if (!this.model.filesMore && this.errorText.length === 0 && this.visibleEntries().length > 0) {
          ListItem() {
            Text($r('app.string.file_total_count', this.pickerMode.length > 0 ? this.visibleEntries().length : this.model.total))
              .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%').height(40).textAlign(TextAlign.Center)
          }
        }
        }
      }.width('100%').height('100%').scrollBar(BarState.Auto).contentEndOffset(this.bottomInset + (this.selecting ? 128 : 0))
        .lanes(this.grid && this.pickerMode.length === 0 && this.visibleEntries().length > 0 ? 2 : 1)
        .padding({ left: this.grid ? WorkbenchMetrics.pageMargin : 0, right: this.grid ? WorkbenchMetrics.pageMargin : 0 })
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
      if (this.selecting) {
        Column() { this.selectionBar() }.padding(8).margin({ left: 16, right: 16, bottom: this.bottomInset })
          .borderRadius(24).backgroundColor($r('app.color.workbench_surface_elevated'))
          .shadow({ radius: 16, color: '#1F000000', offsetY: 4 })
      }
    }.width('100%').layoutWeight(1)
    }.width('100%').height('100%')
      .backgroundColor(this.grid ? $r('app.color.workbench_background') : $r('app.color.workbench_surface'))
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
      Navigation(this.detailStack) { this.fileList() }.mode(NavigationMode.Split).navBarWidth('40%')
        .hideTitleBar(true).hideToolBar(true).navDestination(this.fileDetail).width('100%').height('100%')
    } else { this.fileList() }
  }
}
