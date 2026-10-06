import { nasRecord, NasErrorKind, NasFailure } from './DsmProtocol';
import type { NasFormField } from './DsmProtocol';
import { decodeDriveResponse, DRIVE_FILES_API, validateDriveFileId } from './DriveProtocol';
import { NAS_TRANSFER_PREFIX_BYTES, validateNasTransferFilename } from '../network/NasTransferTransport';
import type { NasBinaryReply, NasDownloadTarget } from '../network/NasTransferTransport';

/** 传输方法与 list 分开登记：同一个 Files 接口下各方法的已核对版本并不一致。 */
export const DRIVE_TRANSFER_VERSION = 2;
export interface DriveUploadRequest {
  parentId: string;
  filename: string;
  conflict: 'version' | 'autorename';
  modifiedTime: number;
}
export interface DriveDownloadRequest {
  fileId: string;
  filename: string;
  preview: boolean;
}
export interface DriveUploadResult { uploadedBytes: number; }
export interface DriveSliceProbe { uploadedBytes: number; newlyCreated: boolean; }
export interface DriveSliceHeaders { 'X-TMP-FILE': string; 'X-TYPE-NAME': string; 'X-FILE-CHUNK-END': string; }

/** 网页 SLICEUPLOAD 固定使用 version；普通 autorename 上传不能冒充同一临时会话续传。 */
export function driveSliceHeaders(token: string, final: boolean): DriveSliceHeaders {
  if (!/^[0-9a-f]{32}$/.test(token)) { throw new NasFailure(NasErrorKind.InvalidInput, '上传临时会话无效，请核对原上传结果。'); }
  return { 'X-TMP-FILE': token, 'X-TYPE-NAME': 'SLICEUPLOAD', 'X-FILE-CHUNK-END': final ? 'true' : 'false' };
}

export function decodeDriveSliceProbe(status: number, text: string, total: number, started: boolean): DriveSliceProbe {
  const data = decodeDriveResponse(DRIVE_FILES_API, status, text);
  const offset = data['uploaded_size'];
  const newly = data['tmp_newly_created'];
  if (!Number.isSafeInteger(total) || total < 0 || typeof offset !== 'number' || !Number.isSafeInteger(offset) ||
    offset < 0 || offset > total || typeof newly !== 'boolean' || (!started && (!newly || offset !== 0))) {
    throw new NasFailure(NasErrorKind.Protocol, '无法确认原上传的进度，请先在 NAS 核对目标文件。');
  }
  // 原 token 消失后探测会创建空会话：旧请求可能已经提交，不能从头重新上传。
  if (started && newly || started && offset === total) {
    throw new NasFailure(NasErrorKind.Protocol, '原上传可能已完成或临时会话已过期，请在 NAS 核对后关闭记录。');
  }
  return { uploadedBytes: offset, newlyCreated: newly };
}

/** SDK extras 的 body 才是业务回执；处理量与 COMPLETED 均不能代替它。 */
export function driveAgentUploadReceipt(status: number, extras: Object | undefined, total: number): DriveUploadResult {
  const body = extras === undefined ? undefined : nasRecord(extras)['body'];
  if (typeof body !== 'string' || body.length > 1024 * 1024) {
    throw new NasFailure(NasErrorKind.Protocol, '上传结果未能确认，请在 NAS 核对目标文件。');
  }
  return decodeDriveUpload(status, body, total);
}

/** multipart 的标量没有 JSON 引号，区别于 P0 普通 RPC；依据原始上传抓包。 */
export function driveUploadFields(input: DriveUploadRequest): NasFormField[] {
  const parent = validateDriveFileId(input.parentId);
  const filename = validateNasTransferFilename(input.filename);
  if (!['version', 'autorename'].includes(input.conflict) || !Number.isFinite(input.modifiedTime) || input.modifiedTime < 0) {
    throw new NasFailure(NasErrorKind.InvalidInput, '上传选项无效，请重新选择。');
  }
  return [
    { name: 'path', content: 'id:' + parent + '/' + filename },
    { name: 'type', content: 'file' },
    { name: 'conflict_action', content: input.conflict },
    { name: 'modified_time', content: input.modifiedTime.toString() }
  ];
}

export function driveDownloadFields(input: DriveDownloadRequest): NasFormField[] {
  const id = validateDriveFileId(input.fileId);
  validateNasTransferFilename(input.filename);
  if (typeof input.preview !== 'boolean') { throw new NasFailure(NasErrorKind.InvalidInput, '下载选项无效。'); }
  const fields: NasFormField[] = [
    { name: 'files', content: JSON.stringify(['id:' + id]) },
    { name: 'force_download', content: input.preview ? 'false' : 'true' }
  ];
  if (input.preview) { fields.push({ name: 'is_preview', content: 'true' }); }
  else {
    fields.push({ name: 'json_error', content: 'true' });
    fields.push({ name: 'download_type', content: JSON.stringify('download') });
    fields.push({ name: 'c2_offload', content: JSON.stringify('allow') });
  }
  return fields;
}

/**
 * 抓包里成功响应有两种形状：只回上传结果，或回完整条目，两者都带 uploaded_size。
 * 因此只认可 uploaded_size，不要求每次都回条目；字节已发出不等于服务端已确认。
 */
export function decodeDriveUpload(status: number, text: string, expectedBytes: number): DriveUploadResult {
  const data = decodeDriveResponse(DRIVE_FILES_API, status, text);
  const bytes = data['uploaded_size'];
  if (typeof bytes !== 'number' || !Number.isSafeInteger(bytes) || bytes < 0 || bytes !== expectedBytes) {
    throw new NasFailure(NasErrorKind.Protocol, '上传结果未能确认，请检查目标文件后再试。');
  }
  return { uploadedBytes: bytes };
}

export function validateDriveDownload(reply: NasBinaryReply, target: NasDownloadTarget): void {
  // 不因 MIME 为 JSON 就拒绝用户的 JSON 文件；只识别明确的 DSM 错误信封。
  // 与错误信封字节完全相同的普通文件无法可靠区分，保守拒绝而不把错误当成文件交付。
  if (reply.bytes <= NAS_TRANSFER_PREFIX_BYTES) {
    let value: Object | undefined = undefined;
    try { value = JSON.parse(reply.prefixText) as Object; } catch (_) {}
    if (value !== null && value !== undefined && !Array.isArray(value) && typeof value === 'object') {
      const row = value as Record<string, Object>;
      if (row['success'] === false && row['error'] !== undefined) {
        decodeDriveResponse(DRIVE_FILES_API, reply.status, reply.prefixText);
      }
    }
  }
  if (reply.status !== 200) {
    throw new NasFailure(NasErrorKind.Http, '下载未完成，请稍后重试。', reply.status);
  }
  if (!Number.isSafeInteger(reply.bytes) || reply.bytes < 0 || reply.bytes > target.maximumBytes ||
    (target.expectedBytes !== undefined && reply.bytes !== target.expectedBytes)) {
    throw new NasFailure(NasErrorKind.Protocol, '下载文件不完整，请重试。');
  }
  if (reply.contentLength.length > 0 && (!/^\d+$/.test(reply.contentLength) ||
    !Number.isSafeInteger(Number(reply.contentLength)) || Number(reply.contentLength) !== reply.bytes)) {
    throw new NasFailure(NasErrorKind.Protocol, '下载文件不完整，请重试。');
  }
  // 返回登录页 HTML 而不是文件时，正文长度与 HTTP 状态都可能是正常的 200。
  if (!/^attachment(?:;|$)/i.test(reply.contentDisposition.trim()) &&
    /text\/html/i.test(reply.contentType) && /^\s*(?:<!doctype html|<html)/i.test(reply.prefixText)) {
    throw new NasFailure(NasErrorKind.Protocol, '未能取得下载文件，请重新登录后重试。');
  }
}
