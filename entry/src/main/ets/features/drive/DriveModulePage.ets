import { fileUri } from '@kit.CoreFileKit';
import { uiMaterial } from '@kit.ArkUI';
import { DriveEntry, DriveEntryKind, DriveView, driveViewLabel, driveEntryRenderKey } from '../../core/domain/DriveProtocol';
import { driveActionAllowed } from '../../core/domain/DriveActionProtocol';
import type { DriveAction } from '../../core/domain/DriveActionProtocol';
import { canPreviewDriveOriginal } from '../../core/domain/DriveOriginalProtocol';
import { driveFileLinkAllowed } from '../../core/domain/DriveCollaborationProtocol';
import { ConnectionViewModel } from '../connection/ConnectionViewModel';
import { WorkbenchMetrics, WorkbenchNotice, WorkbenchSectionTitle, WorkbenchActionRow,
  WorkbenchEntryRow, WorkbenchInfoRow } from '../workbench/WorkbenchUi';
import { workbenchBytes } from '../workbench/WorkbenchPresentation';
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
  @Param searchVisible: boolean = false;
  @Param moreView: string = '';
  @Param moreViews: DriveView[] = [];
  @Event onSelectMore: (view: DriveView) => void = (_view: DriveView): void => {};
  @Event onBackToMore: () => void = (): void => {};
  @Event onExitSearch: () => void = (): void => {};
  @Event onOpenTransfers: () => void = (): void => {};
  @Event onUploadTo: (entry: DriveEntry) => void = (_entry: DriveEntry): void => {};
  @Event onOpenAction: (action: DriveAction, entry?: DriveEntry) => void =
    (_action: DriveAction, _entry?: DriveEntry): void => {};
  @Event onOpenActionRecords: () => void = (): void => {};
  @Event onOpenOriginal: (entry: DriveEntry) => void = (_entry: DriveEntry): void => {};
  @Event onOpenLinks: (entry?: DriveEntry) => void = (_entry?: DriveEntry): void => {};
  @Event onOpenNotifications: () => void = (): void => {};
  @Event onCustomize: () => void = (): void => {};
  @Local private detailVisible: boolean = false;
  @Local private detailEntry: DriveEntry | undefined = undefined;
  private sheetMaterial: uiMaterial.Material =
    new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THICK });
  private sheetMaterialAvailable: boolean = uiMaterial.isImmersiveMaterialSupported();
  private driveSearchController: SearchController = new SearchController();

  private canRenderEntries(): boolean {
    return this.active && (this.model.drive.view === this.expectedView ||
      this.tabId === 'mydrive' && this.searchVisible && this.model.drive.view === DriveView.Search);
  }

  private supportedMoreViews(): DriveView[] {
    return this.moreViews.filter((view: DriveView): boolean =>
      [DriveView.Recent, DriveView.Starred, DriveView.SharedWithMe, DriveView.SharedWithOthers,
        DriveView.Trash].includes(view) && this.model.drive.supportsView(view));
  }

  private refreshDrive(): void {
    if (this.model.busy || this.model.drive.busy) { return; }
    this.model.driveThumbnails.retryVisible();
    this.model.drive.reload();
  }

  private async exitDriveSearch(): Promise<void> {
    this.driveSearchController.stopEditing();
    if (this.model.drive.busy) { return; }
    if (this.model.drive.view === DriveView.Search) {
      await this.model.drive.exitSearch();
      if (this.model.drive.view === DriveView.Search) { return; }
    }
    this.onExitSearch();
  }

  @Builder
  driveSearch() {
    Row({ space: 8 }) {
      Search({ value: this.model.drive.searchText, placeholder: this.model.drive.searchPlaceholder(),
        controller: this.driveSearchController })
        .searchButton('搜索').maxLength(256).layoutWeight(1).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
        .enabled(this.canRenderEntries() && !this.model.busy && !this.model.drive.busy && this.model.drive.supportsView(DriveView.Search))
        .onChange((value: string): void => { this.model.drive.searchText = value; })
        .onSubmit((value: string): void => {
          this.driveSearchController.stopEditing(); this.model.drive.search(value);
        })
      Button('取消').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
        .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.busy && !this.model.drive.busy)
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
            .fontColor(index === this.model.drive.trail.length - 1 ? $r('sys.color.font_primary') : $r('sys.color.font_emphasize'))
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
    Column({ space: 8 }) {
      SymbolGlyph(icon).fontSize(32).fontColor([$r('sys.color.font_tertiary')])
      Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
      Text(description).fontSize(14).fontColor($r('sys.color.font_secondary')).textAlign(TextAlign.Center)
    }.width('100%').padding({ top: 32, bottom: 32, left: 24, right: 24 })
  }

  @Builder
  driveFileList() {
    List({ space: 0, scroller: this.scroller }) {
      ListItem() {
        Column({ space: 4 }) {
          if (this.tabId === 'more') {
            Button() {
              SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20).fontColor([$r('sys.color.icon_primary')])
            }.width(48).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).type(ButtonType.Normal)
              .padding(0).backgroundColor(Color.Transparent).accessibilityText('返回更多')
              .enabled(!this.model.busy && !this.model.drive.busy).onClick(this.onBackToMore)
          }
          if (this.tabId === 'mydrive' && this.searchVisible) { this.driveSearch() }
          if (this.canRenderEntries()) {
            this.driveBreadcrumb()
          }
          this.driveNotices()
          if (this.model.drive.busy) {
            Row({ space: 12 }) {
              LoadingProgress().width(24).height(24)
              Text('正在读取 Drive 内容…').fontSize(14).fontColor($r('sys.color.font_secondary'))
            }.width('100%').padding(12)
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
          .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin,
            top: this.topInset + 4, bottom: 4 })
      }
      if (this.canRenderEntries()) {
        if (!this.model.drive.busy && this.model.drive.entries.length === 0) {
          ListItem() {
            if (this.model.drive.errorText.length > 0) {
              this.emptyState($r('sys.symbol.exclamationmark_circle'), 'Drive 内容未能读取', '请使用标题栏的刷新重试。')
            } else if (this.model.drive.view === DriveView.Search && this.model.drive.trail.length === 1) {
              this.emptyState($r('sys.symbol.magnifyingglass'), '没有搜索结果', '请尝试其他关键词。')
            } else {
              this.emptyState($r('sys.symbol.folder'), '此位置为空', '当前列表没有可显示的项目。')
            }
          }
        }
        ForEach(this.model.drive.entries, (entry: DriveEntry): void => {
          ListItem() {
            Row() {
              WorkbenchEntryRow({ title: entry.name, subtitle: this.driveRowSubtitle(entry),
                thumbnail: this.model.driveThumbnails.path(entry).length > 0 ?
                  fileUri.getUriFromPath(this.model.driveThumbnails.path(entry)) : '',
                icon: entry.kind === DriveEntryKind.Folder ? $r('sys.symbol.folder') : $r('sys.symbol.doc'),
                iconColor: entry.kind === DriveEntryKind.Folder ? $r('sys.color.icon_emphasize') : $r('sys.color.font_secondary'),
                available: !this.model.busy && !this.model.drive.busy && entry.capabilities.canRead &&
                  this.model.drive.view !== DriveView.Trash &&
                  (entry.kind === DriveEntryKind.Folder || entry.capabilities.canDownload &&
                    this.model.driveTransfers.ready && !this.model.driveTransfers.busy),
                onOpen: (): void => { this.openDriveEntry(entry); } }).layoutWeight(1)
              if (this.driveEntryMenu(entry).length > 0) {
                Button() {
                  SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(32)
                    .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
                    .fontColor([$r('sys.color.icon_primary'), Color.Transparent])
                    .accessibilityLevel('no')
                }.width(48).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).type(ButtonType.Normal).padding(0)
                  .backgroundColor(Color.Transparent)
                  .enabled(!this.model.busy && !this.model.drive.busy)
                  .bindMenu(this.driveEntryMenu(entry)).accessibilityText(entry.name + '，操作菜单')
              }
            }.width('100%')
          }
          .onVisibleAreaChange([0], (visible: boolean, ratio: number): void => {
            this.model.driveThumbnails.setVisible(entry, visible && ratio > 0 && this.canRenderEntries() &&
              this.model.drive.view !== DriveView.Trash);
          })
          .onDisAppear((): void => { this.model.driveThumbnails.setVisible(entry, false); })
        }, (entry: DriveEntry): string => driveEntryRenderKey(entry))
        ListItem() {
          Row({ space: 8 }) {
            Button('上一页').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(!this.model.busy && !this.model.drive.busy && this.model.drive.pageOffset > 0)
              .onClick((): void => { this.model.drive.previousPage(); })
            Text(this.driveCountText()).fontSize(12).fontColor($r('sys.color.font_secondary'))
              .layoutWeight(1).textAlign(TextAlign.Center)
            Button('下一页').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(!this.model.busy && !this.model.drive.busy && this.model.drive.more())
              .onClick((): void => { this.model.drive.nextPage(); })
          }.width('100%').padding({ top: 4, bottom: 4 })
        }
      } else if (!this.model.drive.busy) {
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
    }.width('100%').height('100%').scrollBar(BarState.Auto).contentEndOffset(this.bottomInset)
  }

  @Builder
  driveMore() {
    Scroll(this.scroller) {
      Column({ space: WorkbenchMetrics.sectionGap }) {
        if (this.supportedMoreViews().length > 0) {
          WorkbenchSectionTitle({ title: '文件视图' })
          Column() {
            ForEach(this.supportedMoreViews(), (view: DriveView): void => {
              WorkbenchActionRow({ label: driveViewLabel(view), icon: this.driveViewIcon(view),
                available: !this.model.busy && !this.model.drive.busy,
                onAction: (): void => { this.onSelectMore(view); } })
            }, (view: DriveView): string => view)
          }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        }
        if (this.model.driveTransfers.available || this.model.driveTransfers.items.length > 0 ||
          this.model.driveActions.available || this.model.driveActions.items.length > 0 ||
          this.model.driveSharing.available || this.model.driveSharing.items.length > 0 || this.model.driveNotifications.available) {
          WorkbenchSectionTitle({ title: '文件管理' })
          Column() {
            if (this.model.driveTransfers.available || this.model.driveTransfers.items.length > 0) {
              WorkbenchActionRow({ label: 'Drive 传输', icon: $r('sys.symbol.arrow_down_circle'),
                onAction: (): void => { this.openDriveTransfers(); } })
            }
            if (this.model.driveActions.available || this.model.driveActions.items.length > 0) {
              WorkbenchActionRow({ label: '文件操作记录', icon: $r('sys.symbol.doc_text'), onAction: this.onOpenActionRecords })
            }
            if (this.model.driveSharing.available || this.model.driveSharing.items.length > 0) {
              WorkbenchActionRow({ label: '文件链接', icon: $r('sys.symbol.link'), available: !this.model.driveSharing.busy,
                onAction: (): void => { this.openDriveLinks(); } })
            }
            if (this.model.driveNotifications.available) {
              WorkbenchActionRow({ label: '通知', icon: $r('sys.symbol.bell'), onAction: this.onOpenNotifications })
            }
          }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        }
        WorkbenchSectionTitle({ title: '设置' })
        Column() {
          WorkbenchActionRow({ label: '底栏设置', icon: $r('sys.symbol.slider_horizontal_2'), onAction: this.onCustomize })
          if (this.model.drive.supportsView(this.model.drive.view)) {
            WorkbenchActionRow({ label: '刷新', icon: $r('sys.symbol.arrow_2_circlepath'),
              showChevron: false,
              available: !this.model.busy && !this.model.drive.busy, onAction: (): void => { this.refreshDrive(); } })
          }
        }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        this.driveNotices()
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin,
          top: this.topInset + 8, bottom: this.bottomInset })
    }.width('100%').height('100%').scrollBar(BarState.Auto).align(Alignment.Top)
  }

  private driveRowSubtitle(entry: DriveEntry): string {
    return entry.kind === DriveEntryKind.Folder ? '文件夹' : workbenchBytes(entry.sizeBytes);
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

  private driveCountText(): string {
    const total = this.model.drive.total;
    if (this.model.drive.entries.length === 0) { return '0 项'; }
    const range = (this.model.drive.pageOffset + 1).toString() + '–' +
      (this.model.drive.pageOffset + this.model.drive.entries.length).toString();
    return total === undefined ? '第 ' + range + ' 项' : range + ' / ' + total.toString() + ' 项';
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
      menu.push({ value: '下载到本机', action: (): void => { this.model.driveTransfers.download(entry); this.openDriveTransfers(); } });
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

  private openDriveTransfers(): void { this.onOpenTransfers(); }

  private openDriveEntry(entry: DriveEntry): void {
    if (this.model.drive.busy || !entry.capabilities.canRead) { return; }
    if (entry.kind === DriveEntryKind.Folder) { this.model.drive.openFolder(entry); return; }
    if (this.model.drive.view === DriveView.Trash || !entry.capabilities.canDownload) { return; }
    if (canPreviewDriveOriginal(entry)) { this.openDriveOriginal(entry); return; }
    this.model.driveTransfers.download(entry);
    this.openDriveTransfers();
  }

  private openDriveOriginal(entry: DriveEntry): void { this.onOpenOriginal(entry); }

  private openDriveLinks(entry?: DriveEntry): void { this.onOpenLinks(entry); }

  @Builder
  entryDetails() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.detailEntry !== undefined) {
          Text(this.detailEntry.name).fontSize(18).fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary')).width('100%')
          WorkbenchInfoRow({ label: '类型', value: this.detailEntry.kind === DriveEntryKind.Folder ? '文件夹' : '文件' })
          if (this.detailEntry.displayPath !== undefined && this.detailEntry.displayPath.length > 0) {
            WorkbenchInfoRow({ label: '位置', value: this.detailEntry.displayPath })
          }
          if (this.detailEntry.kind !== DriveEntryKind.Folder && this.detailEntry.sizeBytes !== undefined) {
            WorkbenchInfoRow({ label: '大小', value: workbenchBytes(this.detailEntry.sizeBytes) })
          }
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
      .backgroundColor($r('app.color.workbench_surface'))
      .bindSheet($$this.detailVisible, this.entryDetails(), {
        height: SheetSize.MEDIUM, detents: [SheetSize.MEDIUM, SheetSize.LARGE], title: { title: '文件详情' },
        showClose: true, backgroundColor: this.sheetMaterialAvailable ? Color.Transparent : $r('app.color.workbench_surface'),
        systemMaterial: this.sheetMaterial
      })
  }
}
