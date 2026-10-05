import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import { DriveEntry, DriveEntryKind } from '../../core/domain/DriveProtocol';
import { DRIVE_TRANSFER_MAX_BYTES, DriveTransferRecord, copyDriveTransfer, driveTransferFailureState, recoverDriveTransfer } from '../../core/domain/DriveTransferState';
import { DriveTransferAdapter } from '../../core/network/DriveTransferAdapter';
import { NasConnector } from '../../core/network/NasConnector';
import { NasTransferCancellation, NasTransferProgress, validateNasTransferFilename } from '../../core/network/NasTransferTransport';
import { closeFile } from '../../platform/SdkFileIO';
import { copyTransferFile, ensureTransferDirectory, removeTransferFile } from '../transfers/TransferQueueFiles';
import { DriveTransferStore } from './DriveTransferStore';

export interface DriveUploadDraft { parent: DriveEntry; uri: string; name: string; bytes: number; modifiedTime: number; }
interface DriveTransferSession {
  context: common.UIAbilityContext;
  origin: string;
  account: string;
  adapter: DriveTransferAdapter;
  store: DriveTransferStore;
  records: DriveTransferRecord[];
  onSessionFailure: (error: NasFailure) => Promise<void>;
  canStart: () => boolean;
}

function transferMessage(error: Object): string {
  if (error instanceof NasFailure) { return error.message; }
  const code = (error as BusinessError).code;
  return code === 13900025 || code === 13900041 ? '本机存储空间不足，请释放空间后重试。' :
    '传输未完成，请检查网络、文件授权和本机存储后重试。';
}

/** 前台单文件传输。请求开始前持久保存记录，恢复历史时绝不重新发送上传。 */
@ObservedV2
export class DriveTransferModel {
  @Trace items: DriveTransferRecord[] = [];
  @Trace draft: DriveUploadDraft | undefined = undefined;
  @Trace conflict: 'version' | 'autorename' = 'autorename';
  @Trace busy: boolean = false;
  @Trace ready: boolean = false;
  @Trace available: boolean = false;
  @Trace errorText: string = '';
  @Trace notice: string = '';
  @Trace activeId: string = '';
  @Trace progress: number | undefined = undefined;
  private session: DriveTransferSession | undefined = undefined;
  private cancellation: NasTransferCancellation | undefined = undefined;
  private tail: Promise<void> = Promise.resolve();
  private foreground: boolean = true;

  async attach(context: common.UIAbilityContext, connector: NasConnector, origin: string, account: string,
    onSessionFailure: (error: NasFailure) => Promise<void>, canStart: () => boolean = (): boolean => true): Promise<void> {
    this.detach();
    const session: DriveTransferSession = { context, origin: normalizeNasOrigin(origin), account: account.trim(),
      adapter: new DriveTransferAdapter(connector), store: new DriveTransferStore(), records: [], onSessionFailure, canStart };
    this.session = session;
    this.available = session.adapter.available();
    if (session.account.length === 0) { this.errorText = '缺少账号，无法读取 Drive 传输记录。'; return; }
    await this.tail;
    if (this.session === session) { await this.reload(); }
  }

  detach(): void {
    this.cancellation?.cancel();
    this.session = undefined;
    this.items = [];
    this.draft = undefined;
    this.busy = false;
    this.ready = false;
    this.available = false;
    this.errorText = '';
    this.notice = '';
    this.activeId = '';
    this.progress = undefined;
  }

  setForeground(foreground: boolean): void {
    this.foreground = foreground;
    if (!foreground) { this.cancellation?.cancel(); }
  }

  cancel(): void { this.cancellation?.cancel(); }
  async stopAll(): Promise<void> { this.cancel(); await this.tail; }

  async reload(): Promise<void> {
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      this.ready = false;
      const records = await session.store.load(session.context, session.origin, session.account);
      this.ensureCurrent(session);
      session.records = records.map(recoverDriveTransfer);
      await session.store.save(session.records);
      this.ensureCurrent(session);
      this.ready = true;
      this.publish(session);
    }, false);
  }

  async prepareUpload(parent: DriveEntry): Promise<void> {
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      this.requireAvailable();
      if (parent.kind !== DriveEntryKind.Folder || !parent.capabilities.canRead || !parent.capabilities.canWrite) {
        throw new NasFailure(NasErrorKind.Permission, '无法向此文件夹上传文件。');
      }
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const uris = await new picker.DocumentViewPicker(session.context).select(options);
      this.ensureCurrent(session);
      if (uris.length === 0) { return; }
      if (uris.length !== 1) { throw new NasFailure(NasErrorKind.InvalidInput, '每次请选择一个文件。'); }
      const name = validateNasTransferFilename(new fileUri.FileUri(uris[0]).name);
      const file = await fileIo.open(uris[0], fileIo.OpenMode.READ_ONLY);
      let failed = false;
      let bytes = 0;
      let modifiedTime = 0;
      try {
        const stat = await fileIo.stat(file.fd);
        if (!stat.isFile()) { throw new NasFailure(NasErrorKind.InvalidInput, '请选择文件，暂不支持上传整个文件夹。'); }
        bytes = stat.size;
        modifiedTime = stat.mtime;
        this.checkSize(bytes);
      } catch (error) { failed = true; throw error as Error; }
      finally { await closeFile(file, failed); }
      this.ensureCurrent(session);
      this.checkDuplicate(session, parent.fileId, name);
      this.conflict = 'autorename';
      this.draft = { parent, uri: uris[0], name, bytes, modifiedTime };
    });
  }

  clearDraft(): void { if (!this.busy) { this.draft = undefined; } }

  async upload(): Promise<void> {
    const draft = this.draft;
    const conflict = this.conflict;
    if (draft === undefined) { return; }
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      this.requireAvailable();
      this.checkDuplicate(session, draft.parent.fileId, draft.name);
      const record = this.newRecord(session, 'upload', draft.parent, draft.name, draft.bytes);
      await this.transfer(session, record, async (signal: NasTransferCancellation): Promise<void> => {
        await ensureTransferDirectory(this.directory(session, record));
        await copyTransferFile(draft.uri, this.directory(session, record) + '/upload', draft.bytes,
          (): void => { this.ensureCurrent(session); signal.check(); });
      }, async (signal: NasTransferCancellation): Promise<void> => {
        await session.adapter.upload(draft.parent, draft.name, conflict, draft.modifiedTime,
          { path: this.directory(session, record) + '/upload', bytes: draft.bytes },
          { cancellation: signal, onProgress: (value: NasTransferProgress): void => this.acceptProgress(session, record, value) });
      });
      if (this.session === session) { this.draft = undefined; }
    });
  }

  async download(entry: DriveEntry): Promise<void> {
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      this.requireAvailable();
      if (entry.kind !== DriveEntryKind.File || !entry.capabilities.canRead || !entry.capabilities.canDownload) {
        throw new NasFailure(NasErrorKind.Permission, '无法下载此文件。');
      }
      if (entry.sizeBytes !== undefined) { this.checkSize(entry.sizeBytes); }
      const record = this.newRecord(session, 'download', entry, entry.name, entry.sizeBytes);
      await this.transfer(session, record, async (): Promise<void> => {},
        async (signal: NasTransferCancellation): Promise<void> => {
          const result = await session.adapter.download(entry, { directory: this.directory(session, record),
            maximumBytes: DRIVE_TRANSFER_MAX_BYTES, expectedBytes: entry.sizeBytes },
            { cancellation: signal, onProgress: (value: NasTransferProgress): void => this.acceptProgress(session, record, value) });
          record.bytes = result.bytes;
        });
    });
  }

  async exportDownload(id: string): Promise<void> {
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      const record = this.find(session, id);
      if (record.direction !== 'download' || record.state !== 'completed' || record.bytes === undefined) {
        throw new NasFailure(NasErrorKind.InvalidInput, '下载尚未完成，无法保存。');
      }
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [record.name];
      const uris = await new picker.DocumentViewPicker(session.context).save(options);
      this.ensureCurrent(session);
      if (uris.length === 0) { return; }
      await copyTransferFile(this.directory(session, record) + '/content', uris[0], record.bytes,
        (): void => this.ensureCurrent(session), true);
      this.ensureCurrent(session);
      this.notice = '文件已保存到所选位置。';
    });
  }

  /** 仅在用户明确核对后关闭记录；此操作不发送任何远端请求。 */
  async closeUnknown(id: string): Promise<void> {
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      const record = this.find(session, id);
      if (record.direction !== 'upload' || record.state !== 'unknown') {
        throw new NasFailure(NasErrorKind.InvalidInput, '只有结果待确认的上传可以核对后关闭。');
      }
      const records = session.records.map((item: DriveTransferRecord): DriveTransferRecord => {
        const copy = copyDriveTransfer(item);
        if (copy.id === id) { copy.state = 'closed'; copy.errorText = ''; }
        return copy;
      });
      await this.save(session, records);
      session.records = records;
      this.publish(session);
    });
  }

  async remove(id: string): Promise<void> {
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      const record = this.find(session, id);
      if (['preparing', 'running', 'unknown'].includes(record.state)) {
        throw new NasFailure(NasErrorKind.InvalidInput, '请先停止传输；结果待确认的上传须核对后关闭。');
      }
      await this.cleanup(session, record);
      const records = session.records.filter((item: DriveTransferRecord): boolean => item.id !== id);
      await this.save(session, records);
      session.records = records;
      this.publish(session);
    });
  }

  private async transfer(session: DriveTransferSession, record: DriveTransferRecord,
    prepare: (signal: NasTransferCancellation) => Promise<void>, send: (signal: NasTransferCancellation) => Promise<void>): Promise<void> {
    if (!this.foreground) { throw new NasFailure(NasErrorKind.Cancelled, '请在应用前台开始传输。'); }
    const signal = new NasTransferCancellation();
    this.cancellation = signal;
    this.activeId = record.id;
    this.progress = undefined;
    let dispatched = false;
    let failure: Object | undefined = undefined;
    session.records.push(record);
    try {
      await this.save(session, session.records);
      this.ensureCurrent(session); signal.check();
      await prepare(signal);
      this.ensureCurrent(session); signal.check();
      record.state = 'running';
      // 保存失败时绝不发送；崩溃发生在保存后、调用前时，恢复为待确认也是保守的正确结果。
      await this.save(session, session.records);
      this.ensureCurrent(session); signal.check();
      dispatched = true;
      await send(signal);
      this.ensureCurrent(session); signal.check();
      record.state = 'completed';
      record.errorText = '';
      await this.save(session, session.records);
      if (this.session === session) {
        this.notice = record.direction === 'upload' ? '上传已完成，可刷新目标文件夹核对。' : '下载已完成，可在任务页保存到本机。';
      }
    } catch (error) {
      failure = error as Object;
      record.state = driveTransferFailureState(record.direction, dispatched, failure);
      record.errorText = record.state === 'unknown' ? '上传结果未能确认，请在 NAS 核对目标文件后关闭记录。' : transferMessage(failure);
      // 即使退出账号，也在旧账号的独立存储中记录中断结果，不向新账号发布旧响应。
      try { await this.save(session, session.records); }
      catch (_) { if (this.session === session) { this.errorText = '结果记录未保存，已暂停新传输，请重新加载记录。'; } }
      this.publish(session);
    } finally {
      if (record.direction === 'upload' || record.state !== 'completed') {
        try { await this.cleanup(session, record); }
        catch (error) {
          hilog.error(0x0000, 'NasDriveTransfer', 'operation=cleanup result=failed');
          if (this.session === session) { this.errorText = '传输临时文件清理失败，请在任务页移除已结束的记录后重试。'; }
        }
      }
      if (this.cancellation === signal) { this.cancellation = undefined; }
      if (this.session === session) { this.activeId = ''; this.progress = undefined; }
    }
    if (failure instanceof NasFailure && failure.kind === NasErrorKind.SessionExpired && this.session === session) {
      await session.onSessionFailure(failure);
    }
  }

  private async save(session: DriveTransferSession, records: DriveTransferRecord[]): Promise<void> {
    try { await session.store.save(records); }
    catch (error) { if (this.session === session) { this.ready = false; } throw error as Error; }
    this.publish(session);
  }

  private async cleanup(session: DriveTransferSession, record: DriveTransferRecord): Promise<void> {
    const directory = this.directory(session, record);
    await removeTransferFile(directory + '/upload');
    await removeTransferFile(directory + '/content');
    try { await fileIo.rmdir(directory); }
    catch (error) { if ((error as BusinessError).code !== 13900002) { throw error as Error; } }
  }

  private newRecord(session: DriveTransferSession, direction: 'upload' | 'download', entry: DriveEntry,
    name: string, bytes?: number): DriveTransferRecord {
    if (session.records.length >= 1000) { throw new NasFailure(NasErrorKind.InvalidInput, 'Drive 已保存 1000 个传输记录，请先移除已结束的记录。'); }
    const locationName = entry.displayPath || entry.name;
    if (name.length > 4096 || locationName.length > 4096) { throw new NasFailure(NasErrorKind.InvalidInput, '文件名称或位置过长，无法保存传输记录，请使用 DSM Drive 网页。'); }
    return { id: util.generateRandomUUID(), direction, resource: { nasOrigin: session.origin, account: session.account, fileId: entry.fileId },
      name: validateNasTransferFilename(name), locationName, bytes, state: 'preparing', errorText: '' };
  }

  private checkSize(bytes: number): void {
    if (!Number.isSafeInteger(bytes) || bytes < 0 || bytes > DRIVE_TRANSFER_MAX_BYTES) {
      throw new NasFailure(NasErrorKind.InvalidInput, '此文件超过 512 MB 或无法确认大小，请改用 DSM Drive 网页。');
    }
  }

  private requireAvailable(): void {
    if (!this.available) { throw new NasFailure(NasErrorKind.Unsupported, '此 NAS 无法使用 Drive 上传下载，请检查套件和账号权限。'); }
    if (this.session !== undefined && !this.session.canStart()) {
      throw new NasFailure(NasErrorKind.InvalidInput, '请先在任务页处理未结束的 Drive 文件操作。');
    }
  }

  private checkDuplicate(session: DriveTransferSession, parentId: string, name: string): void {
    if (session.records.some((record: DriveTransferRecord): boolean => record.direction === 'upload' &&
      record.resource.fileId === parentId && record.name === name && ['preparing', 'running', 'unknown'].includes(record.state))) {
      throw new NasFailure(NasErrorKind.InvalidInput, '此目标已有上传记录，请先在任务页核对处理。');
    }
  }

  private directory(session: DriveTransferSession, record: DriveTransferRecord): string { return session.store.directory + '/' + record.id; }
  private find(session: DriveTransferSession, id: string): DriveTransferRecord {
    const record = session.records.find((item: DriveTransferRecord): boolean => item.id === id);
    if (record === undefined) { throw new NasFailure(NasErrorKind.InvalidInput, '当前账号没有此 Drive 传输记录。'); }
    return record;
  }
  private ensureCurrent(session: DriveTransferSession): void {
    if (this.session !== session) { throw new NasFailure(NasErrorKind.Cancelled, '连接已变化，传输已停止。'); }
  }
  private publish(session: DriveTransferSession): void {
    if (this.session === session) { this.items = session.records.map(copyDriveTransfer); }
  }
  private acceptProgress(session: DriveTransferSession, record: DriveTransferRecord, value: NasTransferProgress): void {
    if (this.session !== session || this.activeId !== record.id) { return; }
    this.progress = value.total !== undefined && value.total > 0 ? Math.min(99, Math.max(0, value.processed / value.total * 100)) : undefined;
  }
  private async run(work: (session: DriveTransferSession) => Promise<void>, requireReady: boolean = true): Promise<void> {
    const session = this.session;
    if (session === undefined || this.busy) { return; }
    if (requireReady && !this.ready) { this.errorText = 'Drive 传输记录尚未就绪，请重新加载记录。'; return; }
    this.busy = true;
    this.errorText = '';
    this.notice = '';
    const next = this.tail.then(async (): Promise<void> => {
      this.ensureCurrent(session);
      await work(session);
    }).catch((error: Error): void => {
      if (this.session === session) {
        this.errorText = transferMessage(error);
        hilog.error(0x0000, 'NasDriveTransfer', 'operation=transfer result=failed kind=%{public}d', error instanceof NasFailure ? error.kind : -1);
      }
    }).finally((): void => { if (this.session === session) { this.busy = false; } });
    this.tail = next;
    await next;
  }
}
