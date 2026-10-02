import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { NasErrorKind, NasFailure, validateLogicalPath } from '../../core/domain/DsmProtocol';
import { TransferQueueItem, transferRemotePath, validateTransferName } from '../../core/domain/TransferQueueState';
import { TransferQueue, TransferUploadSource } from '../transfers/TransferQueue';

const MAX_SELECTED_FILES: number = 20;
const MAX_FILE_BYTES: number = 256 * 1024 * 1024;
const MAX_SELECTED_BYTES: number = 512 * 1024 * 1024;

export interface PhotoBackupSource extends TransferUploadSource { bytes: number; }
interface AcceptedBackupTarget { remotePath: string; name: string; }

function selectionError(error: Error): string {
  if (error instanceof NasFailure) { return error.message; }
  const code = (error as BusinessError).code;
  if (code === 201 || code === 13900012) {
    return '所选照片或视频的读取授权不可用，请重新选择。';
  }
  if (code === 13900002) { return '所选照片或视频已不可用，请重新选择。'; }
  return '无法读取所选照片或视频，请检查文件授权后重新选择。';
}

/** 只处理系统选择器授权的项目；私有副本与备份结果由传输队列负责。 */
@ObservedV2
export class PhotoBackup {
  @Trace sources: PhotoBackupSource[] = [];
  @Trace selecting: boolean = false;
  @Trace submitting: boolean = false;
  @Trace status: string = '';
  @Trace errorText: string = '';

  private ticket: number = 0;
  private accountGeneration: number = 0;
  private acceptedTargets: Map<string, AcceptedBackupTarget> = new Map<string, AcceptedBackupTarget>();

  async select(_context: common.UIAbilityContext, queue?: TransferQueue): Promise<void> {
    if (this.selecting || this.submitting) { return; }
    const ticket = this.ticket;
    this.selecting = true;
    this.errorText = '';
    this.status = '请选择需要备份的照片或视频';
    try {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
      options.maxSelectNumber = MAX_SELECTED_FILES;
      const selected = await new photoAccessHelper.PhotoViewPicker().select(options);
      this.ensureCurrent(ticket);
      if (selected.photoUris.length === 0) {
        this.status = '已取消选择，已选内容保持不变。';
        return;
      }
      this.releaseClosedTargets(queue);
      const staged = this.sources.slice();
      const seen = new Set<string>(staged.map((source: PhotoBackupSource): string => source.uri));
      const names = new Set<string>();
      this.acceptedTargets.forEach((target: AcceptedBackupTarget): void => { names.add(target.name); });
      staged.forEach((source: PhotoBackupSource): void => { names.add(source.name); });
      let totalBytes = staged.reduce((total: number, source: PhotoBackupSource): number => total + source.bytes, 0);
      let skippedDuplicates = 0;
      const issues: string[] = [];
      for (const uri of selected.photoUris) {
        this.ensureCurrent(ticket);
        if (seen.has(uri) || this.acceptedTargets.has(uri)) { skippedDuplicates++; continue; }
        seen.add(uri);
        if (staged.length >= MAX_SELECTED_FILES) {
          issues.push('每批最多选择 20 项，请先提交或清空当前选择。');
          continue;
        }
        try {
          const source = await this.readSource(uri, ticket);
          this.ensureCurrent(ticket);
          if (totalBytes + source.bytes > MAX_SELECTED_BYTES) {
            throw new NasFailure(NasErrorKind.InvalidInput, '每批照片和视频的总大小不能超过 512 MiB。');
          }
          // 不同授权 URI 的重名文件保留内容，以序号区分 NAS 目标名称。
          source.name = this.availableName(source.name, names);
          names.add(source.name);
          staged.push(source);
          totalBytes += source.bytes;
        } catch (error) {
          this.ensureCurrent(ticket);
          issues.push(selectionError(error as Error));
        }
      }
      this.ensureCurrent(ticket);
      this.sources = staged;
      this.errorText = issues.length === 0 ? '' : issues[0] + (issues.length > 1 ? ` 另有 ${issues.length - 1} 项未加入。` : '');
      this.status = `已选择 ${staged.length} 项，提交后请在传输任务中查看备份结果。` +
        (skippedDuplicates > 0 ? ` 已跳过 ${skippedDuplicates} 个重复或已入队项目。` : '');
    } catch (error) {
      if (this.ticket !== ticket) { return; }
      this.errorText = selectionError(error as Error);
      this.status = '选择未完成，已选内容已保留。';
    } finally {
      if (this.ticket === ticket) { this.selecting = false; }
    }
  }

  async submit(directory: string, queue: TransferQueue): Promise<void> {
    if (this.selecting || this.submitting) { return; }
    if (this.sources.length === 0) {
      this.errorText = '请先选择需要备份的照片或视频。';
      return;
    }
    const ticket = this.ticket;
    const accountGeneration = this.accountGeneration;
    const snapshot = this.sources.map((source: PhotoBackupSource): PhotoBackupSource =>
      ({ uri: source.uri, name: source.name, bytes: source.bytes }));
    this.submitting = true;
    this.errorText = '';
    this.status = '正在将所选照片和视频交给传输队列…';
    try {
      validateLogicalPath(directory);
      const result = await queue.uploadSources(directory, snapshot);
      if (this.accountGeneration !== accountGeneration) { return; }
      const accepted = new Set<number>(result.acceptedIndices);
      snapshot.forEach((source: PhotoBackupSource, index: number): void => {
        if (accepted.has(index)) {
          this.acceptedTargets.set(source.uri, { remotePath: transferRemotePath(directory, source.name), name: source.name });
        }
      });
      // 清空选择时仍记录接管结果，防止同一账号重新选择后重复提交。
      if (this.ticket !== ticket) { return; }
      this.sources = snapshot.filter((_source: PhotoBackupSource, index: number): boolean => !accepted.has(index));
      const acceptedCount = snapshot.length - this.sources.length;
      this.status = acceptedCount > 0 ?
        `已将 ${acceptedCount} 项交给传输队列，备份结果请在传输任务中查看。` : '没有项目被传输队列接收。';
      if (this.sources.length > 0) { this.status += ` 仍有 ${this.sources.length} 项待提交，可重试。`; }
      if (result.issues.length > 0) {
        this.errorText = result.issues[0].errorText + (acceptedCount > 0 ? ' 已入队项目的问题请在传输任务中处理。' : '');
      } else if (this.sources.length > 0) {
        this.errorText = '部分所选项目尚未入队，请重试。';
      }
    } catch (error) {
      if (this.ticket !== ticket || this.accountGeneration !== accountGeneration) { return; }
      this.errorText = error instanceof NasFailure ? error.message : '无法提交备份，请检查连接和本机存储后重试。';
      this.status = '提交未完成，尚未接收的所选内容已保留。';
    } finally {
      if (this.accountGeneration === accountGeneration) { this.submitting = false; }
    }
  }

  /** 清除待提交选择，已入队 URI 仍受保护，直到记录关闭、移除或账号重置。 */
  clear(): void {
    this.ticket++;
    this.sources = [];
    this.selecting = false;
    this.status = '';
    this.errorText = '';
  }

  /** 切换账号或连接时调用，使旧选择和旧提交结果失效。 */
  reset(): void {
    this.accountGeneration++;
    this.clear();
    this.submitting = false;
    this.acceptedTargets = new Map<string, AcceptedBackupTarget>();
  }

  dispose(): void { this.reset(); }

  private releaseClosedTargets(queue?: TransferQueue): void {
    if (queue === undefined || !queue.ready) { return; }
    const released: string[] = [];
    this.acceptedTargets.forEach((target: AcceptedBackupTarget, uri: string): void => {
      // 正在清理仍保留记录；只有明确关闭或彻底移除后才能重新选择。
      const protectedTarget = queue.items.some((item: TransferQueueItem): boolean =>
        item.direction === 'upload' && item.remotePath === target.remotePath && item.state !== 'closed');
      if (!protectedTarget) { released.push(uri); }
    });
    released.forEach((uri: string): void => { this.acceptedTargets.delete(uri); });
  }
  private ensureCurrent(ticket: number): void {
    if (this.ticket !== ticket) { throw new NasFailure(NasErrorKind.Cancelled, '连接或所选内容已变化。'); }
  }

  private async readSource(uri: string, ticket: number): Promise<PhotoBackupSource> {
    const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    try {
      this.ensureCurrent(ticket);
      const stat = await fileIo.stat(file.fd);
      this.ensureCurrent(ticket);
      if (stat.isDirectory() || !Number.isSafeInteger(stat.size) || stat.size < 0) {
        throw new NasFailure(NasErrorKind.InvalidInput, '所选照片或视频的文件大小无效。');
      }
      if (stat.size > MAX_FILE_BYTES) {
        throw new NasFailure(NasErrorKind.InvalidInput, '单个照片或视频不能超过 256 MiB。');
      }
      // 从授权文件对象取得真实名称，不使用媒体 URI 的资源编号。
      return { uri: uri, name: validateTransferName(file.name), bytes: stat.size };
    } finally { await fileIo.close(file); }
  }

  private availableName(name: string, names: Set<string>): string {
    if (!names.has(name)) { return name; }
    const extensionStart = name.lastIndexOf('.');
    const base = extensionStart > 0 ? name.substring(0, extensionStart) : name;
    const extension = extensionStart > 0 ? name.substring(extensionStart) : '';
    let suffix = 2;
    let candidate = `${base} (${suffix})${extension}`;
    while (names.has(candidate)) { suffix++; candidate = `${base} (${suffix})${extension}`; }
    return candidate;
  }
}