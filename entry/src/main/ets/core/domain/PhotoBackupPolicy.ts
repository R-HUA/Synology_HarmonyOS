import { nasRecord, NasErrorKind, NasFailure } from './DsmProtocol';
import { photoDateDirectory } from './PhotoUpload';
import { validateTransferName } from './TransferQueueState';

export type PhotoBackupMode = 'continue' | 'new' | 'all';
export type PhotoBackupLayout = 'date' | 'album' | 'flat';

/** 设置按 NAS 与账号保存，关闭不会清除备份范围或成功记录。 */
export class PhotoBackupSettings {
  enabled: boolean = false;
  mode: PhotoBackupMode = 'continue';
  custom: boolean = false;
  directory: string = '';
  layout: PhotoBackupLayout = 'date';
  photosOnly: boolean = false;
  wifiOnly: boolean = true;
  chargingOnly: boolean = false;
  since: number = 0;
}
export interface LocalBackupAsset {
  uri: string; name: string; bytes: number; modifiedAt: number; takenAt: number; addedAt: number; album: string;
}
export interface PhotoBackupSnapshot { version: number; scope: string; settings: PhotoBackupSettings; completed: string[]; }

/** 成功标识包含内容版本与目标，修改文件或目标目录后可以再次备份。 */
export function backupAssetKey(asset: LocalBackupAsset, directory: string, digest: string): string {
  return JSON.stringify([asset.uri, asset.name, asset.bytes, asset.modifiedAt, directory, digest]);
}

export function backupDirectory(settings: PhotoBackupSettings, model: string, asset: LocalBackupAsset): string {
  let directory = settings.custom ? settings.directory : 'MobileBackup/' + validateTransferName(model);
  if (directory.length === 0) { throw new NasFailure(NasErrorKind.InvalidInput, '请选择备份位置。'); }
  directory.split('/').forEach(validateTransferName);
  if (settings.layout === 'date') { directory += '/' + photoDateDirectory(asset.takenAt, asset.modifiedAt); }
  if (settings.layout === 'album') {
    if (asset.album.length === 0) { throw new NasFailure(NasErrorKind.InvalidInput, '照片缺少来源相册，无法按相册备份。'); }
    directory += '/' + validateTransferName(asset.album);
  }
  return directory;
}

export function decodePhotoBackup(text: string, scope: string): PhotoBackupSnapshot {
  const data = nasRecord(JSON.parse(text) as Object);
  const settings = nasRecord(data['settings']);
  if (data['version'] !== 1 || data['scope'] !== scope || !Array.isArray(data['completed']) ||
    !(data['completed'] as Object[]).every((key: Object): boolean => typeof key === 'string') ||
    !['continue', 'new', 'all'].includes(settings['mode'] as string) || !['date', 'album', 'flat'].includes(settings['layout'] as string) ||
    typeof settings['directory'] !== 'string' || !Number.isSafeInteger(settings['since']) || (settings['since'] as number) < 0 ||
    !['enabled', 'custom', 'photosOnly', 'wifiOnly', 'chargingOnly'].every((key: string): boolean => typeof settings[key] === 'boolean')) {
    throw new NasFailure(NasErrorKind.Protocol, '相册备份记录无法读取，请重试。');
  }
  const result = new PhotoBackupSettings();
  result.enabled = settings['enabled'] as boolean; result.mode = settings['mode'] as PhotoBackupMode;
  result.custom = settings['custom'] as boolean; result.directory = settings['directory'] as string;
  result.layout = settings['layout'] as PhotoBackupLayout; result.photosOnly = settings['photosOnly'] as boolean;
  result.wifiOnly = settings['wifiOnly'] as boolean; result.chargingOnly = settings['chargingOnly'] as boolean;
  result.since = settings['since'] as number;
  if (result.directory.length > 0) { result.directory.split('/').forEach(validateTransferName); }
  return { version: 1, scope, settings: result, completed: data['completed'] as string[] };
}
