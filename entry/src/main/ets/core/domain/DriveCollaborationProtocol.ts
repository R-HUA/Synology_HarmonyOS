import { nasRecord, NasErrorKind, NasFailure, normalizeNasOrigin } from './DsmProtocol';
import type { NasFormField } from './DsmProtocol';
import { validateDriveFileId } from './DriveProtocol';
import type { DriveEntry } from './DriveProtocol';

export const DRIVE_SHARING_API = 'SYNO.SynologyDrive.Sharing';
export const DRIVE_SHARING_VERSION = 1;
export const DRIVE_NOTIFICATIONS_API = 'SYNO.SynologyDrive.Notifications';
export const DRIVE_NOTIFICATIONS_VERSION = 1;
export const DRIVE_NOTIFICATION_LIMIT = 100;

/** 网页 get_file_link / setFileLink 取普通文件链接；can_share 和全局分享开关约束权限编辑及保护链接。 */
export function driveFileLinkAllowed(entry: DriveEntry): boolean { return entry.capabilities.canRead; }
export function copyDriveLinkEntry(entry: DriveEntry): DriveEntry { return { ...entry, capabilities: { ...entry.capabilities } }; }

/** 不更新 shared_with、公共访问权限、密码或有效期。链接访问继续由 NAS 的现有权限决定。 */
export function driveFileLinkFields(entry: DriveEntry): NasFormField[] {
  if (!driveFileLinkAllowed(entry)) { throw new NasFailure(NasErrorKind.Permission, '没有权限获取此项目的文件链接。'); }
  return [{ name: 'path', content: JSON.stringify('id:' + validateDriveFileId(entry.fileId)) }];
}

function invalidLink(): NasFailure { return new NasFailure(NasErrorKind.Protocol, '文件链接未能确认，请先在 Drive 网页核对。'); }

/** 允许 NAS 配置的自定义链接域名；禁止携带登录凭证的 URL 写入历史或剪贴板。 */
export function validateDriveFileLink(value: string): string {
  if (typeof value !== 'string' || value.length === 0 || value.length > 8192 || /[\s\u0000-\u001f\u007f-\u009f\\]/.test(value)) { throw invalidLink(); }
  const match = /^https?:\/\/([^/?#]+)(?:[/?#]|$)/i.exec(value);
  if (match === null || /[@%]/.test(match[1])) { throw invalidLink(); }
  try { normalizeNasOrigin('https://' + match[1]); } catch (_) { throw invalidLink(); }
  let decoded: string;
  try { decoded = decodeURIComponent(value); } catch (_) { throw invalidLink(); }
  if (/[\u0000-\u001f\u007f-\u009f\\]/.test(decoded)) { throw invalidLink(); }
  const sensitive = ['sid', '_sid', 'synotoken', 'syno_token', 'token', 'access_token', 'refresh_token',
    'authorization', 'auth', 'password', 'passwd', 'cookie', 'username', 'user', 'account', 'apikey',
    'api_key', 'secret', 'otp', 'csrf', 'csrf_token', 'x-syno-token'];
  const start = value.search(/[?#]/);
  if (start >= 0) {
    for (const part of value.slice(start + 1).split(/[?&#;]/)) {
      let key: string;
      try { key = decodeURIComponent(part.split('=')[0].replace(/\+/g, ' ')).toLowerCase(); } catch (_) { throw invalidLink(); }
      if (key.includes('%') || sensitive.includes(key)) { throw invalidLink(); }
    }
  }
  return value;
}

export function decodeDriveFileLink(data: Record<string, Object>): string {
  if (typeof data['url'] !== 'string') { throw invalidLink(); }
  return validateDriveFileLink(data['url'] as string);
}

export type DriveLinkState = 'unknown' | 'completed' | 'failed' | 'closed';
export interface DriveLinkRecord {
  id: string; nasOrigin: string; account: string; fileId: string; name: string; createdAt: number;
  state: DriveLinkState; url?: string;
}
export interface DriveLinkSnapshot { version: number; scope: string; records: DriveLinkRecord[]; }
export function copyDriveLink(record: DriveLinkRecord): DriveLinkRecord { return { ...record }; }
export function driveLinkStateText(state: DriveLinkState): string {
  switch (state) {
    case 'unknown': return '获取结果待确认'; case 'completed': return '已获取';
    case 'failed': return '未获取'; case 'closed': return '已核对关闭';
  }
}

export function decodeDriveLinks(text: string, scope: string, origin: string, account: string): DriveLinkRecord[] {
  const invalid = (): NasFailure => new NasFailure(NasErrorKind.Protocol, '本机文件链接记录无法读取，请保留记录后重新加载。');
  let value: Object;
  try { value = JSON.parse(text) as Object; } catch (_) { throw invalid(); }
  const root = nasRecord(value);
  if (root['version'] !== 1 || root['scope'] !== scope || !Array.isArray(root['records']) || (root['records'] as Object[]).length > 1000) { throw invalid(); }
  const ids: string[] = [];
  return (root['records'] as Object[]).map((input: Object): DriveLinkRecord => {
    const row = nasRecord(input);
    const id = row['id'];
    if (typeof id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id) || ids.includes(id) ||
      row['nasOrigin'] !== origin || row['account'] !== account || typeof row['fileId'] !== 'string' ||
      typeof row['name'] !== 'string' || (row['name'] as string).length === 0 || (row['name'] as string).length > 4096 ||
      typeof row['createdAt'] !== 'number' || !Number.isSafeInteger(row['createdAt']) || row['createdAt'] < 0 ||
      !['unknown', 'completed', 'failed', 'closed'].includes(row['state'] as string) ||
      (row['state'] === 'completed' ? typeof row['url'] !== 'string' : row['url'] !== undefined)) { throw invalid(); }
    ids.push(id);
    return { id, nasOrigin: origin, account, fileId: validateDriveFileId(row['fileId'] as string), name: row['name'] as string,
      createdAt: row['createdAt'] as number, state: row['state'] as DriveLinkState,
      url: row['url'] === undefined ? undefined : validateDriveFileLink(row['url'] as string) };
  });
}

export interface DriveNotification {
  id: string; type: string; time: number; title: string; name: string; senderName: string; known: boolean;
}
export interface DriveNotificationPage { items: DriveNotification[]; total: number; }

export function driveNotificationFields(): NasFormField[] { return [{ name: 'limit', content: DRIVE_NOTIFICATION_LIMIT.toString() }]; }
function invalidNotifications(): NasFailure { return new NasFailure(NasErrorKind.Protocol, 'Drive 通知格式无法确认，请稍后刷新或在 Drive 网页查看。'); }
function notificationText(value: Object | undefined): string {
  if (value === undefined) { return ''; }
  if (typeof value !== 'string' || value.length > 4096 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(value)) { throw invalidNotifications(); }
  return value as string;
}
function notificationTitle(type: string, content: Record<string, Object>): string {
  const folder = content['file_type'] === 'dir';
  const item = folder ? '文件夹' : content['file_type'] === 'file' ? '文件' : '项目';
  switch (type) {
    case 'drive#create': return '新建' + item;
    case 'drive#share_with_me': return '收到' + item + '共享';
    case 'drive#request': return '请求访问权限';
    case 'drive#change_owner': return '所有者已变更';
    case 'drive#comment': return '有新评论';
    case 'drive#comment_reply': return '收到评论回复';
    case 'drive#mention': return '评论中提到了你';
    case 'drive#request_office_template': return '收到文档模板请求';
    case 'drive#upload_task': case 'drive#background_task': {
      const task = type === 'drive#upload_task' ? '上传任务' : '后台任务';
      return content['success'] === true ? task + '已完成' : content['success'] === false ? task + '未全部完成' : task + '有更新';
    }
    default: return '收到 Drive 通知';
  }
}

/** 非空样本依据目标 NAS 网页 getMsgFromNotificationType/getStore/getMsgDate；实测仅有 items:[],total:0。 */
export function decodeDriveNotifications(data: Record<string, Object>): DriveNotificationPage {
  if (!Array.isArray(data['items']) || (data['items'] as Object[]).length > DRIVE_NOTIFICATION_LIMIT ||
    typeof data['total'] !== 'number' || !Number.isSafeInteger(data['total']) || data['total'] < (data['items'] as Object[]).length) { throw invalidNotifications(); }
  const ids: string[] = [];
  const items = (data['items'] as Object[]).map((input: Object): DriveNotification => {
    const row = nasRecord(input);
    const value = row['notification_id'];
    const id = typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value.toString() : notificationText(value);
    const type = notificationText(row['type']);
    if (id.length === 0 || id.length > 256 || ids.includes(id) || type.length === 0 || type.length > 256 ||
      typeof row['time'] !== 'number' || !Number.isFinite(row['time']) || row['time'] < 0 || row['time'] > 253402300799) { throw invalidNotifications(); }
    ids.push(id);
    const content: Record<string, Object> = row['content'] === undefined || row['content'] === null ? {} : nasRecord(row['content']);
    const sender: Record<string, Object> = row['sender'] === undefined || row['sender'] === null ? {} : nasRecord(row['sender']);
    const known = ['drive#create', 'drive#share_with_me', 'drive#request', 'drive#change_owner', 'drive#comment',
      'drive#comment_reply', 'drive#mention', 'drive#upload_task', 'drive#background_task', 'drive#request_office_template'].includes(type);
    let name = notificationText(content['name']);
    if (known && (type === 'drive#upload_task' || type === 'drive#background_task') && content['names'] !== undefined) {
      if (!Array.isArray(content['names']) || (content['names'] as Object[]).length > 1000) { throw invalidNotifications(); }
      name = (content['names'] as Object[]).map(notificationText).join('、');
    }
    return { id, type, time: row['time'] as number, title: notificationTitle(type, content), name,
      senderName: notificationText(sender['display_name']), known };
  });
  return { items, total: data['total'] as number };
}

export function driveCollaborationTime(seconds: number): string {
  const date = new Date(seconds * 1000);
  const pad = (value: number): string => value.toString().padStart(2, '0');
  return date.getFullYear().toString() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) + ' ' +
    pad(date.getHours()) + ':' + pad(date.getMinutes());
}
