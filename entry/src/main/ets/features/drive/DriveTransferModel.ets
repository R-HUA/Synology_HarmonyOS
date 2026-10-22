import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { filePreview } from '@kit.PreviewKit';
import { NasErrorKind, NasFailure, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import { DriveEntry, DriveEntryKind } from '../../core/domain/DriveProtocol';
import { DRIVE_TRANSFER_MAX_BYTES, DriveTransferRecord, copyDriveTransfer, driveTransferFailureState, recoverDriveTransfer } from '../../core/domain/DriveTransferState';
import { DriveTransferAdapter } from '../../core/network/DriveTransferAdapter';
import { NasConnector } from '../../core/network/NasConnector';
import { NasTransferCancellation, NasTransferControl, NasTransferProgress, validateNasTransferFilename } from '../../core/network/NasTransferTransport';
import { SdkBackgroundTransfer } from '../../platform/SdkBackgroundTransfer';
import { verifyDriveDownloadedFile } from './DriveDownloadVerification';
import { closeFile, writePrivateSnapshot } from '../../platform/SdkFileIO';
import { copyTransferFile, ensureTransferDirectory, hashTransferFile, removeTransferFile } from '../transfers/TransferQueueFiles';
import { DriveTransferStore } from './DriveTransferStore';
import { DriveBackgroundTransfer } from './DriveBackgroundTransfer';
import { DriveUploadRequest } from '../../core/domain/DriveTransferProtocol';
import { DownloadSubmitResult } from '../../core/domain/DownloadSubmitResult';
import { copyDriveUploadRemainder } from './DriveUploadSlice';
import { TransferRates } from '../../core/domain/TransferRates';

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
  background?: DriveBackgroundTransfer;
  rcpBackground: boolean;
  accountGuardBlocked: boolean;
}

function transferMessage(error: Object): string {
  if (error instanceof NasFailure) { return error.message; }
  const code = (error as BusinessError).code;
  return code === 13900025 || code === 13900041 ? '本机存储空间不足，请释放空间后重试。' :
    '传输未完成，请检查网络、文件授权和本机存储后重试。';
}

/** 前台与系统后台传输共用账号记录；恢复读取原任务，未知上传不自动重放。 */
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
  @Trace backgroundAvailable: boolean = false;
  @Trace useBackground: boolean = true;
  @Trace applicationBackground: boolean = false;
  private lease: SdkBackgroundTransfer = new SdkBackgroundTransfer();
  private activeRecord: DriveTransferRecord | undefined = undefined;
  private pauseRequested: string = '';
  private session: DriveTransferSession | undefined = undefined;
  private cancellation: NasTransferCancellation | undefined = undefined;
  private tail: Promise<void> = Promise.resolve();
  private foreground: boolean = true;
  private timer: number = -1;
  private rates: TransferRates = new TransferRates();
  private processed: Map<string, number> = new Map();
  get hasPending(): boolean { return this.busy || this.items.some((item: DriveTransferRecord): boolean => ['preparing', 'creating', 'waiting', 'running', 'paused', 'verifying', 'unknown'].includes(item.state)); }
  get hasActive(): boolean { return this.busy || this.items.some((item: DriveTransferRecord): boolean => ['preparing', 'creating', 'waiting', 'running', 'paused'].includes(item.state)); }

  async attach(context: common.UIAbilityContext, connector: NasConnector, origin: string, account: string,
    onSessionFailure: (error: NasFailure) => Promise<void>, canStart: () => boolean = (): boolean => true,
    insecureTls: boolean = false): Promise<void> {
    const normalized = normalizeNasOrigin(origin);
    if (this.session !== undefined && (this.session.origin !== normalized || this.session.account !== account.trim()) &&
      this.session.records.some((record: DriveTransferRecord): boolean => record.background !== undefined &&
      (record.background.taskId.length > 0 || record.state === 'creating'))) {
      throw new NasFailure(NasErrorKind.InvalidInput, '请先停止原账号的 Drive 后台任务，再切换连接。');
    }
    this.detach();
    const session: DriveTransferSession = { context, origin: normalized, account: account.trim(),
      adapter: new DriveTransferAdapter(connector), store: new DriveTransferStore(), records: [], onSessionFailure, canStart,
      rcpBackground: insecureTls && normalized.startsWith('https:'), accountGuardBlocked: false };
    this.session = session;
    this.available = session.adapter.available();
    this.applicationBackground = session.rcpBackground;
    this.backgroundAvailable = session.rcpBackground ? SdkBackgroundTransfer.available() :
      session.adapter.backgroundAvailable() && canIUse('SystemCapability.Request.FileTransferAgent');
    this.useBackground = this.backgroundAvailable;
    if (session.account.length === 0) { this.errorText = '缺少账号，无法读取 Drive 传输记录。'; return; }
    await this.tail;
    if (this.session === session) { await this.reload(); }
  }

  detach(): void {
    this.rates.clear(); this.processed.clear();
    this.cancellation?.cancel();
    this.session?.background?.detach();
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
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
    this.backgroundAvailable = false;
    this.applicationBackground = false;
  }

  setForeground(foreground: boolean): void {
    this.foreground = foreground;
    if (!foreground && !this.lease.active) { this.cancellation?.cancel(); }
  }

  cancel(): void { this.cancellation?.cancel(); }
  /** 失败向连接层传播，禁止登出后遗留继续使用旧 Cookie 的系统任务。 */
  async stopAll(): Promise<void> {
    this.cancel(); await this.tail;
    await this.lease.stop();
    const session = this.session;
    if (session === undefined) { return; }
    if (!this.ready && !session.accountGuardBlocked) { throw new NasFailure(NasErrorKind.Protocol, 'Drive 记录尚未就绪，请重新加载后停止后台任务。'); }
    const stopping = this.tail.then(async (): Promise<void> => {
      for (const record of session.records) {
        await session.background?.stop(record); this.ensureCurrent(session);
        if (['preparing', 'creating', 'waiting', 'running', 'paused', 'unknown'].includes(record.state)) {
          record.state = record.direction === 'upload' && (record.background?.startAttempted || record.uploadSession?.started || record.state === 'unknown') ? 'unknown' : 'cancelled';
          record.errorText = record.state === 'unknown' ? '上传已停止，请在 NAS 核对目标文件。' : '';
        }
      }
      await this.save(session, session.records);
      for (const record of session.records.filter((item: DriveTransferRecord): boolean => item.state === 'cancelled')) {
        await this.cleanup(session, record);
      }
      session.records = session.records.filter((record: DriveTransferRecord): boolean => record.state !== 'cancelled');
      await this.save(session, session.records);
    });
    this.tail = stopping.catch((): void => {});
    await stopping;
  }

  async reload(): Promise<void> {
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      this.ready = false;
      session.accountGuardBlocked = false;
      const records = await session.store.load(session.context, session.origin, session.account);
      this.ensureCurrent(session);
      session.records = records.filter((record: DriveTransferRecord): boolean => record.state !== 'cancelled').map(recoverDriveTransfer);
      session.background?.detach();
      if (session.adapter.backgroundAvailable() && canIUse('SystemCapability.Request.FileTransferAgent')) {
        session.background = new DriveBackgroundTransfer(session.context, session.adapter, session.origin, session.store.identity,
          session.store.directory, (): void => this.ensureCurrent(session), (): Promise<void> => this.save(session, session.records),
          (work: () => Promise<void>): void => this.backgroundWork(session, work), (): void => this.publish(session));
      }
      await session.store.save(session.records);
      this.ensureCurrent(session);
      try { await session.background?.guardAccount(); }
      catch (error) {
        session.accountGuardBlocked = error instanceof NasFailure && error.kind === NasErrorKind.InvalidInput;
        throw error as Error;
      }
      this.ready = true;
      await this.refreshSession(session);
      this.publish(session);
      if (session.background !== undefined && this.timer === -1) {
        this.timer = setInterval((): void => {
          if (this.session === session && this.ready && !this.busy && this.foreground && this.hasActive) { this.refresh(); }
        }, 2000);
      }
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
      if (session.records.some((record: DriveTransferRecord): boolean => record.direction === 'upload' &&
        !['completed', 'failed', 'cancelled', 'closed'].includes(record.state))) {
        throw new NasFailure(NasErrorKind.InvalidInput, '仍有上传进行中或结果待核对，请先处理任务。');
      }
      this.checkDuplicate(session, draft.parent.fileId, draft.name);
      const record = this.newRecord(session, 'upload', draft.parent, draft.name, draft.bytes);
      if (record.executor === 'agent' || conflict === 'version' && session.adapter.sliceAvailable()) {
        await this.managedUpload(session, record, draft, conflict);
        this.draft = undefined;
        return;
      }
      await this.transfer(session, record, async (signal: NasTransferCancellation): Promise<void> => {
        await ensureTransferDirectory(this.directory(session, record));
        await copyTransferFile(draft.uri, this.directory(session, record) + '/upload', draft.bytes,
          (): void => { this.ensureCurrent(session); signal.check(); });
      }, async (control: NasTransferControl): Promise<void> => {
        await session.adapter.upload(draft.parent, draft.name, conflict, draft.modifiedTime,
          { path: this.directory(session, record) + '/upload', bytes: draft.bytes }, control);
      });
      if (this.session === session) { this.draft = undefined; }
    });
  }

  /** 系统支持的常见文件可以直接打开；其他格式保留详情和显式下载入口。 */
  canPreview(entry: DriveEntry): boolean {
    return canIUse('SystemCapability.FileManagement.FilePreview.Core') &&
      /\.(txt|cpp|c|h|java|xhtml|xml|html|htm|svg|m4a|aac|mp3|ogg|wav|mp4|mkv|ts|pdf|doc|docx|xls|xlsx|ppt|pptx|csv|ofd)$/i.test(entry.name);
  }

  /** 提交回调在执行器接管后调用一次；返回值仍等待前台下载及预览结束。 */
  async download(entry: DriveEntry, openAfterDownload: boolean = false,
    onSubmitted: (result: DownloadSubmitResult) => void = (): void => {}): Promise<void> {
    if (this.session === undefined || !this.ready || this.busy) {
      onSubmitted({ status: 'rejected', message: this.busy ? '正在处理其他任务，请稍后重试' : '传输记录尚未就绪，请重新加载' });
      return;
    }
    let submitted = false;
    let recordId = '';
    let submissionError = '';
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      try {
      this.requireAvailable(false);
      if (entry.kind !== DriveEntryKind.File || !entry.capabilities.canRead || !entry.capabilities.canDownload) {
        throw new NasFailure(NasErrorKind.Permission, '无法下载此文件。');
      }
      if (entry.sizeBytes !== undefined) { this.checkSize(entry.sizeBytes); }
      const existing = session.records.find((item: DriveTransferRecord): boolean => item.direction === 'download' &&
        item.resource.fileId === entry.fileId && !['completed', 'failed', 'cancelled', 'closed'].includes(item.state));
      if (existing !== undefined) {
        submitted = true;
        onSubmitted({ status: 'duplicate', taskId: existing.id, message: '该任务已存在' });
        return;
      }
      const next = this.newRecord(session, 'download', entry, entry.name, entry.sizeBytes);
      // 打开文件必须在前台完成，避免尚未就绪就跳转到传输页。
      if (openAfterDownload) { next.executor = 'foreground'; }
      if (next.executor === 'agent' && session.background !== undefined) {
        session.records.push(next); recordId = next.id;
        await this.save(session, session.records);
        await ensureTransferDirectory(this.directory(session, next)); this.ensureCurrent(session);
        await session.background.create(next);
        submitted = true;
        onSubmitted({ status: 'created', taskId: next.id, message: '已添加下载任务' });
        this.notice = '后台下载已开始，可在任务页查看进度。';
        return;
      }
      await this.transfer(session, next, async (): Promise<void> => {},
        async (control: NasTransferControl): Promise<void> => {
          submitted = true;
          onSubmitted({ status: 'created', taskId: next.id, message: '已添加下载任务' });
          const result = await session.adapter.download(entry, { directory: this.directory(session, next),
            maximumBytes: DRIVE_TRANSFER_MAX_BYTES, expectedBytes: entry.sizeBytes }, control);
          next.bytes = result.bytes;
        });
      if (!submitted) {
        if (session.records.includes(next)) { recordId = next.id; }
        submissionError = next.errorText;
      }
      if (openAfterDownload && next.state === 'completed') {
        const path = this.directory(session, next) + '/' + next.name;
        await copyTransferFile(this.directory(session, next) + '/content', path, next.bytes!,
          (): void => this.ensureCurrent(session));
        this.ensureCurrent(session);
        const uri = fileUri.getUriFromPath(path);
        if (!await filePreview.canPreview(session.context, uri)) {
          throw new NasFailure(NasErrorKind.Unsupported, '系统暂不支持预览此文件。');
        }
        this.ensureCurrent(session);
        if (!this.foreground) { throw new NasFailure(NasErrorKind.Cancelled, '请返回应用后重新打开文件。'); }
        await filePreview.openPreview(session.context, { uri: uri, title: next.name, mimeType: '' });
        this.notice = '';
      }
      } catch (error) {
        submissionError = transferMessage(error as Object);
        this.publish(session);
        throw error as Error;
      }
    });
    if (!submitted) {
      onSubmitted({ status: recordId.length > 0 ? 'unconfirmed' : 'failed', taskId: recordId.length > 0 ? recordId : undefined,
        message: recordId.length > 0 ? '任务提交未完成' : submissionError || '下载提交失败' });
    }
  }

  async verifyDownload(id: string): Promise<void> {
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      const record = this.find(session, id);
      if (!this.foreground || record.state !== 'verifying') {
        throw new NasFailure(NasErrorKind.InvalidInput, '请在前台确认校验待处理的下载文件。');
      }
      const signal = new NasTransferCancellation(); this.cancellation = signal; this.activeId = id;
      try {
        const md5 = await verifyDriveDownloadedFile(session.adapter, record, this.directory(session, record), signal,
          (): void => this.ensureCurrent(session));
        this.ensureCurrent(session); signal.check();
        record.verifiedMd5 = md5; record.state = 'completed'; record.errorText = '';
        await this.save(session, session.records);
        await session.background?.stop(record);
        this.notice = '已校验完整文件内容，可以保存到本机。';
      } catch (error) {
        if (record.state !== 'completed') { record.errorText = transferMessage(error as Object); }
        await this.save(session, session.records); throw error as Error;
      } finally {
        if (this.cancellation === signal) { this.cancellation = undefined; }
        if (this.session === session) { this.activeId = ''; }
      }
    });
  }

  async exportDownload(id: string): Promise<boolean> {
    let saved = false;
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
      if (record.verifiedMd5 !== undefined && await hashTransferFile(this.directory(session, record) + '/content', record.bytes,
        (): void => this.ensureCurrent(session)) !== record.verifiedMd5) {
        throw new NasFailure(NasErrorKind.Protocol, '已校验的本机副本发生变化，请重新下载。');
      }
      await copyTransferFile(this.directory(session, record) + '/content', uris[0], record.bytes,
        (): void => this.ensureCurrent(session), true);
      this.ensureCurrent(session);
      this.notice = '文件已保存到所选位置。';
      saved = true;
    });
    return saved;
  }

  /** 仅在用户明确核对后关闭记录；此操作不发送任何远端请求。 */
  async closeUnknown(id: string): Promise<void> {
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      const record = this.find(session, id);
      if (record.direction !== 'upload' || record.state !== 'unknown') {
        throw new NasFailure(NasErrorKind.InvalidInput, '只有结果待确认的上传可以核对后关闭。');
      }
      await session.background?.stop(record);
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

  async remove(id: string, deleteLocalFile: boolean = true): Promise<boolean> {
    let removed = false;
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      const record = this.find(session, id);
      if (['preparing', 'creating', 'waiting', 'running', 'paused', 'unknown'].includes(record.state)) {
        throw new NasFailure(NasErrorKind.InvalidInput, '请先停止传输；结果待确认的上传须核对后关闭。');
      }
      await session.background?.stop(record);
      if (deleteLocalFile || record.direction !== 'download') { await this.cleanup(session, record); }
      const records = session.records.filter((item: DriveTransferRecord): boolean => item.id !== id);
      await this.save(session, records);
      session.records = records;
      this.publish(session);
      removed = true;
    });
    return removed;
  }

  async refresh(): Promise<void> {
    await this.run(async (session: DriveTransferSession): Promise<void> => { await this.refreshSession(session); });
  }
  async cancelTask(id: string): Promise<void> {
    if (this.activeId === id) { this.cancel(); return; }
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      const record = this.find(session, id);
      await session.background?.stop(record); this.ensureCurrent(session);
      record.state = record.direction === 'upload' && (record.uploadSession?.started || record.background?.startAttempted || record.state === 'unknown') ? 'unknown' : 'cancelled';
      record.errorText = record.state === 'unknown' ? '上传已停止，请先核对目标文件，再关闭记录或继续原上传。' : '';
      await this.save(session, session.records);
      if (record.state === 'cancelled') {
        await this.cleanup(session, record);
        session.records = session.records.filter((item: DriveTransferRecord): boolean => item.id !== id);
        await this.save(session, session.records);
      }
    });
  }
  async pause(id: string): Promise<void> {
    const active = this.activeRecord;
    if (this.activeId === id && active !== undefined && active.direction === 'upload' &&
      active.uploadSession !== undefined && active.state === 'running') {
      this.pauseRequested = id; this.cancellation?.cancel(); await this.tail; return;
    }
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      const record = this.find(session, id);
      if (record.direction !== 'upload' || record.state !== 'running' || record.uploadSession === undefined) {
        throw new NasFailure(NasErrorKind.InvalidInput, '仅保存新版本的上传支持暂停；下载请取消后重新下载。');
      }
      if (session.background === undefined) { throw new NasFailure(NasErrorKind.Unsupported, '此传输只能停止，无法暂停。'); }
      await session.background.pause(record);
    });
  }
  /** 必须由任务页用户明确确认；不为未知记录生成新的 token。 */
  async resume(id: string): Promise<void> {
    await this.run(async (session: DriveTransferSession): Promise<void> => {
      this.requireAvailable();
      const record = this.find(session, id);
      if (record.direction === 'download') {
        throw new NasFailure(NasErrorKind.InvalidInput, '暂不支持下载续传，请取消旧任务后重新下载。');
      }
      if (session.records.some((item: DriveTransferRecord): boolean => item.id !== id && item.direction === 'upload' &&
        !['completed', 'failed', 'cancelled', 'closed'].includes(item.state))) {
        throw new NasFailure(NasErrorKind.InvalidInput, '仍有其他上传进行中或结果待核对，请先处理任务。');
      }
      if (record.state === 'paused' && record.background?.startAttempted === false && record.background.taskId.length > 0) {
        await session.background?.startUnstarted(record); return;
      }
      if (!['paused', 'unknown'].includes(record.state) || record.uploadSession === undefined) {
        throw new NasFailure(NasErrorKind.InvalidInput, '此记录不能继续原上传，请先在 NAS 核对结果。');
      }
      await session.background?.stop(record);
      await this.continueUpload(session, record);
    });
  }

  private async refreshSession(session: DriveTransferSession): Promise<void> {
    for (const record of session.records) {
      if (record.background !== undefined) { await session.background?.refresh(record); }
    }
  }

  private backgroundWork(session: DriveTransferSession, work: () => Promise<void>): void {
    if (this.session !== session) { return; }
    let failure: NasFailure | undefined = undefined;
    const next = this.tail.then(async (): Promise<void> => { this.ensureCurrent(session); await work(); })
      .catch((error: Error): void => {
        if (this.session !== session) { return; }
        this.errorText = transferMessage(error);
        if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { failure = error; }
      });
    this.tail = next;
    // 通知位于尾链之外，连接层可安全 await stopAll() 后再清理账号。
    next.then(async (): Promise<void> => {
      if (failure !== undefined && this.session === session) { await session.onSessionFailure(failure); }
    }).catch((error: Error): void => { if (this.session === session) { this.errorText = transferMessage(error); } });
  }

  private async managedUpload(session: DriveTransferSession, record: DriveTransferRecord, draft: DriveUploadDraft,
    conflict: 'version' | 'autorename'): Promise<void> {
    const signal = new NasTransferCancellation(); this.cancellation = signal; this.activeId = record.id;
    session.records.push(record);
    try {
      await this.save(session, session.records);
      await ensureTransferDirectory(this.directory(session, record));
      await copyTransferFile(draft.uri, this.directory(session, record) + '/upload', draft.bytes,
        (): void => { this.ensureCurrent(session); signal.check(); });
      this.ensureCurrent(session); signal.check();
      if (conflict === 'version' && session.adapter.sliceAvailable()) {
        const path = this.directory(session, record) + '/upload';
        const stat = await fileIo.stat(path);
        const md5 = await hashTransferFile(path, draft.bytes, (): void => { this.ensureCurrent(session); signal.check(); });
        record.uploadSession = { token: util.generateRandomUUID().replace(/-/g, ''), modifiedTime: draft.modifiedTime,
          sourceMtime: stat.mtime, sourceMd5: md5, started: false, offset: 0 };
        await this.save(session, session.records);
        await this.continueUpload(session, record, signal);
      } else if (session.background !== undefined) {
        signal.check(); await session.background.create(record, draft.modifiedTime, conflict);
      }
      this.notice = record.state === 'completed' ? '上传已完成，可刷新目标文件夹核对。' :
        record.state === 'paused' ? '上传已暂停，可在任务页确认继续。' : '后台上传已开始，可在任务页查看进度。';
    } catch (error) {
      if (record.state !== 'completed' && (record.background === undefined || record.state !== 'creating')) {
        record.state = driveTransferFailureState('upload', record.uploadSession?.started === true || record.background?.startAttempted === true, error as Object);
        record.errorText = record.state === 'unknown' ? '上传结果未能确认，请在 NAS 核对目标文件后关闭记录或继续原上传。' : transferMessage(error as Object);
      }
      try { await this.save(session, session.records); } catch (_) {}
      throw error as Error;
    } finally {
      if (this.cancellation === signal) { this.cancellation = undefined; }
      if (this.activeRecord === record) { this.activeRecord = undefined; }
      if (this.session === session) { this.activeId = ''; this.progress = undefined; }
    }
    if (record.state === 'cancelled') {
      session.records = session.records.filter((item: DriveTransferRecord): boolean => item.id !== record.id);
      await this.save(session, session.records);
    }
  }

  private async continueUpload(session: DriveTransferSession, record: DriveTransferRecord,
    signal: NasTransferCancellation = new NasTransferCancellation()): Promise<void> {
    if (!this.foreground) { throw new NasFailure(NasErrorKind.Cancelled, '请在前台确认继续上传。'); }
    const upload = record.uploadSession!;
    const directory = this.directory(session, record);
    const path = directory + '/upload';
    record.executor = this.execution(session);
    // 原系统任务必须已经停止；不能让持久化记录仍指向旧执行器。
    if (record.executor !== 'agent') { record.background = undefined; }
    this.cancellation = signal; this.activeId = record.id; this.activeRecord = record;
    const input: DriveUploadRequest = { parentId: record.resource.fileId, filename: record.name, conflict: 'version', modifiedTime: upload.modifiedTime };
    try {
      const stat = await fileIo.stat(path);
      if (!stat.isFile() || stat.size !== record.bytes || stat.mtime !== upload.sourceMtime ||
        await hashTransferFile(path, record.bytes!, (): void => { this.ensureCurrent(session); signal.check(); }) !== upload.sourceMd5) {
        throw new NasFailure(NasErrorKind.InvalidInput, '本机上传副本已变化，无法继续原上传，请先核对 NAS。');
      }
      await writePrivateSnapshot(directory + '/probe', new Uint8Array(0)); this.ensureCurrent(session); signal.check();
      await this.rcpOperation(session, record, signal, async (control: NasTransferControl): Promise<void> => {
        const result = await session.adapter.probeUpload(input, upload.token, { path: directory + '/probe', bytes: 0 }, record.bytes!, upload.started, control);
        this.ensureCurrent(session); signal.check(); upload.offset = result.uploadedBytes;
        await this.save(session, session.records);
        if (record.executor === 'agent' && session.background !== undefined) {
          await session.background.create(record, upload.modifiedTime);
        } else {
          await copyDriveUploadRemainder(path, directory + '/remainder', record.bytes!, upload.offset,
            (): void => { this.ensureCurrent(session); signal.check(); });
          upload.started = true; record.state = 'running'; record.errorText = '';
          await this.save(session, session.records); this.ensureCurrent(session); signal.check();
          await session.adapter.uploadSlice(input, upload.token, { path: directory + '/remainder', bytes: record.bytes! - upload.offset }, record.bytes!, control);
          this.ensureCurrent(session); signal.check(); record.state = 'completed'; record.errorText = '';
          await this.save(session, session.records);
        }
      });
    } catch (error) {
      const paused = this.pauseRequested === record.id && error instanceof NasFailure && error.kind === NasErrorKind.Cancelled;
      // 探测失败、token 过期或完成歧义都保留原 token/source，绝不从头另传。
      if (upload.started && record.state !== 'creating' && record.state !== 'completed') {
        record.state = paused ? 'paused' : 'unknown';
        record.errorText = paused ? '' : transferMessage(error as Object);
      }
      try { await this.save(session, session.records); } catch (_) {}
      if (!paused) { throw error as Error; }
    } finally {
      if (this.pauseRequested === record.id) { this.pauseRequested = ''; }
      if (this.cancellation === signal) { this.cancellation = undefined; }
      if (this.activeRecord === record) { this.activeRecord = undefined; }
      if (this.session === session) { this.activeId = ''; this.progress = undefined; }
    }
  }

  private execution(session: DriveTransferSession): 'foreground' | 'agent' | 'rcpBackground' {
    return !this.useBackground || !this.backgroundAvailable ? 'foreground' : session.rcpBackground ? 'rcpBackground' : 'agent';
  }

  private async rcpOperation(session: DriveTransferSession, record: DriveTransferRecord, signal: NasTransferCancellation,
    work: (control: NasTransferControl) => Promise<void>): Promise<void> {
    const background = record.executor === 'rcpBackground';
    try {
      this.ensureCurrent(session); signal.check();
      if (background) {
        if (!this.foreground) { throw new NasFailure(NasErrorKind.Cancelled, '请在前台开始应用后台传输。'); }
        await this.lease.start(session.context, record.direction === 'upload' ? 'Drive 上传' : 'Drive 下载', (): void => signal.cancel());
      }
      this.ensureCurrent(session); signal.check();
      await work({ cancellation: signal, background,
        checkNetwork: background ? (): void => this.lease.check() : undefined,
        onProgress: (value: NasTransferProgress): void => {
          this.acceptProgress(session, record, value);
          if (background) { this.lease.progress(value.processed, value.total); }
        } });
    } finally {
      if (background) {
        try { await this.lease.stop(); }
        catch (error) { if (this.session === session) { this.ready = false; } throw error as Error; }
      }
    }
  }

  private async transfer(session: DriveTransferSession, record: DriveTransferRecord,
    prepare: (signal: NasTransferCancellation) => Promise<void>, send: (control: NasTransferControl) => Promise<void>): Promise<void> {
    if (!this.foreground) { throw new NasFailure(NasErrorKind.Cancelled, '请在应用前台开始传输。'); }
    const signal = new NasTransferCancellation();
    this.cancellation = signal;
    this.activeId = record.id;
    this.activeRecord = record;
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
      await this.rcpOperation(session, record, signal, async (control: NasTransferControl): Promise<void> => {
        dispatched = true; await send(control);
      });
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
      if (this.session === session) { this.errorText = record.errorText; }
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
      if (this.activeRecord === record) { this.activeRecord = undefined; }
      if (this.session === session) { this.activeId = ''; this.progress = undefined; }
    }
    if (record.state === 'cancelled') {
      session.records = session.records.filter((item: DriveTransferRecord): boolean => item.id !== record.id);
      await this.save(session, session.records);
    }
    if (failure instanceof NasFailure && failure.kind === NasErrorKind.SessionExpired && this.session === session) {
      throw failure;
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
    if (record.direction === 'download' && record.name !== 'content') { await removeTransferFile(directory + '/' + record.name); }
    await removeTransferFile(directory + '/probe');
    await removeTransferFile(directory + '/remainder');
    try { await fileIo.rmdir(directory); }
    catch (error) { if ((error as BusinessError).code !== 13900002) { throw error as Error; } }
  }

  private newRecord(session: DriveTransferSession, direction: 'upload' | 'download', entry: DriveEntry,
    name: string, bytes?: number): DriveTransferRecord {
    if (session.records.length >= 1000) { throw new NasFailure(NasErrorKind.InvalidInput, 'Drive 已保存 1000 个传输记录，请先移除已结束的记录。'); }
    const locationName = entry.displayPath || entry.name;
    if (name.length > 4096 || locationName.length > 4096) { throw new NasFailure(NasErrorKind.InvalidInput, '文件名称或位置过长，无法保存传输记录，请使用 DSM Drive 网页。'); }
    return { id: util.generateRandomUUID(), direction, resource: { nasOrigin: session.origin, account: session.account, fileId: entry.fileId },
      name: validateNasTransferFilename(name), locationName, bytes, state: 'preparing', errorText: '',
      executor: this.execution(session),
      downloadVersionId: direction === 'download' ? entry.versionId : undefined,
      downloadModifiedAt: direction === 'download' ? entry.modifiedAt : undefined };
  }

  private checkSize(bytes: number): void {
    if (!Number.isSafeInteger(bytes) || bytes < 0 || bytes > DRIVE_TRANSFER_MAX_BYTES) {
      throw new NasFailure(NasErrorKind.InvalidInput, '此文件超过 512 MB 或无法确认大小，请改用 DSM Drive 网页。');
    }
  }

  private requireAvailable(write: boolean = true): void {
    if (!this.available) { throw new NasFailure(NasErrorKind.Unsupported, '此 NAS 无法使用 Drive 上传下载，请检查套件和账号权限。'); }
    if (write && this.session !== undefined && !this.session.canStart()) {
      throw new NasFailure(NasErrorKind.InvalidInput, '请先在任务页处理未结束的 Drive 文件操作。');
    }
  }

  private checkDuplicate(session: DriveTransferSession, parentId: string, name: string): void {
    if (session.records.some((record: DriveTransferRecord): boolean => record.direction === 'upload' &&
      record.resource.fileId === parentId && record.name === name && ['preparing', 'creating', 'waiting', 'running', 'paused', 'unknown'].includes(record.state))) {
      throw new NasFailure(NasErrorKind.InvalidInput, '此目标已有上传记录，请先在任务页核对处理。');
    }
  }

  private directory(session: DriveTransferSession, record: DriveTransferRecord): string { return session.store.directory + '/' + record.id; }
  downloadLocalPath(id: string): string {
    const session = this.session!;
    return this.directory(session, this.find(session, id)) + '/content';
  }
  private find(session: DriveTransferSession, id: string): DriveTransferRecord {
    const record = session.records.find((item: DriveTransferRecord): boolean => item.id === id);
    if (record === undefined) { throw new NasFailure(NasErrorKind.InvalidInput, '当前账号没有此 Drive 传输记录。'); }
    return record;
  }
  private ensureCurrent(session: DriveTransferSession): void {
    if (this.session !== session) { throw new NasFailure(NasErrorKind.Cancelled, '连接已变化，传输已停止。'); }
  }
  private publish(session: DriveTransferSession): void {
    if (this.session === session) {
      this.items = session.records.map((record: DriveTransferRecord): DriveTransferRecord => {
        const item = copyDriveTransfer(record);
        item.processed = record.background?.processed ?? this.processed.get(record.id);
        item.bytesPerSecond = this.rates.sample(record.id, item.processed ?? 0, record.state);
        return item;
      });
    }
  }
  private acceptProgress(session: DriveTransferSession, record: DriveTransferRecord, value: NasTransferProgress): void {
    if (this.session !== session || this.activeId !== record.id) { return; }
    this.progress = value.total !== undefined && value.total > 0 ? Math.min(99, Math.max(0, value.processed / value.total * 100)) : undefined;
    this.processed.set(record.id, value.processed); this.publish(session);
  }
  private async run(work: (session: DriveTransferSession) => Promise<void>, requireReady: boolean = true): Promise<void> {
    const session = this.session;
    if (session === undefined || this.busy) { return; }
    if (requireReady && !this.ready) { this.errorText = 'Drive 传输记录尚未就绪，请重新加载记录。'; return; }
    this.busy = true;
    this.errorText = '';
    this.notice = '';
    let failure: NasFailure | undefined = undefined;
    const next = this.tail.then(async (): Promise<void> => {
      this.ensureCurrent(session);
      await work(session);
    }).catch((error: Error): void => {
      if (this.session === session) {
        this.errorText = transferMessage(error);
        hilog.error(0x0000, 'NasDriveTransfer', 'operation=transfer result=failed kind=%{public}d', error instanceof NasFailure ? error.kind : -1);
        if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { failure = error; }
      }
    }).finally((): void => { if (this.session === session) { this.busy = false; } });
    this.tail = next;
    await next;
    if (failure !== undefined && this.session === session) { await session.onSessionFailure(failure); }
  }
}
