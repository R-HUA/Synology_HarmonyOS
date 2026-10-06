import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { DriveEntry, DriveEntryKind } from '../../core/domain/DriveProtocol';
import { DRIVE_TRANSFER_MAX_BYTES, DriveTransferRecord } from '../../core/domain/DriveTransferState';
import { DriveTransferAdapter } from '../../core/network/DriveTransferAdapter';
import { NasTransferCancellation } from '../../core/network/NasTransferTransport';
import { hashTransferFile } from '../transfers/TransferQueueFiles';
import { SdkTransferNetwork } from '../../platform/SdkTransferNetwork';

function validateIdentity(entry: DriveEntry, record: DriveTransferRecord): void {
  if (entry.fileId !== record.resource.fileId || entry.kind !== DriveEntryKind.File || !entry.capabilities.canRead ||
    !entry.capabilities.canDownload || entry.sizeBytes !== undefined && entry.sizeBytes !== record.bytes ||
    record.downloadVersionId !== undefined && entry.versionId !== record.downloadVersionId ||
    record.downloadModifiedAt !== undefined && entry.modifiedAt !== record.downloadModifiedAt) {
    throw new NasFailure(NasErrorKind.Protocol, '下载文件或访问权限已变化，请取消此记录并重新下载。');
  }
}

/** 仅用户明确请求后执行：用一次新的受控读取核对全部内容，不借 Drive ID 调用 File Station。 */
export async function verifyDriveDownloadedFile(adapter: DriveTransferAdapter, record: DriveTransferRecord,
  directory: string, signal: NasTransferCancellation, current: () => void): Promise<string> {
  if (record.direction !== 'download' || !record.systemCompleted || record.bytes === undefined) {
    throw new NasFailure(NasErrorKind.InvalidInput, '系统尚未确认下载结束，无法校验。');
  }
  const check = (): void => { current(); signal.check(); };
  const network = new SdkTransferNetwork();
  const verifyDirectory = directory + '/verify-' + util.generateRandomUUID();
  let owned = false;
  try {
    await network.start((): void => signal.cancel()); check();
    const before = await adapter.readEntry(record.resource.fileId); check(); validateIdentity(before, record);
    const local = await hashTransferFile(directory + '/content', record.bytes, check); check();
    const remote = await adapter.download(before, { directory: verifyDirectory, maximumBytes: DRIVE_TRANSFER_MAX_BYTES,
      expectedBytes: record.bytes, onDirectoryCreated: (): void => { owned = true; } }, { cancellation: signal, checkNetwork: (): void => network.check() });
    owned = true; check();
    const remoteMd5 = await hashTransferFile(remote.path, record.bytes, check); check();
    const after = await adapter.readEntry(record.resource.fileId); check(); validateIdentity(after, record);
    if (before.versionId !== after.versionId || before.modifiedAt !== after.modifiedAt || before.sizeBytes !== after.sizeBytes ||
      local !== remoteMd5 || local !== await hashTransferFile(directory + '/content', record.bytes, check)) {
      throw new NasFailure(NasErrorKind.Protocol, 'NAS 与已下载副本内容不一致，请取消此记录并重新下载。');
    }
    check(); return local;
  } finally {
    try {
      if (owned) {
        try { await fileIo.rmdir(verifyDirectory); }
        catch (error) { if ((error as BusinessError).code !== 13900002) { throw error as Error; } }
      }
    } finally { await network.stop(); }
  }
}
