import { NasFormField, NasErrorKind, NasFailure, nasInteger, nasRecord, nasString } from './DsmProtocol';
import { NasPhotoItem, PhotosSpace, validatePhotoIdentity } from './PhotosProtocol';

export type PhotoAction = 'favorite' | 'delete' | 'album' | 'share' | 'copy';
export interface PhotoActionInput { action: PhotoAction; item: NasPhotoItem; favorite?: boolean; targetId?: number; }
export interface PhotoActionRequest { api: string; version: number; method: string; fields: NasFormField[]; }
export interface PhotoActionResult { completed: boolean; taskId?: number; sharePassphrase?: string; }
export interface PhotoFolder { id: number; name: string; }

/** 写入只接受本人或共享空间身份，接收相册不推定修改权限。 */
export function photoActionRequest(input: PhotoActionInput): PhotoActionRequest {
  validatePhotoIdentity(input.item);
  const prefix = input.item.space === PhotosSpace.Shared ? 'SYNO.FotoTeam.' : 'SYNO.Foto.';
  const ids = JSON.stringify([input.item.id]);
  if (input.action === 'favorite') {
    if (typeof input.favorite !== 'boolean') { throw new NasFailure(NasErrorKind.InvalidInput, '收藏状态不正确。'); }
    return { api: prefix + 'Browse.Item', version: 7, method: 'set_favorite',
      fields: [{ name: 'id', content: ids }, { name: 'favorite', content: input.favorite.toString() }] };
  }
  if (input.action === 'delete' || input.action === 'copy') {
    const fields: NasFormField[] = [{ name: 'item_id', content: ids }, { name: 'folder_id', content: '[]' }];
    if (input.action === 'copy') {
      validateTarget(input.targetId);
      fields.push({ name: 'target_folder_id', content: input.targetId!.toString() }, { name: 'action', content: JSON.stringify('skip') });
    }
    return { api: prefix + 'BackgroundTask.File', version: 1, method: input.action, fields };
  }
  if (input.action === 'album') {
    if (input.item.space !== PhotosSpace.Personal) { throw new NasFailure(NasErrorKind.Unsupported, '此空间暂不支持添加到相册。'); }
    validateTarget(input.targetId);
    return { api: 'SYNO.Foto.Browse.NormalAlbum', version: 1, method: 'add_item',
      fields: [{ name: 'id', content: input.targetId!.toString() }, { name: 'item', content: ids }] };
  }
  if (input.item.space !== PhotosSpace.Personal) { throw new NasFailure(NasErrorKind.Unsupported, '此空间暂不支持创建照片分享。'); }
  return { api: 'SYNO.Foto.Browse.NormalAlbum', version: 1, method: 'create', fields: [
    { name: 'name', content: JSON.stringify(input.item.filename) }, { name: 'shared', content: 'true' }, { name: 'item', content: ids }] };
}

function validateTarget(id: number | undefined): void {
  if (id === undefined || !Number.isSafeInteger(id) || id < 0) { throw new NasFailure(NasErrorKind.InvalidInput, '请选择有效目标。'); }
}

/** 后台回执仅表示接受；持久记录须等 get_status 明确 done 后才能清除。 */
export function decodePhotoActionResult(input: PhotoActionInput, data: Record<string, Object>): PhotoActionResult {
  if (input.action === 'delete' || input.action === 'copy') {
    return { completed: false, taskId: nasInteger(nasRecord(data['task_info'])['id']) };
  }
  if (input.action === 'share') {
    const album = nasRecord(data['album']);
    return { completed: true, sharePassphrase: nasString(album['passphrase']) };
  }
  return { completed: true };
}

export function decodePhotoFolders(data: Record<string, Object>): PhotoFolder[] {
  const list = data['list'];
  if (!Array.isArray(list)) { throw new NasFailure(NasErrorKind.Protocol, '照片目录响应格式不正确。'); }
  return (list as Object[]).map((value: Object): PhotoFolder => {
    const row = nasRecord(value);
    return { id: nasInteger(row['id']), name: nasString(row['name']) };
  });
}
