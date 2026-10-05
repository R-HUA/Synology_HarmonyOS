import { nasRecord, NasErrorKind, NasFailure } from './DsmProtocol';
import { validateDriveFileId } from './DriveProtocol';
import { validateDriveTaskId } from './DriveActionProtocol';
import type { DriveAction } from './DriveActionProtocol';
import type { DriveResourceRef } from './DriveTransferState';

export interface DriveActionRecord {
  id: string; action: DriveAction; resource: DriveResourceRef; name: string;
  destination: string; taskId?: string;
  state: 'unknown' | 'accepted' | 'completed' | 'failed' | 'partial' | 'closed';
  progress?: number; errorText: string;
}
export interface DriveActionSnapshot { version: number; scope: string; records: DriveActionRecord[]; }
export function driveActionText(action: DriveAction): string {
  switch (action) { case 'rename': return '改名'; case 'move': return '移动'; case 'copy': return '复制'; case 'delete': return '删除'; }
}
export function driveActionStateText(state: string): string {
  switch (state) {
    case 'unknown': return '结果待确认'; case 'accepted': return '已提交，等待结果'; case 'completed': return '已完成';
    case 'failed': return '未完成'; case 'partial': return '已结束，需核对'; case 'closed': return '已核对关闭';
    default: return '状态待确认';
  }
}
export function copyDriveAction(record: DriveActionRecord): DriveActionRecord {
  return { id: record.id, action: record.action, resource: { nasOrigin: record.resource.nasOrigin,
    account: record.resource.account, fileId: record.resource.fileId }, name: record.name, destination: record.destination,
    taskId: record.taskId, state: record.state, progress: record.progress, errorText: record.errorText };
}
export function decodeDriveActions(text: string, scope: string, origin: string, account: string): DriveActionRecord[] {
  const invalid = (): NasFailure => new NasFailure(NasErrorKind.Protocol, 'Drive 操作记录无法读取，请保留记录后重新加载。');
  let value: Object;
  try { value = JSON.parse(text) as Object; } catch (_) { throw invalid(); }
  const root: Record<string, Object> = nasRecord(value);
  if (root['version'] !== 1 || root['scope'] !== scope || !Array.isArray(root['records']) || (root['records'] as Object[]).length > 1000) { throw invalid(); }
  const ids: string[] = [];
  return (root['records'] as Object[]).map((value: Object): DriveActionRecord => {
    const row: Record<string, Object> = nasRecord(value);
    const resource: Record<string, Object> = nasRecord(row['resource']);
    const id = row['id'];
    const taskId = row['taskId'];
    const progress = row['progress'];
    if (typeof id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id) || ids.includes(id) ||
      !['rename', 'move', 'copy', 'delete'].includes(row['action'] as string) ||
      !['unknown', 'accepted', 'completed', 'failed', 'partial', 'closed'].includes(row['state'] as string) ||
      typeof row['name'] !== 'string' || (row['name'] as string).length > 4096 ||
      typeof row['destination'] !== 'string' || (row['destination'] as string).length > 4096 ||
      typeof row['errorText'] !== 'string' || (row['errorText'] as string).length > 4096 ||
      resource['nasOrigin'] !== origin || resource['account'] !== account || typeof resource['fileId'] !== 'string' ||
      (taskId !== undefined && typeof taskId !== 'string') || (row['state'] === 'accepted' && taskId === undefined) ||
      (row['action'] !== 'rename' && ['completed', 'partial'].includes(row['state'] as string) && taskId === undefined) ||
      (row['action'] === 'rename' && (taskId !== undefined || row['state'] === 'accepted')) ||
      (progress !== undefined && (typeof progress !== 'number' || !Number.isFinite(progress) || progress < 0 || progress > 100))) { throw invalid(); }
    ids.push(id);
    return { id, action: row['action'] as DriveAction, name: row['name'] as string, destination: row['destination'] as string,
      resource: { nasOrigin: origin, account, fileId: validateDriveFileId(resource['fileId'] as string) },
      taskId: taskId === undefined ? undefined : validateDriveTaskId(taskId as string), progress: progress as number | undefined,
      state: row['state'] as DriveActionRecord['state'], errorText: row['errorText'] as string };
  });
}
