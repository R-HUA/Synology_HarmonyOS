import { NasErrorKind, NasFailure } from './DsmProtocol';
import { DriveEntryKind } from './DriveProtocol';
import type { DriveEntry } from './DriveProtocol';

export const DRIVE_ORIGINAL_MAX_BYTES = 128 * 1024 * 1024;
export const DRIVE_ORIGINAL_DECODE_PIXELS = 8 * 1024 * 1024;
export interface DriveOriginalSize { width: number; height: number; }

/** 缩略图只要求读取与预览权限；原文件另行检查下载权限。 */
export function canPreviewDriveMedia(entry: DriveEntry): boolean {
  return entry.kind === DriveEntryKind.File && entry.capabilities.canRead && entry.capabilities.canPreview &&
    /\.(?:jpe?g|png|gif|webp|bmp|heic|heif|tiff?|dng|avif|avis|mp4|mov|mkv|avi|m4v)$/i.test(entry.name);
}

/** 原图通过文件下载取得，不能用预览权限绕过禁止下载的限制。 */
export function canPreviewDriveOriginal(entry: DriveEntry): boolean {
  return entry.kind === DriveEntryKind.File && entry.capabilities.canRead && entry.capabilities.canDownload &&
    entry.capabilities.canPreview && /\.(?:jpe?g|png|gif|webp|bmp|heic|heif|tiff?|dng|avif|avis)$/i.test(entry.name);
}

export function validateDriveOriginal(entry: DriveEntry): void {
  if (!canPreviewDriveOriginal(entry)) { throw new NasFailure(NasErrorKind.Permission, '此文件无法查看原图。'); }
  if (entry.sizeBytes !== undefined && (entry.sizeBytes <= 0 || entry.sizeBytes > DRIVE_ORIGINAL_MAX_BYTES)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '此图片超过 128 MB 或内容为空，请下载后查看。');
  }
}

export function driveOriginalUnchanged(before: DriveEntry, after: DriveEntry, original: boolean = true): boolean {
  return before.fileId === after.fileId && before.sizeBytes === after.sizeBytes && before.versionId === after.versionId &&
    before.modifiedAt === after.modifiedAt && (original ? canPreviewDriveOriginal(after) : canPreviewDriveMedia(after));
}

/** 文件保持完整，显示时按窗口与缩放需要解码；限制的是 PixelMap，不是原文件分辨率。 */
export function driveOriginalDecodeSize(width: number, height: number, viewWidth: number, viewHeight: number,
  zoom: number = 1): DriveOriginalSize {
  if (![width, height, viewWidth, viewHeight, zoom].every((value: number): boolean => Number.isFinite(value) && value > 0) ||
    !Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width * height > 200 * 1000 * 1000) {
    throw new NasFailure(NasErrorKind.Unsupported, '图片尺寸过大或无法识别，请下载后查看。');
  }
  const ratio = Math.min(1, Math.min(viewWidth / width, viewHeight / height) * Math.min(4, zoom),
    Math.sqrt(DRIVE_ORIGINAL_DECODE_PIXELS / (width * height)));
  return { width: Math.max(1, Math.floor(width * ratio)), height: Math.max(1, Math.floor(height * ratio)) };
}
