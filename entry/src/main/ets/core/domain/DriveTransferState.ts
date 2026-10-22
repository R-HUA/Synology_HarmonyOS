import { nasRecord, NasErrorKind, NasFailure } from './DsmProtocol';
import { validateDriveFileId } from './DriveProtocol';
import { validateNasTransferFilename } from '../network/NasTransferTransport';

export const DRIVE_TRANSFER_MAX_BYTES = 512 * 1024 * 1024;
export type DriveTransferState = 'preparing' | 'creating' | 'waiting' | 'running' | 'paused' | 'verifying' | 'completed' | 'failed' | 'cancelled' | 'unknown' | 'closed';
export type DriveTransferExecutor = 'foreground' | 'agent' | 'rcpBackground';
export interface DriveBackgroundState {
  taskId: string; attempt: number; createdAt: number; startAttempted: boolean; processed: number;
  httpStatus: number; contentType: string; contentLength: string; contentDisposition: string;
}
export interface DriveUploadSession {
  token: string; modifiedTime: number; sourceMtime: number; sourceMd5: string; started: boolean; offset: number;
}
/** 与现有任务归属一致，以规范化连接地址和账号定位 NAS；fileId 不转换为 File Station 路径。 */
export interface DriveResourceRef { nasOrigin: string; account: string; fileId: string; }
export interface DriveTransferRecord {
  id: string;
  direction: 'upload' | 'download';
  resource: DriveResourceRef;
  name: string;
  locationName: string;
  bytes?: number;
  processed?: number;
  bytesPerSecond?: number;
  state: DriveTransferState;
  errorText: string;
  background?: DriveBackgroundState;
  uploadSession?: DriveUploadSession;
  executor?: DriveTransferExecutor;
  systemCompleted?: boolean;
  verifiedMd5?: string;
  downloadVersionId?: string;
  downloadModifiedAt?: number;
}
export interface DriveTransferSnapshot { version: number; scope: string; records: DriveTransferRecord[]; }

export function copyDriveTransfer(record: DriveTransferRecord): DriveTransferRecord {
  return { id: record.id, direction: record.direction,
    resource: { nasOrigin: record.resource.nasOrigin, account: record.resource.account, fileId: record.resource.fileId },
    name: record.name, locationName: record.locationName, bytes: record.bytes, state: record.state, errorText: record.errorText,
    background: record.background === undefined ? undefined : { ...record.background },
    executor: record.executor, systemCompleted: record.systemCompleted, verifiedMd5: record.verifiedMd5,
    downloadVersionId: record.downloadVersionId, downloadModifiedAt: record.downloadModifiedAt,
    uploadSession: record.uploadSession === undefined ? undefined : { ...record.uploadSession } };
}

export function driveTransferStateText(state: DriveTransferState): string {
  switch (state) {
    case 'preparing': return '正在准备';
    case 'creating': return '正在建立任务';
    case 'waiting': return '等待执行';
    case 'running': return '正在传输';
    case 'paused': return '已暂停';
    case 'verifying': return '下载待校验';
    case 'completed': return '已完成';
    case 'failed': return '未完成';
    case 'cancelled': return '已取消';
    case 'unknown': return '结果待确认';
    case 'closed': return '已核对关闭';
  }
}

export function driveTransferFailureState(direction: 'upload' | 'download', dispatched: boolean,
  error: Object): DriveTransferState {
  if (direction === 'upload' && dispatched && !(error instanceof NasFailure &&
    [NasErrorKind.InvalidInput, NasErrorKind.Permission, NasErrorKind.Unsupported].includes(error.kind))) { return 'unknown'; }
  return error instanceof NasFailure && error.kind === NasErrorKind.Cancelled ? 'cancelled' : 'failed';
}

/** 系统任务可重新绑定；进程内 RCP 任务不能冒充仍在后台执行。 */
export function recoverDriveTransfer(record: DriveTransferRecord): DriveTransferRecord {
  const recovered = copyDriveTransfer(record);
  if (record.background !== undefined && record.executor !== 'rcpBackground' && record.state !== 'preparing') { return recovered; }
  if (record.state === 'running') {
    recovered.state = record.direction === 'upload' ? 'unknown' : 'cancelled';
    recovered.errorText = record.direction === 'upload' ? '上次上传已中断，请在 NAS 核对目标文件后关闭记录或继续原上传。' : '上次下载已中断，请重新选择文件下载。';
  } else if (record.state === 'preparing') {
    recovered.state = 'cancelled';
    recovered.errorText = '上次传输在准备时中断。';
  }
  return recovered;
}

/** 私有快照也是数据边界；解码失败不得被空历史覆盖。 */
export function decodeDriveTransfers(text: string, scope: string, origin: string, account: string): DriveTransferRecord[] {
  const invalid = (): NasFailure => new NasFailure(NasErrorKind.Protocol, 'Drive 传输记录无法读取，请保留记录并重新加载。');
  let value: Object;
  try { value = JSON.parse(text) as Object; } catch (_) { throw invalid(); }
  const root = nasRecord(value);
  if (root['version'] !== 1 || root['scope'] !== scope || !Array.isArray(root['records']) ||
    (root['records'] as Object[]).length > 1000) { throw invalid(); }
  const ids: string[] = [];
  return (root['records'] as Object[]).map((value: Object): DriveTransferRecord => {
    const row = nasRecord(value);
    const ref = nasRecord(row['resource']);
    const id = row['id'];
    const name = row['name'];
    const location = row['locationName'];
    const direction = row['direction'];
    const state = row['state'];
    const error = row['errorText'];
    const bytes = row['bytes'];
    if (typeof id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id) || ids.includes(id) ||
      typeof name !== 'string' || name.length > 4096 || typeof location !== 'string' || location.length > 4096 ||
      !['upload', 'download'].includes(direction as string) ||
      !['preparing', 'creating', 'waiting', 'running', 'paused', 'verifying', 'completed', 'failed', 'cancelled', 'unknown', 'closed'].includes(state as string) ||
      typeof error !== 'string' || error.length > 4096 ||
      ref['nasOrigin'] !== origin || ref['account'] !== account || typeof ref['fileId'] !== 'string' ||
      (bytes !== undefined && (typeof bytes !== 'number' || !Number.isSafeInteger(bytes) || bytes < 0 || bytes > DRIVE_TRANSFER_MAX_BYTES)) ||
      (direction === 'upload' && bytes === undefined) || (state === 'completed' && bytes === undefined) ||
      (direction === 'download' && (state === 'unknown' || state === 'closed'))) { throw invalid(); }
    const background = row['background'] === undefined ? undefined : nasRecord(row['background']);
    const upload = row['uploadSession'] === undefined ? undefined : nasRecord(row['uploadSession']);
    const integer = (value: Object | undefined, maximum: number): boolean => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 && value <= maximum;
    if (background !== undefined && (typeof background['taskId'] !== 'string' || !/^[0-9]{0,64}$/.test(background['taskId'] as string) ||
      !integer(background['attempt'], 100000) || background['attempt'] === 0 || !integer(background['createdAt'], Number.MAX_SAFE_INTEGER) ||
      typeof background['startAttempted'] !== 'boolean' || !integer(background['processed'], DRIVE_TRANSFER_MAX_BYTES) ||
      !integer(background['httpStatus'], 599) ||
      ['contentType', 'contentLength', 'contentDisposition'].some((key: string): boolean => typeof background[key] !== 'string' || (background[key] as string).length > 4096))) { throw invalid(); }
    if (upload !== undefined && (direction !== 'upload' || typeof upload['token'] !== 'string' || !/^[0-9a-f]{32}$/.test(upload['token'] as string) ||
      typeof upload['sourceMd5'] !== 'string' || !/^[0-9a-f]{32}$/.test(upload['sourceMd5'] as string) ||
      typeof upload['started'] !== 'boolean' || !integer(upload['offset'], bytes as number) ||
      typeof upload['modifiedTime'] !== 'number' || !Number.isFinite(upload['modifiedTime']) || (upload['modifiedTime'] as number) < 0 ||
      typeof upload['sourceMtime'] !== 'number' || !Number.isFinite(upload['sourceMtime']) || (upload['sourceMtime'] as number) < 0)) { throw invalid(); }
    if (row['executor'] !== undefined && !['foreground', 'agent', 'rcpBackground'].includes(row['executor'] as string) ||
      row['systemCompleted'] !== undefined && typeof row['systemCompleted'] !== 'boolean' ||
      row['verifiedMd5'] !== undefined && (direction !== 'download' || typeof row['verifiedMd5'] !== 'string' || !/^[0-9a-f]{32}$/.test(row['verifiedMd5'] as string)) ||
      row['downloadVersionId'] !== undefined && (typeof row['downloadVersionId'] !== 'string' || (row['downloadVersionId'] as string).length > 4096) ||
      row['downloadModifiedAt'] !== undefined && (typeof row['downloadModifiedAt'] !== 'number' ||
        !Number.isFinite(row['downloadModifiedAt']) || row['downloadModifiedAt'] < 0) ||
      row['executor'] === 'rcpBackground' && background !== undefined) { throw invalid(); }
    if (state === 'waiting' && background === undefined ||
      (state === 'creating' || state === 'paused') && background === undefined && upload === undefined ||
      state === 'verifying' && (direction !== 'download' || row['systemCompleted'] !== true || bytes === undefined)) { throw invalid(); }
    ids.push(id);
    return { id, direction: direction as 'upload' | 'download',
      resource: { nasOrigin: origin, account, fileId: validateDriveFileId(ref['fileId'] as string) },
      name: validateNasTransferFilename(name), locationName: location, bytes: bytes as number | undefined,
      state: state as DriveTransferState, errorText: error,
      background: background === undefined ? undefined : background as unknown as DriveBackgroundState,
      uploadSession: upload === undefined ? undefined : upload as unknown as DriveUploadSession,
      executor: row['executor'] as DriveTransferExecutor | undefined, systemCompleted: row['systemCompleted'] as boolean | undefined,
      verifiedMd5: row['verifiedMd5'] as string | undefined, downloadVersionId: row['downloadVersionId'] as string | undefined,
      downloadModifiedAt: row['downloadModifiedAt'] as number | undefined };
  });
}
