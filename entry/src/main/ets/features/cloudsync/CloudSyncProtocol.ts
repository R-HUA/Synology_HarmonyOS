import { nasRecord, NasFailure, NasErrorKind } from '../../core/domain/DsmProtocol';
import { readArray, readId, readText, readNumber, readableLog, utf8Bytes, READ_WINDOW_BYTES, READ_WINDOW_ROWS } from '../../core/domain/ReadOnlyProtocol';

export interface CloudConnection { id: string; name: string; provider: string; account: string; status: string; }
export interface CloudFolder { id: string; direction: string; local: string; remote: string; status: string; error: string; }
export interface CloudHistory { key: string; time: number | undefined; file: string; path: string; action: string; level: string; error: string; }
export interface CloudHistoryPage { items: CloudHistory[]; received: number; more: boolean; }
export interface CloudQuota { total: number | undefined; used: number | undefined; }

function status(value: Object | undefined): string {
  switch (readText(value)) {
    case 'uptodate': return '已同步'; case 'syncing': return '同步中'; case 'paused': return '已暂停';
    case 'error': return '同步异常'; case 'connecting': return '连接中'; default: return '未知状态';
  }
}

export function decodeCloudConnections(data: Object): CloudConnection[] {
  const ids: Set<string> = new Set<string>();
  return readArray(data['conn']).map((value: Object): CloudConnection => {
    const row = nasRecord(value), id = readId(row['id']), account = readText(row['user_name']);
    if (ids.has(id)) { throw new NasFailure(NasErrorKind.Protocol, '云同步连接标识重复。'); } ids.add(id);
    const type = readText(row['type']);
    return { id, name: readText(row['task_display_name']) || readText(row['task_name']) || '云同步连接',
      provider: type === 'db' ? 'Dropbox' : type === 'od_v1' ? '微软 OneDrive' : type === 'gd' ? 'Google 云端硬盘' :
        readText(row['task_name']) || '未提供', account: account.length > 0 ? Array.from(account)[0] + '***' : '未提供',
      status: status(row['status']) };
  });
}

export function decodeCloudFolders(data: Object, connectionId: string): CloudFolder[] {
  const ids: Set<string> = new Set<string>();
  return readArray(data['sess']).map((value: Object): CloudFolder => {
    const row = nasRecord(value), id = readId(row['sess_id']);
    if (readId(row['conn_id']) !== connectionId || ids.has(id)) { throw new NasFailure(NasErrorKind.Protocol, '同步目录与连接不匹配。'); }
    ids.add(id);
    const direction = readText(row['sync_direction']);
    const error = readNumber(row['error']);
    return { id, direction: direction === 'ONLY_DOWNLOAD' ? '仅下载' : direction === 'ONLY_UPLOAD' ? '仅上传' :
      direction === 'BIDIRECTION' ? '双向同步' : '未知方向', local: readText(row['local_sync_path']), remote: readText(row['remote_sync_path']),
      status: status(row['sync_status']), error: readableLog(readText(row['error_desc'])) || (error ? '同步错误（' + error + '）' : '') };
  });
}

export function decodeCloudQuota(data: Object): CloudQuota {
  return { total: readNumber(data['quota_total']), used: readNumber(data['quota_used']) };
}

export function decodeCloudHistory(data: Object, offset: number, until: number): CloudHistoryPage {
  const rows = readArray(data['items']);
  if (rows.length > 100) { throw new NasFailure(NasErrorKind.Protocol, '云同步历史超过单次读取范围。'); }
  const actions = ['删除远端文件', '下载', '上传', '删除本地文件', '重命名远端文件'];
  const items = rows.map((value: Object, index: number): CloudHistory => {
    const row = nasRecord(value), time = readNumber(row['time']), action = readNumber(row['action']), level = readNumber(row['log_level']);
    if (time !== undefined && (time < 0 || time > until)) { throw new NasFailure(NasErrorKind.Protocol, '历史记录超出查询时间范围。'); }
    const error = readNumber(row['error_code']);
    return { key: (offset + index).toString(), time, file: readableLog(readText(row['file_name'])), path: readableLog(readText(row['path'])),
      action: action !== undefined && action >= 0 && action < actions.length ? actions[action] : action === 8 ? '合并' : action === 9 ? '合并删除' : '其他操作',
      level: level === 0 ? '信息' : level === 1 ? '警告' : level === 2 ? '错误' : '未知级别', error: error ? '错误代码：' + error : '' };
  });
  const total = readNumber(data['total']);
  return { items, received: rows.length, more: rows.length === 100 && (total === undefined || offset + rows.length < total) };
}

export function cloudHistoryWindow(items: CloudHistory[]): CloudHistory[] {
  const result: CloudHistory[] = []; let bytes = 0;
  for (const item of items) {
    const size = utf8Bytes(JSON.stringify(item));
    if (result.length >= READ_WINDOW_ROWS || bytes + size > READ_WINDOW_BYTES) { break; }
    result.push(item); bytes += size;
  }
  return result;
}
