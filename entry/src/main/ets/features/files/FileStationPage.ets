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
  @Param errorText: string = '';
  @Param pendingEntry: NasFileEntry | undefined = undefined;
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
    if (this.pendingEntry !== undefined) {
      Column({ space: 4 }) {
        Text((this.pendingOperation === 'copy' ? '复制“' : '移动“') + this.pendingEntry.name + '”')
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
      List({ space: 0, scroller: this.scroller }) {
        ListItem() {
          Column({ space: 8 }) {
            this.breadcrumbBar()
            this.destinationBar()
            this.pickerBar()
            WorkbenchNotice({ text: this.errorText, warning: true })
            if (this.errorText.length === 0) { WorkbenchNotice({ text: this.model.actionNotice }) }
          }.width('100%').padding({ left: 16, right: 16, top: this.topInset + 4, bottom: 8 })
            .alignItems(HorizontalAlign.Start)
        }
        if (!this.model.busy && this.visibleEntries().length === 0 && this.model.errorText.length === 0 && this.errorText.length === 0) {
          ListItem() {
            this.emptyState($r('sys.symbol.folder'), this.pickerMode.length > 0 ? '没有可浏览的文件夹' : '此位置为空')
          }
        }
        ForEach(this.visibleEntries(), (entry: NasFileEntry): void => {
          ListItem() {
            WorkbenchEntryRow({ title: entry.name, subtitle: entry.isDirectory ? '文件夹' : workbenchBytes(entry.bytes),
              icon: entry.isDirectory ? $r('sys.symbol.folder') : $r('sys.symbol.doc'),
              iconColor: entry.isDirectory ? $r('sys.color.icon_emphasize') : $r('sys.color.font_secondary'),
              available: !this.model.busy, menuAvailable: !this.model.busy,
              menu: this.pickerMode.length === 0 ? this.entryMenu(entry) : [],
              onOpen: (): void => {
                if (entry.isDirectory) { this.model.openDirectory(entry); }
                else if (/\.(?:jpe?g|png|gif|webp|bmp|heic|heif|tiff?|dng|avif|avis)$/i.test(entry.name)) { this.onOpenImage(entry); }
                else { this.onOpenForm('detail', entry); }
              } })
          }
        }, (entry: NasFileEntry): string => this.model.address + ':' + this.model.account + ':' + entry.path)
        if (this.model.entries.length > 0) {
          ListItem() {
            Row({ space: 8 }) {
              if (this.model.listLoading === 'more') {
                LoadingProgress().width(24).height(24).accessibilityText($r('app.string.file_list_loading'))
              } else {
                Text(this.model.entries.length.toString() + ' / ' + this.model.total.toString() + ' 项')
                  .fontSize(12).fontColor($r('sys.color.font_secondary'))
              }
            }.width('100%').height(50).justifyContent(FlexAlign.Center)
          }
        }
      }.width('100%').height('100%').scrollBar(BarState.Auto).contentEndOffset(this.bottomInset)
        .onReachEnd((): void => {
          if (this.model.directoryErrorText.length === 0 && !this.pickerBusy) { this.model.nextPage(); }
        })
      if (this.model.listLoading === 'content') {
        Column() {
          LoadingProgress().width(40).height(40).accessibilityText($r('app.string.file_list_loading'))
        }.width('100%').height('100%').padding({ top: this.topInset, bottom: this.bottomInset })
          .justifyContent(FlexAlign.Center).hitTestBehavior(HitTestMode.None)
      }
    }.width('100%').height('100%')
      .backgroundColor($r('app.color.workbench_surface'))
  }
}
