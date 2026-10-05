import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { sha256 } from '../../platform/SdkDigest';
import { writePrivateSnapshot } from '../../platform/SdkFileIO';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { decodeDriveActions } from '../../core/domain/DriveActionState';
import type { DriveActionRecord, DriveActionSnapshot } from '../../core/domain/DriveActionState';
import { ensureTransferDirectory } from '../transfers/TransferQueueFiles';

/** 与传输历史分开存储，写入仍复用平台原子快照。 */
export class DriveActionStore {
  private directory: string = '';
  private scope: string = '';
  private origin: string = '';
  private account: string = '';
  private loaded: boolean = false;

  async load(context: common.UIAbilityContext, origin: string, account: string): Promise<DriveActionRecord[]> {
    this.loaded = false;
    this.scope = await sha256(new util.TextEncoder().encodeInto(JSON.stringify([origin, account])));
    this.origin = origin;
    this.account = account;
    this.directory = context.filesDir + '/drive-actions/' + this.scope;
    await ensureTransferDirectory(this.directory);
    const path = this.directory + '/records.json';
    let missing = false;
    try {
      if ((await fileIo.stat(path)).size > 1024 * 1024) { throw new NasFailure(NasErrorKind.Protocol, 'Drive 操作记录过大，请保留记录后重试。'); }
    } catch (error) {
      if ((error as BusinessError).code !== 13900002) { throw error as Error; }
      missing = true;
    }
    const records = missing ? [] : decodeDriveActions(await fileIo.readText(path), this.scope, origin, account);
    this.loaded = true;
    return records;
  }

  async save(records: DriveActionRecord[]): Promise<void> {
    if (!this.loaded) { throw new NasFailure(NasErrorKind.Protocol, 'Drive 操作记录尚未加载，不能覆盖原记录。'); }
    const snapshot: DriveActionSnapshot = { version: 1, scope: this.scope, records };
    const text = JSON.stringify(snapshot);
    decodeDriveActions(text, this.scope, this.origin, this.account);
    const bytes = new util.TextEncoder().encodeInto(text);
    if (bytes.length > 1024 * 1024) { throw new NasFailure(NasErrorKind.Protocol, 'Drive 操作记录过大，请清理已结束的记录。'); }
    await writePrivateSnapshot(this.directory + '/records.json', bytes);
  }
}
