import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasFailure, NasErrorKind } from '../../core/domain/DsmProtocol';
import { NasTransferCancellation } from '../../core/network/NasTransferTransport';
import { copyTransferFile } from '../transfers/TransferQueueFiles';
import { NoteAttachment, noteAttachmentKey, assertNoteAttachment } from './NoteProtocol';
import { NoteRepository } from './NoteRepository';

interface SavedNoteAttachment { key: string; path: string; bytes: number; }

/** 私有副本只属于当前连接；用户通过文档选择器另存的文件不归本模块清理。 */
@ObservedV2
export class NoteAttachmentStore {
  @Trace files: SavedNoteAttachment[] = [];
  @Trace busy: boolean = false;
  @Trace errorText: string = '';
  @Trace notice: string = '';
  private context: common.UIAbilityContext | undefined = undefined;
  private repository: NoteRepository | undefined = undefined;
  private ticket: number = 0;
  private signal: NasTransferCancellation | undefined = undefined;
  private owned: Set<string> = new Set<string>();
  private tail: Promise<void> = Promise.resolve();
  private ready: boolean = false;
  private onFailure: (error: Error) => Promise<void> = async (): Promise<void> => {};

  attach(context: common.UIAbilityContext | undefined, repository: NoteRepository, failure: (error: Error) => Promise<void>): void {
    this.reset(); this.context = context; this.repository = repository; this.onFailure = failure;
    if (context === undefined) { return; }
    const ticket = this.ticket;
    this.tail = this.tail.then(async (): Promise<void> => {
      const names = await fileIo.listFile(context.cacheDir);
      for (const name of names) {
        if (/^note-attachment-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(name)) { this.owned.add(context.cacheDir + '/' + name); }
      }
      for (const directory of Array.from(this.owned)) { await this.remove(directory); }
      if (ticket === this.ticket) { this.ready = true; }
    }).catch((error: Error): void => { this.cleanupFailure(error, ticket); });
  }
  reset(): void {
    this.cancel(); this.files = []; this.context = undefined; this.repository = undefined; this.ready = false;
    this.errorText = ''; this.notice = ''; this.onFailure = async (): Promise<void> => {};
    const ticket = this.ticket;
    this.tail = this.tail.then(async (): Promise<void> => { for (const directory of Array.from(this.owned)) { await this.remove(directory); } })
      .catch((error: Error): void => { this.cleanupFailure(error, ticket); });
  }
  cancel(): void { this.ticket++; this.signal?.cancel(); this.signal = undefined; this.busy = false; }
  path(item: NoteAttachment): string { return this.files.find((file: SavedNoteAttachment): boolean => file.key === noteAttachmentKey(item))?.path || ''; }
  async download(item: NoteAttachment): Promise<void> {
    const context = this.context, repository = this.repository;
    if (context === undefined || repository === undefined || this.busy || this.path(item).length > 0) { return; }
    const ticket = this.ticket, signal = new NasTransferCancellation(); this.signal = signal; this.busy = true; this.errorText = ''; this.notice = '';
    const directory = context.cacheDir + '/note-attachment-' + util.generateRandomUUID();
    const job = async (): Promise<void> => {
      let retained = false;
      try {
        this.check(ticket);
        if (!this.ready) { throw new NasFailure(NasErrorKind.Permission, '附件缓存清理未完成，请重新连接后重试。'); }
        if (item.version.length === 0) { throw new NasFailure(NasErrorKind.Protocol, '未提供附件版本，请在浏览器中下载。'); }
        const result = await repository.download(item, { directory, maximumBytes: 256 * 1024 * 1024, expectedBytes: item.bytes,
          onDirectoryCreated: (): void => { this.owned.add(directory); } }, signal);
        this.owned.add(directory); this.check(ticket);
        const after = await repository.detail(item.noteId); this.check(ticket); assertNoteAttachment(after, item);
        this.files = this.files.concat([{ key: noteAttachmentKey(item), path: result.path, bytes: result.bytes }]);
        retained = true; this.notice = '附件已下载，可另存到设备。';
      } catch (error) {
        if (ticket === this.ticket) {
          await this.onFailure(error as Error);
          if (ticket === this.ticket) { this.errorText = error instanceof NasFailure ? error.message : '附件下载失败，请重试。'; }
        }
      } finally {
        if (!retained && this.owned.has(directory)) { await this.remove(directory); }
        if (ticket === this.ticket) { this.busy = false; this.signal = undefined; }
      }
    };
    this.tail = this.tail.then(job).catch((error: Error): void => { this.cleanupFailure(error, ticket); }); await this.tail;
  }
  async save(item: NoteAttachment): Promise<void> {
    const context = this.context, file = this.files.find((value: SavedNoteAttachment): boolean => value.key === noteAttachmentKey(item));
    if (context === undefined || file === undefined || this.busy) { return; }
    const ticket = this.ticket; this.busy = true; this.errorText = ''; this.notice = '';
    let destination = '', copied = false;
    try {
      const options = new picker.DocumentSaveOptions(); options.newFileNames = [item.name.replace(/[\\/\u0000-\u001f]/g, '_')];
      const selected = await new picker.DocumentViewPicker(context).save(options); this.check(ticket);
      if (selected.length === 0) { return; } destination = selected[0];
      await copyTransferFile(file.path, destination, file.bytes, (): void => { this.check(ticket); }, true); copied = true;
      if (ticket === this.ticket) { this.notice = '附件已另存。'; }
    } catch (error) {
      if (destination.length > 0 && !copied) {
        try { await fileIo.unlink(destination); }
        catch (cleanup) { hilog.error(0, 'NasNoteAttachment', 'operation=export_cleanup code=%{public}d', (cleanup as BusinessError).code ?? -1); }
      }
      if (ticket === this.ticket) { this.errorText = error instanceof NasFailure ? error.message : '附件另存失败，请重试。'; }
    } finally { if (ticket === this.ticket) { this.busy = false; } }
  }
  private check(ticket: number): void { if (ticket !== this.ticket) { throw new NasFailure(NasErrorKind.Cancelled, '附件读取已取消。'); } }
  private async remove(directory: string): Promise<void> {
    try { await fileIo.rmdir(directory); }
    catch (error) { if ((error as BusinessError).code !== 13900002) { throw error as Error; } }
    this.owned.delete(directory);
  }
  private cleanupFailure(error: Error, ticket: number): void {
    hilog.error(0, 'NasNoteAttachment', 'operation=cleanup code=%{public}d', (error as BusinessError).code ?? -1);
    if (ticket === this.ticket) { this.ready = false; this.busy = false; this.errorText = '附件临时文件清理失败，请退出账号后重试。'; }
  }
}
