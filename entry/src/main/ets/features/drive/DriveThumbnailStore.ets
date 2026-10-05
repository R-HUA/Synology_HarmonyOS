import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import type { DriveEntry } from '../../core/domain/DriveProtocol';
import { canLoadDriveThumbnail } from '../../core/domain/DriveThumbnailProtocol';
import { NasConnector } from '../../core/network/NasConnector';
import { NasTransferCancellation } from '../../core/network/NasTransferTransport';

interface DriveThumbnailCache { key: string; directory: string; path: string; bytes: number; }
interface DriveThumbnailTask {
  key: string; entry: DriveEntry; ticket: number; cancellation: NasTransferCancellation;
}

/** 可见行按需读取，最多 3 个请求；账号切换后不复用任何媒体文件。 */
@ObservedV2
export class DriveThumbnailStore {
  @Trace paths: Record<string, string> = {};
  @Trace errorText: string = '';
  private connector: NasConnector | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;
  private onSessionFailure: ((error: NasFailure) => Promise<void>) | undefined = undefined;
  private generation: number = 0;
  private foreground: boolean = true;
  private directory: string = '';
  private cache: DriveThumbnailCache[] = [];
  private visible: Map<string, DriveEntry> = new Map();
  private pending: DriveThumbnailTask[] = [];
  private active: Map<string, DriveThumbnailTask> = new Map();
  private failed: Set<string> = new Set();
  private cleanupPaths: string[] = [];

  attach(context: common.UIAbilityContext | undefined, connector: NasConnector,
    onSessionFailure: (error: NasFailure) => Promise<void>): void {
    this.detach();
    this.context = context;
    this.connector = connector;
    this.onSessionFailure = onSessionFailure;
  }

  detach(): void {
    this.generation++;
    for (const task of this.active.values()) { task.cancellation.cancel(); }
    this.active.clear();
    this.pending = [];
    this.visible.clear();
    this.failed.clear();
    this.cache = [];
    this.paths = {};
    this.connector = undefined;
    this.context = undefined;
    this.onSessionFailure = undefined;
    if (this.directory.length > 0) { this.remove(this.directory); }
    this.directory = '';
    this.errorText = this.cleanupPaths.length === 0 ? '' : '缩略图缓存清理未完成，请重新登录后重试。';
  }

  path(entry: DriveEntry): string { return this.paths[this.key(entry)] ?? ''; }

  setVisible(entry: DriveEntry, visible: boolean): void {
    const key = this.key(entry);
    if (!visible) {
      this.visible.delete(key);
      this.pending = this.pending.filter((task: DriveThumbnailTask): boolean => task.key !== key);
      this.active.get(key)?.cancellation.cancel();
      return;
    }
    if (!canLoadDriveThumbnail(entry)) { return; }
    this.visible.set(key, entry);
    const index = this.cache.findIndex((row: DriveThumbnailCache): boolean => row.key === key);
    if (index >= 0) { this.cache.push(this.cache.splice(index, 1)[0]); return; }
    this.enqueue(entry);
    this.drain();
  }

  setForeground(foreground: boolean): void {
    this.foreground = foreground;
    if (!foreground) {
      this.pending = [];
      for (const task of this.active.values()) { task.cancellation.cancel(); }
    } else {
      for (const entry of this.visible.values()) { this.enqueue(entry); }
      this.drain();
    }
  }

  /** 用户刷新才清除失败记忆，避免缺缩略图的文件随滚动反复请求。 */
  retryVisible(): void {
    this.failed.clear();
    const leftovers = this.cleanupPaths.slice();
    this.cleanupPaths = [];
    for (const path of leftovers) { this.remove(path); }
    this.errorText = this.cleanupPaths.length === 0 ? '' : '缩略图缓存清理未完成，请重新登录后重试。';
    for (const entry of this.visible.values()) { this.enqueue(entry); }
    this.drain();
  }

  private enqueue(entry: DriveEntry): void {
    const key = this.key(entry);
    if (!this.foreground || this.connector === undefined || this.context === undefined || this.cleanupPaths.length > 0 ||
      this.paths[key] !== undefined || this.failed.has(key) || this.active.has(key) ||
      this.pending.some((task: DriveThumbnailTask): boolean => task.key === key) || this.pending.length >= 60) { return; }
    this.pending.push({ key, entry, ticket: this.generation, cancellation: new NasTransferCancellation() });
  }

  private drain(): void {
    while (this.foreground && this.cleanupPaths.length === 0 && this.active.size < 3 && this.pending.length > 0) {
      const task = this.pending.shift();
      if (task === undefined) { return; }
      this.active.set(task.key, task);
      this.fetch(task).catch((): void => {
        if (task.ticket === this.generation) {
          this.errorText = '缩略图读取未完成，请重新登录后重试。';
          hilog.error(0x0000, 'NasDrive', 'operation=thumbnail_session result=failed');
        }
      }).finally((): void => {
        if (task.ticket !== this.generation) { return; }
        this.active.delete(task.key);
        // 取消期间重新显示的行应能够重新读取；失败则等用户刷新。
        if (task.cancellation.cancelled && this.visible.has(task.key)) { this.enqueue(task.entry); }
        this.drain();
      });
    }
  }

  private async fetch(task: DriveThumbnailTask): Promise<void> {
    const connector = this.connector;
    let directory = '';
    try {
      if (connector === undefined) { return; }
      directory = this.privateDirectory();
      const result = await connector.thumbnailDrive({ fileId: task.entry.fileId, versionId: task.entry.versionId },
        directory, { cancellation: task.cancellation });
      this.check(task);
      await this.validateImage(result.path);
      this.check(task);
      this.cache.push({ key: task.key, directory, path: result.path, bytes: result.bytes });
      directory = '';
      this.evict();
      this.publish();
    } catch (error) {
      if (task.ticket !== this.generation || task.cancellation.cancelled) { return; }
      this.failed.add(task.key);
      this.errorText = '部分文件的缩略图未能读取，可刷新后重试。';
      hilog.error(0x0000, 'NasDrive', 'operation=thumbnail kind=%{public}d', error instanceof NasFailure ? error.kind : -1);
      if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) {
        const onSessionFailure = this.onSessionFailure;
        if (onSessionFailure !== undefined) { await onSessionFailure(error); }
      }
    } finally { if (directory.length > 0) { this.remove(directory); } }
  }

  private async validateImage(path: string): Promise<void> {
    const source = image.createImageSource(path);
    let pixels: image.PixelMap | undefined = undefined;
    try {
      const info = await source.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0 || info.size.width * info.size.height > 4 * 1024 * 1024) {
        throw new NasFailure(NasErrorKind.Protocol, '缩略图尺寸无效。');
      }
      pixels = await source.createPixelMap({ desiredSize: { width: 96, height: 96 } });
    } finally { await pixels?.release(); await source.release(); }
  }

  private check(task: DriveThumbnailTask): void {
    task.cancellation.check();
    if (task.ticket !== this.generation) { throw new NasFailure(NasErrorKind.Cancelled, '缩略图读取已取消。'); }
  }

  private privateDirectory(): string {
    const context = this.context;
    if (context === undefined || this.cleanupPaths.length > 0) { throw new NasFailure(NasErrorKind.Protocol, '无法使用缩略图缓存。'); }
    if (this.directory.length === 0) {
      const base = context.cacheDir + '/drive-thumbnails';
      // 该目录只属于缩略图功能；进程重启不复用上个账号的残留文件。
      if (fileIo.accessSync(base)) { this.remove(base); }
      if (this.cleanupPaths.length > 0) { throw new NasFailure(NasErrorKind.Protocol, '缩略图缓存清理未完成。'); }
      this.directory = base + '/' + util.generateRandomUUID();
      fileIo.mkdirSync(this.directory, true);
    }
    return this.directory + '/' + util.generateRandomUUID();
  }

  private evict(): void {
    let bytes = this.cache.reduce((sum: number, row: DriveThumbnailCache): number => sum + row.bytes, 0);
    while (this.cache.length > 60 || bytes > 24 * 1024 * 1024) {
      const unpinned = this.cache.findIndex((row: DriveThumbnailCache): boolean => !this.visible.has(row.key));
      const row = this.cache.splice(unpinned >= 0 ? unpinned : 0, 1)[0];
      if (row === undefined) { return; }
      bytes -= row.bytes;
      this.remove(row.directory);
    }
  }

  private publish(): void {
    const paths: Record<string, string> = {};
    for (const row of this.cache) { paths[row.key] = row.path; }
    this.paths = paths;
  }

  private key(entry: DriveEntry): string {
    return JSON.stringify([entry.fileId, entry.versionId, entry.modifiedAt, entry.sizeBytes]);
  }

  private remove(directory: string): void {
    try { if (fileIo.accessSync(directory)) { fileIo.rmdirSync(directory); } }
    catch (_) {
      if (!this.cleanupPaths.includes(directory)) { this.cleanupPaths.push(directory); }
      this.errorText = '缩略图缓存清理未完成，请重新登录后重试。';
      hilog.error(0x0000, 'NasDrive', 'operation=thumbnail_cleanup result=failed');
    }
  }
}
