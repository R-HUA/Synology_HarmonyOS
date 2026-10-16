import { dsmFailure, nasInteger, nasRecord, nasString, NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';

export type DownloadTaskStatus = 'waiting' | 'downloading' | 'paused' | 'processing' | 'finished' |
  'seeding' | 'error' | 'unknown';

export interface DownloadTaskFile {
  name: string;
  totalBytes?: number;
  downloadedBytes?: number;
  priority?: string;
}

export interface DownloadTask {
  id: string;
  title: string;
  type?: string;
  rawStatus: string;
  status: DownloadTaskStatus;
  totalBytes?: number;
  downloadedBytes?: number;
  uploadedBytes?: number;
  downloadBytesPerSecond?: number;
  uploadBytesPerSecond?: number;
  destination?: string;
  createdAt?: number;
  errorMessage?: string;
  files?: DownloadTaskFile[];
}

export interface DownloadTaskPage {
  tasks: DownloadTask[];
  total: number;
  offset: number;
}

/** 做种已完成文件下载，同时仍在执行上传。 */
export function downloadMatchesFilter(task: DownloadTask, filter: string): boolean {
  return filter === 'all' || (filter === 'finished' ? ['finished', 'seeding'].includes(task.status) :
    ['waiting', 'downloading', 'processing', 'paused', 'seeding'].includes(task.status));
}

export interface DownloadCreateResult {
  state: 'accepted';
  awaitingConfirmation: true;
  taskId?: string;
}

export interface DownloadTaskActionResult {
  id: string;
  success: boolean;
  errorCode: number;
  message: string;
  errorKind?: NasErrorKind;
}

const MAX_PAGE_SIZE = 200;
const MAX_TEXT_LENGTH = 4096;
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/;

function invalidResponse(): NasFailure {
  return new NasFailure(NasErrorKind.Protocol, 'NAS 下载任务响应格式不正确，请刷新后确认结果。');
}

function responseText(input: Object | undefined, maximum: number = MAX_TEXT_LENGTH): string {
  const text = nasString(input);
  if (text.length > maximum || text.trim().length === 0 || CONTROL_CHARACTERS.test(text)) { throw invalidResponse(); }
  return text;
}

function responseId(input: Object | undefined): string {
  const id = responseText(input, 256);
  if (!/^[a-zA-Z0-9_-]+$/.test(id)) { throw invalidResponse(); }
  return id;
}

function responseQuantity(input: Object | undefined): number | undefined {
  if (input === undefined) { return undefined; }
  if (typeof input === 'string') {
    if (!/^(0|[1-9][0-9]{0,15})$/.test(input)) { throw invalidResponse(); }
    return nasInteger(Number(input));
  }
  return nasInteger(input);
}

function validDestination(destination: string): boolean {
  return typeof destination === 'string' && destination.length > 0 && destination.length <= MAX_TEXT_LENGTH &&
    !/[\\:%\u0000-\u001f\u007f-\u009f\u2028\u2029]/.test(destination) &&
    destination.split('/').every((part: string): boolean =>
      part.length > 0 && part.trim() === part && part !== '.' && part !== '..');
}

export function validateDownloadDestination(destination: string): string {
  if (!validDestination(destination)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '请选择 NAS 共享目录内的相对路径，不使用手机路径或服务器地址。');
  }
  return destination;
}

function decodedUri(uri: string): string {
  let decoded = uri;
  for (let depth = 0; depth < 4; depth++) {
    if (!/%[0-9a-fA-F]{2}/.test(decoded)) { return decoded; }
    let next: string;
    try { next = decodeURIComponent(decoded); }
    catch { throw new NasFailure(NasErrorKind.InvalidInput, '下载链接编码不正确。'); }
    if (next === decoded) { return decoded; }
    decoded = next;
  }
  if (/%[0-9a-fA-F]{2}/.test(decoded)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '下载链接包含过多层编码。');
  }
  return decoded;
}

function containsCredentials(uri: string): boolean {
  if (/[a-z][a-z0-9+.-]*:\/\/[^/?#]*@/i.test(uri)) { return true; }
  const fields = uri.split(/[?&#;]/);
  for (const field of fields) {
    const equals = field.indexOf('=');
    if (equals < 0) { continue; }
    const name = field.slice(0, equals).toLowerCase().replace(/[-_.+\s]/g, '');
    if (/(token|auth|credential|password|passwd|secret|signature|session)/.test(name) ||
      ['sid', 'key', 'apikey', 'accesskey', 'accesskeyid', 'pass', 'passkey', 'pwd', 'sig', 'jwt', 'code',
        'ticket', 'phpsessid', 'awsaccesskeyid'].includes(name) ||
      name.startsWith('xamz')) { return true; }
  }
  return /(?:^|[/?&#;])(?:token|access_token|auth|password|passkey|secret|synotoken|_sid)(?:\/|:)/i.test(uri);
}

function validIpv6Host(host: string): boolean {
  const address = host.slice(1, -1);
  if (address.indexOf('::') !== address.lastIndexOf('::')) { return false; }
  const groups = address.split(':').filter((group: string): boolean => group.length > 0);
  if (!groups.every((group: string): boolean => /^[0-9a-fA-F]{1,4}$/.test(group))) { return false; }
  return address.includes('::') ? groups.length < 8 :
    groups.length === 8 && !address.startsWith(':') && !address.endsWith(':');
}

export function validateDownloadUri(uri: string): string {
  const failure = (): NasFailure => new NasFailure(NasErrorKind.InvalidInput,
    '请输入不含账号、密码或认证令牌的 HTTP、HTTPS、FTP 或 magnet 下载链接。');
  if (typeof uri !== 'string' || uri.length === 0 || uri.length > 8192 || /[\s\\,]/.test(uri) ||
    CONTROL_CHARACTERS.test(uri) || /%(?![0-9a-fA-F]{2})/.test(uri)) { throw failure(); }
  const decoded = decodedUri(uri);
  if (CONTROL_CHARACTERS.test(decoded) || /\\/.test(decoded) || containsCredentials(decoded) ||
    /(?:^|[?=&;])(?:file|smb|javascript|data):/i.test(decoded)) { throw failure(); }
  if (/^magnet:\?/i.test(uri)) {
    const query = decoded.slice(decoded.indexOf('?') + 1);
    if (query.includes('#') || !query.split('&').some((field: string): boolean =>
      /^xt=urn:btih:(?:[0-9a-f]{40}|[a-z2-7]{32})$/i.test(field))) { throw failure(); }
    return uri;
  }
  const match = /^(https?|ftp):\/\/([^/?#]+)(?:[/?#].*)?$/i.exec(uri);
  if (match === null) { throw failure(); }
  const authority = match[2];
  if (/[@%\s]/.test(authority)) { throw failure(); }
  const host = /^(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9.-]+)(?::([0-9]{1,5}))?$/.exec(authority);
  if (host === null || host[1] === '.' || host[1] === '..' ||
    (host[1].startsWith('[') && !validIpv6Host(host[1])) ||
    (!host[1].startsWith('[') && !host[1].split('.').every((part: string): boolean =>
      /^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/.test(part))) ||
    (host[2] !== undefined && (Number(host[2]) < 1 || Number(host[2]) > 65535))) { throw failure(); }
  return uri;
}

export function validateDownloadTaskIds(ids: string[]): void {
  if (!Array.isArray(ids) || ids.length === 0 || ids.length > MAX_PAGE_SIZE ||
    new Set<string>(ids).size !== ids.length) {
    throw new NasFailure(NasErrorKind.InvalidInput, '请选择有效且不重复的 NAS 下载任务。');
  }
  for (const id of ids) {
    if (typeof id !== 'string' || !/^[a-zA-Z0-9_-]{1,256}$/.test(id)) {
      throw new NasFailure(NasErrorKind.InvalidInput, '请选择有效且不重复的 NAS 下载任务。');
    }
  }
}

export function validateDownloadPagination(offset: number, limit: number): void {
  if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 1 || limit > MAX_PAGE_SIZE) {
    throw new NasFailure(NasErrorKind.InvalidInput, '下载任务分页参数不正确。');
  }
}

export function mapDownloadTaskStatus(rawStatus: string): DownloadTaskStatus {
  switch (rawStatus) {
    case 'waiting': case 'filehosting_waiting': return 'waiting';
    case 'downloading': return 'downloading';
    case 'paused': return 'paused';
    case 'finishing': case 'hash_checking': case 'extracting': return 'processing';
    case 'finished': return 'finished';
    case 'seeding': return 'seeding';
    case 'error': return 'error';
    default: return 'unknown';
  }
}

export function downloadStationFailure(code: number): NasFailure {
  switch (code) {
    case 400: return new NasFailure(NasErrorKind.Server, 'NAS 未能接收下载任务文件。', code);
    case 401: return new NasFailure(NasErrorKind.Server, 'NAS 下载任务数量已达上限。', code);
    case 402: return new NasFailure(NasErrorKind.Permission, '当前账号没有下载目标目录的写入权限。', code);
    case 403: return new NasFailure(NasErrorKind.Server, '下载目标目录不存在，请重新选择。', code);
    case 404: return new NasFailure(NasErrorKind.Server, '下载任务不存在，请刷新列表。', code);
    case 405: return new NasFailure(NasErrorKind.Server, '当前任务状态不允许执行此操作，请刷新确认。', code);
    case 406: return new NasFailure(NasErrorKind.Server, 'NAS 尚未设置默认下载目录。', code);
    case 407: return new NasFailure(NasErrorKind.Server, 'NAS 未能设置下载目标目录。', code);
    case 408: return new NasFailure(NasErrorKind.Server, '下载任务所需的文件不存在。', code);
    default: return dsmFailure('SYNO.DownloadStation.Task', code);
  }
}

function taskErrorMessage(input: Object | undefined): string | undefined {
  if (input === undefined || input === null) { return undefined; }
  const extra = nasRecord(input);
  if (extra['error_detail'] === undefined) { return undefined; }
  const detail = responseText(extra['error_detail'], 128);
  switch (detail) {
    case 'destination_not_exist': return '下载目标目录不存在。';
    case 'destination_denied': return '当前账号没有下载目标目录的写入权限。';
    case 'disk_full': return 'NAS 下载磁盘空间不足。';
    case 'quota_reached': return 'NAS 下载存储配额已用尽。';
    case 'broken_link': return '下载链接已失效。';
    case 'timeout': return 'NAS 下载连接超时。';
    case 'torrent_duplicate': return 'NAS 已存在相同种子任务。';
    default: return 'NAS 下载任务发生错误，请在 Download Station 检查详情。';
  }
}

function taskFiles(input: Object | undefined): DownloadTaskFile[] | undefined {
  if (input === undefined) { return undefined; }
  if (!Array.isArray(input) || input.length > 10000) { throw invalidResponse(); }
  const files: DownloadTaskFile[] = [];
  for (const item of input as Object[]) {
    const row = nasRecord(item);
    const file: DownloadTaskFile = { name: responseText(row['filename']) };
    if (row['size'] !== undefined) { file.totalBytes = responseQuantity(row['size']); }
    if (row['size_downloaded'] !== undefined) { file.downloadedBytes = responseQuantity(row['size_downloaded']); }
    if (row['priority'] !== undefined) { file.priority = responseText(row['priority'], 64); }
    files.push(file);
  }
  return files;
}

export function decodeDownloadTask(input: Object, includeFiles: boolean = false): DownloadTask {
  const row = nasRecord(input);
  const rawStatus = responseText(row['status'], 64);
  if (!/^[a-zA-Z0-9_-]+$/.test(rawStatus)) { throw invalidResponse(); }
  const task: DownloadTask = {
    id: responseId(row['id']), title: responseText(row['title']), rawStatus, status: mapDownloadTaskStatus(rawStatus)
  };
  if (row['type'] !== undefined) { task.type = responseText(row['type'], 64); }
  if (row['size'] !== undefined) { task.totalBytes = responseQuantity(row['size']); }
  const errorMessage = taskErrorMessage(row['status_extra']);
  if (errorMessage !== undefined) { task.errorMessage = errorMessage; }
  if (row['additional'] === undefined) { return task; }
  const additional = nasRecord(row['additional']);
  if (additional['detail'] !== undefined) {
    const detail = nasRecord(additional['detail']);
    if (detail['destination'] !== undefined) {
      const destination = responseText(detail['destination']);
      if (!validDestination(destination)) { throw invalidResponse(); }
      task.destination = destination;
    }
    if (detail['create_time'] !== undefined && detail['create_time'] !== null) {
      const seconds = responseQuantity(detail['create_time']) as number;
      if (seconds > 8640000000000) { throw invalidResponse(); }
      task.createdAt = seconds * 1000;
    }
  }
  if (additional['transfer'] !== undefined) {
    const transfer = nasRecord(additional['transfer']);
    if (transfer['size_downloaded'] !== undefined) { task.downloadedBytes = responseQuantity(transfer['size_downloaded']); }
    if (transfer['size_uploaded'] !== undefined) { task.uploadedBytes = responseQuantity(transfer['size_uploaded']); }
    if (transfer['speed_download'] !== undefined) { task.downloadBytesPerSecond = responseQuantity(transfer['speed_download']); }
    if (transfer['speed_upload'] !== undefined) { task.uploadBytesPerSecond = responseQuantity(transfer['speed_upload']); }
  }
  if (includeFiles && additional['file'] !== undefined) { task.files = taskFiles(additional['file']); }
  return task;
}

export function decodeDownloadTaskPage(input: Object, requestedOffset: number, limit: number): DownloadTaskPage {
  const data = nasRecord(input);
  const total = nasInteger(data['total']);
  const offset = nasInteger(data['offset']);
  const rows = data['tasks'];
  if (offset !== requestedOffset || !Array.isArray(rows) || rows.length > limit ||
    rows.length > Math.max(0, total - offset)) { throw invalidResponse(); }
  const tasks: DownloadTask[] = [];
  for (const row of rows as Object[]) { tasks.push(decodeDownloadTask(row)); }
  if (new Set<string>(tasks.map((task: DownloadTask): string => task.id)).size !== tasks.length) { throw invalidResponse(); }
  return { tasks, total, offset };
}

export function decodeDownloadTaskInfo(input: Object, requestedId: string): DownloadTask {
  const rows = nasRecord(input)['tasks'];
  if (!Array.isArray(rows)) { throw invalidResponse(); }
  if (rows.length === 0) { throw downloadStationFailure(404); }
  if (rows.length !== 1) { throw invalidResponse(); }
  const task = decodeDownloadTask(rows[0] as Object, true);
  if (task.id !== requestedId) { throw invalidResponse(); }
  return task;
}

export function decodeDownloadCreateResult(input: Object): DownloadCreateResult {
  const data = nasRecord(input);
  if (data['error'] !== undefined) { throw downloadStationFailure(nasInteger(nasRecord(data['error'])['code'])); }
  if (data['success'] !== undefined) { throw invalidResponse(); }
  const result: DownloadCreateResult = { state: 'accepted', awaitingConfirmation: true };
  if (data['id'] !== undefined) { result.taskId = responseId(data['id']); }
  return result;
}

export function decodeDownloadActionResults(input: Object, requestedIds: string[]): DownloadTaskActionResult[] {
  if (!Array.isArray(input) || input.length !== requestedIds.length) { throw invalidResponse(); }
  const results = new Map<string, DownloadTaskActionResult>();
  for (const item of input as Object[]) {
    const row = nasRecord(item);
    const id = responseId(row['id']);
    const errorCode = nasInteger(row['error']);
    if (!requestedIds.includes(id) || results.has(id)) { throw invalidResponse(); }
    const result: DownloadTaskActionResult = { id, success: errorCode === 0, errorCode, message: '' };
    if (errorCode !== 0) {
      const failure = downloadStationFailure(errorCode);
      result.message = failure.message;
      result.errorKind = failure.kind;
    }
    results.set(id, result);
  }
  return requestedIds.map((id: string): DownloadTaskActionResult => results.get(id) as DownloadTaskActionResult);
}
