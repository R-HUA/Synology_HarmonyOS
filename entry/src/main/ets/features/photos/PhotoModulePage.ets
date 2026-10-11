import { util } from '@kit.ArkTS';
import { NasPhotoAlbum, NasPhotoItem, PhotosSpace } from '../../core/domain/PhotosProtocol';
import { PhotoBackup, PhotoBackupSource } from '../backup/PhotoBackup';
import { ConnectionViewModel } from '../connection/ConnectionViewModel';
import { PhotoLibrary, PhotoLibrarySection } from './PhotoLibrary';
import { PhotoThumbnailCell } from './PhotoThumbnailCell';
import { PhotoAlbumRow, PhotoTimelineRow, photoAlbumColumns, photoAlbumRows, photoGridColumns,
  photoTimelineRows, workbenchBytes } from '../workbench/WorkbenchPresentation';
import { WorkbenchActionRow, WorkbenchChoice, WorkbenchIconTile, WorkbenchMetrics, WorkbenchNotice,
  WorkbenchSectionTitle } from '../workbench/WorkbenchUi';
import { supportsPhotoBackup } from '../workbench/ModuleNavigation';
import { ExtensionStatusPanel } from '../extensions/ExtensionStatusPanel';

@ComponentV2
export struct PhotoModulePage {
  @Param model: ConnectionViewModel = new ConnectionViewModel();
  @Param backup: PhotoBackup = new PhotoBackup();
  @Param tabId: string = 'photos';
  @Param scroller: Scroller = new Scroller();
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param active: boolean = true;
  @Param expectedSpace: PhotosSpace = PhotosSpace.Personal;
  @Param expectedSection: PhotoLibrarySection = 'timeline';
  @Param showBackupInMore: boolean = true;
  @Param showSharedInMore: boolean = false;
  @Param showTransfersInMore: boolean = true;
  @Event onSelectSpace: (space: PhotosSpace) => void = (_space: PhotosSpace): void => {};
  @Event onOpenPhoto: (item: NasPhotoItem) => void = (_item: NasPhotoItem): void => {};
  @Event onSelectBackup: () => void = (): void => {};
  @Event onChooseBackup: () => void = (): void => {};
  @Event onShowBackupContents: () => void = (): void => {};
  @Event onOpenTransfers: () => void = (): void => {};
  @Event onOpenShared: () => void = (): void => {};
  @Event onCustomize: () => void = (): void => {};
  @Local private contentWidth: number = 360;
  @Local private contentHeight: number = 640;
  @Local private timelineRows: PhotoTimelineRow[] = [];
  @Local private albumRows: PhotoAlbumRow[] = [];
  // ConnectionViewModel.photoLibrary 是只读普通字段，Monitor 从本地状态引用进入 @Trace 属性。
  @Local private observedLibrary: PhotoLibrary = new PhotoLibrary();
  private previousPhotos: NasPhotoItem[] = [];
  private previousAlbums: NasPhotoAlbum[] = [];
  private groupGeneration: number = -1;
  private photoColumns: number = 0;
  private albumColumns: number = 0;
  private viewId: string = util.generateRandomUUID();
  private mounted: boolean = false;
  private viewVisible: boolean = true;
  private scrolling: boolean = false;
  private startIndex: number = 0;
  private endIndex: number = -1;

  aboutToAppear(): void { this.observedLibrary = this.model.photoLibrary; this.mounted = true; this.syncRows(); }
  aboutToDisappear(): void { this.mounted = false; this.model.photoLibrary.releaseView(this.viewId); }

  @Monitor('active', 'expectedSpace', 'expectedSection', 'tabId', 'contentWidth', 'contentHeight', 'model',
    'observedLibrary.items', 'observedLibrary.albums', 'observedLibrary.dataGeneration')
  private rowsChanged(): void {
    if (this.observedLibrary !== this.model.photoLibrary) { this.observedLibrary = this.model.photoLibrary; }
    this.syncRows();
  }

  private syncRows(): void {
    const photos = this.visiblePhotos();
    const albums = this.visibleAlbums();
    const columns = photoGridColumns(this.contentWidth);
    const albumColumns = photoAlbumColumns(this.contentWidth);
    const generation = this.model.photoLibrary.dataGeneration;
    const replace = generation !== this.groupGeneration;
    const columnChange = this.photoColumns !== columns || this.albumColumns !== albumColumns;
    const oldPhotoRow = this.timelineRows[Math.max(0, this.startIndex - 1)];
    const oldAlbumRow = this.albumRows[Math.max(0, this.startIndex - 1)];
    const anchor = oldPhotoRow?.key ?? oldAlbumRow?.key;
    if (replace || columnChange || photos !== this.previousPhotos) {
      this.timelineRows = !replace && !columnChange && photos.length >= this.previousPhotos.length ?
        photoTimelineRows(photos.slice(this.previousPhotos.length), columns, this.timelineRows) : photoTimelineRows(photos, columns);
      this.previousPhotos = photos;
    }
    if (replace || columnChange || albums !== this.previousAlbums) {
      this.albumRows = !replace && !columnChange && albums.length >= this.previousAlbums.length ?
        photoAlbumRows(albums.slice(this.previousAlbums.length), albumColumns, this.albumRows) : photoAlbumRows(albums, albumColumns);
      this.previousAlbums = albums;
    }
    this.photoColumns = columns;
    this.albumColumns = albumColumns;
    this.groupGeneration = generation;
    if (replace) { this.startIndex = 0; this.endIndex = -1; }
    else if (columnChange && anchor !== undefined && this.mounted && this.canShowLibrary()) {
      const index = this.timelineRows.length > 0 ? this.timelineRows.findIndex((row: PhotoTimelineRow): boolean =>
        row.items.some((item: NasPhotoItem): boolean => item.space.toString() + ':' + item.id.toString() === anchor)) :
        this.albumRows.findIndex((row: PhotoAlbumRow): boolean =>
          row.albums.some((album: NasPhotoAlbum): boolean => album.space.toString() + ':' + album.id.toString() === anchor));
      if (index >= 0) { this.startIndex = index + 1; this.endIndex = -1; this.scroller.scrollToIndex(index + 1, false, ScrollAlign.START); }
    }
    this.syncDemand();
  }

  private syncDemand(): void {
    if (!this.mounted || !this.viewVisible || !this.canShowLibrary()) { this.model.photoLibrary.releaseView(this.viewId); return; }
    const photoRows = this.timelineRows;
    const rowCount = photoRows.length > 0 ? photoRows.length : this.albumRows.length;
    const columns = photoRows.length > 0 ? this.photoColumns : this.albumColumns;
    const tile = (this.contentWidth - 32 - Math.max(0, columns - 1) * 4) / Math.max(1, columns);
    const rowHeight = photoRows.length > 0 ? tile + 4 : tile + 76;
    const estimated = Math.max(1, Math.ceil(Math.max(1, this.contentHeight - this.topInset - this.bottomInset - 100) / rowHeight));
    const first = Math.max(0, this.startIndex - 1);
    const last = Math.min(rowCount - 1, this.endIndex < 0 ? first + estimated - 1 : this.endIndex - 1);
    const screen = Math.max(1, last - first + 1);
    const visible: NasPhotoItem[] = [];
    const prefetch: NasPhotoItem[] = [];
    for (let index = Math.max(0, first - 1); index <= Math.min(rowCount - 1, last + 1); index++) {
      if (index >= first && index <= last) { visible.push(...(photoRows[index]?.items ?? [])); }
      else { prefetch.push(...(photoRows[index]?.items ?? [])); }
    }
    this.model.photoLibrary.updateViewport(this.viewId, visible, prefetch, rowCount - last - 1 < screen,
      photoRows.length > 0 ? this.model.photoLibrary.items.length : this.model.photoLibrary.albums.length, this.scrolling);
  }

  private supportsSpace(space: PhotosSpace): boolean {
    return space === PhotosSpace.Personal ? this.model.supports('SYNO.Foto.Browse.Item') :
      space === PhotosSpace.Shared ? this.model.supports('SYNO.FotoTeam.Browse.Item') :
      space === PhotosSpace.WithMe && this.model.supports('SYNO.Foto.Sharing.Misc');
  }

  private supportsExpectedView(): boolean {
    if (!this.supportsSpace(this.expectedSpace)) { return false; }
    if (this.tabId === 'photos') {
      return this.expectedSection === (this.expectedSpace === PhotosSpace.WithMe ? 'albums' : 'timeline');
    }
    if (this.tabId === 'shared' && this.expectedSpace === PhotosSpace.Personal) {
      return this.expectedSection === 'sharedByMe' && this.model.supports('SYNO.Foto.Browse.Album');
    }
    return this.expectedSection === 'albums' && (this.tabId === 'albums' || this.tabId === 'shared');
  }

  private libraryMatches(): boolean {
    return this.active && this.supportsExpectedView() &&
      this.model.photoLibrary.space === this.expectedSpace &&
      this.model.photoLibrary.section === this.expectedSection;
  }

  private canShowLibrary(): boolean {
    if (!this.libraryMatches()) { return false; }
    const album = this.model.photoLibrary.selectedAlbum;
    if (album === undefined) { return true; }
    // 所有页签共用一份照片列表，相册内容只能出现在拥有相册视图的页签。
    return album.space === this.expectedSpace && (this.tabId === 'albums' || this.tabId === 'shared' ||
      this.tabId === 'photos' && this.expectedSpace === PhotosSpace.WithMe && this.expectedSection === 'albums');
  }

  private visibleAlbums(): NasPhotoAlbum[] {
    return this.canShowLibrary() && this.expectedSection !== 'timeline' &&
      this.model.photoLibrary.selectedAlbum === undefined ? this.model.photoLibrary.albums : [];
  }

  private visiblePhotos(): NasPhotoItem[] {
    return this.canShowLibrary() && (this.expectedSection === 'timeline' ||
      this.model.photoLibrary.selectedAlbum !== undefined) ? this.model.photoLibrary.items : [];
  }

  private backupSize(): string {
    return workbenchBytes(this.backup.sources.reduce((bytes: number, item: PhotoBackupSource): number => bytes + item.bytes, 0));
  }

  private photoServices(): string {
    const services: string[] = [];
    if (this.supportsSpace(PhotosSpace.Personal)) { services.push('个人照片'); }
    if (this.supportsSpace(PhotosSpace.Shared)) { services.push('共享空间'); }
    if (this.supportsSpace(PhotosSpace.WithMe)) { services.push('与我共享的相册'); }
    return services.length > 0 ? services.join('、') + '可访问。' : '当前设备未提供可用的照片服务。';
  }

  @Builder
  emptyState(title: string, description: string) {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.picture')).fontSize(32).fontColor([$r('sys.color.font_tertiary')])
      Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
      Text(description).fontSize(14).fontColor($r('sys.color.font_secondary')).textAlign(TextAlign.Center)
    }.width('100%').padding({ top: 32, bottom: 32, left: 24, right: 24 })
  }

  @Builder
  loadingState() {
    Row({ space: WorkbenchMetrics.itemGap }) {
      LoadingProgress().width(24).height(24)
      Text(this.expectedSection !== 'timeline' && (!this.canShowLibrary() || this.model.photoLibrary.selectedAlbum === undefined) ?
        '正在读取相册…' : '正在读取照片…').fontSize(14).fontColor($r('sys.color.font_secondary'))
    }.width('100%').padding(WorkbenchMetrics.itemGap)
  }

  @Builder
  backupCard() {
    if (supportsPhotoBackup((api: string): boolean => this.model.supports(api))) {
      if (this.backup.sources.length === 0) {
        Column() {
          WorkbenchActionRow({ icon: $r('sys.symbol.arrow_up_circle'), label: '备份照片与视频',
            description: this.backup.selecting ? '正在选择…' : '选择内容，确认位置后上传',
            available: this.active && !this.backup.selecting && !this.backup.submitting && !this.model.busy,
            onAction: (): void => { this.onSelectBackup(); } })
          WorkbenchNotice({ text: this.backup.errorText, warning: true })
          WorkbenchNotice({ text: this.backup.status })
        }.width('100%').borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
      } else {
        Column({ space: WorkbenchMetrics.itemGap }) {
          Row({ space: WorkbenchMetrics.itemGap }) {
            WorkbenchIconTile({ icon: $r('sys.symbol.arrow_up_circle'), iconSize: 22, tileSize: 40,
              tileRadius: WorkbenchMetrics.innerRadius, iconColor: $r('sys.color.icon_emphasize'),
              tileColor: $r('app.color.workbench_subtle') })
            Column({ space: 2 }) {
              Text('备份照片与视频').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
              Text('已选择 ' + this.backup.sources.length.toString() + ' 项 · ' + this.backupSize() + '，等待确认')
                .fontSize(14).fontColor($r('sys.color.font_secondary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%')
          WorkbenchNotice({ text: this.backup.errorText, warning: true })
          WorkbenchNotice({ text: this.backup.status })
          Flex({ wrap: FlexWrap.Wrap }) {
            Button(this.backup.selecting ? '正在选择…' : '继续选择')
              .constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .enabled(this.active && !this.backup.selecting && !this.backup.submitting && !this.model.busy)
              .onClick((): void => { this.onSelectBackup(); })
            Button('选择备份位置').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(this.active && !this.backup.submitting && !this.backup.selecting)
              .onClick((): void => { this.onChooseBackup(); })
            Button('清空选择').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(this.active && !this.backup.submitting)
              .onClick((): void => { this.backup.clear(); })
          }.width('100%')
          Text(this.backup.sources.map((item: PhotoBackupSource): string => item.name).join('、'))
            .fontSize(12).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('sys.color.font_secondary')).width('100%')
          Button('查看所选内容').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(this.active)
            .onClick((): void => { this.onShowBackupContents(); })
        }.width('100%').padding(WorkbenchMetrics.pageMargin).borderRadius(WorkbenchMetrics.innerRadius)
          .backgroundColor($r('app.color.workbench_surface'))
      }
    } else if (this.tabId === 'backup') {
      this.emptyState('照片备份暂不可用', '当前账号未提供可用的文件上传服务。')
    }
  }

  @Builder
  photoSpaceButton(space: PhotosSpace, label: string) {
    WorkbenchChoice({ label: label, selected: this.expectedSpace === space,
      available: this.active && !this.model.photoLibrary.busy,
      onSelect: (): void => {
        if (space !== this.expectedSpace) { this.onSelectSpace(space); }
      } })
  }

  @Builder
  photoCard(item: NasPhotoItem) {
    PhotoThumbnailCell({ item: item, library: this.model.photoLibrary,
      state: this.model.photoLibrary.thumbnailState(item), available: this.canShowLibrary(),
      onOpen: (photo: NasPhotoItem): void => { if (this.canShowLibrary()) { this.onOpenPhoto(photo); } } }).layoutWeight(1)
  }

  @Builder
  albumCard(album: NasPhotoAlbum) {
    Button() {
      Column({ space: 8 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.picture')).fontSize(32).fontColor([$r('sys.color.icon_emphasize')])
        }.width('100%').aspectRatio(1).borderRadius(8)
          .backgroundColor($r('app.color.workbench_accent_surface'))
        Text(album.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
          .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(album.itemCount.toString() + ' 项').fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
    }.layoutWeight(1).type(ButtonType.Normal).backgroundColor(Color.Transparent)
      .enabled(this.canShowLibrary() && !this.model.photoLibrary.busy)
      .onClick((): void => {
        if (!this.canShowLibrary()) { return; }
        this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
        this.model.photoLibrary.openAlbum(album);
      }).accessibilityText(album.name + '，' + album.itemCount.toString() + ' 项')
  }

  @Builder
  libraryHeader() {
    Column({ space: WorkbenchMetrics.sectionGap }) {
      if (this.tabId === 'shared') {
        Flex({ wrap: FlexWrap.Wrap }) {
          if (this.supportsSpace(PhotosSpace.Personal) && this.model.supports('SYNO.Foto.Browse.Album')) {
            this.photoSpaceButton(PhotosSpace.Personal,
              this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.photos_shared_by_me').id))
          }
          if (this.supportsSpace(PhotosSpace.Shared)) { this.photoSpaceButton(PhotosSpace.Shared, '共享空间') }
          if (this.supportsSpace(PhotosSpace.WithMe)) { this.photoSpaceButton(PhotosSpace.WithMe, '与我共享') }
        }.width('100%')
      }
      if (this.canShowLibrary()) {
        if (this.model.photoLibrary.selectedAlbum !== undefined) {
          Row({ space: 8 }) {
            Button() {
              SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20).fontColor([$r('sys.color.icon_primary')])
            }.width(48).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).type(ButtonType.Normal)
              .padding(0).backgroundColor(Color.Transparent).accessibilityText('返回相册').enabled(!this.model.photoLibrary.busy)
              .onClick((): void => {
                if (this.canShowLibrary()) {
                  this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
                  this.model.photoLibrary.backToLibrary();
                }
              })
            Text(this.model.photoLibrary.selectedAlbum.name).fontSize(18).fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary')).layoutWeight(1)
          }.width('100%')
        } else if (this.expectedSpace === PhotosSpace.WithMe) {
          WorkbenchSectionTitle({ title: '与你共享的相册' })
        }
        WorkbenchNotice({ text: this.model.photoLibrary.thumbnailErrorText })
        if (this.model.photoLibrary.errorText.length > 0) {
          WorkbenchNotice({ text: this.model.photoLibrary.errorText, warning: true })
          Button('重试读取').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.photoLibrary.busy)
            .onClick((): void => { if (this.canShowLibrary()) { this.model.photoLibrary.refresh(); } })
        }
        if (this.model.photoLibrary.busy) { this.loadingState() }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin })
  }

  @Builder
  moreView() {
    Column({ space: WorkbenchMetrics.sectionGap }) {
      if (this.model.extensions.hasPending('photos') || this.model.extensions.recordsError.length > 0) {
        ExtensionStatusPanel({ model: this.model.extensions, feature: 'photos' })
        if (this.model.extensions.hasPending('photos')) {
          Button($r('app.string.preview_check_task')).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.extensions.busy)
            .onClick((): void => { this.model.extensions.refreshPhotoTask(); })
        }
      }
      if (this.showBackupInMore) { this.backupCard() }
      Column() {
        if (this.showTransfersInMore) {
          WorkbenchActionRow({ icon: $r('sys.symbol.arrow_down_circle'), label: '传输任务',
            description: '查看上传与下载进度', available: this.active,
            onAction: (): void => { this.onOpenTransfers(); } })
        }
        if (this.showSharedInMore && (this.supportsSpace(PhotosSpace.Shared) || this.supportsSpace(PhotosSpace.WithMe) ||
          this.model.supports('SYNO.Foto.Browse.Album'))) {
          WorkbenchActionRow({ icon: $r('sys.symbol.picture'), label: '共享相册',
            description: '浏览共享空间与收到的相册', available: this.active,
            onAction: (): void => { this.onOpenShared(); } })
        }
        if (this.supportsSpace(this.model.photoLibrary.space)) {
          WorkbenchActionRow({ icon: $r('sys.symbol.arrow_clockwise'), label: '刷新照片',
            description: '重新读取当前照片空间', available: this.active && !this.model.photoLibrary.busy,
            onAction: (): void => { this.model.photoLibrary.refresh(); } })
        }
        WorkbenchActionRow({ icon: $r('sys.symbol.ellipsis_circle'), label: '底栏设置',
          description: '选择常用页签并调整顺序', available: this.active,
          onAction: (): void => { this.onCustomize(); } })
      }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
      WorkbenchSectionTitle({ title: '照片服务' })
      WorkbenchNotice({ text: this.photoServices() })
    }.width('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin })
  }

  build() {
    Column() {
      List({ space: 2, scroller: this.scroller }) {
        if (this.tabId === 'more') {
          ListItem() { this.moreView() }
        } else if (this.tabId === 'backup') {
          ListItem() {
            Column() { this.backupCard() }.width('100%')
              .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin })
          }
        } else {
          ListItem() { this.libraryHeader() }
          if (!this.supportsExpectedView()) {
            ListItem() { this.emptyState('照片暂不可用', '当前账号在此空间未提供可用的照片或相册服务。') }
          } else if (!this.canShowLibrary()) {
            ListItem() {
              if (this.active) {
                Column() { this.loadingState() }.width('100%')
                  .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin })
              } else {
                this.emptyState('尚未读取内容', '打开此页签后查看照片或相册。')
              }
            }
          } else if (!this.model.photoLibrary.busy && this.visiblePhotos().length === 0 &&
            this.visibleAlbums().length === 0 && this.model.photoLibrary.errorText.length === 0) {
            ListItem() { this.emptyState('没有可见项目', '当前账号在此空间没有可见的照片或相册。') }
          }
          Repeat<PhotoAlbumRow>(this.albumRows)
            .each((row: RepeatItem<PhotoAlbumRow>): void => {
              ListItem() {
                Row({ space: 4 }) {
                  ForEach(row.item.albums, (album: NasPhotoAlbum): void => { this.albumCard(album) },
                    (album: NasPhotoAlbum): string => album.space.toString() + ':' + album.id.toString())
                  ForEach([0, 1, 2, 3].slice(0, photoAlbumColumns(this.contentWidth) - row.item.albums.length),
                    (slot: number): void => { Blank().layoutWeight(1) }, (slot: number): string => slot.toString())
                }.width('100%').alignItems(VerticalAlign.Top)
                  .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin })
              }
            }).key((row: PhotoAlbumRow): string => row.key).virtualScroll()
          Repeat<PhotoTimelineRow>(this.timelineRows)
            .each((row: RepeatItem<PhotoTimelineRow>): void => {
              ListItem() {
                Column({ space: 4 }) {
                  if (row.item.title.length > 0) {
                    Text(row.item.title).fontSize(16).fontWeight(FontWeight.Medium)
                      .fontColor($r('sys.color.font_secondary')).width('100%').padding({ top: 8 })
                  }
                  Row({ space: 2 }) {
                    ForEach(row.item.items, (item: NasPhotoItem): void => { this.photoCard(item) },
                      (item: NasPhotoItem): string => item.space.toString() + ':' + item.id.toString())
                    ForEach([0, 1, 2, 3, 4, 5].slice(0, photoGridColumns(this.contentWidth) - row.item.items.length),
                      (slot: number): void => { Blank().layoutWeight(1) }, (slot: number): string => slot.toString())
                  }.width('100%')
                }.width('100%').alignItems(HorizontalAlign.Start)
                  .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin })
              }
            }).key((row: PhotoTimelineRow): string => row.key).virtualScroll()
          if (this.canShowLibrary() && this.model.photoLibrary.appendError.length > 0) {
            ListItem() {
              Column({ space: 4 }) {
                WorkbenchNotice({ text: this.model.photoLibrary.appendError, warning: true })
                Button('重试加载').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
                  .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.photoLibrary.appending)
                  .onClick((): void => { if (this.canShowLibrary()) { this.model.photoLibrary.loadMore(); } })
              }.width('100%').padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin })
            }
          } else if (this.canShowLibrary() && this.model.photoLibrary.errorText.length === 0 && this.model.photoLibrary.hasMore) {
            ListItem() {
              Row({ space: 8 }) {
                if (this.model.photoLibrary.appending) {
                  LoadingProgress().width(20).height(20)
                  Text('正在加载…').fontSize(14).fontColor($r('sys.color.font_secondary'))
                }
              }.width('100%').constraintSize({ minHeight: 32 }).justifyContent(FlexAlign.Center)
                .accessibilityText(this.model.photoLibrary.appending ? '正在加载下一页' : '')
            }
          }
        }
      }.width('100%').height('100%').scrollBar(BarState.Auto)
        .contentStartOffset(this.topInset + 8).contentEndOffset(this.bottomInset)
        .onScrollIndex((start: number, end: number): void => { this.startIndex = start; this.endIndex = end; this.syncDemand(); })
        .onScrollStart((): void => { this.scrolling = true; this.syncDemand(); })
        .onScrollStop((): void => { this.scrolling = false; this.syncDemand(); })
    }.width('100%').constraintSize({ maxWidth: 960 }).height('100%')
      .onAreaChange((_oldArea: Area, newArea: Area): void => { this.contentWidth = Number(newArea.width); this.contentHeight = Number(newArea.height); })
      .onVisibleAreaChange([0], (visible: boolean): void => { this.viewVisible = visible; this.syncDemand(); })
  }
}
