import { common } from '@kit.AbilityKit';
import { request, BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { encodeNasForm, nasRecord, NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { DriveTransferRecord, DriveBackgroundState } from '../../core/domain/DriveTransferState';
import { driveAgentUploadReceipt, validateDriveDownload } from '../../core/domain/DriveTransferProtocol';
import { DriveTransferAdapter } from '../../core/network/DriveTransferAdapter';
import { sdkTransferAgent } from '../../platform/SdkTransferAgent';
import { hashTransferFile, readTransferPrefix } from '../transfers/TransferQueueFiles';

interface DriveTaskMarker { driveTransfer: string; driveScope: string; driveAttempt: string; spaceBytes: string; }
interface DriveTaskBinding { id: string; dispose: () => void; }
function missing(error: Error): boolean { return (error as BusinessError).code === 21900006; }
function uncertain(): NasFailure { return new NasFailure(NasErrorKind.Protocol, '上传结果未能确认，请在 NAS 核对目标文件。'); }

/** 只驱动 Drive 的系统任务；记录和串行化仍归属 DriveTransferModel。 */
export class DriveBackgroundTransfer {
  private bindings: DriveTaskBinding[] = [];
  private attached: boolean = true;
  private context: common.UIAbilityContext;
  private adapter: DriveTransferAdapter;
  private origin: string;
  private scope: string;
  private directory: string;
  private current: () => void;
  private save: () => Promise<void>;
  private enqueue: (work: () => Promise<void>) => void;
  private publish: () => void;
  constructor(context: common.UIAbilityContext, adapter: DriveTransferAdapter,
    origin: string, scope: string, directory: string,
    current: () => void, save: () => Promise<void>,
    enqueue: (work: () => Promise<void>) => void, publish: () => void) {
    this.context = context; this.adapter = adapter; this.origin = origin; this.scope = scope; this.directory = directory;
    this.current = current; this.save = save; this.enqueue = enqueue; this.publish = publish;
  }

  detach(): void { this.attached = false; this.bindings.forEach((binding: DriveTaskBinding): void => binding.dispose()); this.bindings = []; }

  /** 进程重启后也不允许新账号沿用尚在执行的旧账号任务。 */
  async guardAccount(): Promise<void> {
    const ids = await sdkTransferAgent.search({ after: 0, mode: request.agent.Mode.BACKGROUND });
    for (const id of ids) {
      this.current();
      let info: request.agent.TaskInfo;
      try { info = await sdkTransferAgent.show(id); }
      catch (error) { if (missing(error as Error)) { continue; } throw error as Error; }
      this.current();
      if (info.extras === undefined) { continue; }
      const marker = nasRecord(info.extras);
      if (typeof marker['driveTransfer'] === 'string' && typeof marker['driveScope'] === 'string' && marker['driveScope'] !== this.scope &&
        [request.agent.State.INITIALIZED, request.agent.State.RUNNING, request.agent.State.WAITING, request.agent.State.RETRYING, request.agent.State.PAUSED].includes(info.progress.state)) {
        throw new NasFailure(NasErrorKind.InvalidInput, '原账号仍有 Drive 后台任务，请连接原账号并停止任务后再切换。');
      }
    }
  }

  async create(record: DriveTransferRecord, modifiedTime: number = 0, conflict: 'version' | 'autorename' = 'autorename'): Promise<void> {
    this.current(); sdkTransferAgent.requireCapability();
    if (record.direction === 'upload') {
      const stat = await fileIo.stat(this.path(record, 'upload'));
      if (!stat.isFile() || stat.size !== record.bytes) { throw new NasFailure(NasErrorKind.InvalidInput, '本机上传副本已变化，无法开始上传。'); }
    }
    record.executor = 'agent';
    const previous = record.background;
    record.background = { taskId: '', attempt: previous === undefined ? 1 : previous.attempt + 1,
      createdAt: Date.now(), startAttempted: false, processed: record.uploadSession?.offset || 0,
      httpStatus: 0, contentType: '', contentLength: '', contentDisposition: '' };
    const data = record.background;
    const plan = record.direction === 'upload' ? this.adapter.uploadPlan({ parentId: record.resource.fileId,
      filename: record.name, conflict: record.uploadSession === undefined ? conflict : 'version', modifiedTime }, record.uploadSession?.token) :
      this.adapter.downloadPlan(record.resource.fileId, record.name);
    if (!plan.address.startsWith(this.origin + '/webapi/')) { throw uncertain(); }
    record.state = 'creating'; await this.save(); this.current();
    const headers: Record<string, string> = { 'Cookie': 'id=' + encodeURIComponent(plan.session.sid), 'Cache-Control': 'no-store' };
    if (plan.session.synoToken.length > 0) { headers['X-SYNO-TOKEN'] = plan.session.synoToken; }
    if (plan.headers !== undefined) {
      for (const key of Object.keys(plan.headers)) { headers[key] = plan.headers[key]; }
    }
    const marker: DriveTaskMarker = { driveTransfer: record.id, driveScope: this.scope, driveAttempt: data.attempt.toString(),
      spaceBytes: (record.bytes ?? 512 * 1024 * 1024).toString() };
    const config: request.agent.Config = { action: record.direction === 'upload' ? request.agent.Action.UPLOAD : request.agent.Action.DOWNLOAD,
      url: plan.address, method: plan.method, mode: request.agent.Mode.BACKGROUND,
      title: record.direction === 'upload' ? 'Drive 上传' : 'Drive 下载', headers, retry: false, redirect: false,
      metered: false, roaming: false, gauge: true, extras: marker };
    if (record.direction === 'upload') {
      const fields: request.agent.FormItem[] = plan.fields.map((field): request.agent.FormItem => ({ name: field.name, value: field.content }));
      fields.push({ name: 'file', value: { path: this.path(record, 'upload'), filename: record.name, contentType: 'application/octet-stream' } });
      config.data = fields;
      // API26 的 begins/ends 对上传文件定义闭区间，和网页 file.slice(offset) 对齐。
      config.begins = record.uploadSession?.offset || 0;
      config.ends = -1;
      config.index = 0;
    } else {
      config.url = plan.address + '?' + encodeNasForm(plan.fields);
      config.saveas = this.path(record, 'content'); config.overwrite = false;
    }
    let task: request.agent.Task;
    try { task = await sdkTransferAgent.create(this.context, config); }
    catch (error) { record.errorText = '系统任务创建结果待检查，请刷新任务。'; await this.save(); throw error as Error; }
    data.taskId = task.tid;
    try { await this.save(); }
    catch (error) { await this.removeTask(task.tid); data.taskId = ''; throw error as Error; }
    try { this.current(); }
    catch (error) { await this.removeTask(task.tid); throw error as Error; }
    this.bind(record, task);
    data.startAttempted = true;
    if (record.uploadSession !== undefined) { record.uploadSession.started = true; }
    record.state = 'running'; await this.save(); this.current();
    try { await sdkTransferAgent.start(task); }
    catch (error) {
      record.state = record.direction === 'upload' ? 'unknown' : 'failed';
      record.errorText = '系统任务启动结果待检查，请刷新任务。'; await this.save(); throw error as Error;
    }
  }

  /** 恢复仅采用原任务，INITIALIZED 也不自动 start，避免重放未知上传。 */
  async refresh(record: DriveTransferRecord): Promise<void> {
    const data = record.background;
    if (data === undefined) { return; }
    this.current();
    if (data.taskId.length === 0 && record.state === 'creating') { await this.adopt(record); }
    if (data.taskId.length === 0) {
      if (record.state === 'creating') { record.state = 'failed'; record.errorText = '未找到原系统任务，请核对后重新选择文件。'; await this.save(); }
      return;
    }
    try {
      const info = await sdkTransferAgent.show(data.taskId); this.current();
      if (!this.matches(record, info)) { throw uncertain(); }
      if (['completed', 'closed', 'cancelled'].includes(record.state)) { await this.stop(record); return; }
      if (record.state === 'verifying') { return; }
      if (record.direction === 'download' && [request.agent.State.RUNNING, request.agent.State.WAITING, request.agent.State.PAUSED].includes(info.progress.state)) {
        await sdkTransferAgent.restoreDownloadSpace(this.context, data.taskId, this.path(record, 'content'),
          record.bytes ?? 512 * 1024 * 1024, info.progress.processed);
        this.current();
      }
      await this.accept(record, info.progress);
      if ([request.agent.State.RUNNING, request.agent.State.WAITING, request.agent.State.PAUSED].includes(info.progress.state)) {
        this.bind(record, await sdkTransferAgent.getTask(this.context, data.taskId));
      }
    } catch (error) {
      this.current();
      if (!missing(error as Error)) { throw error as Error; }
      data.taskId = '';
      if (!['completed', 'closed', 'cancelled', 'paused', 'verifying'].includes(record.state)) {
        record.state = record.direction === 'upload' && data.startAttempted ? 'unknown' : 'failed';
        record.errorText = record.state === 'unknown' ? '系统上传记录已不可用，请在 NAS 核对结果；不会自动重传。' : '系统下载记录已不可用，请重新下载。';
      }
      await this.save();
    }
  }

  async stop(record: DriveTransferRecord): Promise<void> {
    const data = record.background;
    if (data === undefined) { return; }
    if (data.taskId.length === 0 && record.state === 'creating') { await this.adopt(record); }
    if (data.taskId.length > 0) {
      const id = data.taskId;
      try {
        const info = await sdkTransferAgent.show(id); this.current();
        if (!this.matches(record, info)) { throw new NasFailure(NasErrorKind.Protocol, '系统任务与此账号的传输记录不符，无法停止。'); }
      } catch (error) { if (!missing(error as Error)) { throw error as Error; } }
      await this.removeTask(id); this.unbind(id); this.current(); data.taskId = ''; await this.save();
    }
  }

  async pause(record: DriveTransferRecord): Promise<void> {
    if (record.direction !== 'upload' || record.uploadSession === undefined) {
      throw new NasFailure(NasErrorKind.InvalidInput, '仅保存新版本的上传支持暂停；下载请取消后重新下载。');
    }
    const data = record.background;
    if (data === undefined || data.taskId.length === 0) { throw uncertain(); }
    // 继续时必须先探测 NAS offset，再新建同 token 的剩余内容任务。
    await this.stop(record);
    record.state = 'paused'; record.errorText = ''; await this.save();
  }

  async startUnstarted(record: DriveTransferRecord): Promise<void> {
    const data = record.background;
    if (data === undefined || data.startAttempted || data.taskId.length === 0 || record.state !== 'paused') { throw uncertain(); }
    const info = await sdkTransferAgent.show(data.taskId); this.current();
    if (!this.matches(record, info) || info.progress.state !== request.agent.State.INITIALIZED) { throw uncertain(); }
    if (record.direction === 'upload') {
      const path = this.path(record, 'upload');
      const stat = await fileIo.stat(path);
      const upload = record.uploadSession;
      if (!stat.isFile() || stat.size !== record.bytes || upload !== undefined && (stat.mtime !== upload.sourceMtime ||
        await hashTransferFile(path, record.bytes!, this.current) !== upload.sourceMd5)) {
        throw new NasFailure(NasErrorKind.InvalidInput, '本机上传副本已变化，无法开始原系统任务。');
      }
      this.current();
    }
    const task = await sdkTransferAgent.getTask(this.context, data.taskId); this.current(); this.bind(record, task);
    data.startAttempted = true;
    if (record.uploadSession !== undefined) { record.uploadSession.started = true; }
    record.state = 'running'; await this.save(); this.current();
    await sdkTransferAgent.start(task);
  }

  private async adopt(record: DriveTransferRecord): Promise<void> {
    const data = record.background!;
    const ids = await sdkTransferAgent.search({ after: Math.max(0, data.createdAt - 60000), mode: request.agent.Mode.BACKGROUND });
    const found: string[] = [];
    for (const id of ids) {
      this.current();
      try { if (this.matches(record, await sdkTransferAgent.show(id))) { found.push(id); } }
      catch (error) { if (!missing(error as Error)) { throw error as Error; } }
    }
    if (found.length > 1) { throw new NasFailure(NasErrorKind.Protocol, '同一上传存在多个系统任务，请核对后处理。'); }
    if (found.length === 1) { data.taskId = found[0]; await this.save(); }
  }

  private matches(record: DriveTransferRecord, info: request.agent.TaskInfo): boolean {
    if (info.extras === undefined) { return false; }
    const marker = nasRecord(info.extras);
    return marker['driveScope'] === this.scope && marker['driveTransfer'] === record.id &&
      marker['driveAttempt'] === record.background!.attempt.toString();
  }

  private bind(record: DriveTransferRecord, task: request.agent.Task): void {
    if (this.bindings.some((binding: DriveTaskBinding): boolean => binding.id === task.tid)) { return; }
    const id = task.tid;
    const dispatch = (work: () => Promise<void>): void => {
      if (!this.attached) { return; }
      this.enqueue(async (): Promise<void> => {
        if (!this.attached) { return; }
        this.current();
        if (record.background?.taskId !== id || ['completed', 'closed', 'cancelled'].includes(record.state)) { return; }
        await work();
      });
    };
    const progress = (value: request.agent.Progress): void => dispatch(async (): Promise<void> => { await this.accept(record, value); });
    const dispose = sdkTransferAgent.observe(task, {
      response: (value: request.agent.HttpResponse): void => dispatch(async (): Promise<void> => {
        const data = record.background!;
        data.httpStatus = value.statusCode;
        value.headers.forEach((values: string[], name: string): void => { this.header(data, name, values.join(';')); });
        await this.save();
      }), progress, completed: progress, failed: progress,
      error: (error: Error): void => dispatch(async (): Promise<void> => { throw error; })
    });
    this.bindings.push({ id, dispose });
  }

  private async accept(record: DriveTransferRecord, progress: request.agent.Progress): Promise<void> {
    this.current();
    const data = record.background!;
    const extra: Record<string, Object> = progress.extras === undefined ? {} : nasRecord(progress.extras);
    for (const name of ['content-type', 'content-length', 'content-disposition']) {
      if (typeof extra[name] === 'string') { this.header(data, name, extra[name] as string); }
    }
    const offset = record.uploadSession?.offset || 0;
    if (Number.isSafeInteger(progress.processed) && progress.processed >= 0) {
      data.processed = Math.min(record.bytes === undefined ? 512 * 1024 * 1024 : record.bytes, offset + progress.processed);
    }
    if (progress.state === request.agent.State.COMPLETED) {
      record.systemCompleted = true;
      if (record.direction === 'download' && (data.httpStatus === 0 || data.httpStatus === 206)) {
        const stat = await fileIo.stat(this.path(record, 'content')); this.current();
        if (stat.isFile() && Number.isSafeInteger(stat.size) && stat.size <= 512 * 1024 * 1024 &&
          (record.bytes === undefined || record.bytes === stat.size)) {
          record.bytes = stat.size; record.state = 'verifying';
          record.errorText = '系统已完成下载，但缺少完整响应证据。请校验已下载文件后再保存。';
          await this.save(); return;
        }
      }
      try {
        if (record.direction === 'upload') { driveAgentUploadReceipt(data.httpStatus, progress.extras, record.bytes!); }
        else { await this.verifyDownload(record); }
        this.current(); record.state = 'completed'; record.errorText = ''; await this.save();
      } catch (error) {
        this.current(); record.state = record.direction === 'upload' ? 'unknown' : 'failed';
        record.errorText = error instanceof NasFailure ? error.message : '无法确认下载文件，请刷新任务。';
        await this.save();
        if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { throw error; }
        return;
      }
      await this.stop(record);
      return;
    }
    if ([request.agent.State.FAILED, request.agent.State.STOPPED, request.agent.State.REMOVED].includes(progress.state)) {
      record.state = record.direction === 'upload' && data.startAttempted ? 'unknown' : 'failed';
      record.errorText = record.state === 'unknown' ? '上传已中断，请核对结果或确认继续原上传。' : '下载已中断，请重新下载。';
    } else if (progress.state === request.agent.State.INITIALIZED) {
      record.state = data.startAttempted && record.direction === 'upload' ? 'unknown' : 'paused';
      record.errorText = '原系统任务尚未运行，请处理此记录后继续。';
    } else if (progress.state === request.agent.State.PAUSED) {
      record.state = 'paused';
      if (record.direction === 'download') { record.errorText = '旧下载已暂停；暂不支持下载续传，请取消后重新下载。'; }
    }
    else if (progress.state === request.agent.State.WAITING) { record.state = 'waiting'; }
    else { record.state = 'running'; this.publish(); return; }
    await this.save();
  }

  private async verifyDownload(record: DriveTransferRecord): Promise<void> {
    const data = record.background!;
    const path = this.path(record, 'content');
    const stat = await fileIo.stat(path);
    if (!stat.isFile()) { throw new NasFailure(NasErrorKind.Protocol, '下载文件不可用。'); }
    const prefix = await readTransferPrefix(path, stat.size); this.current();
    validateDriveDownload({ status: data.httpStatus, contentType: data.contentType, contentLength: data.contentLength,
      contentDisposition: data.contentDisposition, bytes: stat.size, prefix: new Uint8Array(0), prefixText: prefix.text },
      { directory: this.directory + '/' + record.id, maximumBytes: 512 * 1024 * 1024, expectedBytes: record.bytes });
    record.bytes = stat.size;
  }

  private header(data: DriveBackgroundState, name: string, value: string): void {
    if (value.length > 4096) { throw new NasFailure(NasErrorKind.Protocol, '传输响应无法校验，请重新检查。'); }
    switch (name.toLowerCase()) {
      case 'content-type': data.contentType = value; break;
      case 'content-length': data.contentLength = value; break;
      case 'content-disposition': data.contentDisposition = value; break;
    }
  }
  private path(record: DriveTransferRecord, name: string): string { return this.directory + '/' + record.id + '/' + name; }
  private unbind(id: string): void {
    this.bindings.find((binding: DriveTaskBinding): boolean => binding.id === id)?.dispose();
    this.bindings = this.bindings.filter((binding: DriveTaskBinding): boolean => binding.id !== id);
  }
  private async removeTask(id: string): Promise<void> {
    try { await sdkTransferAgent.remove(id); } catch (error) { if (!missing(error as Error)) { throw error as Error; } }
  }
}
