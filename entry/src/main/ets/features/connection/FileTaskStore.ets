import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { sha256 } from '../../platform/SdkDigest';
import { NasErrorKind, NasFailure, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import { FileTaskItem } from '../../core/domain/FileOperations';
import { decodeFileTasks, FileTaskSnapshot } from '../../core/domain/FileTaskState';
import { writePrivateSnapshot } from '../../platform/SdkFileIO';

/** 每个实例绑定一个 NAS/账号；只有成功读取后才允许覆盖该账号的记录。 */
export class FileTaskStore {
  private path: string = '';
  private scope: string = '';

  async load(context: common.UIAbilityContext, origin: string, account: string): Promise<FileTaskItem[]> {
    this.path = '';
    this.scope = '';
    if (account.trim().length === 0) { throw new NasFailure(NasErrorKind.InvalidInput, '缺少账号，无法读取文件操作记录。'); }
    const scope = await sha256(new util.TextEncoder().encodeInto(JSON.stringify([normalizeNasOrigin(origin), account.trim()])));
    const directory = context.filesDir + '/file-tasks/' + scope;
    try { await fileIo.mkdir(directory, true); }
    catch (error) { if ((error as BusinessError).code !== 13900015) { throw error as Error; } }
    const path = directory + '/tasks.json';
    let missing = false;
    try {
      const stat = await fileIo.stat(path);
      if (stat.size > 1024 * 1024) { throw new NasFailure(NasErrorKind.Protocol, '文件操作记录过大，暂不能安全恢复任务。'); }
    } catch (error) {
      if ((error as BusinessError).code !== 13900002) { throw error as Error; }
      missing = true;
    }
    // 仅首次 stat 确认不存在才建立空历史；存在后的读取失败不能允许覆盖原记录。
    const text = missing ? undefined : await fileIo.readText(path);
    const tasks: FileTaskItem[] = text === undefined ? [] : decodeFileTasks(text, scope);
    this.scope = scope;
    this.path = path;
    return tasks;
  }

  /** 调用方串行写入；临时文件完整落盘后再替换正式记录。 */
  async save(tasks: FileTaskItem[]): Promise<void> {
    if (this.path.length === 0) { throw new NasFailure(NasErrorKind.Protocol, '尚未成功读取文件操作记录，不能覆盖原记录。'); }
    const snapshot: FileTaskSnapshot = { version: 2, scope: this.scope, tasks: tasks };
    decodeFileTasks(JSON.stringify(snapshot), this.scope);
    const bytes = new util.TextEncoder().encodeInto(JSON.stringify(snapshot));
    if (bytes.length > 1024 * 1024) { throw new NasFailure(NasErrorKind.Protocol, '文件操作记录过大，无法完整保存。'); }
    await writePrivateSnapshot(this.path, bytes);
  }
}
