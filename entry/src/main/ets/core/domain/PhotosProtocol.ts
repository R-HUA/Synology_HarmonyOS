import { nasInteger, nasRecord, nasString, NasErrorKind, NasFailure } from './DsmProtocol';

export enum PhotosSpace { Personal, Shared, WithMe }

export interface NasPhotoItem {
  id: number;
  filename: string;
  bytes: number;
  space: PhotosSpace;
  mediaType: string;
}

export interface NasPhotoPage { items: NasPhotoItem[]; offset: number; hasMore: boolean; }

export interface NasSharedAlbum {
  id: number;
  name: string;
  itemCount: number;
  // 服务返回的分享访问凭证仅在当前连接内存中使用，不进入日志或持久化。
  passphrase?: string;
}

export interface NasSharedAlbumPage { items: NasSharedAlbum[]; offset: number; hasMore: boolean; }

function incompatiblePhotos(): NasFailure {
  return new NasFailure(NasErrorKind.Protocol, '照片响应格式不符合预期，请检查 Synology Photos 套件版本。');
}

/** 接收已有业务响应解析器确认成功后的 data；满页只说明可继续检查下一页。 */
export function decodePhotosPage(data: Record<string, Object>, space: PhotosSpace, offset: number, limit: number): NasPhotoPage {
  if ((space !== PhotosSpace.Personal && space !== PhotosSpace.Shared && space !== PhotosSpace.WithMe) ||
    !Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit <= 0 ||
    !Number.isSafeInteger(offset + limit)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '照片空间或分页位置不正确。');
  }
  const rows = nasRecord(data)['list'];
  if (!Array.isArray(rows) || rows.length > limit) { throw incompatiblePhotos(); }
  const identities = new Set<number>();
  const items = (rows as Object[]).map((input: Object): NasPhotoItem => {
    const row = nasRecord(input);
    const id = nasInteger(row['id']);
    const filename = nasString(row['filename']);
    const bytes = nasInteger(row['filesize']);
    const mediaType = nasString(row['type']);
    // 目前核对的原始合同为字符串；未知类型不推断为照片或视频。
    if (!['photo', 'video', 'live'].includes(mediaType) || identities.has(id)) { throw incompatiblePhotos(); }
    identities.add(id);
    return { id: id, filename: filename, bytes: bytes, space: space, mediaType: mediaType };
  });
  return { items: items, offset: offset, hasMore: items.length === limit };
}

/** 与我共享列表使用 Sharing.Misc/list_shared_with_me_album；调用者先确认业务成功。 */
export function decodeSharedAlbumPage(data: Record<string, Object>, offset: number, limit: number): NasSharedAlbumPage {
  if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit <= 0 ||
    !Number.isSafeInteger(offset + limit)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '相册分页位置不正确。');
  }
  const rows = nasRecord(data)['list'];
  if (!Array.isArray(rows) || rows.length > limit) { throw incompatiblePhotos(); }
  const identities = new Set<number>();
  const items = (rows as Object[]).map((input: Object): NasSharedAlbum => {
    const row = nasRecord(input);
    const id = nasInteger(row['id']);
    const name = nasString(row['name']);
    const itemCount = nasInteger(row['item_count']);
    if (identities.has(id)) { throw incompatiblePhotos(); }
    identities.add(id);
    const direct = row['passphrase'];
    const sharing = row['sharing_info'] === undefined ? undefined : nasRecord(row['sharing_info']);
    const nested = sharing === undefined ? undefined : sharing['passphrase'];
    if ((direct !== undefined && typeof direct !== 'string') ||
      (nested !== undefined && typeof nested !== 'string')) { throw incompatiblePhotos(); }
    const album: NasSharedAlbum = { id: id, name: name, itemCount: itemCount };
    // 原始客户端优先使用顶层非空凭证，否则读取 sharing_info 中的凭证。
    const passphrase = typeof direct === 'string' && direct.length > 0 ? direct : nested;
    if (typeof passphrase === 'string' && passphrase.length > 0) { album.passphrase = passphrase; }
    return album;
  });
  return { items: items, offset: offset, hasMore: items.length === limit };
}
