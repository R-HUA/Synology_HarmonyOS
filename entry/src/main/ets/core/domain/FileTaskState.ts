import { nasRecord, nasString, NasErrorKind, NasFailure } from './DsmProtocol';
import { NasFileTaskKind, validateFileTask } from './FileOperations';
import type { FileTaskItem, FileTaskState, NasFileTask } from './FileOperations';

export interface FileTaskSnapshot { version: number; scope: string; tasks: FileTaskItem[]; }

function invalidTasks(): NasFailure {
  return new NasFailure(NasErrorKind.Protocol, '文件操作记录损坏，请保留记录并重试读取，暂不能启动新的整理任务。');
}

/** 读取失败必须交给调用方，不能用空列表覆盖已有任务。 */
export function decodeFileTasks(text: string, scope: string): FileTaskItem[] {
  const root = nasRecord(JSON.parse(text) as Object);
  if (root['version'] !== 1 || root['scope'] !== scope || !Array.isArray(root['tasks'])) { throw invalidTasks(); }
  const rows = root['tasks'] as Object[];
  if (rows.length > 1000) { throw invalidTasks(); }
  const ids: string[] = [];
  const handles: string[] = [];
  return rows.map((value: Object): FileTaskItem => {
    const row = nasRecord(value);
    const id = nasString(row['id']);
    const taskRow = nasRecord(row['task']);
    const taskId = nasString(taskRow['taskId']);
    const kind = taskRow['kind'];
    const label = nasString(row['label']);
    const state = row['state'];
    const errorText = row['errorText'];
    if (!/^[0-9a-f-]{36}$/.test(id) || ids.includes(id) || typeof kind !== 'number' ||
      ![NasFileTaskKind.Delete, NasFileTaskKind.Copy, NasFileTaskKind.Move].includes(kind as number) ||
      taskId.length > 4096 || label.length === 0 || label.length > 4096 ||
      !['pending', 'completed', 'failed', 'unknown'].includes(state as string) ||
      typeof errorText !== 'string' || (errorText as string).length > 4096) { throw invalidTasks(); }
    const task: NasFileTask = { taskId: taskId, kind: kind as NasFileTaskKind };
    validateFileTask(task);
    const handle = task.kind.toString() + ':' + task.taskId;
    if (handles.includes(handle)) { throw invalidTasks(); }
    ids.push(id);
    handles.push(handle);
    return { id: id, task: task, label: label, state: state as FileTaskState, errorText: errorText as string };
  });
}
