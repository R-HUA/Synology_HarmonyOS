import { NasErrorKind, NasFailure } from './DsmProtocol';
import type { NasFormField } from './DsmProtocol';
import { DriveEntryKind, validateDriveFileId } from './DriveProtocol';
import type { DriveEntry } from './DriveProtocol';
import { validateDriveDownload } from './DriveTransferProtocol';
import type { NasBinaryReply } from '../network/NasTransferTransport';

export const DRIVE_THUMBNAIL_MAX_BYTES = 4 * 1024 * 1024;
export interface DriveThumbnailRequest { fileId: string; versionId?: string; }

/** 目标 Drive 网页列表使用 small；版本缺失时与网页一样省略，不填猜测值。 */
export function driveThumbnailFields(input: DriveThumbnailRequest): NasFormField[] {
  const fields: NasFormField[] = [
    { name: 'path', content: JSON.stringify('id:' + validateDriveFileId(input.fileId)) },
    { name: 'size', content: JSON.stringify('small') }
  ];
  if (input.versionId !== undefined) {
    return [...fields, { name: 'version_id', content: JSON.stringify(validateDriveFileId(input.versionId)) }];
  }
  return fields;
}

export function canLoadDriveThumbnail(entry: DriveEntry): boolean {
  return entry.kind === DriveEntryKind.File && entry.capabilities.canRead === true && entry.capabilities.canPreview === true &&
    /\.(?:jpg|jpeg|png|gif|bmp|webp|ico|mp4|mov|mkv|avi|m4v)$/i.test(entry.name);
}

/** 拒绝错误信封、登录页、空文件和伪装成图片的响应；完整解码还由 ImageKit 检查。 */
export function validateDriveThumbnail(reply: NasBinaryReply): void {
  validateDriveDownload(reply, { directory: '/thumbnail', maximumBytes: DRIVE_THUMBNAIL_MAX_BYTES });
  const bytes = reply.prefix;
  const jpeg = bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const png = bytes.length >= 8 && [137, 80, 78, 71, 13, 10, 26, 10].every((b: number, i: number): boolean => bytes[i] === b);
  const gif = bytes.length >= 6 && bytes[0] === 71 && bytes[1] === 73 && bytes[2] === 70 && bytes[3] === 56 &&
    (bytes[4] === 55 || bytes[4] === 57) && bytes[5] === 97;
  const webp = bytes.length >= 12 && bytes[0] === 82 && bytes[1] === 73 && bytes[2] === 70 && bytes[3] === 70 &&
    bytes[8] === 87 && bytes[9] === 69 && bytes[10] === 66 && bytes[11] === 80;
  if (reply.bytes === 0 || !/^(?:image\/(?:jpeg|png|gif|webp)|application\/octet-stream)(?:;|$)/i.test(reply.contentType.trim()) ||
    !(jpeg || png || gif || webp)) {
    throw new NasFailure(NasErrorKind.Protocol, '未能取得此文件的缩略图，请刷新后重试。');
  }
}
