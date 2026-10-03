import { common } from '@kit.AbilityKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 官方产品图接口。这是 synology.com 产品页自己在用的前端地址，不是官方文档承诺的公开 API，
 * 路径可能变更；因此只作为内置图之外的补充：命中内置图就不联网，联网失败就回退内置图。
 * 请求只携带型号字符串，不带 NAS 会话、账号或地址。
 */
const PRODUCT_PHOTO_ENDPOINT = 'https://www.synology.com/api/products/getPhoto';
const MAX_ARTWORK_BYTES = 512 * 1024;
const ARTWORK_DIRECTORY = 'device-artwork';

/** 该型号是否收录了官方写实产品图（内置）。 */
export function hasModelArtwork(model: string): boolean {
  switch (model.trim().toLowerCase()) {
    case 'ds120j':
    case 'ds220j':
    case 'ds220+':
    case 'ds223':
    case 'ds223j':
    case 'ds224+':
    case 'ds420+':
    case 'ds423+':
    case 'ds720+':
    case 'ds918+':
    case 'ds920+':
    case 'ds923+':
    case 'ds1522+':
    case 'ds1621+':
    case 'ds1821+':
    case 'ds1823xs+':
    case 'ds3622xs+':
    case 'rs1221+':
    case 'rs2423+':
    case 'fs6400':
      return true;
    default:
      return false;
  }
}

/** 型号对应的内置产品图；未收录时回退到官方通用线性 NAS 图。 */
export function bundledDeviceArtwork(model: string): Resource {
  switch (model.trim().toLowerCase()) {
    case 'ds120j': return $r('app.media.device_ds120j');
    case 'ds220j': return $r('app.media.device_ds220j');
    case 'ds220+': return $r('app.media.device_ds220plus');
    case 'ds223': return $r('app.media.device_ds223');
    case 'ds223j': return $r('app.media.device_ds223j');
    case 'ds224+': return $r('app.media.device_ds224plus');
    case 'ds420+': return $r('app.media.device_ds420plus');
    case 'ds423+': return $r('app.media.device_ds423plus');
    case 'ds720+': return $r('app.media.device_ds720plus');
    case 'ds918+': return $r('app.media.device_ds918plus');
    case 'ds920+': return $r('app.media.device_ds920plus');
    case 'ds923+': return $r('app.media.device_ds923plus');
    case 'ds1522+': return $r('app.media.device_ds1522plus');
    case 'ds1621+': return $r('app.media.device_ds1621plus');
    case 'ds1821+': return $r('app.media.device_ds1821plus');
    case 'ds1823xs+': return $r('app.media.device_ds1823xsplus');
    case 'ds3622xs+': return $r('app.media.device_ds3622xsplus');
    case 'rs1221+': return $r('app.media.device_rs1221plus');
    case 'rs2423+': return $r('app.media.device_rs2423plus');
    case 'fs6400': return $r('app.media.device_fs6400');
    default: return $r('app.media.nas_device_line');
  }
}

/** 官方通用线性 NAS 图（gallery.synology.com 的 product 图标），用作最终兜底。 */
export function fallbackDeviceArtwork(): Resource {
  return $r('app.media.nas_device_line');
}

/** 型号 → 官方产品图地址；型号里的 + 必须编码成 %2B。 */
export function productPhotoAddress(model: string): string {
  return PRODUCT_PHOTO_ENDPOINT + '?product=' + encodeURIComponent(model.trim()) + '&type=img&sort=1';
}

function artworkFileName(model: string): string {
  const safe = model.trim().toLowerCase().replace(/[^a-z0-9]/g, '_');
  return 'device_' + safe + '.webp';
}

/**
 * 未收录型号的产品图：按型号缓存到应用私有目录；命中内置图、型号为空或下载失败都返回空串，
 * 由界面回退到官方线性兜底图。
 */
export async function deviceArtworkPath(context: common.UIAbilityContext, model: string): Promise<string> {
  const trimmed = model.trim();
  if (trimmed.length === 0 || hasModelArtwork(trimmed)) { return ''; }
  const directory = context.cacheDir + '/' + ARTWORK_DIRECTORY;
  const target = directory + '/' + artworkFileName(trimmed);
  try {
    if (fileIo.accessSync(target) && fileIo.statSync(target).size > 0) { return target; }
  } catch { /* 缓存不可用时继续尝试联网 */ }
  const bytes = await fetchArtwork(trimmed);
  if (bytes === undefined) { return ''; }
  try {
    if (!fileIo.accessSync(directory)) { fileIo.mkdirSync(directory); }
    const output = fileIo.openSync(target, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      let offset = 0;
      while (offset < bytes.length) {
        const written = fileIo.writeSync(output.fd, bytes.buffer.slice(offset));
        if (written <= 0) { throw new Error('short write'); }
        offset += written;
      }
    } finally { fileIo.closeSync(output); }
    return fileIo.statSync(target).size === bytes.length ? target : '';
  } catch (error) {
    hilog.error(0x0000, 'NasDeviceArt', 'operation=cache result=failed code=%{public}d', (error as BusinessError).code);
    try { if (fileIo.accessSync(target)) { fileIo.unlinkSync(target); } } catch { /* 清理失败不再处理 */ }
    return '';
  }
}

/** 单次外域请求；失败返回 undefined，不抛给调用方。 */
async function fetchArtwork(model: string): Promise<Uint8Array | undefined> {
  const session = rcp.createSession({
    requestConfiguration: { transfer: { autoRedirect: false, timeout: { connectMs: 8000, transferMs: 15000 } } }
  });
  const request = new rcp.Request(productPhotoAddress(model), 'GET', { 'Accept': 'image/webp,image/*', 'Cache-Control': 'no-store' });
  request.cacheControl = { noStore: true };
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  let overflow = false;
  request.destination = (chunk: ArrayBuffer): void => {
    if (bytes + chunk.byteLength > MAX_ARTWORK_BYTES) { overflow = true; session.cancel(request); return; }
    chunks.push(new Uint8Array(chunk));
    bytes += chunk.byteLength;
  };
  try {
    const reply = await session.fetch(request);
    if (overflow || reply.statusCode !== 200 || bytes === 0) { return undefined; }
    const data = new Uint8Array(bytes);
    let offset = 0;
    for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.length; }
    return data;
  } catch {
    hilog.info(0x0000, 'NasDeviceArt', 'operation=fetch result=failed');
    return undefined;
  } finally { session.close(); }
}
