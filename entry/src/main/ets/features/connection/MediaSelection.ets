import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';

const MAX_MEDIA_BYTES: number = 256 * 1024 * 1024;

/** 验证用户选择的图片可复制到应用缓存，完成后立即清理，不传输媒体内容。 */
@ObservedV2
export class MediaSelection {
  @Trace running: boolean = false;
  @Trace status: string = '';

  async verify(context: common.UIAbilityContext): Promise<void> {
    if (this.running) { return; }
    this.running = true;
    this.status = '请选择一张图片';
    try {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const selected = await new photoAccessHelper.PhotoViewPicker().select(options);
      if (selected.photoUris.length === 0) {
        this.status = '已取消';
        hilog.info(0x0000, 'NasMedia', 'operation=selected-copy result=canceled');
        return;
      }
      this.status = '正在读取所选图片…';
      const bytes = await this.validateCopy(context, selected.photoUris[0]);
      this.status = '所选图片读取成功';
      hilog.info(0x0000, 'NasMedia', 'operation=selected-copy result=success bytes=%{public}d', bytes);
    } catch (error) {
      const code = (error as BusinessError).code;
      hilog.error(0x0000, 'NasMedia', 'operation=selected-copy result=failed code=%{public}d',
        typeof code === 'number' ? code : 0);
      if (error instanceof NasFailure) {
        this.status = error.message;
        throw error as Error;
      }
      this.status = '无法读取所选内容，请重新选择图片。';
      throw new NasFailure(NasErrorKind.Permission, this.status, typeof code === 'number' ? code : 0);
    } finally {
      this.running = false;
    }
  }

  private async validateCopy(context: common.UIAbilityContext, uri: string): Promise<number> {
    const source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const original = await fileIo.stat(source.fd);
      if (original.size > MAX_MEDIA_BYTES) {
        throw new NasFailure(NasErrorKind.InvalidInput, '请选择不超过 256 MB 的图片。');
      }
      const cachePath = context.cacheDir + '/media-check-' + util.generateRandomUUID() + '.media';
      try {
        await fileIo.copyFile(source.fd, cachePath);
        const copied = await fileIo.stat(cachePath);
        if (copied.size !== original.size) {
          throw new NasFailure(NasErrorKind.Protocol, '无法完整读取所选内容，请重新选择图片。');
        }
        return copied.size;
      } finally {
        await this.removeCopy(cachePath);
      }
    } finally {
      await fileIo.close(source);
    }
  }

  private async removeCopy(path: string): Promise<void> {
    try {
      await fileIo.unlink(path);
    } catch (error) {
      if ((error as BusinessError).code !== 13900002) { throw error as Error; }
    }
  }
}
