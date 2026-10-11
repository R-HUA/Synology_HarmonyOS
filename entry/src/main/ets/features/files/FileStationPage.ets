import { NasFileEntry } from '../../core/domain/DsmProtocol';
import { ConnectionViewModel } from '../connection/ConnectionViewModel';
import { WorkbenchBreadcrumb, workbenchBreadcrumbs, workbenchBytes } from '../workbench/WorkbenchPresentation';
import { WorkbenchMetrics, WorkbenchEntryRow, WorkbenchNotice } from '../workbench/WorkbenchUi';

/** File Station 列表复用于文件页和独立的目录选择页，页面级工具由宿主标题栏承载。 */
@ComponentV2
export struct FileStationPage {
  @Param model: ConnectionViewModel = new ConnectionViewModel();
  @Param scroller: Scroller = new Scroller();
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param active: boolean = true;
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
  @Local private refreshing: boolean = false;
  @Local private refreshedCount: number | undefined = undefined;

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
    Scroll() {
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
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
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
        Row({ space: 12 }) {
          if (this.model.supports('SYNO.FileStation.CopyMove')) {
            Button($r('app.string.file_copy')).layoutWeight(1).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .enabled(!this.model.busy && this.selectedPaths.length > 0).onClick((): void => { this.onSelectionAction('copy'); })
            Button($r('app.string.file_move')).layoutWeight(1).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .enabled(!this.model.busy && this.selectedPaths.length > 0).onClick((): void => { this.onSelectionAction('move'); })
          }
          if (this.model.supports('SYNO.FileStation.Delete')) {
            Button($r('app.string.file_delete')).layoutWeight(1).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
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
  emptyState(icon: Resource, title: string) {
    Column({ space: 8 }) {
      SymbolGlyph(icon).fontSize(32).fontColor([$r('sys.color.font_tertiary')])
      Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
    }.width('100%').padding({ top: 32, bottom: 32, left: 24, right: 24 })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Refresh({ refreshing: $$this.refreshing }) {
      List({ space: 0, scroller: this.scroller }) {
        ListItem() {
          Column({ space: 8 }) {
            if (this.refreshedCount !== undefined) {
              Text(this.refreshedCount.toString() + ' 项').fontSize(12).fontColor($r('sys.color.font_secondary'))
                .width('100%').height(32).textAlign(TextAlign.Center)
            }
            this.breadcrumbBar()
            this.destinationBar()
            this.pickerBar()
            this.selectionBar()
            WorkbenchNotice({ text: this.errorText, warning: true })
            if (this.errorText.length === 0) { WorkbenchNotice({ text: this.model.actionNotice }) }
          }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 8 })
            .alignItems(HorizontalAlign.Start)
        }
        if (!this.model.busy && this.visibleEntries().length === 0 && this.model.errorText.length === 0 && this.errorText.length === 0) {
          ListItem() {
            this.emptyState($r('sys.symbol.folder'), this.pickerMode.length > 0 ? '没有可浏览的文件夹' : '此位置为空')
          }
        }
        ForEach(this.visibleEntries(), (entry: NasFileEntry): void => {
          ListItem() {
            Row() {
              if (this.selecting) {
                Checkbox().select(this.selectedPaths.includes(entry.path)).enabled(!this.model.busy)
                  .margin({ left: 16, right: 0 }).width(24).height(24).accessibilityText(entry.name)
                  .onChange((selected: boolean): void => {
                    if (selected !== this.selectedPaths.includes(entry.path)) { this.onToggleSelection(entry); }
                  })
              }
              WorkbenchEntryRow({ title: entry.name, subtitle: entry.isDirectory ? '文件夹' : workbenchBytes(entry.bytes),
                icon: entry.isDirectory ? $r('sys.symbol.folder') : $r('sys.symbol.doc'),
                iconColor: entry.isDirectory ? $r('sys.color.icon_emphasize') : $r('sys.color.font_secondary'),
                available: !this.model.busy, menuAvailable: !this.model.busy,
                menu: this.pickerMode.length === 0 && !this.selecting ? this.entryMenu(entry) : [],
                onOpen: (): void => {
                  if (this.selecting) { this.onToggleSelection(entry); }
                  else if (entry.isDirectory) { this.model.openDirectory(entry); }
                  else if (/\.(?:jpe?g|png|gif|webp|bmp|heic|heif|tiff?|dng|avif|avis)$/i.test(entry.name)) { this.onOpenImage(entry); }
                  else { this.onOpenForm('detail', entry); }
                } }).layoutWeight(1)
            }.width('100%')
          }
        }, (entry: NasFileEntry): string => this.model.address + ':' + this.model.account + ':' + entry.path)
        if (this.model.listLoading === 'more') {
          ListItem() {
            Row({ space: 8 }) {
              LoadingProgress().width(24).height(24).accessibilityText($r('app.string.file_list_loading'))
            }.width('100%').height(50).justifyContent(FlexAlign.Center)
          }
        }
      }.width('100%').height('100%').scrollBar(BarState.Auto).contentEndOffset(this.bottomInset)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource): void => {
          if (offset > 0 && (source === ScrollSource.DRAG || source === ScrollSource.FLING)) {
            this.refreshedCount = undefined;
          }
        })
        .onReachEnd((): void => {
          if (this.model.directoryErrorText.length === 0 && !this.pickerBusy) { this.model.nextPage(); }
        })
      }.width('100%').height('100%').padding({ top: this.topInset })
        .pullToRefresh(this.active && !this.model.busy && !this.pickerBusy)
        .onRefreshing((): void => { this.refreshFiles(); })
      if (this.model.listLoading === 'content' && !this.refreshing) {
        Column() {
          LoadingProgress().width(40).height(40).accessibilityText($r('app.string.file_list_loading'))
        }.width('100%').height('100%').padding({ top: this.topInset, bottom: this.bottomInset })
          .justifyContent(FlexAlign.Center).hitTestBehavior(HitTestMode.None)
      }
    }.width('100%').height('100%')
      .backgroundColor($r('app.color.workbench_surface'))
  }
}
