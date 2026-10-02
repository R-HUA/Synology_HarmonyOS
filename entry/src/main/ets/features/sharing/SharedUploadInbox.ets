import { AbilityConstant, common, Want } from '@kit.AbilityKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { systemShare } from '@kit.ShareKit';
import { closeFile } from '../../platform/SdkFileIO';

const MAX_SHARED_FILES: number = 20;
const MAX_FILE_BYTES: number = 256 * 1024 * 1024;
const MAX_INBOX_BYTES: number = 512 * 1024 * 1024;
const COPY_CHUNK_BYTES: number = 256 * 1024;
const SUPPORTED_TYPES: string[] = [
  'general.image', 'general.video', 'general.audio', 'com.adobe.pdf', 'general.file'
];

/** uri 和 localPath 均指向应用私有副本，fileName 保留原文件名。 */
export interface SharedUploadFile {
  id: string;
  uri: string;
  localPath: string;
  fileName: string;
  size: number;
  utd: string;
}

class SharedIntakeFailure extends Error {}
class SharedIntakeCancelled extends Error {}

/** 只接收分享文件；登录、目录选择和确认上传由页面负责。 */
@ObservedV2
export class SharedUploadInbox {
  @Trace files: SharedUploadFile[] = [];
  @Trace receiving: boolean = false;
  @Trace errorText: string = '';

  private operation: Promise<void> = Promise.resolve();
  private pendingReceipts: number = 0;
  private generation: number = 0;
  private privateDir: string = '';

  @Computed
  get pendingCount(): number { return this.files.length; }

  /** 普通启动不读取分享数据。入站失败保存在 errorText，不影响首页启动。 */
  receive(context: common.UIAbilityContext, want: Want,
    launchParam: AbilityConstant.LaunchParam): Promise<void> {
    if (want.action !== 'ohos.want.action.sendData' &&
      launchParam.launchReasonMessage !== 'ReasonMessage_SystemShare') {
      return Promise.resolve();
    }
    const generation = this.generation;
    this.pendingReceipts++;
    this.receiving = true;
    const pending = this.operation.then(async (): Promise<void> => {
      try {
        this.checkGeneration(generation);
        this.errorText = '';
        await this.receiveFiles(context, want, generation);
      } catch (error) {
        if (!(error instanceof SharedIntakeCancelled)) { this.recordError(error as Error); }
      } finally {
        this.pendingReceipts--;
        this.receiving = this.pendingReceipts > 0;
      }
    });
    this.operation = pending;
    return pending;
  }

  /** 队列复制/接管副本后按快照 ID 消费，保留其他条目和新入站批次。 */
  consume(ids: string[]): Promise<void> {
    const selected = new Set<string>(ids);
    if (selected.size === 0) { return Promise.resolve(); }
    const pending = this.operation.then(async (): Promise<void> => {
      const retained: SharedUploadFile[] = [];
      let failed = false;
      for (const file of this.files) {
        if (!selected.has(file.id)) {
          retained.push(file);
          continue;
        }
        try { await this.removeCopy(file.localPath); }
        catch (error) {
          retained.push(file);
          failed = true;
          this.recordError(error as Error, '无法清理已转交的分享文件，请重试。');
        }
      }
      this.files = retained;
      if (failed) { throw new SharedIntakeFailure('无法清理已转交的分享文件，请重试。'); }
    });
    this.operation = pending.catch((): void => {});
    return pending;
  }

  /** 取消全部待上传文件及尚未完成的入站批次；清理失败保留对应条目并抛错。 */
  clear(): Promise<void> {
    this.generation++;
    const pending = this.operation.then(async (): Promise<void> => {
      this.errorText = '';
      const retained: SharedUploadFile[] = [];
      for (const file of this.files) {
        try { await this.removeCopy(file.localPath); }
        catch (error) {
          retained.push(file);
          this.recordError(error as Error, '无法清理分享文件，请重试。');
        }
      }
      this.files = retained;
      if (retained.length > 0) { throw new SharedIntakeFailure(this.errorText); }
    });
    // 清理失败仍允许下一次接收；调用者可以 await clear() 获取失败结果。
    this.operation = pending.catch((): void => {});
    return pending;
  }

  private async receiveFiles(context: common.UIAbilityContext, want: Want,
    generation: number): Promise<void> {
    const data = await systemShare.getSharedData(want);
    this.checkGeneration(generation);
    const records = data.getRecords();
    if (records.length === 0 || records.length > MAX_SHARED_FILES) {
      throw new SharedIntakeFailure('一次最多接收 20 个分享文件，请重新选择。');
    }
    if (this.files.length + records.length > MAX_SHARED_FILES) {
      throw new SharedIntakeFailure('待上传文件最多保留 20 个，请先处理已有文件。');
    }
    await this.prepareDirectory(context);
    for (let index = 0; index < records.length; index++) {
      this.checkGeneration(generation);
      try {
        const file = await this.copyRecord(records[index], generation);
        if (generation !== this.generation) {
          await this.removeCopy(file.localPath);
          throw new SharedIntakeCancelled();
        }
        this.files = this.files.concat(file);
      } catch (error) {
        if (error instanceof SharedIntakeCancelled) { throw error as Error; }
        this.recordError(error as Error, '', index + 1);
      }
    }
    hilog.info(0x0000, 'NasShare', 'operation=receive result=finished pending=%{public}d', this.files.length);
  }

  private async prepareDirectory(context: common.UIAbilityContext): Promise<void> {
    if (this.privateDir.length > 0) { return; }
    const directory = context.filesDir + '/shared-upload-inbox';
    try { await fileIo.mkdir(directory, true); }
    catch (error) {
      if ((error as BusinessError).code !== 13900015) { throw error as Error; }
      if (!(await fileIo.stat(directory)).isDirectory()) { throw error as Error; }
    }
    // 收件箱只在当前进程内保留；新进程接收前清理上次未确认的副本。
    const names = await fileIo.listFile(directory);
    for (const name of names) {
      if (/^[0-9a-f-]{36}\.share$/.test(name)) { await this.removeCopy(directory + '/' + name); }
    }
    this.privateDir = directory;
  }

  private async copyRecord(record: systemShare.SharedRecord, generation: number): Promise<SharedUploadFile> {
    const uri = record.uri;
    if (typeof uri !== 'string' || uri.length === 0 || uri.length > 4096 ||
      !uri.startsWith('file://') || /[\u0000-\u001f\u007f]/.test(uri)) {
      throw new SharedIntakeFailure('仅支持分享本机文件，不支持文本或链接。');
    }
    if (typeof record.utd !== 'string' || record.utd.length > 256 || !this.supportsType(record.utd)) {
      throw new SharedIntakeFailure('暂不支持此类分享文件。');
    }
    const fileName = new fileUri.FileUri(uri).name;
    if (fileName.length === 0 || fileName.length > 255 || fileName === '.' || fileName === '..' ||
      /[\/\\\u0000-\u001f\u007f]/.test(fileName)) {
      throw new SharedIntakeFailure('分享文件名无效，请在原应用重命名后再分享。');
    }
    const id = util.generateRandomUUID();
    const localPath = this.privateDir + '/' + id + '.share';
    try {
      const size = await this.copyFile(uri, localPath, generation);
      this.checkGeneration(generation);
      return { id: id, uri: fileUri.getUriFromPath(localPath), localPath: localPath,
        fileName: fileName, size: size, utd: record.utd };
    } catch (error) {
      try { await this.removeCopy(localPath); }
      catch (cleanupError) {
        hilog.error(0x0000, 'NasShare', 'operation=copy_cleanup result=failed code=%{public}d',
          (cleanupError as BusinessError).code);
      }
      throw error as Error;
    }
  }

  private supportsType(utd: string): boolean {
    const descriptor = uniformTypeDescriptor.getTypeDescriptor(utd);
    return SUPPORTED_TYPES.some((supported: string): boolean =>
      utd === supported || descriptor.belongsTo(supported));
  }

  private async copyFile(uri: string, localPath: string, generation: number): Promise<number> {
    const source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    let sourceFailed = false;
    try {
      this.checkGeneration(generation);
      const info = await fileIo.stat(source.fd);
      if (!info.isFile() || !Number.isSafeInteger(info.size) || info.size < 0) {
        throw new SharedIntakeFailure('只能接收普通文件，请单独选择文件后分享。');
      }
      if (info.size > MAX_FILE_BYTES) {
        throw new SharedIntakeFailure('单个分享文件不能超过 256 MB。');
      }
      const usedBytes = this.files.reduce((total: number, file: SharedUploadFile): number => total + file.size, 0);
      if (usedBytes + info.size > MAX_INBOX_BYTES) {
        throw new SharedIntakeFailure('待上传分享文件总大小不能超过 512 MB，请先处理已有文件。');
      }
      const destination = await fileIo.open(localPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      let destinationFailed = false;
      try {
        await this.copyBytes(source.fd, destination.fd, info.size, generation);
        if ((await fileIo.stat(destination.fd)).size !== info.size) {
          throw new SharedIntakeFailure('未能完整保存分享文件，请重新分享。');
        }
      } catch (error) { destinationFailed = true; throw error as Error; }
      finally { await closeFile(destination, destinationFailed); }
      return info.size;
    } catch (error) { sourceFailed = true; throw error as Error; }
    finally { await closeFile(source, sourceFailed); }
  }

  private async copyBytes(sourceFd: number, destinationFd: number, size: number,
    generation: number): Promise<void> {
    let copied = 0;
    const buffer = new ArrayBuffer(COPY_CHUNK_BYTES);
    while (copied < size) {
      this.checkGeneration(generation);
      const count = await fileIo.read(sourceFd, buffer, { length: Math.min(COPY_CHUNK_BYTES, size - copied) });
      if (count <= 0 || count > Math.min(COPY_CHUNK_BYTES, size - copied)) {
        throw new SharedIntakeFailure('分享文件已变化，请在原应用重新分享。');
      }
      let written = 0;
      while (written < count) {
        const bytes = await fileIo.write(destinationFd, buffer.slice(written, count));
        if (bytes <= 0 || bytes > count - written) {
          throw new SharedIntakeFailure('未能完整保存分享文件，请重新分享。');
        }
        written += bytes;
      }
      copied += count;
    }
    // 限制外部文件在复制期间增长，避免超出已验证的大小和存储上限。
    if (await fileIo.read(sourceFd, new ArrayBuffer(1)) !== 0) {
      throw new SharedIntakeFailure('分享文件已变化，请在原应用重新分享。');
    }
  }

  private checkGeneration(generation: number): void {
    if (generation !== this.generation) { throw new SharedIntakeCancelled(); }
  }

  private async removeCopy(path: string): Promise<void> {
    try { await fileIo.unlink(path); }
    catch (error) {
      if ((error as BusinessError).code !== 13900002) { throw error as Error; }
    }
  }

  private recordError(error: Error, message: string = '', ordinal: number = 0): void {
    const code = (error as BusinessError).code;
    hilog.error(0x0000, 'NasShare', 'operation=receive result=failed code=%{public}d',
      typeof code === 'number' ? code : 0);
    const text = message.length > 0 ? message : error instanceof SharedIntakeFailure ? error.message :
      '无法读取分享文件，请返回原应用重新分享。';
    const prefix = ordinal > 0 ? '第 ' + ordinal + ' 个文件：' : '';
    this.errorText = this.errorText.length > 0 ? this.errorText + '\n' + prefix + text : prefix + text;
  }
}

export const sharedUploadInbox = new SharedUploadInbox();
