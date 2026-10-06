import { NasFileEntry } from '../../core/domain/DsmProtocol';
import { ConnectionViewModel } from '../connection/ConnectionViewModel';
import { WorkbenchBreadcrumb, workbenchBreadcrumbs, workbenchBytes } from '../workbench/WorkbenchPresentation';
import { WorkbenchMetrics, WorkbenchIconTile, WorkbenchNotice } from '../workbench/WorkbenchUi';

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
            .fontColor(crumb.path === this.model.directory ? $r('sys.color.font_primary') : $r('sys.color.font_emphasize'))
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

  private fileCountText(): string {
    return this.model.total === 0 ? '0 项' : (this.model.pageOffset + 1).toString() + '–' +
      (this.model.pageOffset + this.model.entries.length).toString() + ' / ' + this.model.total.toString() + ' 项';
  }

  @Builder
  emptyState(icon: Resource, title: string) {
    Column({ space: 8 }) {
      SymbolGlyph(icon).fontSize(32).fontColor([$r('sys.color.font_tertiary')])
      Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
    }.width('100%').padding({ top: 32, bottom: 32, left: 24, right: 24 })
  }

  build() {
    Column() {
      List({ space: 0, scroller: this.scroller }) {
        ListItem() {
          Column({ space: 8 }) {
            this.breadcrumbBar()
            this.destinationBar()
            this.pickerBar()
            WorkbenchNotice({ text: this.errorText, warning: true })
            if (this.errorText.length === 0) { WorkbenchNotice({ text: this.model.actionNotice }) }
            if (this.model.busy) {
              Row({ space: 12 }) {
                LoadingProgress().width(24).height(24)
                Text('正在处理…').fontSize(14).fontColor($r('sys.color.font_secondary'))
              }.width('100%').padding(12)
            }
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
            Column() {
              Row({ space: 4 }) {
                Button() {
                  Row({ space: 12 }) {
                    WorkbenchIconTile({ icon: entry.isDirectory ? $r('sys.symbol.folder') : $r('sys.symbol.doc'),
                      iconSize: 22, tileSize: 40, tileRadius: 12,
                      iconColor: entry.isDirectory ? $r('sys.color.icon_emphasize') : $r('sys.color.font_secondary'),
                      tileColor: $r('app.color.workbench_subtle') })
                    Column({ space: 2 }) {
                      Text(entry.name).fontSize(16).fontWeight(FontWeight.Medium).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                        .fontColor($r('sys.color.font_primary')).width('100%')
                      Text(entry.isDirectory ? '文件夹' : workbenchBytes(entry.bytes))
                        .fontSize(14).fontColor($r('sys.color.font_secondary'))
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  }.width('100%').padding({ top: 8, bottom: 8, right: 8 })
                }.layoutWeight(1).type(ButtonType.Normal).padding(0).constraintSize({ minHeight: 64 })
                  .backgroundColor(Color.Transparent).enabled(!this.model.busy)
                  .onClick((): void => {
                    if (entry.isDirectory) { this.model.openDirectory(entry); }
                    else { this.onOpenForm('detail', entry); }
                  }).accessibilityText((entry.isDirectory ? '文件夹，' : '文件，') + entry.name)
                if (this.pickerMode.length === 0) {
                  Button() {
                    SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(32)
                      .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
                      .fontColor([$r('sys.color.font_secondary'), Color.Transparent])
                      .accessibilityLevel('no')
                  }
                    .width(48).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).type(ButtonType.Normal).padding(0).backgroundColor(Color.Transparent)
                    .enabled(!this.model.busy).onClick((): void => { this.onOpenForm('actions', entry); })
                    .accessibilityText(entry.name + '，更多操作')
                }
              }.width('100%').constraintSize({ minHeight: 64 }).padding({ left: 16, right: 8 })
              Divider().color($r('app.color.workbench_divider')).margin({ left: 68, right: 16 })
            }.width('100%').backgroundColor($r('app.color.workbench_surface'))
          }
        }, (entry: NasFileEntry): string => this.model.address + ':' + this.model.account + ':' + entry.path)
        if (this.model.pageOffset > 0 || this.model.pageOffset + this.model.entries.length < this.model.total) {
          ListItem() {
            Row({ space: 8 }) {
              Button('上一页').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
                .enabled(!this.model.busy && this.model.pageOffset > 0).onClick((): void => { this.model.previousPage(); })
              Text(this.fileCountText()).fontSize(12).fontColor($r('sys.color.font_secondary'))
                .layoutWeight(1).textAlign(TextAlign.Center)
              Button('下一页').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
                .enabled(!this.model.busy && this.model.pageOffset + this.model.entries.length < this.model.total)
                .onClick((): void => { this.model.nextPage(); })
            }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
          }
        }
      }.width('100%').height('100%').scrollBar(BarState.Auto).contentEndOffset(this.bottomInset)
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.workbench_surface'))
  }
}
