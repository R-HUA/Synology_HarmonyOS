import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { sha256 } from '../../platform/SdkDigest';
import { writePrivateSnapshot } from '../../platform/SdkFileIO';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { decodeDriveTransfers, DriveTransferRecord, DriveTransferSnapshot } from '../../core/domain/DriveTransferState';
import { ensureTransferDirectory } from '../transfers/TransferQueueFiles';

export class DriveTransferStore {
  directory: string = '';
  private scope: string = '';
  private loaded: boolean = false;

  async load(context: common.UIAbilityContext, origin: string, account: string): Promise<DriveTransferRecord[]> {
    this.loaded = false;
    this.scope = await sha256(new util.TextEncoder().encodeInto(JSON.stringify([origin, account])));
    this.directory = context.filesDir + '/drive-transfers/' + this.scope;
    await ensureTransferDirectory(this.directory);
    const path = this.directory + '/records.json';
    let missing = false;
    try {
      if ((await fileIo.stat(path)).size > 1024 * 1024) { throw new NasFailure(NasErrorKind.Protocol, 'Drive 传输记录过大，请保留记录后重试。'); }
    } catch (error) {
      if ((error as BusinessError).code !== 13900002) { throw error as Error; }
      missing = true;
    }
    const records = missing ? [] : decodeDriveTransfers(await fileIo.readText(path), this.scope, origin, account);
    this.loaded = true;
    return records;
  }

  async save(records: DriveTransferRecord[]): Promise<void> {
    if (!this.loaded) { throw new NasFailure(NasErrorKind.Protocol, 'Drive 记录尚未读取成功，不能覆盖原记录。'); }
    const snapshot: DriveTransferSnapshot = { version: 1, scope: this.scope, records };
    const bytes = new util.TextEncoder().encodeInto(JSON.stringify(snapshot));
    if (bytes.length > 1024 * 1024) { throw new NasFailure(NasErrorKind.Protocol, 'Drive 传输记录过大，请清理已结束记录。'); }
    await writePrivateSnapshot(this.directory + '/records.json', bytes);
  }
}
