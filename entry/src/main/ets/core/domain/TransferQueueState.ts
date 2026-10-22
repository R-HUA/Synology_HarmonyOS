import { decodeNasResponse, dsmFailure, NasErrorKind, NasFailure, nasInteger, nasRecord, nasString,
  validateLogicalPath } from './DsmProtocol';

export type TransferDirection = 'upload' | 'download';
export type TransferSource = 'fileUpload' | 'shareUpload' | 'photoUpload' | 'photoBackup' | 'download' | 'legacy';
export type TransferState = 'preparing' | 'queued' | 'creating' | 'running' | 'waiting' | 'paused' |
  'verifying' | 'completed' | 'failed' | 'unknown' | 'cancelled' | 'closed' | 'clearing';

/** 普通记录只保存业务状态；URL、Cookie、SID 与系统配置不进入记录。 */
export interface TransferQueueRecord {
  id: string;
  direction: TransferDirection;
  source: TransferSource;
  name: string;
  remotePath: string;
  bytes: number;
  localName: string;
  localReady: boolean;
  state: TransferState;
  taskId: string;
  attempts: number;
  startAttempted: boolean;
  uploadAccepted: boolean;
  httpStatus: number;
  contentType: string;
  attachmentName: string;
  processed: number;
  createdAt: number;
  updatedAt: number;
  errorText: string;
  contentVerified: boolean;
  localMd5: string;
  checksumTaskId: string;
  systemCompleted: boolean;
  protocol?: 'photos';
  photoFolderId?: number;
  photoModifiedAt?: number;
  photoWifiOnly?: boolean;
  backupKey?: string;
}

export interface TransferQueueItem {
  bytesPerSecond?: number;
  canPause?: boolean;
  canResume?: boolean;
  id: string;
  direction: TransferDirection;
  source: TransferSource;
  name: string;
  remotePath: string;
  bytes: number;
  processed: number;
  state: TransferState;
  stateText: string;
  errorText: string;
  canCancel: boolean;
  canRetry: boolean;
  canExport: boolean;
  canClose: boolean;
  canRemove: boolean;
  backupKey?: string;
}

export interface TransferQueueSnapshot { version: number; scope: string; records: TransferQueueRecord[]; }
export interface TransferChecksumStatus { finished: boolean; md5: string; }

export function validateChecksumTaskId(id: string): string {
  if (!/^[A-Za-z0-9_-]{1,256}$/.test(id)) {
    throw new NasFailure(NasErrorKind.Protocol, '文件校验任务标识不正确。');
  }
  return id;
}

export function decodeTransferChecksumTask(data: Record<string, Object>): string {
  return validateChecksumTaskId(nasString(data['taskid']));
}

export function decodeTransferChecksumStatus(data: Record<string, Object>): TransferChecksumStatus {
  if (data['error'] !== undefined) { throw dsmFailure('SYNO.FileStation.MD5', nasInteger(nasRecord(data['error'])['code'])); }
  if (typeof data['finished'] !== 'boolean' || data['finished'] === true &&
    (typeof data['md5'] !== 'string' || !/^[0-9a-f]{32}$/i.test(data['md5'] as string))) {
    throw new NasFailure(NasErrorKind.Protocol, 'NAS 文件校验响应不符合预期。');
  }
  return { finished: data['finished'] === true, md5: data['finished'] === true ? (data['md5'] as string).toLowerCase() : '' };
}

function invalidRecord(): NasFailure {
  return new NasFailure(NasErrorKind.Protocol, '传输记录损坏，无法安全恢复任务。');
}

export function validateTransferName(name: string): string {
  if (name.length === 0 || name === '.' || name === '..' || /[\\/\u0000-\u001f\u007f]/.test(name)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '文件名称无效，请重新选择文件。');
  }
  return name;
}

export function transferRemotePath(directory: string, name: string): string {
  validateLogicalPath(directory);
  validateTransferName(name);
  return validateLogicalPath(directory + (directory.endsWith('/') ? '' : '/') + name);
}

export function transferCanRetry(record: TransferQueueRecord): boolean {
  if (!record.localReady && record.direction === 'upload') { return false; }
  if (record.direction === 'upload' && record.startAttempted && record.state !== 'failed') { return false; }
  return ['failed', 'cancelled', 'unknown'].includes(record.state);
}

/** 未确认的上传须由用户核对后关闭，不能随着普通历史清理丢失。 */
export function transferCanRemove(record: TransferQueueRecord): boolean {
  return ['completed', 'failed', 'cancelled', 'closed', 'clearing'].includes(record.state) ||
    record.direction === 'download' && record.state === 'unknown';
}

export function transferItem(record: TransferQueueRecord): TransferQueueItem {
  let text: string;
  switch (record.state) {
    case 'preparing': text = '正在准备文件'; break;
    case 'queued': text = '等待传输'; break;
    case 'creating': text = '正在建立任务'; break;
    case 'running': text = record.direction === 'upload' ? '正在上传' : '正在下载'; break;
    case 'waiting': text = '等待网络或系统调度'; break;
    case 'paused': text = '已暂停'; break;
    case 'verifying': text = '正在校验'; break;
    case 'completed': text = record.contentVerified ? (record.direction === 'upload' ? '上传内容已核验' : '下载内容已核验') :
      record.direction === 'upload' ? '上传已确认' : '下载已校验'; break;
    case 'failed': text = '传输失败'; break;
    case 'unknown': text = '结果待确认'; break;
    case 'cancelled': text = '已取消'; break;
    case 'closed': text = '已核对并关闭'; break;
    case 'clearing': text = '正在清理记录'; break;
  }
  return { id: record.id, direction: record.direction, source: record.source, name: record.name, remotePath: record.remotePath,
    bytes: record.bytes, processed: record.processed, state: record.state, stateText: text,
    errorText: record.errorText, canCancel: !['completed', 'cancelled', 'failed', 'unknown', 'closed', 'clearing'].includes(record.state),
    canRetry: transferCanRetry(record), canExport: record.direction === 'download' && record.state === 'completed',
    canClose: record.direction === 'upload' && record.state === 'unknown', canRemove: transferCanRemove(record), backupKey: record.backupKey };
}

export function decodeTransferQueue(text: string, scope: string): TransferQueueRecord[] {
  const root = nasRecord(JSON.parse(text) as Object);
  if (![1, 2].includes(root['version'] as number) || root['scope'] !== scope || !Array.isArray(root['records'])) { throw invalidRecord(); }
  const rows = root['records'] as Object[];
  if (rows.length > 1000) { throw invalidRecord(); }
  const ids: string[] = [];
  return rows.map((value: Object): TransferQueueRecord => {
    const row = nasRecord(value);
    const id = nasString(row['id']);
    const direction = row['direction'];
    const source = root['version'] === 1 ? 'legacy' : row['source'];
    const state = row['state'];
    const localName = nasString(row['localName']);
    const attempts = nasInteger(row['attempts']);
    const taskId = row['taskId'];
    const errorText = row['errorText'];
    const contentType = row['contentType'];
    const attachmentName = row['attachmentName'];
    const contentVerified = row['contentVerified'] === undefined ? false : row['contentVerified'];
    const localMd5 = row['localMd5'] === undefined ? '' : row['localMd5'];
    const checksumTaskId = row['checksumTaskId'] === undefined ? '' : row['checksumTaskId'];
    const systemCompleted = row['systemCompleted'] === undefined ? false : row['systemCompleted'];
    if (!/^[0-9a-f-]{36}$/.test(id) || ids.includes(id) ||
      !['upload', 'download'].includes(direction as string) ||
      !['fileUpload', 'shareUpload', 'photoUpload', 'photoBackup', 'download', 'legacy'].includes(source as string) ||
      direction === 'download' && source !== 'download' && source !== 'legacy' || direction === 'upload' && source === 'download' ||
      !['preparing', 'queued', 'creating', 'running', 'waiting', 'paused', 'verifying', 'completed', 'failed', 'unknown', 'cancelled', 'closed', 'clearing'].includes(state as string) ||
      localName !== id + '-' + attempts.toString() + '.bin' || attempts < 1 ||
      typeof taskId !== 'string' || (taskId.length > 0 && !/^[0-9]+$/.test(taskId)) ||
      typeof errorText !== 'string' || errorText.length > 1024 ||
      typeof contentType !== 'string' || contentType.length > 256 ||
      typeof attachmentName !== 'string' || attachmentName.length > 1024 ||
      typeof row['localReady'] !== 'boolean' || typeof row['startAttempted'] !== 'boolean' ||
      typeof row['uploadAccepted'] !== 'boolean' || typeof contentVerified !== 'boolean' || typeof systemCompleted !== 'boolean' ||
      typeof localMd5 !== 'string' || localMd5.length > 0 && !/^[0-9a-f]{32}$/.test(localMd5) ||
      typeof checksumTaskId !== 'string' || checksumTaskId.length > 0 && !/^[A-Za-z0-9_-]{1,256}$/.test(checksumTaskId) ||
      contentVerified === true && (localMd5.length === 0 || systemCompleted !== true)) { throw invalidRecord(); }
    ids.push(id);
    const httpStatus = nasInteger(row['httpStatus']);
    if (httpStatus !== 0 && (httpStatus < 100 || httpStatus > 599)) { throw invalidRecord(); }
    if (row['protocol'] !== undefined && (row['protocol'] !== 'photos' || direction !== 'upload' ||
      !Number.isSafeInteger(row['photoFolderId']) || (row['photoFolderId'] as number) < 0 ||
      !Number.isSafeInteger(row['photoModifiedAt']) || (row['photoModifiedAt'] as number) <= 0 || typeof row['photoWifiOnly'] !== 'boolean')) { throw invalidRecord(); }
    if (row['backupKey'] !== undefined && (typeof row['backupKey'] !== 'string' || source !== 'photoBackup' || row['protocol'] !== 'photos')) { throw invalidRecord(); }
    return { id: id, direction: direction as TransferDirection, source: source as TransferSource, name: validateTransferName(nasString(row['name'])),
      remotePath: validateLogicalPath(nasString(row['remotePath'])), bytes: nasInteger(row['bytes']),
      localName: localName, localReady: row['localReady'] as boolean, state: state as TransferState,
      taskId: taskId as string, attempts: attempts, startAttempted: row['startAttempted'] as boolean,
      uploadAccepted: row['uploadAccepted'] as boolean, httpStatus: httpStatus, contentType: contentType as string,
      attachmentName: attachmentName as string,
      processed: nasInteger(row['processed']), createdAt: nasInteger(row['createdAt']),
      updatedAt: nasInteger(row['updatedAt']), errorText: errorText as string, contentVerified: contentVerified as boolean,
      localMd5: localMd5 as string, checksumTaskId: checksumTaskId as string, systemCompleted: systemCompleted as boolean,
      protocol: row['protocol'] as 'photos' | undefined, photoFolderId: row['photoFolderId'] as number | undefined,
      photoModifiedAt: row['photoModifiedAt'] as number | undefined, photoWifiOnly: row['photoWifiOnly'] as boolean | undefined,
      backupKey: row['backupKey'] as string | undefined };
  });
}

/** 缺少响应不能以系统 completed 或同名同大小文件推断上传成功。 */
export function acceptTransferUpload(status: number, body: string, photos: boolean = false): void {
  if (status !== 200) { throw new NasFailure(NasErrorKind.Http, '上传 HTTP 响应未成功，结果待确认。', status); }
  decodeNasResponse(photos ? 'SYNO.Foto.Upload.Item' : 'SYNO.FileStation.Upload', status, body);
}

/** RFC 5987 文件名优先；返回空串表示未取得可核对的附件文件名。 */
export function transferAttachmentName(disposition: string): string {
  if (!/^\s*attachment(?:\s*;|\s*$)/i.test(disposition)) { return ''; }
  const extended = /(?:^|;)\s*filename\*\s*=\s*UTF-8'[^']*'([^;]*)/i.exec(disposition);
  if (extended !== null) {
    try { return validateTransferName(decodeURIComponent(extended[1].trim())); }
    catch (_) { return ''; }
  }
  const quoted = /(?:^|;)\s*filename\s*=\s*"((?:[^"\\]|\\.)*)"/i.exec(disposition);
  const plain = /(?:^|;)\s*filename\s*=\s*([^;\s]+)/i.exec(disposition);
  const name = quoted !== null ? quoted[1].replace(/\\(.)/g, '$1') : plain !== null ? plain[1] : '';
  if (name.length === 0) { return ''; }
  try { return validateTransferName(name); } catch (_) { return ''; }
}

/** 附件身份经响应头确认时，HTML 和 DSM 形状 JSON 都可以是用户的真实文件。 */
export function checkTransferDownload(status: number, expected: number, actual: number,
  contentType: string, prefix: string, wholeFile: boolean, attachmentName: string = '', expectedName: string = ''): void {
  if (status !== 200) { throw new NasFailure(NasErrorKind.Http, '缺少成功的下载 HTTP 响应，请重新下载。', status); }
  if (actual !== expected) { throw new NasFailure(NasErrorKind.Protocol, '下载文件大小与 NAS 不符，请重新下载。'); }
  if (attachmentName.length > 0) {
    if (attachmentName !== expectedName) { throw new NasFailure(NasErrorKind.Protocol, '下载响应的文件名称与 NAS 目标不符。'); }
    return;
  }
  if (/text\/html|application\/xhtml\+xml/i.test(contentType) || /^\s*(?:<!doctype\s+html|<html\b)/i.test(prefix)) {
    throw new NasFailure(NasErrorKind.Protocol, 'NAS 返回了网页，未取得可用的下载文件。');
  }
  if (!wholeFile || !/^\s*\{/.test(prefix)) { return; }
  let value: Object;
  try { value = JSON.parse(prefix) as Object; } catch (_) { return; }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) { return; }
  const row = value as Record<string, Object>;
  if (row['success'] === false && row['error'] !== undefined) {
    decodeNasResponse('SYNO.FileStation.Download', status, prefix);
  }
}
