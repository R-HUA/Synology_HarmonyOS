import { nasRecord, NasFailure, NasErrorKind } from '../../core/domain/DsmProtocol';
import { readArray, readText, readNumber, readableLog, utf8Bytes, READ_WINDOW_BYTES, READ_WINDOW_ROWS } from '../../core/domain/ReadOnlyProtocol';

export interface SystemLogRecord { key: string; time: string; timestamp: number | undefined; level: string; source: string; who: string; address: string; message: string; }
export interface SystemLogPage { items: SystemLogRecord[]; received: number; more: boolean; }

/** 缺少时区的服务器时间仅按原文展示，避免按手机时区猜测事件时刻。 */
export function systemLogTimestamp(time: string): number | undefined {
  if (!/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:?\d{2})$/.test(time)) { return undefined; }
  const value = Date.parse(time); return Number.isFinite(value) ? value : undefined;
}
export function decodeSystemLogs(data: Object, offset: number): SystemLogPage {
  const rows = readArray(data['items']);
  if (rows.length > 100) { throw new NasFailure(NasErrorKind.Protocol, '日志记录超过单次读取范围。'); }
  const items = rows.map((value: Object, index: number): SystemLogRecord => {
    const row = nasRecord(value), time = readText(row['time']), level = readText(row['level']).toLowerCase(), source = readText(row['logtype']);
    return { key: (offset + index).toString(), time, timestamp: systemLogTimestamp(time),
      level: level === 'information' || level === 'info' ? '信息' : level === 'warning' || level === 'warn' ? '警告' :
        level === 'error' || level === 'err' ? '错误' : '未知级别',
      source: source === 'system' ? '系统' : source === 'connection' ? '连接' : source === 'fileTransfer' ? '文件传输' : '其他来源',
      who: readText(row['who']), address: readText(row['ip']), message: readableLog(readText(row['descr'])) };
  });
  const total = readNumber(data['total']);
  return { items, received: rows.length, more: rows.length === 100 && (total === undefined || offset + rows.length < total) };
}
export function systemLogWindow(items: SystemLogRecord[]): SystemLogRecord[] {
  const result: SystemLogRecord[] = []; let bytes = 0;
  for (const item of items) {
    const size = utf8Bytes(JSON.stringify(item));
    if (result.length >= READ_WINDOW_ROWS || bytes + size > READ_WINDOW_BYTES) { break; }
    result.push(item); bytes += size;
  }
  return result;
}
export function filterSystemLogs(items: SystemLogRecord[], query: string, level: string, source: string, hours: number, now: number): SystemLogRecord[] {
  const keyword = query.trim().toLowerCase();
  return items.filter((item: SystemLogRecord): boolean => (level === '全部' || item.level === level) &&
    (source === '全部' || item.source === source) && (hours === 0 || item.timestamp !== undefined && item.timestamp >= now - hours * 3600000 && item.timestamp <= now) &&
    (item.message + '\n' + item.who + '\n' + item.address).toLowerCase().includes(keyword));
}
export function systemLogCopy(item: SystemLogRecord): string {
  return [item.time || '未提供时间', item.source + ' · ' + item.level, item.who, item.address, item.message].filter((value: string): boolean => value.length > 0).join('\n');
}
