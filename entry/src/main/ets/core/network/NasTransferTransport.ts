import { NasErrorKind, NasFailure } from '../domain/DsmProtocol';
import type { NasFormField, NasLoginSession } from '../domain/DsmProtocol';
import type { NasHttpReply } from './DsmRpcClient';

/** 单次传输的主动取消信号，不取消同一连接上的其他请求。 */
export class NasTransferCancellation {
  private stopped: boolean = false;
  private listeners: Set<() => void> = new Set();

  get cancelled(): boolean { return this.stopped; }

  check(): void {
    if (this.stopped) { throw new NasFailure(NasErrorKind.Cancelled, '传输已取消。'); }
  }

  subscribe(listener: () => void): () => void {
    if (this.stopped) { listener(); return (): void => {}; }
    this.listeners.add(listener);
    return (): void => { this.listeners.delete(listener); };
  }

  cancel(): void {
    if (this.stopped) { return; }
    this.stopped = true;
    const listeners = Array.from(this.listeners);
    this.listeners.clear();
    // 一个监听器失败不能阻止其余请求释放资源；执行者仍须在回调和完成时检查信号。
    for (const listener of listeners) { try { listener(); } catch (_) {} }
  }
}

export interface NasTransferProgress {
  direction: 'upload' | 'download';
  processed: number;
  total?: number;
}
export interface NasTransferControl {
  cancellation: NasTransferCancellation;
  onProgress?: (progress: NasTransferProgress) => void;
}
export interface NasUploadSource {
  /** 调用方准备好的应用私有文件，不接受远端 URL。 */
  path: string;
  bytes: number;
}
export interface NasDownloadTarget {
  /** 尚不存在的私有临时目录；执行者独占创建，避免覆盖已有文件。 */
  directory: string;
  maximumBytes: number;
  expectedBytes?: number;
}
export interface NasDownloadResult { path: string; bytes: number; }
/** 仅内核可见：最终代际检查失败时释放已经落盘的结果。 */
export interface NasDownloadReceipt extends NasDownloadResult { discard: () => void; }
export interface NasBinaryReply {
  status: number;
  contentType: string;
  contentLength: string;
  contentDisposition: string;
  bytes: number;
  prefix: Uint8Array;
  prefixText: string;
}
/** 只由内核构造，不能持久化、输出日志或交给页面。 */
export interface NasTransferRequest {
  address: string;
  method: 'GET' | 'POST';
  fields: NasFormField[];
  session: NasLoginSession;
}
export interface NasTransferTransport {
  upload(request: NasTransferRequest, source: NasUploadSource, filename: string,
    control: NasTransferControl): Promise<NasHttpReply>;
  download(request: NasTransferRequest, target: NasDownloadTarget, control: NasTransferControl,
    validate: (reply: NasBinaryReply) => void): Promise<NasDownloadReceipt>;
}

/** 下载响应只保留这么长的前缀用于识别业务错误，正文一律逐块落盘、不在内存聚合。 */
export const NAS_TRANSFER_PREFIX_BYTES = 64 * 1024;
/** 上传业务响应的聚合上限；超过即无法确认结果，不能当作成功。 */
export const NAS_TRANSFER_UPLOAD_REPLY_BYTES = 1024 * 1024;

/** 远端文件名不接受路径分隔符和控制字符，避免借文件名越出目标目录。 */
export function validateNasTransferFilename(name: string): string {
  if (name.length === 0 || name === '.' || name === '..' || /[\\/\x00-\x1f\x7f]/.test(name)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '文件名无效，请重新选择文件。');
  }
  return name;
}

/** 只接受应用私有绝对路径；路径必须由调用方保证来源，这里只校验形状。 */
function validatePrivatePath(path: string): void {
  if (!path.startsWith('/') || path.endsWith('/') || /[\x00-\x1f\x7f\\]/.test(path) ||
    path.split('/').some((part: string): boolean => part === '.' || part === '..')) {
    throw new NasFailure(NasErrorKind.InvalidInput, '无法使用此本地文件位置。');
  }
}

export function validateNasUploadSource(source: NasUploadSource): void {
  validatePrivatePath(source.path);
  if (!Number.isSafeInteger(source.bytes) || source.bytes < 0) {
    throw new NasFailure(NasErrorKind.InvalidInput, '无法确认上传文件大小，请重新选择文件。');
  }
}

export function validateNasDownloadTarget(target: NasDownloadTarget): void {
  validatePrivatePath(target.directory);
  if (!Number.isSafeInteger(target.maximumBytes) || target.maximumBytes <= 0 ||
    (target.expectedBytes !== undefined && (!Number.isSafeInteger(target.expectedBytes) ||
      target.expectedBytes < 0 || target.expectedBytes > target.maximumBytes))) {
    throw new NasFailure(NasErrorKind.InvalidInput, '文件超过此次下载的大小限制。');
  }
}
