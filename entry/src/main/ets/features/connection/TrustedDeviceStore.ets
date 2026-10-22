import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { nasRecord, nasString } from '../../core/domain/DsmProtocol';

interface TrustedDevice { origin: string; account: string; deviceId: string; }

/** 设备凭证与会话一样存入系统资产库，仅匹配原服务器和账号时取用。 */
export class TrustedDeviceStore {
  private query(): asset.AssetMap {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto('nas-workbench.trusted-device'));
    return query;
  }

  async load(origin: string, account: string): Promise<string> {
    const query = this.query(); query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    let records: asset.AssetMap[];
    try { records = await asset.query(query); }
    catch (error) {
      if ((error as BusinessError).code === asset.ErrorCode.NOT_FOUND) { return ''; }
      throw new Error('无法读取可信设备凭证，请解锁设备后重试。');
    }
    if (records.length !== 1 || !(records[0].get(asset.Tag.SECRET) instanceof Uint8Array)) { throw new Error('可信设备凭证格式无效。'); }
    const secret = records[0].get(asset.Tag.SECRET) as Uint8Array;
    try {
      const row = nasRecord(JSON.parse(util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(secret)) as Object);
      return row['origin'] === origin && row['account'] === account ? nasString(row['deviceId']) : '';
    } finally { secret.fill(0); }
  }

  async save(origin: string, account: string, deviceId: string): Promise<void> {
    const value: TrustedDevice = { origin, account, deviceId };
    const secret = new util.TextEncoder().encodeInto(JSON.stringify(value));
    const attributes = this.query();
    attributes.set(asset.Tag.SECRET, secret);
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attributes.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try { await asset.add(attributes); }
    catch { throw new Error('无法保存可信设备凭证，请重试。'); }
    finally { secret.fill(0); }
  }
}
