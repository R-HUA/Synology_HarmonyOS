import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { writePrivateSnapshot } from '../../platform/SdkFileIO';
import { ModuleTabSettings, decodeModuleTabSettings } from './ModuleNavigation';

/** 底栏偏好仅保存在本机，不随 NAS 的功能可见性覆盖用户选择。 */
export class ModuleTabStore {
  private path: string = '';

  async load(context: common.UIAbilityContext): Promise<ModuleTabSettings> {
    this.path = '';
    const target = context.filesDir + '/module-tabs.json';
    let settings = new ModuleTabSettings();
    try {
      const stat = await fileIo.stat(target);
      if (stat.size > 4096) { throw new NasFailure(NasErrorKind.Protocol, '底栏设置文件过大，请保留文件并重试读取。'); }
      settings = decodeModuleTabSettings(await fileIo.readText(target));
    } catch (error) {
      if (error instanceof NasFailure) { throw error; }
      if ((error as BusinessError).code !== 13900002) {
        throw new NasFailure(NasErrorKind.Protocol, '无法读取底栏设置，请重试。', (error as BusinessError).code);
      }
    }
    this.path = target;
    return settings;
  }

  async save(settings: ModuleTabSettings): Promise<void> {
    if (this.path.length === 0) { throw new NasFailure(NasErrorKind.Protocol, '请先重新读取底栏设置。'); }
    await writePrivateSnapshot(this.path, new util.TextEncoder().encodeInto(JSON.stringify(settings)));
  }
}
