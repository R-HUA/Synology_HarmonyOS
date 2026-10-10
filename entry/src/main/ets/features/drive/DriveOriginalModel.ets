import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure, NasFileEntry } from '../../core/domain/DsmProtocol';
import { DRIVE_FILES_API, decodeDriveEntry } from '../../core/domain/DriveProtocol';
import type { DriveEntry } from '../../core/domain/DriveProtocol';
import { DRIVE_ORIGINAL_MAX_BYTES, driveOriginalDecodeSize, driveOriginalUnchanged, validateDriveOriginal, canPreviewDriveMedia } from '../../core/domain/DriveOriginalProtocol';
import { NasConnector } from '../../core/network/NasConnector';
import { DriveTransferAdapter } from '../../core/network/DriveTransferAdapter';
import { NasTransferCancellation } from '../../core/network/NasTransferTransport';
import type { NasTransferProgress } from '../../core/network/NasTransferTransport';

/** 一次只保留当前原文件；关闭与换账号均取消请求并清除私有文件。 */
@ObservedV2
export class DriveOriginalModel {
  @Trace entry: DriveEntry | undefined = undefined;
  @Trace fileEntry: NasFileEntry | undefined = undefined;
  @Trace pixels: image.PixelMap | undefined = undefined;
  @Trace busy: boolean = false;
  @Trace progress: number | undefined = undefined;
  @Trace errorText: string = '';
  @Trace staticFrame: boolean = false;
  @Trace originalLoaded: boolean = false;
  private context: common.UIAbilityContext | undefined = undefined;
  private connector: NasConnector | undefined = undefined;
  private onSessionFailure: (error: NasFailure) => Promise<void> = async (): Promise<void> => {};
  private ticket: number = 0;
  private signal: NasTransferCancellation | undefined = undefined;
  private source: image.ImageSource | undefined = undefined;
  private ownedDirectories: Set<string> = new Set();
  private width: number = 0;
  private height: number = 0;
  private viewWidth: number = 1200;
  private viewHeight: number = 1600;
  private tail: Promise<void> = Promise.resolve();
  private cacheReady: boolean = false;
  private cachePrefix: string;
  constructor(cachePrefix: string = 'drive-original') { this.cachePrefix = cachePrefix; }

  attach(context: common.UIAbilityContext, connector: NasConnector,
    onSessionFailure: (error: NasFailure) => Promise<void>): void {
    this.detach(); this.cacheReady = false; this.context = context; this.connector = connector; this.onSessionFailure = onSessionFailure;
    const ticket = this.ticket;
    // 上次进程被终止时无法执行 close；仅清理本功能拥有的 UUID 临时目录。
    this.tail = this.tail.then(async (): Promise<void> => {
      const names = await fileIo.listFile(context.cacheDir);
      for (const name of names) {
        if (new RegExp('^' + this.cachePrefix + '-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').test(name)) {
          this.ownedDirectories.add(context.cacheDir + '/' + name);
        }
      }
      for (const directory of Array.from(this.ownedDirectories)) { await this.removeDirectory(directory); }
      if (this.context === context && this.connector === connector) { this.cacheReady = true; }
    }).catch((error: Error): void => { this.reportCleanup(error, ticket); });
  }

  detach(): void { this.close(); this.context = undefined; this.connector = undefined; }
  setForeground(foreground: boolean): void {
    if (!foreground) { const entry = this.entry, fileEntry = this.fileEntry; this.close(); this.entry = entry; this.fileEntry = fileEntry; }
  }

  setViewport(width: number, height: number): void {
    if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
      this.viewWidth = width * 2; this.viewHeight = height * 2;
    }
  }

  async open(entry: DriveEntry, original: boolean = false): Promise<void> {
    const connector = this.connector, context = this.context;
    if (connector === undefined || context === undefined) { return; }
    await this.close();
    if (connector !== this.connector || context !== this.context) { return; }
    if (!this.cacheReady) { this.entry = entry; this.errorText = '图片缓存清理未完成，请重新连接后重试。'; return; }
    if (this.ownedDirectories.size > 0) { this.entry = entry; return; }
    const ticket = ++this.ticket;
    const signal = new NasTransferCancellation();
    this.signal = signal; this.entry = entry; this.busy = true; this.errorText = ''; this.progress = undefined;
    const directory = context.cacheDir + '/drive-original-' + util.generateRandomUUID();
    const job = async (): Promise<void> => {
      let source: image.ImageSource | undefined = undefined;
      let pixels: image.PixelMap | undefined = undefined;
      let retained = false;
      let phase = 'metadata_before';
      try {
        if (original) { validateDriveOriginal(entry); }
        else if (!canPreviewDriveMedia(entry)) { throw new NasFailure(NasErrorKind.Permission, '此文件无法预览。'); }
        const before = await this.readEntry(connector, entry.fileId);
        this.check(ticket);
        if (original) { validateDriveOriginal(before); }
        else if (!canPreviewDriveMedia(before)) { throw new NasFailure(NasErrorKind.Permission, '此文件无法预览。'); }
        // 下载层独占创建目录后才通知所有权；失败清理也保留可追踪的目录。
        this.check(ticket);
        phase = original ? 'original' : 'thumbnail';
        const result = original ? await new DriveTransferAdapter(connector).download(before,
          { directory, maximumBytes: DRIVE_ORIGINAL_MAX_BYTES, expectedBytes: before.sizeBytes,
            onDirectoryCreated: (): void => { this.ownedDirectories.add(directory); } },
          { cancellation: signal, onProgress: (value: NasTransferProgress): void => {
            if (ticket === this.ticket && value.total !== undefined && value.total > 0) { this.progress = Math.min(99, value.processed / value.total * 100); }
          } }) : await connector.thumbnailDrive({ fileId: before.fileId, versionId: before.versionId }, directory,
            { cancellation: signal });
        this.ownedDirectories.add(directory);
        this.check(ticket);
        phase = 'metadata_after';
        const after = await this.readEntry(connector, entry.fileId);
        this.check(ticket);
        if (!driveOriginalUnchanged(before, after, original)) { throw new NasFailure(NasErrorKind.Protocol, '图片或访问权限已变化，请刷新文件列表后重试。'); }
        phase = 'decode';
        source = image.createImageSource(result.path);
        const info = await source.getImageInfo();
        this.check(ticket);
        const frames = await source.getFrameCount();
        this.check(ticket);
        pixels = await source.createPixelMap({ desiredSize: driveOriginalDecodeSize(info.size.width, info.size.height, this.viewWidth, this.viewHeight) });
        this.check(ticket);
        this.source = source; this.pixels = pixels;
        this.width = info.size.width; this.height = info.size.height; this.entry = after; this.progress = 100;
        this.staticFrame = frames > 1;
        this.originalLoaded = original;
        retained = true;
      } catch (error) {
        if (ticket === this.ticket) {
          hilog.error(0x0000, 'NasDriveOriginal', 'operation=preview result=failed phase=%{public}s kind=%{public}d code=%{public}d',
            phase, error instanceof NasFailure ? error.kind : -1, error instanceof NasFailure ? error.code : (error as BusinessError).code ?? -1);
          this.errorText = error instanceof NasFailure ? error.message :
            [13900025, 13900041].includes((error as BusinessError).code) ? '本机存储空间不足，请释放空间后重试。' :
              '图片无法打开，请下载后使用其他应用查看。';
          if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { await this.onSessionFailure(error); }
        }
      } finally {
        if (!retained) {
          try { await pixels?.release(); } finally {
            try { await source?.release(); } finally {
              if (this.ownedDirectories.has(directory)) { await this.removeDirectory(directory); }
            }
          }
        }
        if (ticket === this.ticket) { this.busy = false; this.signal = undefined; }
      }
    };
    this.tail = job().catch((error: Error): void => { this.reportCleanup(error, ticket); });
    await this.tail;
  }

  refine(zoom: number): void {
    const source = this.source, ticket = this.ticket;
    if (source === undefined || this.pixels === undefined) { return; }
    const size = driveOriginalDecodeSize(this.width, this.height, this.viewWidth, this.viewHeight, zoom);
    const job = async (): Promise<void> => {
      if (ticket !== this.ticket) { return; }
      let next: image.PixelMap | undefined = undefined;
      try {
        next = await source.createPixelMap({ desiredSize: size });
        if (ticket !== this.ticket) { await next.release(); return; }
        const previous = this.pixels; this.pixels = next; next = undefined; await previous?.release();
      } catch (error) {
        await next?.release();
        if (ticket === this.ticket) { this.errorText = '高清细节未能加载，可继续查看当前图片。'; }
      }
    };
    this.tail = this.tail.then(job).catch((error: Error): void => { this.reportCleanup(error, ticket); });
  }

  /** 仅在文件页打开图片时读取缩略图；原文件须由用户另行选择。 */
  async openFile(entry: NasFileEntry, original: boolean = false): Promise<void> {
    const connector = this.connector, context = this.context;
    if (connector === undefined || context === undefined) { return; }
    await this.close();
    if (connector !== this.connector || context !== this.context) { return; }
    this.fileEntry = entry;
    if (!this.cacheReady || this.ownedDirectories.size > 0) { this.errorText = '图片缓存清理未完成。'; return; }
    const ticket = ++this.ticket, signal = new NasTransferCancellation();
    this.signal = signal; this.busy = true;
    const directory = context.cacheDir + '/' + this.cachePrefix + '-' + util.generateRandomUUID();
    const job = async (): Promise<void> => {
      let source: image.ImageSource | undefined = undefined;
      let pixels: image.PixelMap | undefined = undefined;
      let retained = false;
      try {
        const before = await connector.getFileInfo(entry.path); this.check(ticket);
        if (before.isDirectory || before.bytes <= 0 || original && before.bytes > DRIVE_ORIGINAL_MAX_BYTES) {
          throw new NasFailure(NasErrorKind.InvalidInput, '此图片无法预览，请下载后查看。');
        }
        const result = await connector.fileImage(before.path, { directory,
          maximumBytes: original ? DRIVE_ORIGINAL_MAX_BYTES : 4 * 1024 * 1024,
          expectedBytes: original ? before.bytes : undefined,
          onDirectoryCreated: (): void => { this.ownedDirectories.add(directory); } }, { cancellation: signal }, original);
        this.ownedDirectories.add(directory); this.check(ticket);
        const after = await connector.getFileInfo(entry.path); this.check(ticket);
        if (after.isDirectory || before.bytes !== after.bytes) { throw new NasFailure(NasErrorKind.Protocol, '图片已变化，请刷新后重试。'); }
        source = image.createImageSource(result.path);
        const info = await source.getImageInfo(); this.check(ticket);
        pixels = await source.createPixelMap({ desiredSize: driveOriginalDecodeSize(info.size.width, info.size.height, this.viewWidth, this.viewHeight) });
        this.check(ticket);
        this.source = source; this.pixels = pixels; this.width = info.size.width; this.height = info.size.height;
        this.fileEntry = after; this.originalLoaded = original; retained = true;
      } catch (error) {
        if (ticket === this.ticket) {
          this.errorText = error instanceof NasFailure ? error.message : '图片无法打开，请下载后查看。';
          if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { await this.onSessionFailure(error); }
        }
      } finally {
        if (!retained) {
          try { await pixels?.release(); } finally {
            try { await source?.release(); } finally { if (this.ownedDirectories.has(directory)) { await this.removeDirectory(directory); } }
          }
        }
        if (ticket === this.ticket) { this.busy = false; this.signal = undefined; }
      }
    };
    this.tail = job().catch((error: Error): void => { this.reportCleanup(error, ticket); });
    await this.tail;
  }

  async close(): Promise<void> {
    const ticket = ++this.ticket;
    this.signal?.cancel(); this.signal = undefined;
    const source = this.source, pixels = this.pixels;
    this.source = undefined; this.pixels = undefined; this.entry = undefined; this.fileEntry = undefined;
    this.busy = false; this.progress = undefined; this.errorText = '';
    this.staticFrame = false;
    this.originalLoaded = false;
    const job = async (): Promise<void> => {
      try { await pixels?.release(); } finally {
        try { await source?.release(); } finally {
          for (const owned of Array.from(this.ownedDirectories)) { await this.removeDirectory(owned); }
        }
      }
    };
    this.tail = this.tail.then(job).catch((error: Error): void => { this.reportCleanup(error, ticket); });
    await this.tail;
  }

  private async readEntry(connector: NasConnector, id: string): Promise<DriveEntry> {
    const entry = decodeDriveEntry(await connector.requestDrive(DRIVE_FILES_API, 3, 'get',
      [{ name: 'path', content: JSON.stringify('id:' + id) }]));
    if (entry.fileId !== id) { throw new NasFailure(NasErrorKind.Protocol, '图片身份未能确认，请刷新后重试。'); }
    hilog.info(0x0000, 'NasDriveOriginal', 'operation=metadata read=%{public}d preview=%{public}d download=%{public}d',
      Number(entry.capabilities.canRead), Number(entry.capabilities.canPreview), Number(entry.capabilities.canDownload));
    return entry;
  }
  private check(ticket: number): void { if (ticket !== this.ticket) { throw new NasFailure(NasErrorKind.Cancelled, '图片查看已结束。'); } }
  private async removeDirectory(directory: string): Promise<void> {
    try { await fileIo.rmdir(directory); }
    catch (error) { if ((error as BusinessError).code !== 13900002) { throw error as Error; } }
    this.ownedDirectories.delete(directory);
  }
  private reportCleanup(error: Error, ticket: number): void {
    hilog.error(0x0000, 'NasDriveOriginal', 'operation=cleanup result=failed code=%{public}d', (error as BusinessError).code ?? -1);
    if (ticket === this.ticket) { this.errorText = '图片临时资源清理失败，请退出账号后重试。'; }
  }
}
