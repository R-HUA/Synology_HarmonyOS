import { nasRecord, NasErrorKind, NasFailure } from './DsmProtocol';
import type { NasFormField } from './DsmProtocol';
import { decodeDriveEntry, DriveEntryKind, validateDriveFileId } from './DriveProtocol';
import type { DriveEntry } from './DriveProtocol';
import { validateNasTransferFilename } from '../network/NasTransferTransport';

export const DRIVE_TASKS_API = 'SYNO.SynologyDrive.Tasks';
export type DriveAction = 'create' | 'rename' | 'move' | 'copy' | 'delete';
export interface DriveActionInput { action: DriveAction; entry: DriveEntry; name?: string; target?: DriveEntry; }
export interface DriveActionStatus { state: 'accepted' | 'completed' | 'failed' | 'partial'; progress?: number; }

export function driveActionAllowed(entry: DriveEntry, action: DriveAction): boolean {
  if (!entry.capabilities.canRead) { return false; }
  switch (action) {
    case 'create': return entry.kind === DriveEntryKind.Folder && entry.capabilities.canWrite;
    case 'rename': return entry.capabilities.canRename;
    case 'delete': return entry.capabilities.canDelete;
    // 当前 Drive 网页的 copy/move 权限规则，不再使用未证实的 can_organize 映射。
    case 'copy': return true;
    case 'move': return entry.capabilities.canDelete;
  }
}

export function driveActionFields(input: DriveActionInput, preview: boolean = false): NasFormField[] {
  const id = validateDriveFileId(input.entry.fileId);
  if (!driveActionAllowed(input.entry, input.action)) { throw new NasFailure(NasErrorKind.Permission, '没有权限执行此操作。'); }
  if (input.action === 'rename' || input.action === 'create') {
    const name: string = validateNasTransferFilename((input.name ?? '').trim());
    if (name.length > 255 || input.action === 'rename' && name === input.entry.name) {
      throw new NasFailure(NasErrorKind.InvalidInput, input.action === 'create' ? '请输入有效的文件夹名称。' : '请输入有效且不同的新名称。');
    }
    if (input.action === 'create') {
      // 官方 Drive 2.0.2 网页 createNode 使用父目录 ID 拼接名称，并由服务端处理重名。
      return [{ name: 'path', content: JSON.stringify('id:' + id + '/' + name) },
        { name: 'type', content: JSON.stringify('folder') }, { name: 'conflict_action', content: JSON.stringify('autorename') }];
    }
    return [{ name: 'path', content: JSON.stringify('id:' + id) }, { name: 'name', content: JSON.stringify(name) }];
  }
  const files: NasFormField = { name: 'files', content: JSON.stringify(['id:' + id]) };
  if (input.action === 'delete') {
    if (input.entry.revisionCount === undefined || !Number.isSafeInteger(input.entry.revisionCount) || input.entry.revisionCount < 0) {
      throw new NasFailure(NasErrorKind.InvalidInput, '无法确认此文件的版本信息，请刷新后重试。');
    }
    return [files, { name: 'permanent', content: 'false' }, { name: 'revisions', content: input.entry.revisionCount.toString() }];
  }
  const target = input.target;
  if (target === undefined || target.kind !== 'folder' || !target.capabilities.canRead || !target.capabilities.canWrite ||
    target.fileId === id || input.action === 'move' && target.fileId === input.entry.parentId) {
    throw new NasFailure(NasErrorKind.InvalidInput, '请选择其他可写的目标文件夹。');
  }
  const fields: NasFormField[] = [files,
    { name: 'to_parent_folder', content: JSON.stringify('id:' + validateDriveFileId(target.fileId)) },
    { name: 'to_parent_folder_name', content: JSON.stringify(target.name) }];
  return [...fields, preview ? { name: 'dry_run', content: 'true' } :
    { name: 'conflict_action', content: JSON.stringify('autorename') }];
}

export function decodeDrivePreflight(data: Record<string, Object>): number {
  const result: Object = data['result'];
  if (data['async_task_id'] !== undefined) { throw new NasFailure(NasErrorKind.Protocol, '无法确认目标文件夹的检查结果。'); }
  // Drive 网页只对非空冲突列表提示冲突；兼容空 JSON 结果，缺失或非空未知结构仍拒绝。
  if (result === null || typeof result === 'object' && !Array.isArray(result) && Object.keys(result).length === 0) { return 0; }
  if (!Array.isArray(result) || (result as Object[]).length > 1000) { throw new NasFailure(NasErrorKind.Protocol, '无法确认目标文件夹的检查结果。'); }
  return (result as Object[]).length;
}

export function validateDriveTaskId(id: string): string {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$/.test(id)) {
    throw new NasFailure(NasErrorKind.Protocol, '无法确认 Drive 操作任务，请在 NAS 核对结果。');
  }
  return id;
}

export function decodeDriveActionStart(data: Record<string, Object>, input: DriveActionInput): string | undefined {
  if (input.action === 'create') {
    const entry: DriveEntry = decodeDriveEntry(data);
    if (entry.kind !== DriveEntryKind.Folder || entry.parentId !== input.entry.fileId || entry.fileId === input.entry.fileId) {
      throw new NasFailure(NasErrorKind.Protocol, '新建文件夹结果未能确认，请在 NAS 核对。');
    }
    return undefined;
  }
  if (input.action === 'rename') {
    const entry: DriveEntry = decodeDriveEntry(data);
    if (entry.fileId !== input.entry.fileId || entry.name !== input.name?.trim()) {
      throw new NasFailure(NasErrorKind.Protocol, '改名结果未能确认，请在 NAS 核对。');
    }
    return undefined;
  }
  if (typeof data['async_task_id'] !== 'string') {
    throw new NasFailure(NasErrorKind.Protocol, '操作已发送但任务未能确认，请在 NAS 核对结果。');
  }
  return validateDriveTaskId(data['async_task_id'] as string);
}

/** 当前网页以 finished 和 result.errors/skips 判断结果；未知状态保留待确认。 */
export function decodeDriveActionStatus(data: Record<string, Object>, taskId: string): DriveActionStatus {
  if (data['task_id'] !== taskId || !['string', 'number'].includes(typeof data['status'])) {
    throw new NasFailure(NasErrorKind.Protocol, 'Drive 任务状态无法确认，请稍后重新查询。');
  }
  const progress = data['progress'];
  if (progress !== undefined && (typeof progress !== 'number' || !Number.isFinite(progress) || progress < -1 || progress > 100)) {
    throw new NasFailure(NasErrorKind.Protocol, 'Drive 任务进度无法确认。');
  }
  const status: DriveActionStatus = { state: 'accepted', progress: typeof progress === 'number' && progress >= 0 ? progress : undefined };
  if (data['status'] === 'finished' && data['result'] === undefined) {
    throw new NasFailure(NasErrorKind.Protocol, 'Drive 任务结果无法确认，请先在 NAS 核对。');
  }
  if (data['result'] !== undefined) {
    const result: Record<string, Object> = nasRecord(data['result']);
    for (const key of ['errors', 'skips']) {
      if (result[key] !== undefined && !Array.isArray(result[key])) {
        throw new NasFailure(NasErrorKind.Protocol, 'Drive 任务结果无法确认。');
      }
    }
    if (data['status'] === 'finished') {
      status.state = Array.isArray(result['errors']) && (result['errors'] as Object[]).length > 0 ? 'failed' :
        Array.isArray(result['skips']) && (result['skips'] as Object[]).length > 0 ? 'partial' : 'completed';
    }
  }
  return status;
}
