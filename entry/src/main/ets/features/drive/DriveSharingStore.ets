import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { sha256 } from '../../platform/SdkDigest';
import { writePrivateSnapshot } from '../../platform/SdkFileIO';
import { NasErrorKind, NasFailure, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import { decodeDriveLinks } from '../../core/domain/DriveCollaborationProtocol';
import type { DriveLinkRecord, DriveLinkSnapshot } from '../../core/domain/DriveCollaborationProtocol';
import { ensureTransferDirectory } from '../transfers/TransferQueueFiles';

/** 文件链接可能包含访问标识，只保存于应用私有目录，按 NAS 与账号隔离。 */
export class DriveSharingStore {
  private directory: string = '';
  private scope: string = '';
  private origin: string = '';
  private account: string = '';
  private loaded: boolean = false;

  async load(context: common.UIAbilityContext, origin: string, account: string): Promise<DriveLinkRecord[]> {
    this.loaded = false;
    this.origin = normalizeNasOrigin(origin);
    this.account = account.trim();
    if (this.account.length === 0) { throw new NasFailure(NasErrorKind.InvalidInput, '缺少账号，无法读取文件链接记录。'); }
    this.scope = await sha256(new util.TextEncoder().encodeInto(JSON.stringify([this.origin, this.account])));
    this.directory = context.filesDir + '/drive-file-links/' + this.scope;
    await ensureTransferDirectory(this.directory);
    const path = this.directory + '/records.json';
    let missing = false;
    try {
      if ((await fileIo.stat(path)).size > 1024 * 1024) { throw new NasFailure(NasErrorKind.Protocol, '本机文件链接记录过大，请保留记录后重试。'); }
    } catch (error) {
      if ((error as BusinessError).code !== 13900002) { throw error as Error; }
      missing = true;
    }
    const records = missing ? [] : decodeDriveLinks(await fileIo.readText(path), this.scope, this.origin, this.account);
    this.loaded = true;
    return records;
  }

  async save(records: DriveLinkRecord[]): Promise<void> {
    if (!this.loaded) { throw new NasFailure(NasErrorKind.Protocol, '文件链接记录尚未加载，不能覆盖原记录。'); }
    const snapshot: DriveLinkSnapshot = { version: 1, scope: this.scope, records };
    const text = JSON.stringify(snapshot);
    decodeDriveLinks(text, this.scope, this.origin, this.account);
    const bytes = new util.TextEncoder().encodeInto(text);
    if (bytes.length > 1024 * 1024) { throw new NasFailure(NasErrorKind.Protocol, '本机文件链接记录过大，请清理已结束的记录。'); }
    await writePrivateSnapshot(this.directory + '/records.json', bytes);
  }
}
