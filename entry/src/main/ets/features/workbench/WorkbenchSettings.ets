import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';

/** 外观偏好属于本机，清理媒体缓存不触碰账号或传输文件。 */
@ObservedV2
export class WorkbenchSettings {
  @Trace appearance: number = 0;
  @Trace cacheBytes: number = 0;
  @Trace busy: boolean = false;
  @Trace errorText: string = '';
  private context: common.UIAbilityContext | undefined = undefined;
  private store: preferences.Preferences | undefined = undefined;

  async load(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    try {
      this.store = await preferences.getPreferences(context, { name: 'workbench-appearance' });
      const value = await this.store.get('appearance', 0);
      if (typeof value !== 'number' || ![0, 1, 2].includes(value)) { throw new Error('外观设置无效，请重新选择。'); }
      this.applyAppearance(value);
      await this.measureCache();
    } catch (error) { this.errorText = (error as Error).message; }
  }

  async setAppearance(value: number): Promise<void> {
    if (this.store === undefined || this.busy) { return; }
    this.busy = true; this.errorText = '';
    try {
      await this.store.put('appearance', value);
      await this.store.flush();
      this.applyAppearance(value);
    } catch (error) { this.errorText = (error as Error).message; }
    finally { this.busy = false; }
  }

  private applyAppearance(value: number): void {
    this.context!.getApplicationContext().setColorMode(value === 1 ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT :
      value === 2 ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    this.appearance = value;
  }

  /** 只统计各媒体功能拥有的目录，不包括待上传源和已下载文件。 */
  async measureCache(): Promise<void> {
    const context = this.context;
    if (context === undefined) { return; }
    try {
      let bytes = 0;
      for (const name of await fileIo.listFile(context.cacheDir)) {
        if (name === 'photos-v2' || name === 'drive-thumbnails' || /^(drive-original|file-preview)-[0-9a-f-]+$/.test(name)) {
          bytes += await this.directoryBytes(context.cacheDir + '/' + name);
        }
      }
      this.cacheBytes = bytes;
    } catch (error) { this.errorText = (error as Error).message; }
  }

  private async directoryBytes(path: string): Promise<number> {
    const stat = await fileIo.stat(path);
    if (!stat.isDirectory()) { return stat.size; }
    let bytes = 0;
    for (const name of await fileIo.listFile(path)) { bytes += await this.directoryBytes(path + '/' + name); }
    return bytes;
  }
}
