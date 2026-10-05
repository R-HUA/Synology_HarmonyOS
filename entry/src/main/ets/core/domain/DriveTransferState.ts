import { nasRecord, NasErrorKind, NasFailure } from './DsmProtocol';
import { validateDriveFileId } from './DriveProtocol';
import { validateNasTransferFilename } from '../network/NasTransferTransport';

export const DRIVE_TRANSFER_MAX_BYTES = 512 * 1024 * 1024;
export type DriveTransferState = 'preparing' | 'running' | 'completed' | 'failed' | 'cancelled' | 'unknown' | 'closed';
/** 与现有任务归属一致，以规范化连接地址和账号定位 NAS；fileId 不转换为 File Station 路径。 */
export interface DriveResourceRef { nasOrigin: string; account: string; fileId: string; }
export interface DriveTransferRecord {
  id: string;
  direction: 'upload' | 'download';
  resource: DriveResourceRef;
  name: string;
  locationName: string;
  bytes?: number;
  state: DriveTransferState;
  errorText: string;
}
export interface DriveTransferSnapshot { version: number; scope: string; records: DriveTransferRecord[]; }

export function copyDriveTransfer(record: DriveTransferRecord): DriveTransferRecord {
  return { id: record.id, direction: record.direction,
    resource: { nasOrigin: record.resource.nasOrigin, account: record.resource.account, fileId: record.resource.fileId },
    name: record.name, locationName: record.locationName, bytes: record.bytes, state: record.state, errorText: record.errorText };
}

export function driveTransferStateText(state: DriveTransferState): string {
  switch (state) {
    case 'preparing': return '正在准备';
    case 'running': return '正在传输';
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

/** 恢复只记录中断结果，不恢复网络请求；上传开始后退出可能已有远端写入。 */
export function recoverDriveTransfer(record: DriveTransferRecord): DriveTransferRecord {
  const recovered = copyDriveTransfer(record);
  if (record.state === 'running') {
    recovered.state = record.direction === 'upload' ? 'unknown' : 'cancelled';
    recovered.errorText = record.direction === 'upload' ? '上次上传已中断，请在 NAS 核对目标文件后关闭记录。' : '上次下载已中断，请重新选择文件下载。';
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
      !['preparing', 'running', 'completed', 'failed', 'cancelled', 'unknown', 'closed'].includes(state as string) ||
      typeof error !== 'string' || error.length > 4096 ||
      ref['nasOrigin'] !== origin || ref['account'] !== account || typeof ref['fileId'] !== 'string' ||
      (bytes !== undefined && (typeof bytes !== 'number' || !Number.isSafeInteger(bytes) || bytes < 0 || bytes > DRIVE_TRANSFER_MAX_BYTES)) ||
      (direction === 'upload' && bytes === undefined) || (state === 'completed' && bytes === undefined) ||
      (direction === 'download' && (state === 'unknown' || state === 'closed'))) { throw invalid(); }
    ids.push(id);
    return { id, direction: direction as 'upload' | 'download',
      resource: { nasOrigin: origin, account, fileId: validateDriveFileId(ref['fileId'] as string) },
      name: validateNasTransferFilename(name), locationName: location, bytes: bytes as number | undefined,
      state: state as DriveTransferState, errorText: error };
  });
}
