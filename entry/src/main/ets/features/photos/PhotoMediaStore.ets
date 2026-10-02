import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { NasPhotoItem, NasPhotoMediaAccess, PHOTO_ORIGINAL_MAX_BYTES, PhotosSpace } from '../../core/domain/PhotosProtocol';
import { NasConnector } from '../../core/network/NasConnector';
import { RcpNasTransport } from '../../core/network/RcpNasTransport';
import { copyTransferFile } from '../transfers/TransferQueueFiles';

interface PhotoCacheEntry { key: string; path: string; bytes: number; }
interface PhotoThumbnailTask {
  item: NasPhotoItem;
  key: string;
  size: 'm' | 'xl';
  ticket: number;
  access?: NasPhotoMediaAccess;
  resolve: (path: string) => void;
  reject: (error: Error) => void;
}

/** 凭证只由 connector 提供；缓存按本次账号连接随机隔离，最多 60 张、24 MiB。 */
export class PhotoMediaStore {
  private context: common.UIAbilityContext | undefined = undefined;
  private connector: NasConnector | undefined = undefined;
  private directory: string = '';
  private generation: number = 0;
  private transport: RcpNasTransport | undefined = undefined;
  private originalTransport: RcpNasTransport | undefined = undefined;
  private originalGeneration: number = 0;
  private cache: PhotoCacheEntry[] = [];
  private pending: PhotoThumbnailTask[] = [];
  private promises: Map<string, Promise<string>> = new Map();
  private active: number = 0;
  private pinnedKeys: string[] = [];
  private access: NasPhotoMediaAccess | undefined = undefined;
  private originalFile: string = '';
  private originalBytes: number = 0;
  cleanupErrorText: string = '';
  private cleanupPaths: string[] = [];
  private changed: () => void = (): void => {};

  attach(context: common.UIAbilityContext | undefined, connector: NasConnector, changed: () => void, access?: NasPhotoMediaAccess): void {
    this.reset();
    this.connector = connector;
    this.context = context;
    this.changed = changed;
    this.access = access === undefined ? undefined : { albumId: access.albumId, scope: access.scope, passphrase: access.passphrase };
  }

  setAccess(access?: NasPhotoMediaAccess): void {
    const connector = this.connector;
    if (connector === undefined) { return; }
    this.attach(this.context, connector, this.changed, access);
  }

  pinPreview(item: NasPhotoItem, size: 'm' | 'xl' = 'm'): string {
    this.pinnedKeys = [this.key(item, size)];
    this.evict();
    this.changed();
    const entry = this.cache.find((cached: PhotoCacheEntry): boolean => cached.key === this.pinnedKeys[0]);
    return entry === undefined ? '' : entry.path;
  }

  reset(): void {
    this.generation++;
    this.cancelOriginal();
    this.transport?.close();
    this.transport = undefined;
    for (const task of this.pending) { task.reject(this.cancelled() as Error); }
    this.pending = [];
    this.promises.clear();
    this.active = 0;
    this.cache = [];
    this.pinnedKeys = [];
    const directory = this.directory;
    this.directory = '';
    this.context = undefined;
    this.connector = undefined;
    this.access = undefined;
    const leftovers = this.cleanupPaths.slice();
    this.cleanupPaths = [];
    this.cleanupErrorText = '';
    for (const owned of leftovers) { this.removeOwned(owned); }
    if (directory.length > 0) { this.removeDirectory(directory); }
    this.changed();
  }

  thumbnailPath(item: NasPhotoItem): string {
    const key = this.key(item, 'm');
    const entry = this.cache.find((cached: PhotoCacheEntry): boolean => cached.key === key);
    return entry === undefined ? '' : entry.path;
  }

  thumbnail(item: NasPhotoItem, size: 'm' | 'xl' = 'm'): Promise<string> {
    if (item.thumbnail === undefined) {
      return Promise.reject(new NasFailure(NasErrorKind.Unsupported, '此照片尚未提供可访问的缩略图。'));
    }
    const key = this.key(item, size);
    // 等待大预览时继续保护现有 m；大预览展示成功后由 pinPreview 释放 m。
    if (size === 'xl' && !this.pinnedKeys.includes(key)) { this.pinnedKeys.push(key); }
    const index = this.cache.findIndex((entry: PhotoCacheEntry): boolean => entry.key === key);
    if (index >= 0) {
      const entry = this.cache[index];
      this.cache.splice(index, 1);
      this.cache.push(entry);
      return Promise.resolve(entry.path);
    }
    const existing = this.promises.get(key);
    if (existing !== undefined) { return existing; }
    if (this.pending.length >= 60) { return Promise.reject(new NasFailure(NasErrorKind.Cancelled, '缩略图队列已满，请刷新后重试。')); }
    const ticket = this.generation;
    const promise = new Promise<string>((resolve, reject): void => {
      this.pending.push({ item: item, key: key, size: size, ticket: ticket, access: this.access, resolve: resolve, reject: reject });
    });
    this.promises.set(key, promise);
    this.drain();
    return promise;
  }

  closeDetail(): void {
    this.pinnedKeys = [];
    this.cancelOriginal();
    this.evict();
    this.changed();
  }

  cancelOriginal(): void {
    this.originalGeneration++;
    this.originalTransport?.close();
    this.originalTransport = undefined;
    if (this.originalFile.length > 0) { this.removeFile(this.originalFile); }
    this.originalFile = '';
    this.originalBytes = 0;
  }

  async original(item: NasPhotoItem, access: NasPhotoMediaAccess | undefined = this.access): Promise<string> {
    this.cancelOriginal();
    if (item.bytes > PHOTO_ORIGINAL_MAX_BYTES) { throw new NasFailure(NasErrorKind.InvalidInput, '原图超过 256 MiB 的前台读取限制。'); }
    const connector = this.requireConnector();
    if (item.space === PhotosSpace.WithMe && (access === undefined || access.scope !== this.access?.scope)) { throw this.cancelled(); }
    const plan = connector.photoOriginalPlan(item, access);
    const destination = this.privatePath();
    const transport = new RcpNasTransport();
    this.originalTransport = transport;
    const ticket = this.generation;
    const originalTicket = this.originalGeneration;
    const current = (): boolean => ticket === this.generation && originalTicket === this.originalGeneration;
    try {
      const bytes = await transport.downloadMedia(plan, destination, false, item.bytes, current);
      if (!current()) { this.removeFile(destination); throw this.cancelled(); }
      this.originalFile = destination;
      this.originalBytes = bytes;
      return destination;
    } catch (error) {
      this.removeFile(destination);
      if (!current()) { throw this.cancelled(); }
      if (error instanceof NasFailure) { await connector.photoMediaFailure(error); }
      throw error as Error;
    } finally {
      transport.close();
      if (current()) { this.originalTransport = undefined; }
    }
  }

  async exportOriginal(item: NasPhotoItem): Promise<boolean> {
    const context = this.context;
    const source = this.originalFile;
    const bytes = this.originalBytes;
    if (context === undefined || source.length === 0 || bytes < 1) {
      throw new NasFailure(NasErrorKind.InvalidInput, '请先完整读取原图，再另存到系统文件。');
    }
    const ticket = this.generation;
    const originalTicket = this.originalGeneration;
    const ensureCurrent = (): void => {
      if (ticket !== this.generation || originalTicket !== this.originalGeneration) { throw this.cancelled(); }
    };
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [item.filename.replace(/[\/\\\u0000-\u001f<>:"|?*]/g, '_').slice(0, 200) || '照片原图'];
    const destinations = await new picker.DocumentViewPicker(context).save(options);
    ensureCurrent();
    if (destinations.length === 0) { return false; }
    try {
      await copyTransferFile(source, destinations[0], bytes, ensureCurrent, true);
      ensureCurrent();
      return true;
    } catch (error) {
      try { await fileIo.unlink(destinations[0]); }
      catch { hilog.error(0x0000, 'NasPhotos', 'operation=export_cleanup result=failed'); }
      throw new NasFailure(error instanceof NasFailure ? error.kind : NasErrorKind.Protocol, '另存原图未完成，请检查目标文件后重试。');
    }
  }

  private drain(): void {
    while (this.active < 3 && this.pending.length > 0) {
      const task = this.pending.shift();
      if (task === undefined) { return; }
      this.active++;
      this.fetchThumbnail(task).then(task.resolve, task.reject).finally((): void => {
        if (task.ticket === this.generation) { this.promises.delete(task.key); this.active--; this.drain(); }
      });
    }
  }

  private async fetchThumbnail(task: PhotoThumbnailTask): Promise<string> {
    const connector = this.requireConnector();
    const plan = connector.photoThumbnailPlan(task.item, task.size, task.access);
    const destination = this.privatePath();
    if (this.transport === undefined) { this.transport = new RcpNasTransport(); }
    try {
      const bytes = await this.transport.downloadMedia(plan, destination, true, undefined,
        (): boolean => task.ticket === this.generation);
      if (task.ticket !== this.generation) { this.removeFile(destination); throw this.cancelled(); }
      this.cache.push({ key: task.key, path: destination, bytes: bytes });
      this.evict();
      this.changed();
      return destination;
    } catch (error) {
      this.removeFile(destination);
      if (task.ticket !== this.generation) { throw this.cancelled(); }
      if (error instanceof NasFailure) { await connector.photoMediaFailure(error); }
      throw error as Error;
    }
  }

  private privatePath(): string {
    const context = this.context;
    if (this.cleanupErrorText.length > 0) { throw new NasFailure(NasErrorKind.Protocol, this.cleanupErrorText); }
    if (context === undefined) { throw new NasFailure(NasErrorKind.Unsupported, '照片媒体需要应用私有缓存目录，请重新打开应用。'); }
    if (this.directory.length === 0) {
      const base = context.cacheDir + '/photos-v2';
      // 此目录仅归本功能所有；启动或切换账号后不复用旧账号的媒体文件。
      if (fileIo.accessSync(base)) { this.removeDirectory(base); }
      if (this.cleanupErrorText.length > 0) { throw new NasFailure(NasErrorKind.Protocol, this.cleanupErrorText); }
      this.directory = base + '/' + util.generateRandomUUID();
      fileIo.mkdirSync(this.directory, true);
    }
    return this.directory + '/' + util.generateRandomUUID() + '.media';
  }

  private evict(): void {
    let bytes = this.cache.reduce((total: number, entry: PhotoCacheEntry): number => total + entry.bytes, 0);
    while (this.cache.length > 60 || bytes > 24 * 1024 * 1024) {
      const index = this.cache.findIndex((cached: PhotoCacheEntry): boolean => !this.pinnedKeys.includes(cached.key));
      if (index < 0) { return; }
      const entry = this.cache.splice(index, 1)[0];
      this.removeFile(entry.path);
      bytes -= entry.bytes;
    }
  }

  private key(item: NasPhotoItem, size: string): string {
    return JSON.stringify([item.space, item.sourceSpace, item.id, item.thumbnail?.unitId, item.thumbnail?.cacheKey, size, this.access?.scope]);
  }
  private requireConnector(): NasConnector {
    if (this.connector === undefined) { throw this.cancelled(); }
    return this.connector;
  }
  private cancelled(): NasFailure { return new NasFailure(NasErrorKind.Cancelled, '照片读取已取消。'); }
  private removeFile(path: string): void {
    try { if (fileIo.accessSync(path)) { fileIo.unlinkSync(path); } }
    catch { this.cleanupFailed(path); }
  }
  private removeDirectory(path: string): void {
    try { if (fileIo.accessSync(path)) { fileIo.rmdirSync(path); } }
    catch { this.cleanupFailed(path); }
  }
  private removeOwned(path: string): void {
    try {
      if (!fileIo.accessSync(path)) { return; }
      if (fileIo.statSync(path).isDirectory()) { fileIo.rmdirSync(path); }
      else { fileIo.unlinkSync(path); }
    } catch { this.cleanupFailed(path); }
  }
  private cleanupFailed(path: string): void {
    if (!this.cleanupPaths.includes(path)) { this.cleanupPaths.push(path); }
    this.cleanupErrorText = '照片私有缓存清理失败，已停止继续缓存；请重新登录后重试。';
    hilog.error(0x0000, 'NasPhotos', 'operation=cache_cleanup result=failed');
  }
}
