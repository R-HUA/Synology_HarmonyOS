import { TransferQueueItem } from './TransferQueueState';
import { DriveTransferRecord, driveTransferStateText } from './DriveTransferState';
import { DriveActionRecord, driveActionText, driveActionStateText } from './DriveActionState';
import { FileTaskItem } from './FileOperations';

export type TaskScope = 'root' | 'files' | 'photos' | 'drive';
export type TaskFilter = 'all' | 'active' | 'finished';
export type TaskGroup = 'download' | 'upload' | 'processing';
export type TaskModel = 'transfer' | 'driveTransfer' | 'file' | 'driveAction';

/** 仅投影列表展示信息，记录及业务动作仍归原模型所有。 */
export interface TaskRecordView {
  key: string;
  model: TaskModel;
  id: string;
  group: TaskGroup;
  name: string;
  path: string;
  state: string;
  stateText: string;
  errorText: string;
  bytes?: number;
  processed?: number;
  progress?: number;
  canRemove: boolean;
}

export function taskEnded(state: string): boolean {
  return ['completed', 'failed', 'partial', 'closed', 'clearing'].includes(state);
}

export function taskMatchesFilter(record: TaskRecordView, filter: TaskFilter): boolean {
  return filter === 'all' || (filter === 'finished' ? taskEnded(record.state) : !taskEnded(record.state));
}

/** 未迁移来源与取消记录不参与展示、计数或批量操作。 */
export function taskRecords(scope: TaskScope, transfers: TransferQueueItem[], drive: DriveTransferRecord[],
  files: FileTaskItem[], actions: DriveActionRecord[]): TaskRecordView[] {
  const result: TaskRecordView[] = [];
  if (scope !== 'drive') {
    transfers.forEach((item: TransferQueueItem): void => {
      const photo = item.source === 'photoUpload' || item.source === 'photoBackup';
      if (item.source === 'legacy' || item.state === 'cancelled' || scope === 'photos' && !photo || scope === 'files' && photo) { return; }
      result.push({ key: 'transfer:' + item.id, model: 'transfer', id: item.id,
        group: item.direction, name: item.name, path: item.remotePath, state: item.state, stateText: item.stateText,
        errorText: item.errorText, bytes: item.bytes > 0 ? item.bytes : undefined, processed: item.processed,
        progress: item.bytes > 0 ? Math.min(100, item.processed / item.bytes * 100) : undefined,
        canRemove: item.canRemove });
    });
  }
  if (scope === 'root' || scope === 'drive') {
    drive.forEach((item: DriveTransferRecord): void => {
      if (item.state === 'cancelled') { return; }
      result.push({ key: 'driveTransfer:' + item.id, model: 'driveTransfer', id: item.id,
        group: item.direction, name: item.name, path: item.locationName, state: item.state,
        stateText: driveTransferStateText(item.state), errorText: item.errorText, bytes: item.bytes,
        processed: item.state === 'completed' ? item.bytes : item.background?.processed,
        progress: item.state === 'completed' ? 100 : item.bytes !== undefined && item.bytes > 0 && item.background !== undefined ?
          Math.min(99, item.background.processed / item.bytes * 100) : undefined,
        canRemove: taskEnded(item.state) });
    });
    actions.forEach((item: DriveActionRecord): void => {
      result.push({ key: 'driveAction:' + item.id, model: 'driveAction', id: item.id, group: 'processing',
        name: driveActionText(item.action) + ' ' + item.name, path: item.destination, state: item.state,
        stateText: driveActionStateText(item.state), errorText: item.errorText, progress: item.progress,
        canRemove: taskEnded(item.state) });
    });
  }
  if (scope === 'root' || scope === 'files') {
    files.forEach((item: FileTaskItem): void => {
      if (item.operation === 'legacy') { return; }
      result.push({ key: 'file:' + item.id, model: 'file', id: item.id, group: 'processing',
        name: item.label, path: item.target ?? item.sources.join('、'), state: item.state,
        stateText: item.state === 'pending' ? '正在处理' : item.state === 'unknown' ? '结果待确认' :
          item.state === 'completed' ? '已完成' : item.state === 'failed' ? '处理失败' : '已核对关闭',
        errorText: item.errorText, canRemove: taskEnded(item.state) });
    });
  }
  return result;
}
