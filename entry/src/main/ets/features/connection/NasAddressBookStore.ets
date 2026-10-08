import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { sha256 } from '../../platform/SdkDigest';
import { writePrivateSnapshot } from '../../platform/SdkFileIO';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import {
  decodeConnectionAddressBook, decodeNasDeviceIdentity, encodeConnectionAddressBook,
  NasConnectionAddress, NasConnectionDeviceIdentity
} from '../../core/domain/ConnectionRoutes';

const MAX_ADDRESS_BOOK_BYTES = 64 * 1024;

export class NasAddressBookStore {
  corrupt: boolean = false;
  private path: string = '';
  private legacy: string | undefined = undefined;

  async load(context: common.UIAbilityContext): Promise<NasConnectionAddress[]> {
    this.path = '';
    this.legacy = undefined;
    this.corrupt = false;
    const path = context.filesDir + '/nas-addresses.json';
    let missing = false;
    try {
      const stat = await fileIo.stat(path);
      if (stat.size > MAX_ADDRESS_BOOK_BYTES) {
        throw new NasFailure(NasErrorKind.Protocol, '连接地址记录过大，请保留记录并重试读取。');
      }
    } catch (error) {
      if (error instanceof NasFailure) { throw error; }
      if ((error as BusinessError).code !== 13900002) {
        throw new NasFailure(NasErrorKind.Protocol, '无法检查连接地址记录，请稍后重试。', (error as BusinessError).code);
      }
      missing = true;
    }
    let addresses: NasConnectionAddress[] = [];
    if (!missing) {
      try {
        const text = await fileIo.readText(path);
        if (new util.TextEncoder().encodeInto(text).length > MAX_ADDRESS_BOOK_BYTES) {
          throw new NasFailure(NasErrorKind.Protocol, '连接地址记录过大，请保留记录并重试读取。');
        }
        try { addresses = decodeConnectionAddressBook(text); }
        catch (error) { this.corrupt = true; throw error as Error; }
        if ((JSON.parse(text) as Record<string, Object>)['version'] === 1) { this.legacy = text; }
      } catch (error) {
        if (error instanceof NasFailure) { throw error; }
        throw new NasFailure(NasErrorKind.Protocol, '无法读取连接地址记录，请保留记录并稍后重试。', (error as BusinessError).code);
      }
    }
    this.path = path;
    return addresses;
  }

  async save(addresses: NasConnectionAddress[]): Promise<void> {
    if (this.path.length === 0) {
      throw new NasFailure(NasErrorKind.Protocol, '尚未成功读取连接地址记录，不能覆盖原记录。');
    }
    const bytes = new util.TextEncoder().encodeInto(encodeConnectionAddressBook(addresses));
    if (bytes.length > MAX_ADDRESS_BOOK_BYTES) {
      throw new NasFailure(NasErrorKind.Protocol, '连接地址记录过大，无法完整保存。');
    }
    const path = this.path;
    try {
      if (this.legacy !== undefined) {
        await writePrivateSnapshot(path + '.v1.backup', new util.TextEncoder().encodeInto(this.legacy));
      }
      const file = await fileIo.open(path + '.tmp', fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        let offset = 0;
        while (offset < bytes.length) {
          const count = await fileIo.write(file.fd, bytes.slice(offset).buffer as ArrayBuffer);
          if (!Number.isSafeInteger(count) || count < 1 || count > bytes.length - offset) {
            throw new NasFailure(NasErrorKind.Protocol, '无法完整保存连接地址记录。');
          }
          offset += count;
        }
        await fileIo.fsync(file.fd);
      } finally { await fileIo.close(file); }
      await fileIo.rename(path + '.tmp', path);
      this.legacy = undefined;
    } catch (error) {
      if (error instanceof NasFailure) { throw error; }
      throw new NasFailure(NasErrorKind.Protocol, '无法保存连接地址记录，原记录尚未确认更新，请稍后重试。', (error as BusinessError).code);
    }
  }

  /** 只有已确认损坏的文件可以隔离，不以重建掩盖读写权限错误。 */
  async quarantine(context: common.UIAbilityContext): Promise<void> {
    if (!this.corrupt) { throw new NasFailure(NasErrorKind.InvalidInput, '连接配置未确认损坏，请先重试读取。'); }
    const path = context.filesDir + '/nas-addresses.json';
    try { await fileIo.rename(path, path + '.corrupt-' + util.generateRandomUUID(true)); }
    catch (error) { throw new NasFailure(NasErrorKind.Protocol, '无法保留损坏的连接配置，未重建地址簿。', (error as BusinessError).code); }
    this.corrupt = false;
  }
}

export async function nasDeviceFingerprint(identity: NasConnectionDeviceIdentity): Promise<string> {
  const verified = decodeNasDeviceIdentity(identity as Object as Record<string, Object>);
  try {
    return await sha256(new util.TextEncoder().encodeInto(JSON.stringify([verified.model, verified.serial])));
  } catch (error) {
    if (error instanceof NasFailure && error.kind === NasErrorKind.Unsupported) { throw error; }
    throw new NasFailure(NasErrorKind.Protocol, '无法计算设备指纹，暂不能登记或核验设备身份。', (error as BusinessError).code);
  }
}
