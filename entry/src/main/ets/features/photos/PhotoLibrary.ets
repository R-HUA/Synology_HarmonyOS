import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { mergePhotoItems, NasPhotoAlbum, NasPhotoItem, NasPhotoMediaAccess, PhotosSpace } from '../../core/domain/PhotosProtocol';
import { NasConnector } from '../../core/network/NasConnector';
import { PhotoMediaStore } from './PhotoMediaStore';

export type PhotoLibrarySection = 'timeline' | 'albums';
interface PhotoTabContext {
  space: PhotosSpace;
  section: PhotoLibrarySection;
  items: NasPhotoItem[];
  albums: NasPhotoAlbum[];
  selectedAlbum?: NasPhotoAlbum;
  selectedAccess?: NasPhotoMediaAccess;
  passphrases: Map<string, string>;
  offset: number;
  hasMore: boolean;
}

/** 一个稳定照片身份对应一个可观察对象，媒体完成仅通知自己的单元格。 */
@ObservedV2
export class PhotoThumbnailState {
  @Trace path: string = '';
  @Trace loading: boolean = false;
  @Trace errorText: string = '';
  visible: boolean = false;
  visibleCycle: number = 0;
  decodeRetryCycle: number = -1;
  request: number = 0;
  retryAfterLoad: boolean = false;
}

@ObservedV2
export class PhotoLibrary {
  @Trace space: PhotosSpace = PhotosSpace.Personal;
  @Trace section: PhotoLibrarySection = 'timeline';
  @Trace items: NasPhotoItem[] = [];
  @Trace albums: NasPhotoAlbum[] = [];
  @Trace selectedAlbum: NasPhotoAlbum | undefined = undefined;
  @Trace busy: boolean = false;
  @Trace errorText: string = '';
  @Trace appendError: string = '';
  @Trace appending: boolean = false;
  @Trace dataGeneration: number = 0;
  @Trace hasMore: boolean = false;
  @Trace detail: NasPhotoItem | undefined = undefined;
  @Trace previewPath: string = '';
  @Trace originalPath: string = '';
  @Trace loadingMedia: boolean = false;
  @Trace mediaErrorText: string = '';
  @Trace thumbnailErrorText: string = '';
  @Trace exportNotice: string = '';
  private thumbnails: Map<string, PhotoThumbnailState> = new Map();
  private itemByKey: Map<string, NasPhotoItem> = new Map();
  private connector: NasConnector | undefined = undefined;
  private media: PhotoMediaStore = new PhotoMediaStore();
  private generation: number = 0;
  private requestGeneration: number = 0;
  private detailGeneration: number = 0;
  private offset: number = 0;
  private albumPassphrases: Map<string, string> = new Map();
  private selectedAccess: NasPhotoMediaAccess | undefined = undefined;
  private detailAccess: NasPhotoMediaAccess | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;
  private foreground: boolean = true;
  private viewportOwner: string = '';
  private visible: NasPhotoItem[] = [];
  private prefetch: NasPhotoItem[] = [];
  private visibleStateKeys: Set<string> = new Set();
  private nearEnd: boolean = false;
  private tabContexts: Map<string, PhotoTabContext> = new Map();
  private activeTab: string = '';
  private loaded: boolean = false;
  private viewportCount: number = -1;
  private demandTimer: number = -1;
  private foregroundChanged = (foreground: boolean): void => { this.setForeground(foreground); };
  private expired: (error: NasFailure) => Promise<void> = async (): Promise<void> => {};

  attach(connector: NasConnector, context: common.UIAbilityContext | undefined,
    expired: (error: NasFailure) => Promise<void>, insecureTls: boolean = false): void {
    this.reset();
    this.connector = connector;
    this.context = context;
    this.foreground = true;
    context?.eventHub?.on('nas-foreground-change', this.foregroundChanged);
    this.expired = expired;
    this.media.attach(context, connector, (identity?: string, path?: string): void => this.thumbnailChanged(identity, path), insecureTls);
    this.thumbnailErrorText = this.media.cleanupErrorText;
  }

  reset(): void {
    this.tabContexts.clear(); this.activeTab = ''; this.loaded = false;
    this.generation++;
    this.requestGeneration++;
    this.context?.eventHub?.off('nas-foreground-change', this.foregroundChanged);
    this.context = undefined;
    this.releaseView(this.viewportOwner);
    this.closeDetail();
    this.connector = undefined;
    this.media.reset();
    this.space = PhotosSpace.Personal;
    this.section = 'timeline';
    this.items = [];
    this.albums = [];
    this.selectedAlbum = undefined;
    this.selectedAccess = undefined;
    this.albumPassphrases.clear();
    this.thumbnails.clear();
    this.itemByKey.clear();
    this.thumbnailErrorText = '';
    this.offset = 0;
    this.hasMore = false;
    this.busy = false;
    this.errorText = '';
    this.appending = false;
    this.appendError = '';
    this.dataGeneration++;
  }

  async open(space: PhotosSpace = this.space, section: PhotoLibrarySection = this.section): Promise<void> {
    if (![PhotosSpace.Personal, PhotosSpace.Shared, PhotosSpace.WithMe].includes(space) || !['timeline', 'albums'].includes(section)) {
      this.errorText = '照片空间或视图不正确。'; return;
    }
    this.requestGeneration++;
    this.loaded = false;
    this.closeDetail();
    this.clearDemand();
    this.media.setAccess();
    this.space = space;
    this.section = space === PhotosSpace.WithMe ? 'albums' : section;
    this.selectedAlbum = undefined;
    this.selectedAccess = undefined;
    this.albumPassphrases.clear();
    this.items = [];
    this.albums = [];
    this.offset = 0;
    this.hasMore = false;
    this.thumbnailErrorText = '';
    this.clearItems();
    this.dataGeneration++;
    await this.readPage(true);
  }

  /** 相册和照片页各自保留浏览进度，授权只在当前账号内存中保存。 */
  async activateTab(key: string, space: PhotosSpace, section: PhotoLibrarySection): Promise<void> {
    if (key === this.activeTab && space === this.space && (this.loaded || this.busy)) { return; }
    if (this.loaded && this.activeTab.length > 0) {
      this.tabContexts.set(this.activeTab, { space: this.space, section: this.section, items: this.items.slice(),
        albums: this.albums.slice(), selectedAlbum: this.selectedAlbum, selectedAccess: this.selectedAccess,
        passphrases: new Map(this.albumPassphrases), offset: this.offset, hasMore: this.hasMore });
    }
    this.activeTab = key;
    this.requestGeneration++;
    this.busy = false; this.appending = false;
    this.closeDetail(); this.clearDemand(); this.clearItems();
    const saved = this.tabContexts.get(key);
    if (saved === undefined || saved.space !== space) { await this.open(space, section); return; }
    this.space = saved.space; this.section = saved.section;
    this.items = saved.items.slice(); this.albums = saved.albums.slice();
    this.selectedAlbum = saved.selectedAlbum; this.selectedAccess = saved.selectedAccess;
    this.albumPassphrases = new Map(saved.passphrases);
    this.offset = saved.offset; this.hasMore = saved.hasMore;
    this.loaded = true; this.errorText = ''; this.thumbnailErrorText = '';
    this.media.setAccess(this.selectedAccess);
    for (const item of this.items) { this.itemByKey.set(this.itemKey(item), item); }
    this.dataGeneration++;
  }

  async refresh(): Promise<void> {
    if (this.busy) { return; }
    this.loaded = false;
    this.requestGeneration++;
    this.closeDetail();
    this.clearDemand();
    this.media.setAccess(this.selectedAccess);
    this.clearItems();
    this.items = [];
    this.albums = [];
    this.offset = 0;
    this.hasMore = false;
    this.appendError = '';
    this.dataGeneration++;
    await this.readPage(true);
  }

  async loadMore(): Promise<void> {
    if (this.busy || this.appending || !this.hasMore) { return; }
    await this.readPage(false);
  }

  async openAlbum(album: NasPhotoAlbum): Promise<void> {
    const trusted = this.albums.find((entry: NasPhotoAlbum): boolean => entry.id === album.id && entry.space === album.space);
    if (trusted === undefined || album.space !== this.space) { this.errorText = '相册来源已变化，请刷新后重试。'; return; }
    this.requestGeneration++;
    this.closeDetail();
    this.clearDemand();
    const passphrase = this.albumPassphrases.get(this.albumKey(trusted));
    this.loaded = false;
    this.selectedAlbum = { id: trusted.id, name: trusted.name, itemCount: trusted.itemCount, space: trusted.space, passphrase: passphrase };
    this.selectedAccess = { albumId: trusted.id, scope: util.generateRandomUUID(), passphrase: passphrase };
    this.media.setAccess(this.selectedAccess);
    this.items = [];
    this.hasMore = false;
    this.offset = 0;
    this.clearItems();
    this.dataGeneration++;
    await this.readPage(true);
  }

  async backToLibrary(): Promise<void> {
    await this.open(this.space, this.selectedAlbum === undefined ? this.section : 'albums');
  }

  async openDetail(item: NasPhotoItem): Promise<void> {
    const trusted = this.itemByKey.get(this.itemKey(item));
    if (trusted === undefined || item.space !== this.space) { this.mediaErrorText = '照片来源已变化，请刷新后重试。'; return; }
    this.closeDetail();
    this.detail = trusted;
    this.previewPath = this.media.pinPreview(trusted);
    this.pauseDemand();
    this.detailAccess = this.selectedAccess;
    const connector = this.connector;
    if (connector === undefined) { this.mediaErrorText = '请先登录 NAS。'; return; }
    const ticket = this.generation;
    const detailTicket = this.detailGeneration;
    this.loadingMedia = true;
    try {
      // 共享相册列表已给出只读元数据，不假设其 Item/get 授权合同。
      const detail = trusted.space === PhotosSpace.WithMe ? trusted : await connector.photoDetail(trusted);
      if (!this.currentDetail(ticket, detailTicket)) { return; }
      this.detail = detail;
      // 详情元数据只属于详情视图；不重新映射整个时间线或触发日期分行。
      if (detail.thumbnail === undefined) { this.mediaErrorText = '此照片尚未提供可用预览。'; return; }
      const preview = await this.media.thumbnail(detail, 'xl');
      if (this.currentDetail(ticket, detailTicket)) { this.previewPath = this.media.pinPreview(detail, 'xl') || preview; }
    } catch (error) {
      if (this.currentDetail(ticket, detailTicket)) {
        this.mediaErrorText = this.message(error as Error, '照片详情或预览读取失败，请重试。');
        await this.handleFailure(error as Error, ticket, 'detail');
      }
    } finally { if (this.currentDetail(ticket, detailTicket)) { this.loadingMedia = false; } }
  }

  closeDetail(): void {
    this.detailGeneration++;
    this.media.closeDetail();
    this.detail = undefined;
    this.detailAccess = undefined;
    this.previewPath = '';
    this.originalPath = '';
    this.loadingMedia = false;
    this.mediaErrorText = '';
    this.exportNotice = '';
    this.applyDemand();
  }

  async loadOriginal(): Promise<void> {
    const item = this.detail;
    if (item === undefined || this.loadingMedia) { return; }
    const ticket = this.generation;
    const detailTicket = this.detailGeneration;
    this.loadingMedia = true;
    this.mediaErrorText = '';
    this.originalPath = '';
    this.exportNotice = '';
    try {
      const original = await this.media.original(item, this.detailAccess);
      if (this.currentDetail(ticket, detailTicket)) { this.originalPath = original; }
    } catch (error) {
      if (this.currentDetail(ticket, detailTicket)) {
        this.mediaErrorText = this.message(error as Error, '原图读取未完成，请重试。');
        await this.handleFailure(error as Error, ticket, 'original');
      }
    } finally { if (this.currentDetail(ticket, detailTicket)) { this.loadingMedia = false; } }
  }

  async exportOriginal(): Promise<boolean> {
    const item = this.detail;
    if (item === undefined || this.loadingMedia) { return false; }
    const ticket = this.generation;
    const detailTicket = this.detailGeneration;
    this.loadingMedia = true;
    this.mediaErrorText = '';
    this.exportNotice = '';
    try {
      const saved = await this.media.exportOriginal(item);
      if (!this.currentDetail(ticket, detailTicket)) { return false; }
      if (saved) { this.exportNotice = '原图已另存'; }
      return saved;
    } catch (error) {
      if (this.currentDetail(ticket, detailTicket)) {
        this.mediaErrorText = this.message(error as Error, '另存原图未完成，请重试。');
        await this.handleFailure(error as Error, ticket, 'export');
      }
      return false;
    } finally { if (this.currentDetail(ticket, detailTicket)) { this.loadingMedia = false; } }
  }

  thumbnailPath(item: NasPhotoItem): string {
    return this.thumbnailState(item).path;
  }

  thumbnailState(item: NasPhotoItem): PhotoThumbnailState {
    const key = this.itemKey(item);
    let state = this.thumbnails.get(key);
    if (state === undefined) {
      state = new PhotoThumbnailState();
      state.path = this.media.thumbnailPath(item);
      this.thumbnails.set(key, state);
    }
    return state;
  }

  /** 只有当前活动页可以持有需求；滚动期间最多每 80 ms 合并一次。 */
  updateViewport(owner: string, visible: NasPhotoItem[], prefetch: NasPhotoItem[], nearEnd: boolean,
    count: number, scrolling: boolean = false): void {
    this.viewportOwner = owner;
    this.visible = visible;
    this.prefetch = scrolling ? [] : prefetch;
    this.nearEnd = nearEnd;
    this.viewportCount = count;
    if (scrolling) {
      if (this.demandTimer < 0) {
        this.demandTimer = setTimeout((): void => { this.demandTimer = -1; this.applyDemand(); }, 80);
      }
    } else { this.cancelDemandTimer(); this.applyDemand(); }
    this.maybeLoadMore();
  }

  releaseView(owner: string): void {
    if (owner.length === 0 || owner !== this.viewportOwner) { return; }
    this.clearDemand();
    this.viewportOwner = '';
  }

  setForeground(foreground: boolean): void {
    if (foreground === this.foreground) { return; }
    this.foreground = foreground;
    if (foreground) {
      if (this.detail !== undefined && this.viewportOwner.length > 0) { this.openDetail(this.detail); }
      else { this.applyDemand(); this.maybeLoadMore(); }
    } else {
      this.pauseDemand();
      this.media.cancelThumbnails();
      this.media.cancelOriginal();
      this.detailGeneration++;
      this.originalPath = '';
      this.loadingMedia = false;
    }
  }

  retryThumbnail(item: NasPhotoItem): void {
    const state = this.thumbnails.get(this.itemKey(item));
    if (state === undefined || !state.visible || !this.canDemand()) { return; }
    state.errorText = '';
    this.media.invalidateThumbnail(item);
    this.requestThumbnail(item, state);
  }

  thumbnailImageError(item: NasPhotoItem, path: string): void {
    const state = this.thumbnails.get(this.itemKey(item));
    if (state === undefined || !state.visible || !this.canDemand() || path.length === 0 || state.path !== path) { return; }
    this.media.invalidateThumbnail(item);
    if (state.decodeRetryCycle === state.visibleCycle) { state.errorText = '缩略图无法显示，请重试。'; return; }
    state.decodeRetryCycle = state.visibleCycle;
    state.errorText = '';
    if (state.loading) { state.retryAfterLoad = true; }
    else { this.requestThumbnail(item, state); }
  }

  private itemKey(item: NasPhotoItem): string { return item.space.toString() + ':' + item.id.toString(); }
  private clearItems(): void {
    this.itemByKey.clear();
    this.thumbnails.clear();
    this.appendError = '';
    this.appending = false;
  }
  private canDemand(): boolean { return this.viewportOwner.length > 0 && this.foreground && this.detail === undefined; }
  private cancelDemandTimer(): void {
    if (this.demandTimer >= 0) { clearTimeout(this.demandTimer); this.demandTimer = -1; }
  }
  private pauseDemand(): void {
    this.cancelDemandTimer();
    if (this.viewportOwner.length > 0) { this.media.setDemand([], []); }
    for (const key of this.visibleStateKeys) { const state = this.thumbnails.get(key); if (state !== undefined) { state.visible = false; } }
    this.visibleStateKeys.clear();
  }
  private clearDemand(): void {
    this.pauseDemand();
    this.visible = [];
    this.prefetch = [];
    this.nearEnd = false;
    this.viewportCount = -1;
  }
  private applyDemand(): void {
    if (!this.canDemand()) { return; }
    const visibleKeys = new Set(this.visible.map((item: NasPhotoItem): string => this.itemKey(item)));
    for (const key of this.visibleStateKeys) {
      if (!visibleKeys.has(key)) { const state = this.thumbnails.get(key); if (state !== undefined) { state.visible = false; } }
    }
    this.visibleStateKeys = visibleKeys;
    this.media.setDemand(this.visible, this.prefetch);
    for (const item of this.visible.concat(this.prefetch)) {
      if (this.itemByKey.get(this.itemKey(item)) !== item) { continue; }
      const state = this.thumbnailState(item);
      if (visibleKeys.has(this.itemKey(item)) && !state.visible) { state.visible = true; state.visibleCycle++; }
      if (state.path.length === 0 && state.errorText.length === 0 && !state.loading && item.thumbnail !== undefined) {
        this.requestThumbnail(item, state);
      }
    }
    this.thumbnailErrorText = this.media.cleanupErrorText;
  }
  private requestThumbnail(item: NasPhotoItem, state: PhotoThumbnailState): void {
    if (state.loading || item.thumbnail === undefined) { return; }
    const ticket = this.dataGeneration;
    const accountTicket = this.generation;
    const request = ++state.request;
    const current = (): boolean => ticket === this.dataGeneration && accountTicket === this.generation &&
      this.thumbnails.get(this.itemKey(item)) === state && state.request === request;
    let cancelled = false;
    state.loading = true;
    this.media.thumbnail(item).then((): void => {
      if (current()) { state.path = this.media.thumbnailPath(item); state.errorText = ''; }
    }, async (error: Error): Promise<void> => {
      if (!current()) { return; }
      cancelled = error instanceof NasFailure && error.kind === NasErrorKind.Cancelled;
      if (!cancelled) {
        state.errorText = this.message(error, '缩略图读取失败，请重试。');
        await this.handleFailure(error, accountTicket, 'thumbnail');
      }
    }).finally((): void => {
      if (!current()) { return; }
      state.loading = false;
      const retry = state.retryAfterLoad;
      state.retryAfterLoad = false;
      // 请求被取消后又滚回同一行时，待旧传输退出后重新补取。
      const wanted = this.visible.concat(this.prefetch).some((entry: NasPhotoItem): boolean => this.itemKey(entry) === this.itemKey(item));
      if ((cancelled || retry) && this.canDemand() && wanted && state.path.length === 0 && state.errorText.length === 0) { this.requestThumbnail(item, state); }
    });
  }
  private thumbnailChanged(identity?: string, path?: string): void {
    if (identity === undefined) { this.thumbnailErrorText = this.media.cleanupErrorText; return; }
    const state = this.thumbnails.get(identity);
    if (state !== undefined) { state.path = path ?? ''; }
  }
  private maybeLoadMore(): void {
    const count = this.section === 'albums' && this.selectedAlbum === undefined ? this.albums.length : this.items.length;
    if (!this.canDemand() || !this.nearEnd || this.viewportCount !== count || this.errorText.length > 0 || this.appendError.length > 0) { return; }
    this.loadMore();
  }

  private async readPage(replace: boolean): Promise<void> {
    const connector = this.connector;
    if (connector === undefined) { this.errorText = '请先登录 NAS。'; this.busy = false; return; }
    const ticket = this.generation;
    const requestTicket = ++this.requestGeneration;
    const space = this.space;
    const album = this.selectedAlbum;
    const albumList = this.section === 'albums' && album === undefined;
    const offset = replace ? 0 : this.offset;
    if (replace) { this.busy = true; this.errorText = ''; }
    else { this.appending = true; }
    this.appendError = '';
    try {
      if (albumList) {
        const page = await connector.photoAlbums(space, offset);
        if (!this.currentPage(ticket, requestTicket)) { return; }
        const albums = replace ? [] : this.albums.slice();
        if (replace) { this.albumPassphrases.clear(); }
        for (const incoming of page.items) {
          if (incoming.space !== space) { throw new NasFailure(NasErrorKind.Protocol, '相册响应来源不正确。'); }
          if (incoming.passphrase !== undefined && incoming.passphrase.length > 0) {
            this.albumPassphrases.set(this.albumKey(incoming), incoming.passphrase);
          }
          if (!albums.some((existing: NasPhotoAlbum): boolean => existing.id === incoming.id)) {
            albums.push({ id: incoming.id, name: incoming.name, itemCount: incoming.itemCount, space: incoming.space });
          }
        }
        this.albums = albums;
        this.items = [];
        this.offset = offset + page.items.length;
        this.hasMore = page.items.length > 0 && page.hasMore;
      } else {
        const page = album === undefined ? await connector.photos(space, offset) : await connector.albumPhotos(album, offset);
        if (!this.currentPage(ticket, requestTicket)) { return; }
        this.items = mergePhotoItems(replace ? [] : this.items, page.items, space);
        for (const item of page.items) { if (!this.itemByKey.has(this.itemKey(item))) { this.itemByKey.set(this.itemKey(item), item); } }
        this.offset = offset + page.items.length;
        this.hasMore = page.items.length > 0 && page.hasMore;
      }
      this.loaded = true;
    } catch (error) {
      if (this.currentPage(ticket, requestTicket)) {
        if (replace) { this.errorText = this.message(error as Error, '照片读取失败，请重试。'); }
        else { this.appendError = this.message(error as Error, '更多内容读取失败，请重试。'); }
        await this.handleFailure(error as Error, ticket, 'list');
      }
    } finally { if (this.currentPage(ticket, requestTicket)) { this.busy = false; this.appending = false; } }
  }
  private albumKey(album: NasPhotoAlbum): string { return album.space.toString() + ':' + album.id.toString(); }
  private currentPage(ticket: number, requestTicket: number): boolean {
    return ticket === this.generation && requestTicket === this.requestGeneration;
  }
  private currentDetail(ticket: number, detailTicket: number): boolean {
    return ticket === this.generation && detailTicket === this.detailGeneration;
  }
  private message(error: Error, fallback: string): string { return error instanceof NasFailure ? error.message : fallback; }
  private async handleFailure(error: Error, ticket: number, operation: string): Promise<void> {
    hilog.error(0x0000, 'NasPhotos', 'operation=%{public}s kind=%{public}d code=%{public}d', operation,
      error instanceof NasFailure ? error.kind : -1, error instanceof NasFailure ? error.code : 0);
    if (ticket === this.generation && error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) {
      await this.expired(error);
    }
  }
}
