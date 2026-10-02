import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { decodeNasControlRecord, encodeNasControlRecord, NasControlRecord } from '../../core/domain/SystemControl';

const MAX_CONTROL_RECORD_BYTES = 16 * 1024;

export class NasControlRecordStore {
  private path: string = '';

  async load(context: common.UIAbilityContext): Promise<NasControlRecord | undefined> {
    this.path = '';
    const path = context.filesDir + '/nas-control.json';
    let missing = false;
    try {
      const stat = await fileIo.stat(path);
      if (stat.size > MAX_CONTROL_RECORD_BYTES) {
        throw new NasFailure(NasErrorKind.Protocol, 'NAS 控制记录过大，请保留记录并重试读取。');
      }
    } catch (error) {
      if (error instanceof NasFailure) { throw error; }
      if ((error as BusinessError).code !== 13900002) {
        throw new NasFailure(NasErrorKind.Protocol, '无法检查 NAS 控制记录，请稍后重试。', (error as BusinessError).code);
      }
      missing = true;
    }
    let record: NasControlRecord | undefined = undefined;
    if (!missing) {
      try {
        const text = await fileIo.readText(path);
        if (new util.TextEncoder().encodeInto(text).length > MAX_CONTROL_RECORD_BYTES) {
          throw new NasFailure(NasErrorKind.Protocol, 'NAS 控制记录过大，请保留记录并重试读取。');
        }
        record = decodeNasControlRecord(text);
      } catch (error) {
        if (error instanceof NasFailure) { throw error; }
        throw new NasFailure(NasErrorKind.Protocol, '无法读取 NAS 控制记录，请保留记录并稍后重试。', (error as BusinessError).code);
      }
    }
    this.path = path;
    return record;
  }

  async save(record: NasControlRecord): Promise<void> {
    if (this.path.length === 0) {
      throw new NasFailure(NasErrorKind.Protocol, '尚未成功读取 NAS 控制记录，不能覆盖原记录。');
    }
    const bytes = new util.TextEncoder().encodeInto(encodeNasControlRecord(record));
    if (bytes.length > MAX_CONTROL_RECORD_BYTES) {
      throw new NasFailure(NasErrorKind.Protocol, 'NAS 控制记录过大，无法完整保存。');
    }
    const path = this.path;
    try {
      const file = await fileIo.open(path + '.tmp', fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        let offset = 0;
        while (offset < bytes.length) {
          const count = await fileIo.write(file.fd, bytes.slice(offset).buffer as ArrayBuffer);
          if (!Number.isSafeInteger(count) || count < 1 || count > bytes.length - offset) {
            throw new NasFailure(NasErrorKind.Protocol, '无法完整保存 NAS 控制记录。');
          }
          offset += count;
        }
        await fileIo.fsync(file.fd);
      } finally { await fileIo.close(file); }
      await fileIo.rename(path + '.tmp', path);
    } catch (error) {
      if (error instanceof NasFailure) { throw error; }
      throw new NasFailure(NasErrorKind.Protocol, '无法保存 NAS 控制记录，原记录尚未确认更新，请稍后重试。', (error as BusinessError).code);
    }
  }
}
