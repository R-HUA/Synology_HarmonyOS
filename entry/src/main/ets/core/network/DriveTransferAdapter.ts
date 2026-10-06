import { NasErrorKind, NasFailure } from '../domain/DsmProtocol';
import { DRIVE_FILES_API, DriveEntryKind, decodeDriveEntry, validateDriveFileId } from '../domain/DriveProtocol';
import type { NasFormField } from '../domain/DsmProtocol';
import type { DriveEntry } from '../domain/DriveProtocol';
import { DRIVE_TRANSFER_VERSION } from '../domain/DriveTransferProtocol';
import type { DriveDownloadRequest, DriveSliceProbe, DriveUploadRequest, DriveUploadResult } from '../domain/DriveTransferProtocol';
import type { NasDownloadResult, NasDownloadTarget, NasTransferControl, NasTransferRequest, NasUploadSource } from './NasTransferTransport';

/** 与 P0 浏览端口分离；认证计划仅供传输驱动，页面不接触会话、令牌或下载 URL。 */
export interface DriveTransferKernelPort {
  supportsDriveApi(api: string, version: number): boolean;
  requestDrive?(api: string, version: number, method: string, fields: NasFormField[]): Promise<Record<string, Object>>;
  uploadDrive(input: DriveUploadRequest, source: NasUploadSource, control: NasTransferControl): Promise<DriveUploadResult>;
  downloadDrive(input: DriveDownloadRequest, target: NasDownloadTarget, control: NasTransferControl): Promise<NasDownloadResult>;
  driveUploadPlan?(input: DriveUploadRequest, token?: string): NasTransferRequest;
  driveDownloadPlan?(input: DriveDownloadRequest): NasTransferRequest;
  probeDriveUpload?(input: DriveUploadRequest, token: string, source: NasUploadSource, total: number,
    started: boolean, control: NasTransferControl): Promise<DriveSliceProbe>;
  uploadDriveSlice?(input: DriveUploadRequest, token: string, source: NasUploadSource, total: number,
    control: NasTransferControl): Promise<DriveUploadResult>;
}

export class DriveTransferAdapter {
  constructor(private kernel: DriveTransferKernelPort) {}

  async readEntry(fileId: string): Promise<DriveEntry> {
    const id = validateDriveFileId(fileId);
    if (this.kernel.requestDrive === undefined || !this.kernel.supportsDriveApi(DRIVE_FILES_API, 3)) {
      throw new NasFailure(NasErrorKind.Unsupported, '此连接无法核对 Drive 文件，请在网页查看。');
    }
    const entry = decodeDriveEntry(await this.kernel.requestDrive(DRIVE_FILES_API, 3, 'get',
      [{ name: 'path', content: JSON.stringify('id:' + id) }]));
    if (entry.fileId !== id) { throw new NasFailure(NasErrorKind.Protocol, '下载文件身份无法确认。'); }
    return entry;
  }

  available(): boolean { return this.kernel.supportsDriveApi(DRIVE_FILES_API, DRIVE_TRANSFER_VERSION); }
  backgroundAvailable(): boolean { return this.kernel.driveUploadPlan !== undefined && this.kernel.driveDownloadPlan !== undefined; }
  sliceAvailable(): boolean { return this.kernel.probeDriveUpload !== undefined && this.kernel.uploadDriveSlice !== undefined; }
  uploadPlan(input: DriveUploadRequest, token?: string): NasTransferRequest {
    if (this.kernel.driveUploadPlan === undefined) { throw new NasFailure(NasErrorKind.Unsupported, '此连接无法使用后台上传。'); }
    return this.kernel.driveUploadPlan(input, token);
  }
  downloadPlan(fileId: string, filename: string): NasTransferRequest {
    if (this.kernel.driveDownloadPlan === undefined) { throw new NasFailure(NasErrorKind.Unsupported, '此连接无法使用后台下载。'); }
    return this.kernel.driveDownloadPlan({ fileId, filename, preview: false });
  }
  probeUpload(input: DriveUploadRequest, token: string, source: NasUploadSource, total: number,
    started: boolean, control: NasTransferControl): Promise<DriveSliceProbe> {
    if (this.kernel.probeDriveUpload === undefined) { throw new NasFailure(NasErrorKind.Unsupported, '此连接无法继续原上传。'); }
    return this.kernel.probeDriveUpload(input, token, source, total, started, control);
  }
  uploadSlice(input: DriveUploadRequest, token: string, source: NasUploadSource, total: number,
    control: NasTransferControl): Promise<DriveUploadResult> {
    if (this.kernel.uploadDriveSlice === undefined) { throw new NasFailure(NasErrorKind.Unsupported, '此连接无法继续原上传。'); }
    return this.kernel.uploadDriveSlice(input, token, source, total, control);
  }

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
