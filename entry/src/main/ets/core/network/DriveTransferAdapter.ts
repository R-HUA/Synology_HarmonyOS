import { NasErrorKind, NasFailure } from '../domain/DsmProtocol';
import { DRIVE_FILES_API, DriveEntryKind } from '../domain/DriveProtocol';
import type { DriveEntry } from '../domain/DriveProtocol';
import { DRIVE_TRANSFER_VERSION } from '../domain/DriveTransferProtocol';
import type { DriveDownloadRequest, DriveUploadRequest, DriveUploadResult } from '../domain/DriveTransferProtocol';
import type { NasDownloadResult, NasDownloadTarget, NasTransferControl, NasUploadSource } from './NasTransferTransport';

/** 与 P0 浏览端口分离，调用方从不接触会话、令牌或下载 URL。 */
export interface DriveTransferKernelPort {
  supportsDriveApi(api: string, version: number): boolean;
  uploadDrive(input: DriveUploadRequest, source: NasUploadSource, control: NasTransferControl): Promise<DriveUploadResult>;
  downloadDrive(input: DriveDownloadRequest, target: NasDownloadTarget, control: NasTransferControl): Promise<NasDownloadResult>;
}

export class DriveTransferAdapter {
  constructor(private kernel: DriveTransferKernelPort) {}

  available(): boolean { return this.kernel.supportsDriveApi(DRIVE_FILES_API, DRIVE_TRANSFER_VERSION); }

  upload(parent: DriveEntry, filename: string, conflict: 'version' | 'autorename', modifiedTime: number,
    source: NasUploadSource, control: NasTransferControl): Promise<DriveUploadResult> {
    if (parent.kind !== DriveEntryKind.Folder || !parent.capabilities.canWrite) {
      throw new NasFailure(NasErrorKind.Permission, '无法向此文件夹上传文件。');
    }
    return this.kernel.uploadDrive({ parentId: parent.fileId, filename, conflict, modifiedTime }, source, control);
  }

  download(entry: DriveEntry, target: NasDownloadTarget, control: NasTransferControl,
    preview: boolean = false): Promise<NasDownloadResult> {
    if (entry.kind !== DriveEntryKind.File || !entry.capabilities.canRead ||
      (preview ? !entry.capabilities.canPreview : !entry.capabilities.canDownload)) {
      throw new NasFailure(NasErrorKind.Permission, preview ? '无法预览此文件。' : '无法下载此文件。');
    }
    return this.kernel.downloadDrive({ fileId: entry.fileId, filename: entry.name, preview }, target, control);
  }
}
