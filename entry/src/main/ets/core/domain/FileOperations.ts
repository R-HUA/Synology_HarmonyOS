import { dsmFailure, nasInteger, nasRecord, nasString, NasErrorKind, NasFailure,
  validateLogicalPath } from './DsmProtocol';
import type { NasFileEntry } from './DsmProtocol';

export enum NasFileSortBy { Name = 'name', Size = 'size', ModifiedTime = 'mtime', Type = 'type' }
export enum NasFileSortDirection { Ascending = 'asc', Descending = 'desc' }
export enum NasFileTaskKind { Delete, Copy, Move }
export enum NasFileTaskUnit { Files, Bytes }

export type FileEditResult = 'completed' | 'pending' | 'failed';
export type FileTaskState = 'pending' | 'completed' | 'failed' | 'unknown' | 'closed';
export type FileMutationKind = 'createFolder' | 'rename' | 'delete' | 'copy' | 'move' | 'legacy';

/** 本地意图先于请求保存；远端回执缺失时也能保留核对依据。 */
export interface FileTaskItem {
  id: string;
  task?: NasFileTask;
  operation: FileMutationKind;
  sources: string[];
  target?: string;
  createdAt: number;
  label: string;
  state: FileTaskState;
  errorText: string;
}

/** API 版本可用性不代表当前账号拥有目标文件的写权限。 */
export interface NasFileOperationCapabilities {
  createFolder: boolean;
  renameFile: boolean;
  deleteFiles: boolean;
  copyFiles: boolean;
  moveFiles: boolean;
}

/** start 成功仅表示任务已启动，必须查询 status 才能确认完成。 */
export interface NasFileTask { taskId: string; kind: NasFileTaskKind; }
export interface NasFileTaskStatus extends NasFileTask {
  finished: boolean;
  unit: NasFileTaskUnit;
  progress?: number;
  processed?: number;
  /** 服务端 total=-1 表示仍在统计，此时不提供总量。 */
  total?: number;
}

function invalidOperationResponse(): NasFailure {
  return new NasFailure(NasErrorKind.Protocol, '文件操作响应格式不符合预期，请检查 File Station 版本。');
}

export function validateFileName(name: string): void {
  if (name.trim().length === 0 || name === '.' || name === '..' || /[/:\u0000-\u001f\u007f]/.test(name)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '名称不能为空，不能包含斜杠、冒号或控制字符。');
  }
}

/** 整理操作只接受规范逻辑路径；共享目录本身不能被重命名、删除或移动。 */
export function validateFileOperationPath(path: string, requireChild: boolean = false): void {
  validateLogicalPath(path);
  if (path.endsWith('/') || path.includes('//') || /\u007f/.test(path) || requireChild && path.lastIndexOf('/') === 0) {
    throw new NasFailure(NasErrorKind.InvalidInput, '请选择共享目录内的有效文件或文件夹。');
  }
}

export function validateFileOperationPaths(paths: string[]): void {
  if (paths.length === 0) { throw new NasFailure(NasErrorKind.InvalidInput, '请先选择文件或文件夹。'); }
  for (let index = 0; index < paths.length; index++) {
    validateFileOperationPath(paths[index], true);
    for (let earlier = 0; earlier < index; earlier++) {
      if (paths[index] === paths[earlier] || paths[index].startsWith(paths[earlier] + '/') ||
        paths[earlier].startsWith(paths[index] + '/')) {
        throw new NasFailure(NasErrorKind.InvalidInput, '不能重复选择文件，或同时选择文件夹及其内部文件。');
      }
    }
  }
}

export function validateFileTask(task: NasFileTask): void {
  if (![NasFileTaskKind.Delete, NasFileTaskKind.Copy, NasFileTaskKind.Move].includes(task.kind) ||
    task.taskId.trim().length === 0 || /[\u0000-\u001f\u007f]/.test(task.taskId)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '文件操作任务标识不正确。');
  }
}

/** 逐文件错误不能被外层 success=true 掩盖。 */
export function assertFileOperationSuccess(data: Record<string, Object>, api: string): void {
  if (data['error'] !== undefined) { throw dsmFailure(api, nasInteger(nasRecord(data['error'])['code'])); }
  const errors = data['errors'];
  if (errors !== undefined) {
    if (!Array.isArray(errors)) { throw invalidOperationResponse(); }
    if (errors.length > 0) { throw dsmFailure(api, nasInteger(nasRecord((errors as Object[])[0])['code'])); }
  }
}

/** 创建和重命名必须返回唯一且匹配的目标，不把其它文件视作成功结果。 */
export function decodeFileOperationEntry(data: Record<string, Object>, api: string, key: string,
  expectedPath: string, expectedName: string, directoryOnly: boolean): NasFileEntry {
  assertFileOperationSuccess(data, api);
  const files = data[key];
  if (!Array.isArray(files) || files.length !== 1) { throw invalidOperationResponse(); }
  const row = nasRecord((files as Object[])[0]);
  assertFileOperationSuccess(row, api);
  const path = validateLogicalPath(nasString(row['path']));
  const name = nasString(row['name']);
  if (path !== expectedPath || name !== expectedName || typeof row['isdir'] !== 'boolean' ||
    directoryOnly && row['isdir'] !== true) { throw invalidOperationResponse(); }
  const additional = row['additional'] === undefined ? undefined : nasRecord(row['additional']);
  return { path: path, name: name, isDirectory: row['isdir'] === true,
    bytes: additional === undefined || additional['size'] === undefined ? undefined : nasInteger(additional['size']) };
}

export function decodeFileTask(data: Record<string, Object>, api: string, kind: NasFileTaskKind): NasFileTask {
  assertFileOperationSuccess(data, api);
  const taskId = nasString(data['taskid']);
  if (taskId.trim().length === 0 || /[\u0000-\u001f\u007f]/.test(taskId)) { throw invalidOperationResponse(); }
  return { taskId: taskId, kind: kind };
}

export function decodeFileTaskStatus(data: Record<string, Object>, api: string, task: NasFileTask): NasFileTaskStatus {
  assertFileOperationSuccess(data, api);
  if (typeof data['finished'] !== 'boolean') { throw invalidOperationResponse(); }
  const isDelete = task.kind === NasFileTaskKind.Delete;
  const processed = data[isDelete ? 'processed_num' : 'processed_size'];
  const total = data['total'];
  const progress = data['progress'];
  if (total !== undefined && (typeof total !== 'number' || !Number.isSafeInteger(total) || (total as number) < -1) ||
    progress !== undefined && (typeof progress !== 'number' || !Number.isFinite(progress) || (progress as number) < 0 || (progress as number) > 1)) {
    throw invalidOperationResponse();
  }
  const processedValue = processed === undefined ? undefined : nasInteger(processed);
  const totalValue = total === undefined || total === -1 ? undefined : nasInteger(total);
  if (processedValue !== undefined && totalValue !== undefined && processedValue > totalValue) {
    throw invalidOperationResponse();
  }
  return { taskId: task.taskId, kind: task.kind, finished: data['finished'] === true,
    unit: isDelete ? NasFileTaskUnit.Files : NasFileTaskUnit.Bytes,
    processed: processedValue, total: totalValue, progress: progress === undefined ? undefined : progress as number };
}
