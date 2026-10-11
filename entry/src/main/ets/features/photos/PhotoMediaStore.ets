import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { NasPhotoItem, NasPhotoMediaAccess, PHOTO_ORIGINAL_MAX_BYTES, PhotosSpace } from '../../core/domain/PhotosProtocol';
import { NasConnector } from '../../core/network/NasConnector';
import { RcpNasTransport } from '../../core/network/RcpNasTransport';
import { copyTransferFile } from '../transfers/TransferQueueFiles';

interface PhotoCacheEntry { key: string; identity: string; size: 'm' | 'xl'; path: string; bytes: number; }
interface PhotoThumbnailTask {
  item: NasPhotoItem;
  key: string;
  size: 'm' | 'xl';
  ticket: number;
  cancelled: boolean;
  transport?: RcpNasTransport;
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
  private originalTransport: RcpNasTransport | undefined = undefined;
  private originalGeneration: number = 0;
  private cache: PhotoCacheEntry[] = [];
  private cacheByKey: Map<string, PhotoCacheEntry> = new Map();
  private pending: PhotoThumbnailTask[] = [];
  private running: Map<string, PhotoThumbnailTask> = new Map();
  private promises: Map<string, Promise<string>> = new Map();
  private active: number = 0;
  private pinnedKeys: string[] = [];
  private visibleKeys: Set<string> = new Set();
  private demandKeys: Set<string> = new Set();
  private managedDemand: boolean = false;
  private access: NasPhotoMediaAccess | undefined = undefined;
  private originalFile: string = '';
  private originalBytes: number = 0;
  /** 与当前连接一致的证书校验策略；跳过校验时缩略图与原图仍可读取。 */
  private insecureTls: boolean = false;
  cleanupErrorText: string = '';
  private cleanupPaths: string[] = [];
  private cancelFailures: number = 0;
  private cleanupFailures: number = 0;
  private diagnosticTimer: number = -1;
  private changed: (identity?: string, path?: string) => void = (): void => {};

  attach(context: common.UIAbilityContext | undefined, connector: NasConnector, changed: (identity?: string, path?: string) => void,
    insecureTls: boolean = false, access?: NasPhotoMediaAccess): void {
    this.reset();
    this.connector = connector;
    this.context = context;
    this.changed = changed;
    this.insecureTls = insecureTls;
    this.access = access === undefined ? undefined : { albumId: access.albumId, scope: access.scope, passphrase: access.passphrase };
  }

  setAccess(access?: NasPhotoMediaAccess): void {
    const connector = this.connector;
    if (connector === undefined) { return; }
    this.attach(this.context, connector, this.changed, this.insecureTls, access);
  }

  pinPreview(item: NasPhotoItem, size: 'm' | 'xl' = 'm'): string {
    this.pinnedKeys = [this.key(item, size)];
    this.evict();
    this.changed();
    const entry = this.cacheByKey.get(this.pinnedKeys[0]);
    return entry === undefined ? '' : entry.path;
  }

  reset(): void {
    this.generation++;
    this.cancelOriginal();
    for (const task of this.running.values()) { this.cancelTask(task); }
    for (const task of this.pending) { task.reject(this.cancelled() as Error); }
    this.pending = [];
    this.running.clear();
    this.promises.clear();
    this.active = 0;
    this.cache = [];
    this.cacheByKey.clear();
    this.pinnedKeys = [];
    this.visibleKeys.clear();
    this.demandKeys.clear();
    this.managedDemand = false;
    const directory = this.directory;
    this.directory = '';
    this.context = undefined;
    this.connector = undefined;
    this.access = undefined;
    this.insecureTls = false;
    const leftovers = this.cleanupPaths.slice();
    this.cleanupPaths = [];
    this.cleanupErrorText = '';
    for (const owned of leftovers) { this.removeOwned(owned); }
    if (directory.length > 0) { this.removeDirectory(directory); }
    this.changed();
  }

  thumbnailPath(item: NasPhotoItem): string {
    const key = this.key(item, 'm');
    const entry = this.cacheByKey.get(key);
    return entry === undefined ? '' : entry.path;
  }

  /** 只保留可见行与相邻预取行的需求；可见文件在引用释放前不得淘汰。 */
  setDemand(visible: NasPhotoItem[], prefetch: NasPhotoItem[]): void {
    this.managedDemand = true;
    this.visibleKeys = new Set(visible.map((item: NasPhotoItem): string => this.key(item, 'm')));
    this.demandKeys = new Set(visible.concat(prefetch).map((item: NasPhotoItem): string => this.key(item, 'm')));
    const retained: PhotoThumbnailTask[] = [];
    for (const task of this.pending) {
      if (this.wanted(task)) { retained.push(task); }
      else { task.cancelled = true; this.promises.delete(task.key); task.reject(this.cancelled() as Error); }
    }
    // 可见项始终排在预取前；取消的进行中请求仍占槽，直到传输确实退出。
    this.pending = retained.filter((task: PhotoThumbnailTask): boolean => this.visibleKeys.has(task.key) || task.size === 'xl')
      .concat(retained.filter((task: PhotoThumbnailTask): boolean => !this.visibleKeys.has(task.key) && task.size !== 'xl'));
    for (const task of this.running.values()) { if (!this.wanted(task)) { this.cancelTask(task); } }
    this.evict();
    this.drain();
  }

  invalidateThumbnail(item: NasPhotoItem): void {
    const key = this.key(item, 'm');
    const entry = this.cacheByKey.get(key);
    if (entry !== undefined) { this.removeCache(entry); }
  }

  thumbnail(item: NasPhotoItem, size: 'm' | 'xl' = 'm'): Promise<string> {
    if (item.thumbnail === undefined) {
      return Promise.reject(new NasFailure(NasErrorKind.Unsupported, '此照片尚未提供可访问的缩略图。'));
    }
    const key = this.key(item, size);
    if (size === 'm' && this.managedDemand && !this.demandKeys.has(key)) { return Promise.reject(this.cancelled()); }
    // 等待大预览时继续保护现有 m；大预览展示成功后由 pinPreview 释放 m。
    if (size === 'xl' && !this.pinnedKeys.includes(key)) { this.pinnedKeys.push(key); }
    const entry = this.cacheByKey.get(key);
    if (entry !== undefined) {
      const index = this.cache.indexOf(entry);
      this.cache.splice(index, 1);
      this.cache.push(entry);
      return Promise.resolve(entry.path);
    }
    const existing = this.promises.get(key);
    if (existing !== undefined) { return existing; }
    if (this.pending.length >= 60) { return Promise.reject(new NasFailure(NasErrorKind.Protocol, '等待读取的缩略图过多，请稍后重试。')); }
    const ticket = this.generation;
    const promise = new Promise<string>((resolve, reject): void => {
      const task: PhotoThumbnailTask = { item: item, key: key, size: size, ticket: ticket, cancelled: false,
        access: this.access, resolve: resolve, reject: reject };
      const prefetchIndex = this.pending.findIndex((queued: PhotoThumbnailTask): boolean =>
        queued.size !== 'xl' && !this.visibleKeys.has(queued.key));
      if ((size === 'xl' || this.visibleKeys.has(key)) && prefetchIndex >= 0) {
        this.pending.splice(prefetchIndex, 0, task);
      } else { this.pending.push(task); }
    });
    this.promises.set(key, promise);
    this.drain();
    return promise;
  }

  closeDetail(): void {
    this.pinnedKeys = [];
    this.cancelOriginal();
    if (this.managedDemand) { this.setDemandFromKeys(); }
    this.evict();
    this.changed();
  }

  cancelThumbnails(): void {
    for (const task of this.pending) { this.promises.delete(task.key); task.reject(this.cancelled() as Error); }
    this.pending = [];
    for (const task of this.running.values()) { this.cancelTask(task); }
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
    const transport = new RcpNasTransport(this.insecureTls);
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

  /** 由系统确认保存授权，逐个原文件拷贝；每批不超过相册创建接口的 100 项限制。 */
  async saveToGallery(items: NasPhotoItem[], access?: NasPhotoMediaAccess): Promise<number> {
    const ticket = this.generation;
    const connector = this.requireConnector();
    const helper = photoAccessHelper.getPhotoAccessHelper(this.context!);
    let saved = 0;
    const ensureCurrent = (): void => { if (ticket !== this.generation) { throw this.cancelled(); } };
    try {
      for (let start = 0; start < items.length; start += 100) {
        const batch = items.slice(start, start + 100);
        const paths: string[] = [];
        const transport = new RcpNasTransport(this.insecureTls);
        try {
          for (const item of batch) {
            ensureCurrent();
            const destination = this.privatePath(); paths.push(destination);
            await transport.downloadMedia(connector.photoOriginalPlan(item, access), destination, false, item.bytes,
              (): boolean => ticket === this.generation);
          }
          const configs: photoAccessHelper.PhotoCreationConfig[] = batch.map((item: NasPhotoItem): photoAccessHelper.PhotoCreationConfig => {
            const dot = item.filename.lastIndexOf('.');
            if (dot <= 0) { throw new NasFailure(NasErrorKind.InvalidInput, '照片文件名称缺少扩展名。'); }
            return { title: item.filename.substring(0, dot), fileNameExtension: item.filename.substring(dot + 1),
              photoType: item.mediaType === 'video' ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE };
          });
          const destinations = await helper.showAssetsCreationDialog(paths.map((path: string): string => fileUri.getUriFromPath(path)), configs);
          ensureCurrent();
          if (destinations.length === 0) { return saved; }
          if (destinations.length !== batch.length) { throw new NasFailure(NasErrorKind.Protocol, `已保存 ${saved} 项，相册保存回执不完整。`); }
          const issues: string[] = [];
          for (let index = 0; index < destinations.length; index++) {
            if (!destinations[index].startsWith('file://')) { issues.push(batch[index].filename); continue; }
            await copyTransferFile(paths[index], destinations[index], batch[index].bytes, ensureCurrent, true);
            saved++;
          }
          if (issues.length > 0) { throw new NasFailure(NasErrorKind.Protocol, `已保存 ${saved} 项，${issues.length} 项保存失败：${issues[0]}`); }
        } finally {
          transport.close();
          for (const path of paths) { this.removeFile(path); }
        }
      }
      return saved;
    } finally { await helper.release(); }
  }

  private drain(): void {
    while (this.active < 3 && this.pending.length > 0) {
      const task = this.pending.shift();
      if (task === undefined) { return; }
      // 视口引用已用完预算时，不派发无处保留的预取请求。
      if (!this.canCachePrefetch(task, 0)) { this.promises.delete(task.key); task.resolve(''); continue; }
      this.active++;
      this.running.set(task.key, task);
      this.fetchThumbnail(task).then((path: string): void => {
        this.finish(task); task.resolve(path);
      }, (error: Error): void => { this.finish(task); task.reject(error); });
    }
  }

  private async fetchThumbnail(task: PhotoThumbnailTask): Promise<string> {
    const connector = this.requireConnector();
    const plan = connector.photoThumbnailPlan(task.item, task.size, task.access);
    const destination = this.privatePath();
    const transport = new RcpNasTransport(this.insecureTls);
    task.transport = transport;
    try {
      const bytes = await transport.downloadMedia(plan, destination, true, undefined,
        (): boolean => this.currentTask(task));
      if (!this.currentTask(task) || !this.wanted(task)) { throw this.cancelled(); }
      if (!this.canCachePrefetch(task, bytes)) { this.removeFile(destination); return ''; }
      const entry: PhotoCacheEntry = { key: task.key, identity: this.identity(task.item), size: task.size, path: destination, bytes: bytes };
      this.cache.push(entry);
      this.cacheByKey.set(task.key, entry);
      this.evict();
      if (task.size === 'm' && this.cacheByKey.has(task.key)) { this.changed(entry.identity, destination); }
      return destination;
    } catch (error) {
      this.removeFile(destination);
      if (!this.currentTask(task)) { throw this.cancelled(); }
      if (error instanceof NasFailure) { await connector.photoMediaFailure(error); }
      throw error as Error;
    } finally { transport.close(); task.transport = undefined; }
  }

  private finish(task: PhotoThumbnailTask): void {
    if (task.ticket !== this.generation) { return; }
    this.promises.delete(task.key);
    this.running.delete(task.key);
    this.active--;
    this.drain();
  }
  private currentTask(task: PhotoThumbnailTask): boolean { return task.ticket === this.generation && !task.cancelled; }
  private wanted(task: PhotoThumbnailTask): boolean {
    return !this.managedDemand || (task.size === 'xl' ? this.pinnedKeys.includes(task.key) : this.demandKeys.has(task.key));
  }
  private canCachePrefetch(task: PhotoThumbnailTask, bytes: number): boolean {
    if (!this.managedDemand || this.visibleKeys.has(task.key) || this.pinnedKeys.includes(task.key)) { return true; }
    let protectedCount = 0;
    let protectedBytes = 0;
    for (const entry of this.cache) {
      if (this.visibleKeys.has(entry.key) || this.pinnedKeys.includes(entry.key)) { protectedCount++; protectedBytes += entry.bytes; }
    }
    return protectedCount < 60 && (bytes === 0 ? protectedBytes < 24 * 1024 * 1024 : protectedBytes + bytes <= 24 * 1024 * 1024);
  }
  private cancelTask(task: PhotoThumbnailTask): void {
    if (task.cancelled) { return; }
    task.cancelled = true;
    try { task.transport?.close(); }
    catch { this.cancelFailures++; this.scheduleDiagnostics(); }
  }
  private setDemandFromKeys(): void {
    const retained: PhotoThumbnailTask[] = [];
    for (const task of this.pending) {
      if (this.wanted(task)) { retained.push(task); }
      else { this.promises.delete(task.key); task.reject(this.cancelled() as Error); }
    }
    this.pending = retained;
    for (const task of this.running.values()) { if (!this.wanted(task)) { this.cancelTask(task); } }
  }

  private privatePath(): string {
    const context = this.context;
    if (this.cleanupErrorText.length > 0) { throw new NasFailure(NasErrorKind.Protocol, this.cleanupErrorText); }
    if (context === undefined) { throw new NasFailure(NasErrorKind.Unsupported, '照片媒体需要应用私有缓存目录，请重新打开应用。'); }
    if (this.directory.length === 0) {
      const base = context.cacheDir + '/photos-v2';
      try {
        // 此目录仅归本功能所有；启动或切换账号后不复用旧账号的媒体文件。
        if (fileIo.accessSync(base)) { this.removeDirectory(base); }
        if (this.cleanupErrorText.length > 0) { throw new NasFailure(NasErrorKind.Protocol, this.cleanupErrorText); }
        const directory = base + '/' + util.generateRandomUUID();
        fileIo.mkdirSync(directory, true);
        this.directory = directory;
      } catch (error) {
        if (error instanceof NasFailure) { throw error; }
        throw new NasFailure(NasErrorKind.Protocol, '无法创建照片缓存目录，请检查可用存储空间后重试。', (error as BusinessError).code);
      }
    }
    return this.directory + '/' + util.generateRandomUUID() + '.media';
  }

  private evict(): void {
    let bytes = this.cache.reduce((total: number, entry: PhotoCacheEntry): number => total + entry.bytes, 0);
    while (this.cache.length > 60 || bytes > 24 * 1024 * 1024) {
      const index = this.cache.findIndex((cached: PhotoCacheEntry): boolean => !this.pinnedKeys.includes(cached.key) && !this.visibleKeys.has(cached.key));
      if (index < 0) { return; }
      const entry = this.cache[index];
      this.removeCache(entry);
      bytes -= entry.bytes;
    }
  }

  private removeCache(entry: PhotoCacheEntry): void {
    this.cacheByKey.delete(entry.key);
    this.cache.splice(this.cache.indexOf(entry), 1);
    if (entry.size === 'm') { this.changed(entry.identity, ''); }
    this.removeFile(entry.path);
  }
  private identity(item: NasPhotoItem): string { return item.space.toString() + ':' + item.id.toString(); }

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
    if (this.cleanupPaths.includes(path)) { return; }
    this.cleanupPaths.push(path);
    this.cleanupErrorText = '照片私有缓存清理失败，已停止继续缓存；请重新登录后重试。';
    this.cleanupFailures++;
    this.scheduleDiagnostics();
  }

  /** 故障在滚动过程中可能成批出现，立即保留错误状态，日志每秒汇总一次。 */
  private scheduleDiagnostics(): void {
    if (this.diagnosticTimer >= 0) { return; }
    this.diagnosticTimer = setTimeout((): void => {
      this.diagnosticTimer = -1;
      if (this.cancelFailures > 0) {
        hilog.error(0x0000, 'NasPhotos', 'operation=thumbnail_cancel result=failed count=%{public}d', this.cancelFailures);
        this.cancelFailures = 0;
      }
      if (this.cleanupFailures > 0) {
        hilog.error(0x0000, 'NasPhotos', 'operation=cache_cleanup result=failed count=%{public}d', this.cleanupFailures);
        this.cleanupFailures = 0;
      }
    }, 1000);
  }
}
