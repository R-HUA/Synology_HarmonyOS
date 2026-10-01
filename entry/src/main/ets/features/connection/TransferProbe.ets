import { common } from '@kit.AbilityKit';
import { request, BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasConnector, NasTransferPlan } from '../../core/network/NasConnector';
import { decodeNasResponse, encodeNasForm, nasRecord, nasString, NasErrorKind, NasFailure,
  validateLogicalPath } from '../../core/domain/DsmProtocol';

interface ProbeRecord {
  scope: string;
  nonce: string;
  directory: string;
  uploadId: string;
  downloadId: string;
  uploadAccepted: boolean;
  verified: boolean;
}
interface ProbeOutcome { progress: request.agent.Progress; status?: number; }
interface ProbeHeaders { Cookie: string; 'X-SYNO-TOKEN'?: string; 'Cache-Control': string; 'Content-Type'?: string; }

function content(nonce: string): string { return 'NAS transfer verification\n' + nonce + '\n中文内容校验 & + ,\n'; }
function filename(record: ProbeRecord): string { return 'nas-check-' + record.nonce + '.txt'; }
function remotePath(record: ProbeRecord): string { return record.directory + '/' + filename(record); }
function failure(message: string): NasFailure { return new NasFailure(NasErrorKind.Protocol, message); }
function ensureCurrent(current: () => boolean): void {
  if (!current()) { throw new NasFailure(NasErrorKind.Cancelled, '操作已结束，任务结果可在重新打开后检查。'); }
}

/** 小文件读写验证：系统任务完成、DSM 业务成功、目标确认、下载内容一致分别检查。 */
@ObservedV2
export class TransferProbe {
  @Trace running: boolean = false;
  @Trace available: boolean = false;
  @Trace status: string = '';
  @Trace processed: number = 0;
  private record: ProbeRecord | undefined = undefined;

  async inspectSaved(context: common.UIAbilityContext, origin: string, account: string): Promise<void> {
    const record = await this.readRecord(context);
    const sameAccount = record !== undefined && record.scope === await this.scope(origin, account);
    this.record = record;
    this.available = this.record !== undefined;
    this.status = record === undefined ? '' : !sameAccount ? '其他账号有传输记录' : record.verified ? '上次上传下载已校验' : '传输结果待检查';
  }

  async run(context: common.UIAbilityContext, connector: NasConnector, origin: string, account: string, directory: string, current: () => boolean): Promise<void> {
    if (this.running) { return; }
    validateLogicalPath(directory);
    const previous = await this.readRecord(context);
    const scope = await this.scope(origin, account);
    ensureCurrent(current);
    if (previous !== undefined && previous.scope !== scope && !previous.verified) { throw failure('存在其他账号的传输记录，请切回原账号处理。'); }
    if (previous !== undefined && !previous.verified) { throw failure('已有传输尚未确认，请先重新检查。'); }
    if (previous !== undefined) { await this.removeTasks(previous); }
    ensureCurrent(current);
    const record: ProbeRecord = {
      scope: scope, nonce: util.generateRandomUUID(), directory: directory,
      uploadId: '', downloadId: '', uploadAccepted: false, verified: false
    };
    this.record = record;
    this.available = true;
    this.running = true;
    try {
      await this.save(context, record);
      const source = context.cacheDir + '/' + filename(record);
      await this.write(source, new util.TextEncoder().encodeInto(content(record.nonce)));
      ensureCurrent(current);
      const plan = connector.transferUploadPlan(directory);
      const fields: request.agent.FormItem[] = plan.fields.map((field): request.agent.FormItem => ({ name: field.name, value: field.content }));
      // 群晖要求文件为最后一个 multipart 部分；不手动设置 multipart boundary。
      fields.push({ name: 'file', value: { path: source, filename: filename(record), contentType: 'text/plain' } });
      const task = await request.agent.create(context, {
        action: request.agent.Action.UPLOAD, url: plan.address, method: 'POST',
        mode: request.agent.Mode.BACKGROUND, title: '上传测试文件', data: fields,
        headers: this.headers(plan), retry: false, redirect: false, metered: false, roaming: false
      });
      record.uploadId = task.tid;
      await this.save(context, record);
      ensureCurrent(current);
      this.status = '正在上传';
      const outcome = await this.monitor(task, true);
      ensureCurrent(current);
      this.acceptUpload(outcome);
      record.uploadAccepted = true;
      await this.save(context, record);
      await this.finish(context, connector, record, current);
    } catch (error) {
      this.status = '传输结果待检查';
      throw error as Error;
    } finally { this.running = false; }
  }

  async reconcile(context: common.UIAbilityContext, connector: NasConnector, origin: string, account: string, current: () => boolean): Promise<void> {
    if (this.running) { return; }
    const record = await this.readRecord(context);
    if (record === undefined || record.scope !== await this.scope(origin, account)) {
      throw failure('当前账号没有可检查的传输。');
    }
    this.record = record;
    this.available = true;
    this.running = true;
    this.status = '正在检查传输';
    try {
      if (record.uploadId.length === 0) { throw failure('上传任务尚未建立，未确认写入，请重新开始。'); }
      const info = await request.agent.show(record.uploadId);
      ensureCurrent(current);
      hilog.info(0x0000, 'NasTransfer', 'operation=reconcile-upload state=%{public}d', info.progress.state);
      if (info.progress.state !== request.agent.State.COMPLETED) {
        const task = await request.agent.getTask(context, record.uploadId);
        ensureCurrent(current);
        const outcome = await this.monitor(task, info.progress.state === request.agent.State.INITIALIZED);
        ensureCurrent(current);
        this.acceptUpload(outcome);
        record.uploadAccepted = true;
        await this.save(context, record);
      } else if (!record.uploadAccepted) {
        const body = info.progress.extras === undefined ? undefined : nasRecord(info.progress.extras)['body'];
        if (typeof body === 'string') {
          this.acceptUpload({ progress: info.progress });
          record.uploadAccepted = true;
          await this.save(context, record);
        } else {
          // 系统完成不代表 DSM 成功；正文缺失时只通过随机内容的完整对账确认结果。
          hilog.info(0x0000, 'NasTransfer', 'operation=reconcile-upload result=body-unavailable');
        }
      }
      await this.finish(context, connector, record, current);
    } catch (error) {
      this.status = '传输结果待检查';
      throw error as Error;
    } finally { this.running = false; }
  }

  async cancelPending(context: common.UIAbilityContext): Promise<void> {
    const record = this.record ?? await this.readRecord(context);
    if (record !== undefined) { await this.removeTasks(record); }
    if (record !== undefined) {
      try { await fileIo.unlink(context.filesDir + '/transfer-probe.json'); }
      catch (error) { if ((error as BusinessError).code !== 13900002) { throw error as Error; } }
    }
    this.record = undefined;
    this.available = false;
    this.status = '';
  }

  private async finish(context: common.UIAbilityContext, connector: NasConnector, record: ProbeRecord, current: () => boolean): Promise<void> {
    ensureCurrent(current);
    this.status = '正在核对目标文件';
    const expected = new util.TextEncoder().encodeInto(content(record.nonce));
    const target = await connector.getFileInfo(remotePath(record));
    ensureCurrent(current);
    if (target.isDirectory || target.bytes !== expected.length) { throw failure('目标文件大小不符，上传结果未通过校验。'); }
    const destination = context.cacheDir + '/download-' + filename(record);
    let outcome: ProbeOutcome;
    if (record.downloadId.length > 0) {
      const info = await request.agent.show(record.downloadId);
      hilog.info(0x0000, 'NasTransfer', 'operation=reconcile-download state=%{public}d', info.progress.state);
      if (info.progress.state === request.agent.State.COMPLETED) { outcome = { progress: info.progress }; }
      else {
        const task = await request.agent.getTask(context, record.downloadId);
        ensureCurrent(current);
        outcome = await this.monitor(task, info.progress.state === request.agent.State.INITIALIZED);
      }
    } else {
      const plan = connector.transferDownloadPlan(remotePath(record));
      const headers = this.headers(plan, true);
      const task = await request.agent.create(context, {
        action: request.agent.Action.DOWNLOAD, url: plan.address, method: 'POST', data: encodeNasForm(plan.fields),
        mode: request.agent.Mode.BACKGROUND, title: '下载测试文件', saveas: destination, headers: headers,
        overwrite: false, retry: false, redirect: false, metered: false, roaming: false
      });
      record.downloadId = task.tid;
      await this.save(context, record);
      ensureCurrent(current);
      this.status = '正在下载';
      outcome = await this.monitor(task, true);
    }
    if (outcome.status !== undefined && outcome.status !== 200) {
      throw failure('下载 HTTP 请求未成功，文件未通过校验。');
    }
    const size = (await fileIo.stat(destination)).size;
    if (size !== expected.length) { throw failure('下载文件大小不符，未通过校验。'); }
    const actual = await this.readBytes(destination, expected.length);
    ensureCurrent(current);
    if (!actual.every((byte: number, index: number): boolean => byte === expected[index])) {
      throw failure('下载内容与原文件不一致，未通过校验。');
    }
    record.uploadAccepted = true;
    record.verified = true;
    await this.save(context, record);
    this.status = '上传下载已校验';
    hilog.info(0x0000, 'NasTransfer', 'operation=verify result=success bytes=%{public}d', expected.length);
  }

  private acceptUpload(outcome: ProbeOutcome): void {
    if (outcome.status !== undefined && outcome.status !== 200) { throw failure('上传 HTTP 请求未成功，结果待确认。'); }
    if (outcome.progress.extras === undefined) { throw failure('系统未提供上传响应，结果待确认。'); }
    const body = nasRecord(outcome.progress.extras)['body'];
    if (typeof body !== 'string') { throw failure('上传响应无法解析，结果待确认。'); }
    decodeNasResponse('SYNO.FileStation.Upload', 200, body as string);
    hilog.info(0x0000, 'NasTransfer', 'operation=upload-response result=success');
  }

  private headers(plan: NasTransferPlan, download: boolean = false): ProbeHeaders {
    const cookie = 'id=' + plan.session.sid;
    if (download) {
      if (plan.session.synoToken.length > 0) {
        return { Cookie: cookie, 'Cache-Control': 'no-store', 'X-SYNO-TOKEN': plan.session.synoToken,
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' };
      }
      return { Cookie: cookie, 'Cache-Control': 'no-store', 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' };
    }
    if (plan.session.synoToken.length > 0) {
      return { Cookie: cookie, 'Cache-Control': 'no-store', 'X-SYNO-TOKEN': plan.session.synoToken };
    }
    return { Cookie: cookie, 'Cache-Control': 'no-store' };
  }

  private monitor(task: request.agent.Task, start: boolean): Promise<ProbeOutcome> {
    this.processed = 0;
    return new Promise((resolve, reject): void => {
      let settled = false;
      let httpStatus: number | undefined = undefined;
      const response = (reply: request.agent.HttpResponse): void => {
        httpStatus = reply.statusCode;
        hilog.info(0x0000, 'NasTransfer', 'operation=http-response status=%{public}d', reply.statusCode);
      };
      const progress = (value: request.agent.Progress): void => { this.processed = value.processed; };
      const finish = (value?: request.agent.Progress, error?: NasFailure): void => {
        if (settled) { return; }
        settled = true;
        clearTimeout(timer);
        task.off('response', response); task.off('progress', progress);
        task.off('completed', completed); task.off('failed', failed);
        if (error !== undefined) { reject(error); }
        else if (value !== undefined) { resolve({ progress: value, status: httpStatus }); }
      };
      const completed = (value: request.agent.Progress): void => { finish(value); };
      const failed = (): void => { finish(undefined, new NasFailure(NasErrorKind.Network, '系统传输未成功，结果待检查。')); };
      const timer = setTimeout((): void => { finish(undefined, new NasFailure(NasErrorKind.Network, '系统传输仍待确认，请稍后重新检查。')); }, 30000);
      task.on('response', response); task.on('progress', progress);
      task.on('completed', completed); task.on('failed', failed);
      if (start) { task.start().catch((error: BusinessError): void => { finish(undefined, new NasFailure(NasErrorKind.Network, '无法启动系统传输。', error.code)); }); }
      else {
        request.agent.show(task.tid).then((info: request.agent.TaskInfo): void => {
          if (info.progress.state === request.agent.State.COMPLETED) { completed(info.progress); }
          else if ([request.agent.State.FAILED, request.agent.State.STOPPED, request.agent.State.REMOVED].includes(info.progress.state)) { failed(); }
        }).catch((error: BusinessError): void => { finish(undefined, new NasFailure(NasErrorKind.Network, '无法查询系统传输。', error.code)); });
      }
    });
  }

  private async scope(origin: string, account: string): Promise<string> {
    const digest = cryptoFramework.createMd('SHA256');
    await digest.update({ data: new util.TextEncoder().encodeInto(origin + '\n' + account.trim()) });
    return (await digest.digest()).data.reduce((text: string, byte: number): string => text + byte.toString(16).padStart(2, '0'), '');
  }

  private async save(context: common.UIAbilityContext, record: ProbeRecord): Promise<void> {
    const path = context.filesDir + '/transfer-probe.json';
    await this.write(path + '.tmp', new util.TextEncoder().encodeInto(JSON.stringify(record)));
    await fileIo.rename(path + '.tmp', path);
  }

  private async readRecord(context: common.UIAbilityContext): Promise<ProbeRecord | undefined> {
    let text: string;
    try {
      const path = context.filesDir + '/transfer-probe.json';
      if ((await fileIo.stat(path)).size > 4096) { throw failure('传输记录无效，无法安全恢复。'); }
      text = await fileIo.readText(path);
    } catch (error) {
      if ((error as BusinessError).code === 13900002) { return undefined; }
      throw error as Error;
    }
    const row = nasRecord(JSON.parse(text) as Object);
    const scope = nasString(row['scope']);
    const nonce = nasString(row['nonce']);
    const directory = validateLogicalPath(nasString(row['directory']));
    if (!/^[a-f0-9]{64}$/.test(scope) || !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(nonce) ||
      typeof row['uploadId'] !== 'string' || typeof row['downloadId'] !== 'string' ||
      typeof row['uploadAccepted'] !== 'boolean' || typeof row['verified'] !== 'boolean') {
      throw failure('传输记录无效，无法安全恢复。');
    }
    if ((row['uploadAccepted'] === true && nasString(row['uploadId']).length === 0) ||
      (row['verified'] === true && (row['uploadAccepted'] !== true || nasString(row['downloadId']).length === 0))) {
      throw failure('传输记录无效，无法安全恢复。');
    }
    return { scope: scope, nonce: nonce, directory: directory, uploadId: row['uploadId'] as string,
      downloadId: row['downloadId'] as string, uploadAccepted: row['uploadAccepted'] as boolean, verified: row['verified'] as boolean };
  }

  private async write(path: string, bytes: Uint8Array): Promise<void> {
    const file = await fileIo.open(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      let offset = 0;
      while (offset < bytes.length) {
        const size = await fileIo.write(file.fd, bytes.slice(offset).buffer as ArrayBuffer);
        if (size <= 0) { throw failure('本地文件写入未完成。'); }
        offset += size;
      }
    } finally { await fileIo.close(file); }
  }

  private async readBytes(path: string, length: number): Promise<Uint8Array> {
    const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
    const result = new Uint8Array(length);
    try {
      let offset = 0;
      while (offset < length) {
        const buffer = new ArrayBuffer(length - offset);
        const size = await fileIo.read(file.fd, buffer);
        if (size <= 0) { throw failure('本地文件读取未完成。'); }
        result.set(new Uint8Array(buffer).slice(0, size), offset);
        offset += size;
      }
    } finally { await fileIo.close(file); }
    return result;
  }

  private async removeTasks(record: ProbeRecord): Promise<void> {
    let failed: NasFailure | undefined = undefined;
    for (const id of [record.uploadId, record.downloadId]) {
      if (id.length === 0) { continue; }
      try { await request.agent.remove(id); }
      catch (error) {
        const code = (error as BusinessError).code;
        if (code !== 21900006) { failed = new NasFailure(NasErrorKind.Network, '本机传输任务未能全部取消，请重试。', code); }
      }
    }
    if (failed !== undefined) { throw failed; }
  }
}
