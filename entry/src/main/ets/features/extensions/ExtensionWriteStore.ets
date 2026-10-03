import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { sha256 } from '../../platform/SdkDigest';
import { writePrivateSnapshot } from '../../platform/SdkFileIO';
import { NasErrorKind, NasFailure, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import { decodeExtensionWrites, ExtensionPendingWrite, ExtensionWriteSnapshot } from '../../core/domain/ExtensionWriteState';

export class ExtensionWriteStore {
  private path: string = '';
  private scope: string = '';

  async load(context: common.UIAbilityContext, origin: string, account: string): Promise<ExtensionPendingWrite[]> {
    this.path = '';
    this.scope = '';
    if (account.trim().length === 0) { throw new NasFailure(NasErrorKind.InvalidInput, '缺少账号，无法读取操作记录。'); }
    const scope = await sha256(new util.TextEncoder().encodeInto(JSON.stringify([normalizeNasOrigin(origin), account.trim()])));
    const directory = context.filesDir + '/nas-extensions/' + scope;
    try { await fileIo.mkdir(directory, true); }
    catch (error) { if ((error as BusinessError).code !== 13900015) { throw error as Error; } }
    const path = directory + '/pending.json';
    let missing = false;
    try {
      const stat = await fileIo.stat(path);
      if (stat.size > 16384) { throw new NasFailure(NasErrorKind.Protocol, '扩展操作记录过大，暂不能安全读取。'); }
    } catch (error) {
      if ((error as BusinessError).code !== 13900002) { throw error as Error; }
      missing = true;
    }
    let pending: ExtensionPendingWrite[] = [];
    if (!missing) {
      try {
        const text = await fileIo.readText(path);
        if (new util.TextEncoder().encodeInto(text).length > 16384) {
          throw new NasFailure(NasErrorKind.Protocol, '扩展操作记录过大，暂不能安全读取。');
        }
        pending = decodeExtensionWrites(text, scope);
      } catch (error) {
        if (error instanceof NasFailure) { throw error; }
        throw new NasFailure(NasErrorKind.Protocol, '无法读取扩展操作记录，请保留原记录并重新加载。', (error as BusinessError).code);
      }
    }
    this.scope = scope;
    this.path = path;
    return pending;
  }

  async save(pending: ExtensionPendingWrite[]): Promise<void> {
    if (this.path.length === 0) { throw new NasFailure(NasErrorKind.Protocol, '操作记录未成功加载，不能覆盖原记录。'); }
    const snapshot: ExtensionWriteSnapshot = { version: 1, scope: this.scope, pending: pending };
    const text = JSON.stringify(snapshot);
    decodeExtensionWrites(text, this.scope);
    await writePrivateSnapshot(this.path, new util.TextEncoder().encodeInto(text));
  }
}
