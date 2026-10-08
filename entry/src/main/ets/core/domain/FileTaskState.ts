import { nasRecord, nasString, NasErrorKind, NasFailure, validateLogicalPath } from './DsmProtocol';
import { NasFileTaskKind, validateFileTask } from './FileOperations';
import type { FileTaskItem, FileTaskState, NasFileTask, FileMutationKind } from './FileOperations';

export interface FileTaskSnapshot { version: number; scope: string; tasks: FileTaskItem[]; }

function invalidTasks(): NasFailure {
  return new NasFailure(NasErrorKind.Protocol, '文件操作记录损坏，请保留记录并重试读取，暂不能启动新的整理任务。');
}

/** 读取失败必须交给调用方，不能用空列表覆盖已有任务。 */
export function decodeFileTasks(text: string, scope: string): FileTaskItem[] {
  const root = nasRecord(JSON.parse(text) as Object);
  if (![1, 2].includes(root['version'] as number) || root['scope'] !== scope || !Array.isArray(root['tasks'])) { throw invalidTasks(); }
  const rows = root['tasks'] as Object[];
  if (rows.length > 1000) { throw invalidTasks(); }
  const ids: string[] = [];
  const handles: string[] = [];
  return rows.map((value: Object): FileTaskItem => {
    const row = nasRecord(value);
    const id = nasString(row['id']);
    const label = nasString(row['label']);
    const state = row['state'];
    const errorText = row['errorText'];
    if (!/^[0-9a-f-]{36}$/.test(id) || ids.includes(id) || label.length === 0 || label.length > 4096 ||
      !['pending', 'completed', 'failed', 'unknown', 'closed'].includes(state as string) ||
      typeof errorText !== 'string' || (errorText as string).length > 4096) { throw invalidTasks(); }
    let task: NasFileTask | undefined = undefined;
    if (row['task'] !== undefined) {
      const taskRow = nasRecord(row['task']);
      const taskId = nasString(taskRow['taskId']);
      const kind = taskRow['kind'];
      if (typeof kind !== 'number' || ![NasFileTaskKind.Delete, NasFileTaskKind.Copy, NasFileTaskKind.Move].includes(kind) || taskId.length > 4096) { throw invalidTasks(); }
      task = { taskId: taskId, kind: kind as NasFileTaskKind };
      validateFileTask(task);
      const handle = task.kind.toString() + ':' + task.taskId;
      if (handles.includes(handle)) { throw invalidTasks(); }
      handles.push(handle);
    } else if (root['version'] === 1 || state === 'pending') { throw invalidTasks(); }
    let operation: FileMutationKind = 'legacy';
    let sources: string[] = [];
    let target: string | undefined = undefined;
    let createdAt = 0;
    if (root['version'] === 2) {
      if (!['createFolder', 'rename', 'delete', 'copy', 'move', 'legacy'].includes(row['operation'] as string) ||
        !Array.isArray(row['sources']) || typeof row['createdAt'] !== 'number' ||
        !Number.isSafeInteger(row['createdAt']) || (row['createdAt'] as number) < 0) { throw invalidTasks(); }
      operation = row['operation'] as FileMutationKind;
      sources = (row['sources'] as Object[]).map((path: Object): string => { const text = nasString(path); validateLogicalPath(text); return text; });
      createdAt = row['createdAt'] as number;
      if (operation !== 'legacy' && (sources.length !== 1 || createdAt <= 0)) { throw invalidTasks(); }
      if (row['target'] !== undefined) { target = nasString(row['target']); validateLogicalPath(target); }
      if (operation !== 'legacy' && operation !== 'delete' && target === undefined) { throw invalidTasks(); }
      if (task !== undefined && operation !== 'legacy' &&
        (operation === 'delete' ? task.kind !== NasFileTaskKind.Delete : operation === 'copy' ? task.kind !== NasFileTaskKind.Copy :
          operation === 'move' ? task.kind !== NasFileTaskKind.Move : true)) { throw invalidTasks(); }
    }
    ids.push(id);
    return { id: id, task: task, operation: operation, sources: sources, target: target, createdAt: createdAt,
      label: label, state: state as FileTaskState, errorText: errorText as string };
  });
}
