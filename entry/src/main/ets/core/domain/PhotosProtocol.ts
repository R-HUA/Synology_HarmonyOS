import { nasInteger, nasRecord, nasString, decodeNasResponse, NasErrorKind, NasFailure } from './DsmProtocol';

const MAX_PHOTO_TIME_SECONDS = 8640000000000;

export enum PhotosSpace { Personal, Shared, WithMe }

export interface NasPhotoItem {
  id: number;
  filename: string;
  bytes: number;
  space: PhotosSpace;
  mediaType: string;
  takenAt?: number;
  width?: number;
  height?: number;
  orientation?: number;
  thumbnail?: NasPhotoThumbnail;
  sourceSpace?: PhotosSpace;
  favorite?: boolean;
  folderId?: number;
  description?: string;
  exif?: Record<string, string>;
  location?: string;
  address?: string;
  tags?: string[];
}

// 授权上下文只在当前连接内存中使用；scope 是本机随机标识，不包含分享口令。
export interface NasPhotoMediaAccess { albumId: number; scope: string; passphrase?: string; }

export interface NasPhotoThumbnail { unitId: number; cacheKey?: string; }
export interface NasPhotoAlbum extends NasSharedAlbum { space: PhotosSpace; }
export interface NasPhotoAlbumPage { items: NasPhotoAlbum[]; offset: number; hasMore: boolean; }

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
    const item: NasPhotoItem = { id: id, filename: filename, bytes: bytes, space: space, mediaType: mediaType };
    if (row['is_favorite'] !== undefined) {
      if (typeof row['is_favorite'] !== 'boolean') { throw incompatiblePhotos(); }
      item.favorite = row['is_favorite'] as boolean;
    }
    if (row['folder_id'] !== undefined) { item.folderId = nasInteger(row['folder_id']); }
    if (row['time'] !== undefined) {
      const seconds = nasInteger(row['time']);
      if (seconds > MAX_PHOTO_TIME_SECONDS) { throw incompatiblePhotos(); }
      item.takenAt = seconds;
    }
    if (row['owner_user_id'] !== undefined) {
      item.sourceSpace = nasInteger(row['owner_user_id']) === 0 ? PhotosSpace.Shared : PhotosSpace.Personal;
    }
    if (row['additional'] !== undefined) {
      const additional = nasRecord(row['additional']);
      if (additional['favorite'] !== undefined) {
        if (typeof additional['favorite'] !== 'boolean') { throw incompatiblePhotos(); }
        item.favorite = additional['favorite'] as boolean;
      }
      if (additional['description'] !== undefined) {
        if (typeof additional['description'] !== 'string') { throw incompatiblePhotos(); }
        item.description = additional['description'] as string;
      }
      if (additional['address'] !== undefined && additional['address'] !== null) {
        const address = nasRecord(additional['address']), parts: string[] = [];
        for (const key of ['country', 'state', 'city', 'county', 'district', 'town', 'village', 'route', 'landmark']) {
          const value = address[key];
          if (value !== undefined && value !== null) {
            if (typeof value !== 'string') { throw incompatiblePhotos(); }
            if (value.length > 0 && !parts.includes(value)) { parts.push(value); }
          }
        }
        item.address = parts.join('，');
      }
      if (additional['tag'] !== undefined) {
        if (!Array.isArray(additional['tag'])) { throw incompatiblePhotos(); }
        item.tags = (additional['tag'] as Object[]).map((tag: Object): string => nasString(nasRecord(tag)['name']));
      }
      if (additional['exif'] !== undefined) {
        const exif = nasRecord(additional['exif']);
        item.exif = {};
        for (const key of Object.keys(exif)) {
          const value = exif[key];
          if (typeof value === 'string' || typeof value === 'number' && Number.isFinite(value)) { item.exif[key] = value.toString(); }
          else if (value !== null) { throw incompatiblePhotos(); }
        }
      }
      if (additional['resolution'] !== undefined) {
        const resolution = nasRecord(additional['resolution']);
        if (resolution['width'] !== undefined) { item.width = nasInteger(resolution['width']); }
        if (resolution['height'] !== undefined) { item.height = nasInteger(resolution['height']); }
      }
      if (additional['orientation'] !== undefined) { item.orientation = nasInteger(additional['orientation']); }
      if (additional['thumbnail'] !== undefined) {
        const thumbnail = nasRecord(additional['thumbnail']);
        // 可用尺寸状态不影响身份；服务未提供 unit_id 时不猜测缩略图地址。
        if (space === PhotosSpace.WithMe && thumbnail['cache_key'] !== undefined) {
          const cacheKey = nasString(thumbnail['cache_key']);
          // PR344 的共享媒体合同明确使用列表 item.id。
          item.thumbnail = { unitId: id, cacheKey: cacheKey };
        }
        if (thumbnail['unit_id'] !== undefined && space !== PhotosSpace.WithMe) {
          item.thumbnail = { unitId: nasInteger(thumbnail['unit_id']) };
          if (thumbnail['cache_key'] !== undefined) { item.thumbnail.cacheKey = nasString(thumbnail['cache_key']); }
        }
      }
    }
    return item;
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

/** 常规相册与接收相册具有不同来源，身份不能跨空间复用。 */
export function decodePhotoAlbumPage(data: Record<string, Object>, space: PhotosSpace, offset: number, limit: number): NasPhotoAlbumPage {
  if (space !== PhotosSpace.Personal && space !== PhotosSpace.Shared && space !== PhotosSpace.WithMe) {
    throw new NasFailure(NasErrorKind.InvalidInput, '相册空间不正确。');
  }
  const page = decodeSharedAlbumPage(data, offset, limit);
  return { items: page.items.map((album: NasSharedAlbum): NasPhotoAlbum => ({ id: album.id, name: album.name,
    itemCount: album.itemCount, space: space, passphrase: album.passphrase })), offset: offset, hasMore: page.hasMore };
}

export function validatePhotoIdentity(item: NasPhotoItem, allowReceived: boolean = false): void {
  if (!Number.isSafeInteger(item.id) || item.id < 0 ||
    ![PhotosSpace.Personal, PhotosSpace.Shared, PhotosSpace.WithMe].includes(item.space)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '照片标识或空间不正确。');
  }
  if (item.space === PhotosSpace.WithMe && !allowReceived) {
    throw new NasFailure(NasErrorKind.Unsupported, '此共享相册的详情请使用已读取的相册元数据。');
  }
}

/** 浏览来源 WithMe 不等同于 Foto/Fototeam 媒体命名空间。 */
export function photoMediaSource(item: NasPhotoItem, access?: NasPhotoMediaAccess): PhotosSpace {
  validatePhotoIdentity(item, true);
  const source = item.sourceSpace;
  if (source !== undefined && source !== PhotosSpace.Personal && source !== PhotosSpace.Shared) { throw incompatiblePhotos(); }
  if (item.space === PhotosSpace.WithMe) {
    if (source === undefined) { throw new NasFailure(NasErrorKind.Unsupported, '共享照片未提供有效来源信息，无法确认媒体访问。'); }
    if (access === undefined || !Number.isSafeInteger(access.albumId) || access.albumId < 0 ||
      !/^[A-Za-z0-9-]{1,80}$/.test(access.scope) || access.passphrase !== undefined && typeof access.passphrase !== 'string') {
      throw new NasFailure(NasErrorKind.InvalidInput, '共享相册授权上下文已失效，请重新打开相册。');
    }
    return source;
  }
  if (source !== undefined && source !== item.space) { throw incompatiblePhotos(); }
  return item.space;
}

export function decodePhotoDetail(data: Record<string, Object>, item: NasPhotoItem): NasPhotoItem {
  validatePhotoIdentity(item);
  const page = decodePhotosPage(data, item.space, 0, 1);
  if (page.items.length !== 1 || page.items[0].id !== item.id ||
    page.items[0].sourceSpace !== undefined && page.items[0].sourceSpace !== item.space) { throw incompatiblePhotos(); }
  return page.items[0];
}

export function mergePhotoItems(existing: NasPhotoItem[], incoming: NasPhotoItem[], space: PhotosSpace): NasPhotoItem[] {
  const items = existing.slice();
  const identities = new Set<number>();
  for (const item of items) { identities.add(item.id); }
  for (const item of incoming) {
    if (item.space !== space) { throw incompatiblePhotos(); }
    if (!identities.has(item.id)) { identities.add(item.id); items.push(item); }
  }
  return items;
}

export const PHOTO_ORIGINAL_MAX_BYTES = 256 * 1024 * 1024;
export const PHOTO_THUMBNAIL_MAX_BYTES = 4 * 1024 * 1024;

/** 只接受完整二进制媒体；HTTP 错误或业务 JSON 不能被当作图片写入缓存。 */
export function validatePhotoMediaResponse(api: string, status: number, contentType: string, contentLength: string,
  received: number, prefix: Uint8Array, prefixText: string, thumbnail: boolean, expectedBytes?: number): void {
  if (status !== 200) { throw new NasFailure(NasErrorKind.Http, '照片媒体请求失败，请重试。', status); }
  const maximum = thumbnail ? PHOTO_THUMBNAIL_MAX_BYTES : PHOTO_ORIGINAL_MAX_BYTES;
  if (!Number.isSafeInteger(received) || received <= 0 || received > maximum) { throw incompatiblePhotos(); }
  if (contentLength.length > 0 && (!/^[0-9]+$/.test(contentLength) || Number(contentLength) !== received)) {
    throw new NasFailure(NasErrorKind.Protocol, '照片媒体长度不符合响应声明，请重试。');
  }
  const type = contentType.split(';')[0].trim().toLowerCase();
  const text = prefixText.trim();
  if (type.includes('json') || text.startsWith('{') || text.startsWith('[')) {
    decodeNasResponse(api, status, prefixText);
    throw new NasFailure(NasErrorKind.Protocol, '服务器返回了业务响应，未提供照片媒体。');
  }
  if (text.startsWith('<') || type.includes('html') || type.startsWith('text/')) { throw incompatiblePhotos(); }
  const jpeg = prefix.length >= 3 && prefix[0] === 255 && prefix[1] === 216 && prefix[2] === 255;
  const png = prefix.length >= 8 && prefix[0] === 137 && prefix[1] === 80 && prefix[2] === 78 && prefix[3] === 71 &&
    prefix[4] === 13 && prefix[5] === 10 && prefix[6] === 26 && prefix[7] === 10;
  const gif = prefix.length >= 6 && prefix[0] === 71 && prefix[1] === 73 && prefix[2] === 70 && prefix[3] === 56;
  const riff = prefix.length >= 12 && prefix[0] === 82 && prefix[1] === 73 && prefix[2] === 70 && prefix[3] === 70;
  const webp = riff && prefix[8] === 87 && prefix[9] === 69 && prefix[10] === 66 && prefix[11] === 80;
  const iso = prefix.length >= 12 && prefix[4] === 102 && prefix[5] === 116 && prefix[6] === 121 && prefix[7] === 112;
  const tiff = prefix.length >= 4 && ((prefix[0] === 73 && prefix[1] === 73 && prefix[2] === 42 && prefix[3] === 0) ||
    (prefix[0] === 77 && prefix[1] === 77 && prefix[2] === 0 && prefix[3] === 42));
  const brand = iso ? String.fromCharCode(prefix[8], prefix[9], prefix[10], prefix[11]) : '';
  const heif = iso && ['heic', 'heix', 'hevc', 'hevx', 'mif1', 'msf1', 'heif'].includes(brand);
  const avif = iso && ['avif', 'avis'].includes(brand);
  const mp4 = iso && ['isom', 'iso2', 'iso3', 'iso4', 'iso5', 'iso6', 'mp41', 'mp42', 'avc1', 'M4V ', 'dash', '3gp4', '3gp5', '3g2a'].includes(brand);
  const quicktime = iso && brand === 'qt  ';
  const avi = riff && prefix[8] === 65 && prefix[9] === 86 && prefix[10] === 73 && prefix[11] === 32;
  const ebml = prefix.length >= 4 && prefix[0] === 26 && prefix[1] === 69 && prefix[2] === 223 && prefix[3] === 163;
  const mpeg = prefix.length >= 4 && prefix[0] === 0 && prefix[1] === 0 && prefix[2] === 1 && [179, 186].includes(prefix[3]);
  const image = jpeg || png || gif || webp || tiff || heif || avif;
  const video = mp4 || quicktime || avi || ebml || mpeg;
  let recognized = false;
  switch (type) {
    case 'image/jpeg': case 'image/jpg': case 'image/pjpeg': recognized = jpeg; break;
    case 'image/png': recognized = png; break;
    case 'image/gif': recognized = gif; break;
    case 'image/webp': recognized = webp; break;
    case 'image/tiff': recognized = tiff; break;
    case 'image/heic': case 'image/heif': recognized = heif; break;
    case 'image/avif': recognized = avif; break;
    case 'video/mp4': case 'video/3gpp': case 'video/3gpp2': recognized = mp4; break;
    case 'video/quicktime': recognized = quicktime; break;
    case 'video/webm': case 'video/x-matroska': recognized = ebml; break;
    case 'video/avi': case 'video/x-msvideo': recognized = avi; break;
    case 'video/mpeg': recognized = mpeg; break;
    case 'application/octet-stream': recognized = thumbnail ? image : image || video; break;
  }
  if (!recognized || thumbnail && !image) {
    throw new NasFailure(NasErrorKind.Protocol, '服务器媒体类型与已支持的文件签名不一致，未保存原文件。');
  }
  if (!thumbnail && expectedBytes !== undefined && expectedBytes > 0 && received !== expectedBytes) {
    throw new NasFailure(NasErrorKind.Protocol, '原图大小与照片信息不一致，请刷新后重试。');
  }
}
