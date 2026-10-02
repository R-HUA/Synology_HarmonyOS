import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { mergePhotoItems, NasPhotoAlbum, NasPhotoItem, NasPhotoMediaAccess, PhotosSpace } from '../../core/domain/PhotosProtocol';
import { NasConnector } from '../../core/network/NasConnector';
import { PhotoMediaStore } from './PhotoMediaStore';

export type PhotoLibrarySection = 'timeline' | 'albums';
interface PhotoThumbnailPath { id: number; space: PhotosSpace; path: string; }

@ObservedV2
export class PhotoLibrary {
  @Trace space: PhotosSpace = PhotosSpace.Personal;
  @Trace section: PhotoLibrarySection = 'timeline';
  @Trace items: NasPhotoItem[] = [];
  @Trace albums: NasPhotoAlbum[] = [];
  @Trace selectedAlbum: NasPhotoAlbum | undefined = undefined;
  @Trace busy: boolean = false;
  @Trace errorText: string = '';
  @Trace hasMore: boolean = false;
  @Trace detail: NasPhotoItem | undefined = undefined;
  @Trace previewPath: string = '';
  @Trace originalPath: string = '';
  @Trace loadingMedia: boolean = false;
  @Trace mediaErrorText: string = '';
  @Trace thumbnailErrorText: string = '';
  @Trace exportNotice: string = '';
  @Trace thumbnailPaths: PhotoThumbnailPath[] = [];
  private connector: NasConnector | undefined = undefined;
  private media: PhotoMediaStore = new PhotoMediaStore();
  private generation: number = 0;
  private requestGeneration: number = 0;
  private detailGeneration: number = 0;
  private offset: number = 0;
  private albumPassphrases: Map<string, string> = new Map();
  private selectedAccess: NasPhotoMediaAccess | undefined = undefined;
  private detailAccess: NasPhotoMediaAccess | undefined = undefined;
  private expired: (error: NasFailure) => Promise<void> = async (): Promise<void> => {};

  attach(connector: NasConnector, context: common.UIAbilityContext | undefined,
    expired: (error: NasFailure) => Promise<void>): void {
    this.reset();
    this.connector = connector;
    this.expired = expired;
    this.media.attach(context, connector, (): void => this.updateThumbnailPaths());
    this.thumbnailErrorText = this.media.cleanupErrorText;
  }

  reset(): void {
    this.generation++;
    this.requestGeneration++;
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
    this.thumbnailPaths = [];
    this.thumbnailErrorText = '';
    this.offset = 0;
    this.hasMore = false;
    this.busy = false;
    this.errorText = '';
  }

  async open(space: PhotosSpace = this.space, section: PhotoLibrarySection = this.section): Promise<void> {
    if (![PhotosSpace.Personal, PhotosSpace.Shared, PhotosSpace.WithMe].includes(space) || !['timeline', 'albums'].includes(section)) {
      this.errorText = '照片空间或视图不正确。'; return;
    }
    this.requestGeneration++;
    this.closeDetail();
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
    await this.readPage(true);
  }

  async refresh(): Promise<void> {
    if (this.busy) { return; }
    await this.readPage(true);
  }

  async loadMore(): Promise<void> {
    if (this.busy || !this.hasMore) { return; }
    await this.readPage(false);
  }

  async openAlbum(album: NasPhotoAlbum): Promise<void> {
    const trusted = this.albums.find((entry: NasPhotoAlbum): boolean => entry.id === album.id && entry.space === album.space);
    if (trusted === undefined || album.space !== this.space) { this.errorText = '相册来源已变化，请刷新后重试。'; return; }
    this.requestGeneration++;
    this.closeDetail();
    const passphrase = this.albumPassphrases.get(this.albumKey(trusted));
    this.selectedAlbum = { id: trusted.id, name: trusted.name, itemCount: trusted.itemCount, space: trusted.space, passphrase: passphrase };
    this.selectedAccess = { albumId: trusted.id, scope: util.generateRandomUUID(), passphrase: passphrase };
    this.media.setAccess(this.selectedAccess);
    this.items = [];
    this.hasMore = false;
    this.offset = 0;
    await this.readPage(true);
  }

  async backToLibrary(): Promise<void> {
    await this.open(this.space, this.selectedAlbum === undefined ? this.section : 'albums');
  }

  async openDetail(item: NasPhotoItem): Promise<void> {
    const trusted = this.items.find((entry: NasPhotoItem): boolean => entry.id === item.id && entry.space === item.space);
    if (trusted === undefined || item.space !== this.space) { this.mediaErrorText = '照片来源已变化，请刷新后重试。'; return; }
    this.closeDetail();
    this.detail = trusted;
    this.previewPath = this.media.pinPreview(trusted);
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
      this.items = this.items.map((entry: NasPhotoItem): NasPhotoItem => entry.id === detail.id && entry.space === detail.space ? detail : entry);
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
    const entry = this.thumbnailPaths.find((cached: PhotoThumbnailPath): boolean => cached.id === item.id && cached.space === item.space);
    return entry === undefined ? '' : entry.path;
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
    this.busy = true;
    this.errorText = '';
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
        this.hasMore = page.hasMore;
      } else {
        const page = album === undefined ? await connector.photos(space, offset) : await connector.albumPhotos(album, offset);
        if (!this.currentPage(ticket, requestTicket)) { return; }
        this.items = mergePhotoItems(replace ? [] : this.items, page.items, space);
        this.offset = offset + page.items.length;
        this.hasMore = page.hasMore;
        this.warmThumbnails(page.items, ticket);
      }
      this.updateThumbnailPaths();
    } catch (error) {
      if (this.currentPage(ticket, requestTicket)) {
        this.errorText = this.message(error as Error, '照片读取失败，请重试。');
        await this.handleFailure(error as Error, ticket, 'list');
      }
    } finally { if (this.currentPage(ticket, requestTicket)) { this.busy = false; } }
  }

  private warmThumbnails(items: NasPhotoItem[], ticket: number): void {
    for (const item of items) {
      if (item.thumbnail === undefined) { continue; }
      this.media.thumbnail(item).catch(async (error: Error): Promise<void> => {
        if (ticket !== this.generation || error instanceof NasFailure && error.kind === NasErrorKind.Cancelled) { return; }
        this.thumbnailErrorText = this.message(error, '缩略图读取失败，请刷新后重试。');
        await this.handleFailure(error, ticket, 'thumbnail');
      });
    }
  }
  private albumKey(album: NasPhotoAlbum): string { return album.space.toString() + ':' + album.id.toString(); }
  private updateThumbnailPaths(): void {
    this.thumbnailPaths = this.items.map((item: NasPhotoItem): PhotoThumbnailPath =>
      ({ id: item.id, space: item.space, path: this.media.thumbnailPath(item) }));
  }
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
