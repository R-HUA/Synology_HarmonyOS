import { image } from '@kit.ImageKit';

/** 只解析用户已读取的原文件，不为信息面板额外下载大文件。 */
export async function readPhotoExif(path: string): Promise<Record<string, string>> {
  const source = image.createImageSource(path);
  try {
    const keys: image.PropertyKey[] = [image.PropertyKey.IMAGE_WIDTH, image.PropertyKey.IMAGE_LENGTH,
      image.PropertyKey.IMAGE_DESCRIPTION, image.PropertyKey.MAKE, image.PropertyKey.MODEL,
      image.PropertyKey.ORIENTATION, image.PropertyKey.X_RESOLUTION, image.PropertyKey.Y_RESOLUTION,
      image.PropertyKey.RESOLUTION_UNIT, image.PropertyKey.DATE_TIME_ORIGINAL, image.PropertyKey.DATE_TIME_DIGITIZED,
      image.PropertyKey.YCBCR_POSITIONING, image.PropertyKey.EXPOSURE_TIME, image.PropertyKey.F_NUMBER,
      image.PropertyKey.EXPOSURE_PROGRAM, image.PropertyKey.ISO_SPEED_RATINGS, image.PropertyKey.EXIF_VERSION,
      image.PropertyKey.FOCAL_LENGTH, image.PropertyKey.LENS_MAKE, image.PropertyKey.LENS_MODEL];
    const properties = await source.getImageProperties(keys);
    const values: Record<string, string> = {};
    for (const key of keys) { const value = properties[key]; if (value !== null && value.length > 0) { values[key] = value; } }
    return values;
  } finally { await source.release(); }
}
