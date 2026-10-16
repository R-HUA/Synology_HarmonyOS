import { common } from '@kit.AbilityKit';
import { request, BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { sha256 } from '../../platform/SdkDigest';
import { sdkTransferAgent } from '../../platform/SdkTransferAgent';
import { util } from '@kit.ArkTS';
import { DownloadSubmitResult } from '../../core/domain/DownloadSubmitResult';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasConnector, NasTransferPlan } from '../../core/network/NasConnector';
import { NasTransferCancellation } from '../../core/network/NasTransferTransport';
import { encodeNasForm, NasErrorKind, NasFailure, NasFileEntry, normalizeNasOrigin,
  validateLogicalPath } from '../../core/domain/DsmProtocol';
import { acceptTransferUpload, checkTransferDownload, TransferChecksumStatus, TransferDirection, TransferSource, TransferQueueItem, TransferQueueRecord,
  transferAttachmentName, transferCanRemove, transferCanRetry, transferItem, transferRemotePath, validateTransferName } from '../../core/domain/TransferQueueState';
import { copyTransferFile, ensureTransferDirectory, hashTransferFile, readTransferPrefix, readTransferRecords, removeTransferArtifacts, removeTransferFile,
  saveTransferRecords, transferQueueDirectory } from './TransferQueueFiles';

export interface TransferUploadSource { uri: string; name: string; bytes?: number; }
export interface PhotoTransferSource extends TransferUploadSource {
  folderId: number; modifiedAt: number; wifiOnly: boolean; backupKey?: string; directory?: string;
}
export interface TransferUploadIssue { index: number; errorText: string; }
export interface TransferUploadBatchResult { acceptedIndices: number[]; issues: TransferUploadIssue[]; }
interface QueueSession {
  context: common.UIAbilityContext;
  connector: NasConnector;
  origin: string;
  scope: string;
  directory: string;
  records: TransferQueueRecord[];
  loaded: boolean;
  canUpload: () => boolean;
  insecureTls: boolean;
}
interface QueueMarker { transferQueue: string; transferScope: string; transferAttempt: string; spaceBytes: string; }
interface TransferHeaders { Cookie: string; 'Cache-Control': string; 'X-SYNO-TOKEN'?: string; 'Content-Type'?: string; }
interface TaskBinding { taskId: string; dispose: () => void; }

function queueFailure(message: string): NasFailure { return new NasFailure(NasErrorKind.Protocol, message); }
function isMissingTask(error: Error): boolean { return (error as BusinessError).code === 21900006; }
function transferError(error: Error): string {
  if (error instanceof NasFailure) { return error.message; }
  const code = (error as BusinessError).code;
  if (code === 13900025 || code === 13900041) { return '本机存储空间不足，请释放空间后重试。'; }
  if (code === 13900002) { return '本机文件已不可用，请重新选择或下载。'; }
  return '无法处理传输任务，请检查网络、文件授权和本机存储后重试。';
}

/** 系统后台任务与 DSM 业务结果分别对账，未知上传只能检查，不能自动重放。 */
@ObservedV2
export class TransferQueue {
  @Trace items: TransferQueueItem[] = [];
  @Trace busy: boolean = false;
  @Trace errorText: string = '';
  @Trace ready: boolean = false;
  private session: QueueSession | undefined = undefined;
  private generation: number = 0;
  private tail: Promise<void> = Promise.resolve();
  private bindings: TaskBinding[] = [];
  private timer: number = -1;
  private polling: boolean = false;
  private backupAllowed: boolean = false;
  private photoUploads: Map<string, NasTransferCancellation> = new Map();
  backupCompleted: ((key: string) => Promise<void>) | undefined = undefined;

  async attach(context: common.UIAbilityContext, connector: NasConnector, origin: string, account: string,
    canUpload: () => boolean = (): boolean => true, insecureTls: boolean = false): Promise<void> {
    this.detach();
    sdkTransferAgent.requireCapability();
    const generation = this.generation;
    const normalized = normalizeNasOrigin(origin);
    if (account.length === 0) { throw queueFailure('缺少传输账号，无法加载任务。'); }
    const scope = await sha256(new util.TextEncoder().encodeInto(JSON.stringify([normalized, account])));
    await this.tail;
    if (this.generation !== generation) { throw new NasFailure(NasErrorKind.Cancelled, '连接已变化。'); }
    const session: QueueSession = { context: context, connector: connector, origin: normalized, scope: scope,
      directory: transferQueueDirectory(context, scope), records: [], loaded: false, canUpload: canUpload, insecureTls };
    this.session = session;
    try {
      await this.loadSession(session);
    } catch (error) { this.report(session, error as Error); throw error as Error; }
  }

  private async loadSession(session: QueueSession): Promise<void> {
    await this.operation(session, async (): Promise<void> => {
      await ensureTransferDirectory(session.directory);
      const records = await readTransferRecords(session.directory, session.scope);
      this.ensureCurrent(session);
      session.records = records.filter((record: TransferQueueRecord): boolean => record.source !== 'legacy' && record.state !== 'cancelled');
      if (session.records.length !== records.length) { await saveTransferRecords(session.directory, session.scope, session.records); }
      // 完整读取与解码成功之前，空数组绝不是可以覆盖历史的有效队列。
      session.loaded = true;
      this.ready = true;
      this.publish(session);
      await this.reconcileSession(session);
    });
    if (this.session === session && this.timer === -1) {
      this.timer = setInterval((): void => {
        if (this.polling || this.busy || this.session !== session) { return; }
        this.polling = true;
        this.operation(session, async (): Promise<void> => { await this.reconcileSession(session, true); }, false)
          .catch((error: Error): void => { this.report(session, error); })
          .finally((): void => { this.polling = false; });
      }, 2000);
    }
  }

  /** 离开页面仅解除监听；账号退出需先 await stopAll()。 */
  detach(): void {
    this.photoUploads.forEach((cancellation: NasTransferCancellation): void => cancellation.cancel());
    this.photoUploads.clear();
    this.backupAllowed = false;
    this.generation++;
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
    this.bindings.forEach((binding: TaskBinding): void => { binding.dispose(); });
    this.bindings = [];
    this.session = undefined;
    this.items = [];
    this.busy = false;
    this.errorText = '';
    this.ready = false;
  }

  async pickAndUpload(directory: string): Promise<void> {
    const session = this.requireSession();
    await this.operation(session, async (): Promise<void> => {
      this.requireUploadAdmission(session);
      validateLogicalPath(directory);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 20;
      const uris = await new picker.DocumentViewPicker(session.context).select(options);
      this.ensureCurrent(session);
      await this.uploadSelected(session, directory, uris);
    });
  }

  /** acceptedIndices 对应已持久保存私有副本的来源，可清理分享 inbox；issues 包含准备或启动失败。 */
  async uploadSources(directory: string, sources: TransferUploadSource[], source: TransferSource = 'fileUpload'): Promise<TransferUploadBatchResult> {
    const session = this.requireSession();
    let result: TransferUploadBatchResult = { acceptedIndices: [], issues: [] };
    await this.operation(session, async (): Promise<void> => {
      this.requireUploadAdmission(session);
      result = await this.enqueueUploads(session, directory, sources, source);
    });
    return result;
  }

  async uploadUris(directory: string, uris: string[]): Promise<void> {
    const session = this.requireSession();
    await this.operation(session, async (): Promise<void> => { this.requireUploadAdmission(session); await this.uploadSelected(session, directory, uris); });
  }

  /** 自动备份逐项接管，手动上传仍保留整批的部分成功回执。 */
  async uploadPhotos(directory: string, sources: PhotoTransferSource[], automatic: boolean): Promise<TransferUploadBatchResult> {
    const session = this.requireSession();
    let result: TransferUploadBatchResult = { acceptedIndices: [], issues: [] };
    await this.operation(session, async (): Promise<void> => {
      this.requireUploadAdmission(session);
      result = await this.enqueueUploads(session, directory, sources, automatic ? 'photoBackup' : 'photoUpload', sources);
    });
    return result;
  }

  /** 只暂停自动备份的同一个系统任务，条件恢复时 resume，不重复建立上传。 */
  async setBackupAllowed(allowed: boolean): Promise<void> {
    this.backupAllowed = allowed;
    const session = this.session;
    if (session === undefined || !session.loaded) { return; }
    if (!allowed) {
      session.records.filter((record: TransferQueueRecord): boolean => record.source === 'photoBackup')
        .forEach((record: TransferQueueRecord): void => { this.photoUploads.get(record.id)?.cancel(); });
    }
    await this.operation(session, async (): Promise<void> => {
      for (const record of session.records) {
        if (record.protocol !== 'photos' || record.source !== 'photoBackup' || record.taskId.length === 0 ||
          !['running', 'waiting'].includes(record.state)) { continue; }
        const info = await sdkTransferAgent.show(record.taskId);
        const task = await sdkTransferAgent.getTask(session.context, record.taskId);
        if (!allowed && [request.agent.State.RUNNING, request.agent.State.WAITING, request.agent.State.RETRYING].includes(info.progress.state)) {
          await sdkTransferAgent.pause(task); record.state = 'waiting';
        } else if (allowed && info.progress.state === request.agent.State.PAUSED) {
          await sdkTransferAgent.resume(task); record.state = 'running'; record.errorText = '';
        }
      }
      await this.save(session);
    }, false);
  }

  async download(entry: NasFileEntry): Promise<DownloadSubmitResult> {
    const session = this.session;
    if (session === undefined || !session.loaded || this.busy || entry.isDirectory) {
      return { status: 'rejected', message: this.busy ? '正在处理其他任务，请稍后重试' : entry.isDirectory ?
        '请进入文件夹后选择要下载的文件' : '传输记录尚未就绪，请重新加载' };
    }
    let result: DownloadSubmitResult = { status: 'failed', message: '' };
    let recordId: string | undefined = undefined;
    try { await this.operation(session, async (): Promise<void> => {
      validateLogicalPath(entry.path);
      const info = await session.connector.getFileInfo(entry.path);
      this.ensureCurrent(session);
      if (info.isDirectory) { throw queueFailure('所选项目已变为文件夹。'); }
      const existing = session.records.find((record: TransferQueueRecord): boolean => record.direction === 'download' &&
        record.source !== 'legacy' && record.remotePath === entry.path && !['completed', 'cancelled', 'failed', 'closed', 'clearing'].includes(record.state));
      if (existing !== undefined) {
        result = { status: 'duplicate', taskId: existing.id, message: '该任务已存在' };
        return;
      }
      const record = this.newRecord('download', validateTransferName(info.name), entry.path, info.bytes);
      record.state = 'queued';
      record.localReady = true;
      this.addRecord(session, record);
      recordId = record.id;
      this.publish(session);
      await this.save(session);
      await this.createTask(session, record);
      result = { status: 'created', taskId: record.id, message: '已添加下载任务' };
    }); } catch (error) {
      result = { status: recordId === undefined ? 'failed' : 'unconfirmed', taskId: recordId,
        message: recordId === undefined ? transferError(error as Error) : '任务提交未完成',
        failure: error instanceof NasFailure ? error : undefined };
    }
    return result;
  }

  async reconcile(): Promise<void> {
    const session = this.session;
    if (session === undefined) { throw queueFailure('请先连接 NAS 再处理传输。'); }
    if (!session.loaded) { await this.loadSession(session); return; }
    await this.operation(session, async (): Promise<void> => { await this.reconcileSession(session); });
  }

  /** 用户已在 NAS 核对写入结果；关闭后可重新选择文件，绝不在此重发上传。 */
  async closeUnknownUpload(id: string): Promise<void> {
    const session = this.requireSession();
    await this.operation(session, async (): Promise<void> => {
      const record = this.find(session, id);
      if (record.direction !== 'upload' || record.state !== 'unknown') { throw queueFailure('只有结果待确认的上传可以核对后关闭。'); }
      if (record.taskId.length > 0) { await this.removeTask(record.taskId); this.unbind(record.taskId); }
      await this.stopChecksum(session, record);
      this.ensureCurrent(session);
      record.taskId = '';
      record.state = 'closed';
      record.errorText = '';
      await this.save(session);
    });
  }

  async removeRecord(id: string, deleteLocalFile: boolean = true): Promise<void> {
    const session = this.requireSession();
    await this.operation(session, async (): Promise<void> => { await this.clearRecord(session, this.find(session, id), deleteLocalFile); });
  }

  async clearHistory(ids: string[], deleteLocalFile: boolean = false): Promise<number> {
    const session = this.requireSession();
    const frozen = ids.slice();
    let cleared = 0;
    await this.operation(session, async (): Promise<void> => {
      for (const id of frozen) {
        try { await this.clearRecord(session, this.find(session, id), deleteLocalFile); cleared++; }
        catch (error) { throw queueFailure('已清理 ' + cleared.toString() + ' 项，' + transferError(error as Error)); }
      }
    });
    return cleared;
  }

  async cancel(id: string): Promise<void> {
    const session = this.requireSession();
    this.photoUploads.get(id)?.cancel();
    await this.operation(session, async (): Promise<void> => { await this.cancelRecord(session, this.find(session, id)); });
  }

  /** 失败即向调用方传播，调用方应阻止登出，以免后台任务继续使用旧会话。 */
  async stopAll(): Promise<void> {
    const session = this.session;
    if (session === undefined) { return; }
    if (!session.loaded) { throw queueFailure('传输记录尚未读取成功，无法确认后台任务已停止；请先在任务页重新加载。'); }
    this.photoUploads.forEach((cancellation: NasTransferCancellation): void => cancellation.cancel());
    await this.operation(session, async (): Promise<void> => {
      // 先找回 create 返回后、taskId 保存前可能遗留的任务，再移除当前账号全部系统任务。
      for (const record of session.records) {
        this.ensureCurrent(session);
        if (record.taskId.length === 0 && record.state === 'creating') { await this.adoptCreatedTask(session, record); }
        if (record.taskId.length > 0) { await this.removeTask(record.taskId); this.unbind(record.taskId); }
        await this.stopChecksum(session, record);
        if (!['completed', 'closed', 'clearing', 'cancelled', 'failed'].includes(record.state)) {
          record.state = record.direction === 'upload' && record.startAttempted ? 'unknown' : 'cancelled';
          record.errorText = record.state === 'unknown' ? '后台上传已停止，NAS 可能已收到部分或全部内容；请核对目标文件。' : '';
        }
      }
      await this.save(session);
    });
  }

  async retry(id: string): Promise<void> {
    const session = this.requireSession();
    await this.operation(session, async (): Promise<void> => {
      const record = this.find(session, id);
      if (!transferCanRetry(record)) { throw queueFailure('上传结果尚未确认，请先核对 NAS；不会重复上传。'); }
      if (record.direction === 'upload') { this.requireUploadAdmission(session); }
      if (record.taskId.length > 0) { await this.removeTask(record.taskId); this.unbind(record.taskId); }
      await this.stopChecksum(session, record);
      const oldPath = this.localPath(session, record);
      const nextName = record.id + '-' + (record.attempts + 1).toString() + '.bin';
      if (record.direction === 'upload') {
        // 本机副本保留原名，新的 attempt 使用新文件名，避免旧任务读写同一个文件。
        await copyTransferFile(oldPath, session.directory + '/' + nextName, record.bytes, (): void => this.ensureCurrent(session));
      } else {
        const info = await session.connector.getFileInfo(record.remotePath);
        this.ensureCurrent(session);
        if (info.isDirectory) { throw queueFailure('下载目标已变为文件夹。'); }
        record.bytes = info.bytes;
      }
      record.attempts++;
      record.localName = nextName;
      record.taskId = '';
      record.startAttempted = false;
      record.uploadAccepted = false;
      record.httpStatus = 0;
      record.contentType = '';
      record.attachmentName = '';
      record.contentVerified = false;
      record.localMd5 = '';
      record.checksumTaskId = '';
      record.systemCompleted = false;
      record.processed = 0;
      record.errorText = '';
      record.state = 'queued';
      await this.save(session);
      await removeTransferFile(oldPath);
      await this.createTask(session, record);
    });
  }

  async exportDownload(id: string): Promise<boolean> {
    const session = this.requireSession();
    let saved = false;
    await this.operation(session, async (): Promise<void> => {
      const record = this.find(session, id);
      if (record.direction !== 'download' || record.state !== 'completed') { throw queueFailure('下载尚未通过校验，无法保存。'); }
      await this.verifyDownload(session, record);
      this.ensureCurrent(session);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [record.name];
      const selected = await new picker.DocumentViewPicker(session.context).save(options);
      this.ensureCurrent(session);
      if (selected.length === 0) { return; }
      await copyTransferFile(this.localPath(session, record), selected[0], record.bytes,
        (): void => this.ensureCurrent(session), true);
      saved = true;
    });
    return saved;
  }

  private async uploadSelected(session: QueueSession, directory: string, uris: string[]): Promise<void> {
    validateLogicalPath(directory);
    if (uris.length > 20) { throw queueFailure('每次最多选择 20 个文件。'); }
    const sources: TransferUploadSource[] = [];
    for (const uri of uris) {
      this.ensureCurrent(session);
      const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      try { sources.push({ uri: uri, name: new fileUri.FileUri(uri).name, bytes: (await fileIo.stat(file.fd)).size }); }
      finally { await fileIo.close(file); }
    }
    const result = await this.enqueueUploads(session, directory, sources);
    if (result.issues.length > 0) { throw queueFailure(result.issues[0].errorText); }
  }

  private async enqueueUploads(session: QueueSession, directory: string, sources: TransferUploadSource[], origin: TransferSource = 'fileUpload', photos?: PhotoTransferSource[]): Promise<TransferUploadBatchResult> {
    validateLogicalPath(directory);
    if (sources.length > 20) { throw queueFailure('每次最多选择 20 个文件。'); }
    const result: TransferUploadBatchResult = { acceptedIndices: [], issues: [] };
    for (let index = 0; index < sources.length; index++) {
      this.ensureCurrent(session);
      try {
        const source = sources[index];
        let bytes = source.bytes;
        if (bytes === undefined) {
          const file = await fileIo.open(source.uri, fileIo.OpenMode.READ_ONLY);
          try { bytes = (await fileIo.stat(file.fd)).size; } finally { await fileIo.close(file); }
        }
        if (!Number.isSafeInteger(bytes) || bytes < 0) { throw queueFailure('所选文件大小无效。'); }
        const path = transferRemotePath(photos?.[index].directory ?? directory, source.name);
        if (session.records.some((record: TransferQueueRecord): boolean => record.direction === 'upload' &&
          record.remotePath === path && !['completed', 'failed', 'cancelled', 'closed', 'clearing'].includes(record.state))) {
          throw queueFailure('这个文件已有上传任务，请先处理已有任务。');
        }
        const record = this.newRecord('upload', source.name, path, bytes);
        record.source = origin;
        if (photos !== undefined) {
          record.protocol = 'photos'; record.photoFolderId = photos[index].folderId;
          record.photoModifiedAt = photos[index].modifiedAt; record.photoWifiOnly = photos[index].wifiOnly;
          record.backupKey = photos[index].backupKey;
        }
        this.addRecord(session, record);
        await this.save(session);
        try {
          const destination = this.localPath(session, record);
          await copyTransferFile(source.uri, destination + '.tmp', bytes, (): void => this.ensureCurrent(session));
          this.ensureCurrent(session);
          await fileIo.rename(destination + '.tmp', destination);
          record.localReady = true;
          record.state = 'queued';
          await this.save(session);
        } catch (error) {
          record.state = 'failed';
          record.errorText = transferError(error as Error);
          await this.save(session);
          await removeTransferFile(this.localPath(session, record) + '.tmp');
          throw error as Error;
        }
        result.acceptedIndices.push(index);
        if (this.canStartQueuedUpload(session, record)) { await this.createTask(session, record); }
      } catch (error) {
        this.ensureCurrent(session);
        result.issues.push({ index: index, errorText: transferError(error as Error) });
        if (session.records.some((record: TransferQueueRecord): boolean => record.direction === 'upload' && ['unknown', 'creating'].includes(record.state))) { break; }
        this.report(session, error as Error);
      }
    }
    return result;
  }

  private newRecord(direction: TransferDirection, name: string, remotePath: string, bytes: number): TransferQueueRecord {
    const id = util.generateRandomUUID();
    const now = Date.now();
    return { id: id, direction: direction, source: direction === 'upload' ? 'fileUpload' : 'download', name: name, remotePath: remotePath, bytes: bytes,
      localName: id + '-1.bin', localReady: false, state: 'preparing', taskId: '', attempts: 1,
      startAttempted: false, uploadAccepted: false, httpStatus: 0, contentType: '', attachmentName: '', processed: 0,
      createdAt: now, updatedAt: now, errorText: '', contentVerified: false, localMd5: '', checksumTaskId: '', systemCompleted: false };
  }

  private addRecord(session: QueueSession, record: TransferQueueRecord): void {
    if (session.records.length >= 1000) { throw queueFailure('本机已保存 1000 个传输记录，请到任务页清理历史后再添加。'); }
    session.records.push(record);
  }

  private async createTask(session: QueueSession, record: TransferQueueRecord): Promise<void> {
    this.ensureCurrent(session);
    let plan: NasTransferPlan;
    if (record.direction === 'upload') {
      const stat = await fileIo.stat(this.localPath(session, record));
      if (stat.size !== record.bytes || stat.isDirectory()) { throw queueFailure('上传私有副本不可用，请重新选择。'); }
      plan = record.protocol === 'photos' ? session.connector.photoUploadPlan(record.photoFolderId!, record.name, record.photoModifiedAt!) :
        session.connector.transferUploadPlan(record.remotePath.substring(0, record.remotePath.lastIndexOf('/')));
    } else { plan = session.connector.transferDownloadPlan(record.remotePath); }
    // 传输计划必须属于 attach 的可信 origin，防止绑定错误账号/连接。
    if (!plan.address.startsWith(session.origin + '/webapi/')) { throw queueFailure('连接与传输账号不一致，请重新连接。'); }
    if (record.protocol === 'photos' && session.insecureTls && session.origin.startsWith('https:')) {
      await this.startPhotoUpload(session, record);
      return;
    }
    record.state = 'creating';
    await this.save(session);
    this.ensureCurrent(session);
    const marker: QueueMarker = { transferQueue: record.id, transferScope: session.scope, transferAttempt: record.attempts.toString(), spaceBytes: record.bytes.toString() };
    // 系统代理使用系统证书策略；Photos 的已确认例外由当前连接执行。
    const config: request.agent.Config = { action: record.direction === 'upload' ? request.agent.Action.UPLOAD : request.agent.Action.DOWNLOAD,
      url: plan.address, method: 'POST', mode: request.agent.Mode.BACKGROUND,
      title: record.direction === 'upload' ? '上传文件' : '下载文件', headers: this.headers(plan, record.direction === 'download'),
      retry: false, redirect: false, metered: false, roaming: false, gauge: true, extras: marker };
    if (record.protocol === 'photos') {
      config.metered = true;
      config.roaming = !record.photoWifiOnly;
      config.network = record.photoWifiOnly ? request.agent.Network.WIFI : request.agent.Network.ANY;
    }
    if (record.direction === 'upload') {
      const fields: request.agent.FormItem[] = plan.fields.map((field): request.agent.FormItem => ({ name: field.name, value: field.content }));
      // DSM 要求文件部分排在普通字段之后，boundary 由系统生成。
      fields.push({ name: 'file', value: { path: this.localPath(session, record), filename: record.name, contentType: 'application/octet-stream' } });
      config.data = fields;
    } else { config.data = encodeNasForm(plan.fields); config.saveas = this.localPath(session, record); config.overwrite = false; }
    let task: request.agent.Task;
    try { task = await sdkTransferAgent.create(session.context, config); }
    catch (error) {
      // 创建调用失败可能已生成 INITIALIZED 任务；恢复时通过 marker 搜索，不再创建另一份。
      record.errorText = '系统任务创建结果待检查，请点击重新检查。';
      await this.save(session);
      throw error as Error;
    }
    record.taskId = task.tid;
    try { await this.save(session); }
    catch (error) {
      // 没有已落盘 ID 的任务绝不能启动；移除失败保留 creating 供下次双向对账。
      await this.removeTask(task.tid);
      record.taskId = '';
      throw error as Error;
    }
    if (this.session !== session) { await this.removeTask(task.tid); throw new NasFailure(NasErrorKind.Cancelled, '连接已变化，任务未启动。'); }
    await this.startTask(session, record, task);
  }

  private async startTask(session: QueueSession, record: TransferQueueRecord, task: request.agent.Task): Promise<void> {
    this.ensureCurrent(session);
    this.bind(session, record, task);
    record.startAttempted = true;
    record.state = 'running';
    record.errorText = '';
    await this.save(session);
    this.ensureCurrent(session);
    try { await sdkTransferAgent.start(task); }
    catch (error) {
      record.state = record.direction === 'upload' ? 'unknown' : 'failed';
      record.errorText = '系统任务启动结果待检查，请重新检查任务状态。';
      await this.save(session);
      throw error as Error;
    }
  }

  /** 系统代理无法继承证书例外时，沿用连接的文件流上传；完成回执仍先落盘。 */
  private async startPhotoUpload(session: QueueSession, record: TransferQueueRecord): Promise<void> {
    const cancellation = new NasTransferCancellation();
    record.startAttempted = true;
    record.state = 'running';
    await this.save(session);
    this.ensureCurrent(session);
    this.photoUploads.set(record.id, cancellation);
    session.connector.uploadPhoto(record.photoFolderId!, record.name, record.photoModifiedAt!,
      { path: this.localPath(session, record), bytes: record.bytes }, {
        cancellation,
        onProgress: (progress): void => {
          if (this.session !== session) { return; }
          record.processed = Math.max(0, Math.min(record.bytes, progress.processed));
          this.publish(session);
        },
        checkNetwork: (): void => {
          this.ensureCurrent(session);
          if (record.source === 'photoBackup' && !this.backupAllowed) { cancellation.cancel(); cancellation.check(); }
        }
      }).then(async (reply): Promise<void> => {
        if (this.session !== session) { return; }
        await this.operation(session, async (): Promise<void> => {
          record.httpStatus = reply.status;
          acceptTransferUpload(reply.status, reply.text, true);
          record.uploadAccepted = true;
          await this.save(session);
          await this.finishRecord(session, record);
          hilog.info(0x0000, 'NasQueue', 'operation=photo_upload result=success bytes=%{public}d', record.bytes);
        }, false);
      }).catch(async (error: Error): Promise<void> => {
        if (this.session !== session) { return; }
        await this.operation(session, async (): Promise<void> => {
          if (record.uploadAccepted || ['closed', 'cancelled', 'completed'].includes(record.state)) { throw error; }
          const rejection = error instanceof NasFailure && record.httpStatus === 200 &&
            ![NasErrorKind.Http, NasErrorKind.Protocol, NasErrorKind.Network, NasErrorKind.Cancelled].includes(error.kind);
          record.state = rejection ? 'failed' : 'unknown';
          record.errorText = transferError(error);
          await this.save(session);
          this.report(session, error);
        }, false);
      }).catch((error: Error): void => { this.report(session, error); })
      .finally((): void => { this.photoUploads.delete(record.id); });
  }

  private async reconcileSession(session: QueueSession, automatic: boolean = false): Promise<void> {
    for (const record of session.records.slice()) {
      this.ensureCurrent(session);
      if (record.state === 'clearing') { await this.clearRecord(session, record); continue; }
      if (['cancelled', 'failed', 'closed'].includes(record.state)) { continue; }
      if (automatic && record.state === 'unknown') { continue; }
      try {
        if (record.state === 'completed') {
          if (record.taskId.length > 0) { await this.removeTask(record.taskId); record.taskId = ''; await this.save(session); }
          continue;
        }
        if (record.state === 'preparing') {
          record.state = 'failed'; record.errorText = '文件准备被中断，请重新选择文件。';
          await this.save(session); continue;
        }
        if (record.taskId.length === 0) {
          if (this.photoUploads.has(record.id)) { continue; }
          if (record.protocol === 'photos' && record.startAttempted) {
            if (record.uploadAccepted) { await this.finishRecord(session, record); }
            else {
              record.state = 'unknown'; record.errorText = '未取得照片上传回执，请在相册核对结果；不会自动重传。';
              await this.save(session);
            }
            continue;
          }
          if (record.state === 'queued' && !record.startAttempted && record.localReady) {
            if (record.direction === 'download' || this.canStartQueuedUpload(session, record)) { await this.createTask(session, record); }
            continue;
          }
          if (record.state === 'creating') { await this.adoptCreatedTask(session, record); }
          if (record.taskId.length === 0) {
            record.state = 'failed'; record.errorText = '任务尚未启动，请点击重试。';
            await this.save(session); continue;
          }
        }
        const info = await sdkTransferAgent.show(record.taskId);
        this.ensureCurrent(session);
        if (info.progress.state === request.agent.State.FAILED) {
          hilog.error(0x0000, 'NasQueue', 'operation=task_status result=failed fault=%{public}d processed=%{public}d http=%{public}d',
            info.faults, info.progress.processed, record.httpStatus);
        }
        if (record.direction === 'download' && [request.agent.State.INITIALIZED, request.agent.State.RUNNING, request.agent.State.WAITING, request.agent.State.RETRYING].includes(info.progress.state)) {
          await sdkTransferAgent.restoreDownloadSpace(session.context, record.taskId, this.localPath(session, record), record.bytes, info.progress.processed);
          this.ensureCurrent(session);
        }
        await this.acceptProgress(session, record, info.progress, info.faults);
        if (record.protocol === 'photos' && record.source === 'photoBackup' && !this.backupAllowed &&
          [request.agent.State.RUNNING, request.agent.State.WAITING, request.agent.State.RETRYING].includes(info.progress.state)) {
          await sdkTransferAgent.pause(await sdkTransferAgent.getTask(session.context, record.taskId));
          record.state = 'waiting'; await this.save(session); continue;
        }
        if (info.progress.state === request.agent.State.INITIALIZED) {
          if (record.direction === 'upload' && !this.canStartQueuedUpload(session, record)) { continue; }
          // INITIALIZED 是尚未开始执行的系统任务；恢复同一个 ID，不建立新上传。
          const task = await sdkTransferAgent.getTask(session.context, record.taskId);
          await this.startTask(session, record, task);
        } else if ([request.agent.State.RUNNING, request.agent.State.WAITING, request.agent.State.RETRYING].includes(info.progress.state)) {
          this.bind(session, record, await sdkTransferAgent.getTask(session.context, record.taskId));
        }
      } catch (error) {
        if (this.session !== session) { throw error as Error; }
        if (isMissingTask(error as Error)) {
          if (record.systemCompleted && (record.httpStatus === 0 || record.httpStatus === 200)) {
            try {
              if (await this.verifyRecoveredContent(session, record)) { await this.finishRecord(session, record); }
              continue;
            } catch (verificationError) { record.errorText = transferError(verificationError as Error); }
          }
          record.state = record.direction === 'upload' && record.startAttempted ? 'unknown' : 'failed';
          record.errorText = (record.errorText.length > 0 ? record.errorText + ' ' : '') +
            (record.state === 'unknown' ? '系统上传记录已不可用，NAS 写入结果需人工核对；不会自动重传。' : '系统任务已不可用，请重试。');
          await this.save(session);
        } else {
          record.errorText = transferError(error as Error);
          // 查询/业务核对失败不能把未确认上传变为可重试。
          if (record.direction === 'upload' && record.startAttempted && !['failed', 'completed'].includes(record.state)) { record.state = 'unknown'; }
          await this.save(session);
          this.report(session, error as Error);
        }
      }
    }
    this.publish(session);
  }

  private async adoptCreatedTask(session: QueueSession, record: TransferQueueRecord): Promise<void> {
    const ids = await sdkTransferAgent.search({ after: Math.max(0, record.createdAt - 60000), mode: request.agent.Mode.BACKGROUND });
    const found: string[] = [];
    for (const id of ids) {
      this.ensureCurrent(session);
      let info: request.agent.TaskInfo;
      try { info = await sdkTransferAgent.show(id); }
      catch (error) { if (isMissingTask(error as Error)) { continue; } throw error as Error; }
      const extra = info.extras as Record<string, Object> | undefined;
      if (extra !== undefined && extra['transferScope'] === session.scope && extra['transferQueue'] === record.id &&
        extra['transferAttempt'] === record.attempts.toString()) { found.push(id); }
    }
    if (found.length > 1) { throw queueFailure('同一文件存在多个系统任务，需要核对后处理。'); }
    if (found.length === 1) { record.taskId = found[0]; await this.save(session); }
  }

  private async acceptProgress(session: QueueSession, record: TransferQueueRecord, progress: request.agent.Progress,
    faults?: request.agent.Faults): Promise<void> {
    this.ensureCurrent(session);
    record.processed = Math.max(0, Math.min(record.bytes, progress.processed));
    if (progress.state === request.agent.State.COMPLETED) {
      record.systemCompleted = true;
      record.state = 'verifying';
      // show 可带回系统保存的响应头；只提取业务校验所需字段。
      this.acceptProgressHeaders(record, progress);
      await this.save(session);
      if (record.direction === 'upload') {
        if (!record.uploadAccepted && !record.contentVerified) {
          const extra = progress.extras as Record<string, Object> | undefined;
          const body = extra === undefined ? undefined : extra['body'];
          if (typeof body !== 'string' || record.httpStatus === 0) {
            if (record.httpStatus !== 0 && record.httpStatus !== 200) {
              record.state = 'unknown'; record.errorText = '上传 HTTP 响应未成功，NAS 写入结果需人工核对。';
              await this.save(session); return;
            }
            if (!await this.verifyRecoveredContent(session, record)) { return; }
          } else {
            try { acceptTransferUpload(record.httpStatus, body, record.protocol === 'photos'); }
            catch (error) {
              // 明确 DSM 拒绝可以由用户重试；HTTP/无法解析仍属未知写入结果。
              const failure = error as NasFailure;
              record.state = failure instanceof NasFailure && ![NasErrorKind.Http, NasErrorKind.Protocol].includes(failure.kind) ? 'failed' : 'unknown';
              record.errorText = transferError(error as Error); await this.save(session); return;
            }
            record.uploadAccepted = true;
            await this.save(session);
          }
        }
        if (record.protocol !== 'photos') {
          const target = await session.connector.getFileInfo(record.remotePath);
          this.ensureCurrent(session);
          if (target.isDirectory || target.bytes !== record.bytes) { throw queueFailure('NAS 目标文件大小不符，上传结果待确认。'); }
        }
      } else {
        try {
          if (record.httpStatus === 0 && !record.contentVerified) {
            if (!await this.verifyRecoveredContent(session, record)) { return; }
          } else {
            try { await this.verifyDownload(session, record); }
            catch (error) {
              // 附件名证据缺失时，HTML/JSON 也可能是原文件；以 NAS 全文件摘要消除歧义。
              if (record.httpStatus !== 200 || record.contentVerified) { throw error as Error; }
              if (!await this.verifyRecoveredContent(session, record)) { return; }
            }
          }
        } catch (error) {
          record.state = record.httpStatus === 0 ? 'unknown' : 'failed';
          record.errorText = transferError(error as Error); await this.save(session); return;
        }
      }
      await this.finishRecord(session, record);
    } else if ([request.agent.State.FAILED, request.agent.State.STOPPED, request.agent.State.REMOVED].includes(progress.state)) {
      record.state = record.direction === 'upload' && record.startAttempted ? 'unknown' : 'failed';
      record.errorText = record.state === 'unknown' ? '上传已中断，NAS 可能已收到内容；请核对后处理，系统不会自动重传。' : '下载已中断，请重试。';
      if (progress.state === request.agent.State.FAILED && faults === request.agent.Faults.SSL && progress.processed === 0 && record.httpStatus === 0) {
        record.state = 'failed';
        record.errorText = '上传未能建立安全连接，请检查当前连接设置后重试。';
      }
      if (record.direction === 'upload' && progress.state === request.agent.State.FAILED && record.httpStatus === 200) {
        const extra = progress.extras as Record<string, Object> | undefined;
        const body = extra === undefined ? undefined : extra['body'];
        if (typeof body === 'string') {
          try { acceptTransferUpload(record.httpStatus, body, record.protocol === 'photos'); }
          catch (error) {
            // 只有明确的 DSM 拒绝能证明本次失败；取消/移除、解析失败和缺少 HTTP 均不开放重试。
            const failure = error as NasFailure;
            if (failure instanceof NasFailure && ![NasErrorKind.Http, NasErrorKind.Protocol].includes(failure.kind)) {
              record.state = 'failed';
              record.errorText = transferError(error as Error);
            }
          }
        }
      }
      await this.save(session); this.unbind(record.taskId);
    } else if (progress.state === request.agent.State.PAUSED) {
      record.state = 'waiting'; record.errorText = record.protocol === 'photos' && record.source === 'photoBackup' ? '' : '系统任务已暂停，请取消后重新处理。'; await this.save(session);
    } else {
      const state = progress.state === request.agent.State.WAITING ? 'waiting' : 'running';
      if (record.state !== state) { record.state = state; record.errorText = ''; await this.save(session); }
      else { this.publish(session); }
    }
  }

  private async verifyDownload(session: QueueSession, record: TransferQueueRecord): Promise<void> {
    const path = this.localPath(session, record);
    const stat = await fileIo.stat(path);
    if (stat.isDirectory()) { throw queueFailure('下载文件不可用。'); }
    if (record.contentVerified) {
      if (await hashTransferFile(path, record.bytes, (): void => this.ensureCurrent(session)) !== record.localMd5) {
        throw queueFailure('下载副本已变化，请重新下载。');
      }
      return;
    }
    const prefix = await readTransferPrefix(path, stat.size);
    this.ensureCurrent(session);
    checkTransferDownload(record.httpStatus, record.bytes, stat.size, record.contentType, prefix.text,
      prefix.wholeFile, record.attachmentName, record.name);
  }

  private acceptProgressHeaders(record: TransferQueueRecord, progress: request.agent.Progress): void {
    const extra = progress.extras as Record<string, Object> | undefined;
    if (extra === undefined) { return; }
    const type = extra['content-type'];
    const disposition = extra['content-disposition'];
    if (typeof type === 'string') { record.contentType = type.substring(0, 256); }
    if (typeof disposition === 'string') { record.attachmentName = transferAttachmentName(disposition); }
  }

  /** 回调证据缺失时用完整文件摘要核对内容，不能以同名同大小替代。 */
  private async verifyRecoveredContent(session: QueueSession, record: TransferQueueRecord): Promise<boolean> {
    this.ensureCurrent(session);
    if (record.protocol === 'photos') { throw queueFailure('未取得照片上传回执，请在相册核对结果；不会自动重传。'); }
    if (!record.systemCompleted) { throw queueFailure('系统尚未确认传输完成，请先检查任务状态。'); }
    const remote = await session.connector.getFileInfo(record.remotePath);
    this.ensureCurrent(session);
    if (remote.isDirectory || remote.bytes !== record.bytes) { throw queueFailure('NAS 文件大小不符，传输内容尚未确认。'); }
    if (record.checksumTaskId.length === 0) {
      record.checksumTaskId = await session.connector.startFileChecksum(record.remotePath);
      await this.save(session);
    }
    let status: TransferChecksumStatus;
    try { status = await session.connector.fileChecksumStatus(record.checksumTaskId); }
    catch (error) {
      if (!(error instanceof NasFailure) || error.kind !== NasErrorKind.Server || error.code !== 599) { throw error as Error; }
      // NAS 明确确认旧校验任务不存在，可以重新创建只读校验，绝不重发原传输。
      record.checksumTaskId = '';
      await this.save(session);
      record.checksumTaskId = await session.connector.startFileChecksum(record.remotePath);
      await this.save(session);
      status = await session.connector.fileChecksumStatus(record.checksumTaskId);
    }
    this.ensureCurrent(session);
    if (!status.finished) {
      record.state = 'verifying'; record.errorText = 'NAS 正在核验文件内容，稍后可刷新状态。';
      await this.save(session); return false;
    }
    record.checksumTaskId = '';
    // 校验任务可能跨重启等待；在取得 NAS 结果后读取当前私有副本，避免使用过期的本机摘要。
    record.localMd5 = await hashTransferFile(this.localPath(session, record), record.bytes, (): void => this.ensureCurrent(session));
    if (status.md5 !== record.localMd5) { throw queueFailure('NAS 与本机副本的文件内容不符，无法确认传输结果。'); }
    record.contentVerified = true;
    await this.save(session);
    return true;
  }

  private async finishRecord(session: QueueSession, record: TransferQueueRecord): Promise<void> {
    record.state = 'completed'; record.processed = record.bytes; record.errorText = '';
    await this.save(session);
    if (record.backupKey !== undefined && this.backupCompleted !== undefined) { await this.backupCompleted(record.backupKey); }
    this.unbind(record.taskId);
    // 先保存可验证结果，再释放含凭据的系统配置。
    if (record.taskId.length > 0) { await this.removeTask(record.taskId); record.taskId = ''; await this.save(session); }
  }

  private async stopChecksum(session: QueueSession, record: TransferQueueRecord): Promise<void> {
    if (record.checksumTaskId.length === 0) { return; }
    try { await session.connector.stopFileChecksum(record.checksumTaskId); }
    catch (error) {
      // 明确不存在的校验任务已经停止；网络、权限与会话错误仍须向上报告。
      if (!(error instanceof NasFailure) || error.kind !== NasErrorKind.Server || error.code !== 599) { throw error as Error; }
    }
    this.ensureCurrent(session);
    record.checksumTaskId = '';
  }

  private bind(session: QueueSession, record: TransferQueueRecord, task: request.agent.Task): void {
    if (this.bindings.some((binding: TaskBinding): boolean => binding.taskId === task.tid)) { return; }
    const taskId = task.tid;
    const response = (value: request.agent.HttpResponse): void => {
      this.background(session, taskId, async (): Promise<void> => {
        record.httpStatus = value.statusCode;
        const types: string[] = [];
        value.headers.forEach((values: string[], name: string): void => {
          if (name.toLowerCase() === 'content-type') { types.push(...values); }
          if (name.toLowerCase() === 'content-disposition' && values.length === 1) {
            record.attachmentName = transferAttachmentName(values[0]);
          }
        });
        record.contentType = types.join(';').substring(0, 256);
        await this.save(session);
      });
    };
    const progress = (value: request.agent.Progress): void => {
      if (this.session !== session || record.taskId !== taskId) { return; }
      record.processed = Math.max(0, Math.min(record.bytes, value.processed));
      this.publish(session);
    };
    const completed = (value: request.agent.Progress): void => {
      this.background(session, taskId, async (): Promise<void> => { await this.acceptProgress(session, record, value); });
    };
    const failed = (value: request.agent.Progress): void => {
      this.background(session, taskId, async (): Promise<void> => {
        const info = await sdkTransferAgent.show(taskId);
        hilog.error(0x0000, 'NasQueue', 'operation=task_status result=failed fault=%{public}d processed=%{public}d http=%{public}d',
          info.faults, value.processed, record.httpStatus);
        await this.acceptProgress(session, record, value, info.faults);
      });
    };
    const dispose = sdkTransferAgent.observe(task, { response: response, progress: progress, completed: completed, failed: failed,
      error: (error: Error): void => this.report(session, error) });
    this.bindings.push({ taskId: taskId, dispose: dispose });
  }

  private background(session: QueueSession, taskId: string, work: () => Promise<void>): void {
    if (this.session !== session) { return; }
    this.operation(session, async (): Promise<void> => {
      if (!session.records.some((record: TransferQueueRecord): boolean => record.taskId === taskId &&
        !['cancelled', 'completed'].includes(record.state))) { return; }
      await work();
    }, false).catch((error: Error): void => { this.report(session, error); });
  }

  private async cancelRecord(session: QueueSession, record: TransferQueueRecord): Promise<void> {
    if (record.state === 'completed') { throw queueFailure('任务已完成。'); }
    if (record.taskId.length === 0 && record.state === 'creating') { await this.adoptCreatedTask(session, record); }
    if (record.taskId.length > 0) { await this.removeTask(record.taskId); this.unbind(record.taskId); }
    await this.stopChecksum(session, record);
    record.state = record.direction === 'upload' && record.startAttempted ? 'unknown' : 'cancelled';
    record.errorText = record.state === 'unknown' ? '上传已停止，NAS 写入结果需核对；不会自动重传。' : '';
    await this.save(session);
    if (record.direction === 'download') { await removeTransferFile(this.localPath(session, record)); }
    if (record.state === 'cancelled') { await this.clearRecord(session, record); }
  }

  private async clearRecord(session: QueueSession, record: TransferQueueRecord, deleteLocalFile: boolean = true): Promise<void> {
    this.ensureCurrent(session);
    if (!transferCanRemove(record)) { throw queueFailure('请先停止任务；结果待确认的上传需在 NAS 核对后关闭。'); }
    if (record.backupKey !== undefined && record.state === 'completed') {
      if (this.backupCompleted === undefined) { throw queueFailure('备份记录尚未读取，请稍后清理。'); }
      await this.backupCompleted(record.backupKey);
    }
    if (record.taskId.length > 0) { await this.removeTask(record.taskId); this.unbind(record.taskId); }
    await this.stopChecksum(session, record);
    if (deleteLocalFile || record.direction !== 'download' || !record.localReady) {
      record.taskId = '';
      record.state = 'clearing';
      record.errorText = '';
      // 删除副本前保存清理标记；保留副本时不写此标记，避免重启后误删。
      await this.save(session);
      await removeTransferArtifacts(session.directory, record);
    }
    this.ensureCurrent(session);
    const remaining = session.records.filter((value: TransferQueueRecord): boolean => value.id !== record.id);
    await saveTransferRecords(session.directory, session.scope, remaining);
    session.records = remaining;
    this.publish(session);
  }

  private async removeTask(id: string): Promise<void> {
    try { await sdkTransferAgent.remove(id); }
    catch (error) { if (!isMissingTask(error as Error)) { throw error as Error; } }
  }

  private unbind(id: string): void {
    const binding = this.bindings.find((value: TaskBinding): boolean => value.taskId === id);
    binding?.dispose();
    this.bindings = this.bindings.filter((value: TaskBinding): boolean => value.taskId !== id);
  }

  private headers(plan: NasTransferPlan, download: boolean): TransferHeaders {
    const cookie = 'id=' + plan.session.sid;
    if (download) {
      if (plan.session.synoToken.length > 0) {
        return { Cookie: cookie, 'Cache-Control': 'no-store', 'X-SYNO-TOKEN': plan.session.synoToken,
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' };
      }
      return { Cookie: cookie, 'Cache-Control': 'no-store', 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' };
    }
    if (plan.session.synoToken.length > 0) { return { Cookie: cookie, 'Cache-Control': 'no-store', 'X-SYNO-TOKEN': plan.session.synoToken }; }
    return { Cookie: cookie, 'Cache-Control': 'no-store' };
  }

  private async save(session: QueueSession): Promise<void> {
    this.ensureCurrent(session);
    if (!session.loaded) { throw queueFailure('传输记录读取失败，已暂停传输，请在任务页重新加载。'); }
    session.records.forEach((record: TransferQueueRecord): void => { record.updatedAt = Date.now(); });
    await saveTransferRecords(session.directory, session.scope, session.records);
    this.publish(session);
  }

  private publish(session: QueueSession): void {
    if (this.session === session) { this.items = session.records.map(transferItem); }
  }

  private localPath(session: QueueSession, record: TransferQueueRecord): string { return session.directory + '/' + record.localName; }
  downloadLocalPath(id: string): string {
    const session = this.requireSession();
    return this.localPath(session, this.find(session, id));
  }
  private find(session: QueueSession, id: string): TransferQueueRecord {
    const record = session.records.find((value: TransferQueueRecord): boolean => value.id === id);
    if (record === undefined) { throw queueFailure('当前账号没有这个传输任务。'); }
    return record;
  }
  private requireSession(): QueueSession {
    if (this.session === undefined) { throw queueFailure('请先连接 NAS 再处理传输。'); }
    if (!this.session.loaded) { throw queueFailure('传输记录读取失败，已暂停传输，请在任务页重新加载。'); }
    return this.session;
  }
  /** 整批只准入一次；已有未知写入不能通过重新选择另一个文件绕过。 */
  private requireUploadAdmission(session: QueueSession): void {
    if (!session.canUpload() || session.records.some((record: TransferQueueRecord): boolean => record.direction === 'upload' &&
      !['completed', 'failed', 'cancelled', 'closed', 'clearing'].includes(record.state))) {
      throw new NasFailure(NasErrorKind.InvalidInput, '仍有写入进行中、结果待核对或记录未读取，请先处理任务。');
    }
  }

  /** 已接管的批次串行发送；未知写入阻止后续项目，无需重新提交整批。 */
  private canStartQueuedUpload(session: QueueSession, record: TransferQueueRecord): boolean {
    return (record.protocol !== 'photos' || record.source !== 'photoBackup' || this.backupAllowed) && session.canUpload() && !session.records.some((item: TransferQueueRecord): boolean => item.id !== record.id &&
      item.direction === 'upload' && !['preparing', 'queued', 'completed', 'failed', 'cancelled', 'closed', 'clearing'].includes(item.state));
  }
  private ensureCurrent(session: QueueSession): void {
    if (this.session !== session) { throw new NasFailure(NasErrorKind.Cancelled, '连接已变化，操作已结束。'); }
  }
  private report(session: QueueSession, error: Error): void {
    if (this.session !== session) { return; }
    this.errorText = transferError(error);
    const code = (error as BusinessError).code;
    hilog.error(0x0000, 'NasQueue', 'operation=transfer result=failed code=%{public}d', typeof code === 'number' ? code : 0);
  }
  private operation(session: QueueSession, work: () => Promise<void>, visible: boolean = true): Promise<void> {
    const next = this.tail.then(async (): Promise<void> => {
      this.ensureCurrent(session);
      if (visible) { this.busy = true; this.errorText = ''; }
      try { await work(); }
      catch (error) { this.report(session, error as Error); throw error as Error; }
      finally { if (visible && this.session === session) { this.busy = false; } }
    });
    // 链尾仅用于串行调度，真实错误由返回给调用方的 next 传播。
    this.tail = next.catch((): void => {});
    return next;
  }
}
