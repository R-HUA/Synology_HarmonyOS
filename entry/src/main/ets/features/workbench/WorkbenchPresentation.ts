import type { NasPhotoItem, NasPhotoAlbum } from '../../core/domain/PhotosProtocol';

export interface WorkbenchBreadcrumb {
  title: string;
  path: string;
}

export function workbenchBreadcrumbs(directory: string): WorkbenchBreadcrumb[] {
  const result: WorkbenchBreadcrumb[] = [{ title: '共享文件夹', path: '' }];
  let path = '';
  directory.split('/').filter((part: string): boolean => part.length > 0)
    .forEach((part: string): void => {
      path += '/' + part;
      result.push({ title: part, path: path });
    });
  return result;
}

export function workbenchBytes(bytes: number | undefined): string {
  if (bytes === undefined) { return '大小未提供'; }
  if (bytes < 1024) { return bytes.toString() + ' B'; }
  const units = ['KB', 'MB', 'GB', 'TB'];
  let amount = bytes / 1024;
  let unit = 0;
  while (amount >= 1024 && unit < units.length - 1) { amount /= 1024; unit++; }
  return amount.toFixed(amount < 10 ? 1 : 0) + ' ' + units[unit];
}

export function workbenchCanUseDestination(source: string, isDirectory: boolean, directory: string): boolean {
  if (directory.length === 0) { return false; }
  const parent = source.substring(0, source.lastIndexOf('/'));
  return parent !== directory && (!isDirectory || (directory !== source && !directory.startsWith(source + '/')));
}

export interface PhotoTimelineRow {
  key: string;
  title: string;
  items: NasPhotoItem[];
}

/** 根据实际内容宽度安排照片网格；日期缺失时保留独立分组。 */
export function photoGridColumns(width: number): number {
  return width < 300 ? 3 : width < 600 ? 4 : 6;
}

export function photoTakenDate(item: NasPhotoItem): string {
  if (item.takenAt === undefined) { return '拍摄时间未提供'; }
  const date = new Date(item.takenAt * 1000);
  return date.getFullYear().toString() + '年' + (date.getMonth() + 1).toString() + '月' + date.getDate().toString() + '日';
}

export function photoTimelineRows(items: NasPhotoItem[], columns: number,
  previous: PhotoTimelineRow[] = []): PhotoTimelineRow[] {
  if (items.length === 0) { return previous; }
  // 追加只重组最后一行；前面的行保留对象身份，避免虚拟列表重新绑定。
  const result = previous.slice();
  let previousDay: string = result.length === 0 ? '' : photoTakenDate(result[result.length - 1].items[0]);
  if (result.length > 0) {
    const tail = result[result.length - 1];
    result[result.length - 1] = { key: tail.key, title: tail.title, items: tail.items.slice() };
  }
  for (const item of items) {
    const day = photoTakenDate(item);
    const last = result.length === 0 ? undefined : result[result.length - 1];
    if (day !== previousDay || last === undefined || last.items.length >= columns) {
      result.push({ key: item.space.toString() + ':' + item.id.toString(), title: day !== previousDay ? day : '', items: [item] });
    } else { last.items.push(item); }
    previousDay = day;
  }
  return result;
}

export function photoMediaLabel(item: NasPhotoItem): string {
  return item.mediaType === 'video' ? '视频' : item.mediaType === 'live' ? '动态照片' : '照片';
}

export interface PhotoAlbumRow {
  key: string;
  albums: NasPhotoAlbum[];
}

export function workbenchBottomInset(navigationInset: number, barHeight: number = 56): number {
  return Math.max(0, navigationInset) + barHeight + 16;
}

/**
 * 快捷入口列数：固定一行五个。width 预留给将来的宽屏分档；目前不按宽度分档，
 * 免得同一台设备换个窗口就改分组、让第二行只落一项。
 */
export function workbenchShortcutColumns(width: number): number {
  return 5;
}

/** 列宽按列表内容区域计算，窄窗口仍保留三列。 */
export function workbenchFileGridColumns(width: number): number {
  return Math.max(3, Math.floor((width - 32 + 12) / 100));
}

/** 网格仅展示已有日期和文件大小，不推断目录数量。 */
export function workbenchFileGridMetadata(directory: boolean, modifiedAt: number | undefined,
  bytes: number | undefined): string {
  const date = workbenchRelativeDate(modifiedAt);
  if (directory || bytes === undefined) { return date; }
  const size = workbenchBytes(bytes);
  return date.length > 0 ? date + '\n' + size : size;
}

export function photoAlbumColumns(width: number): number {
  return Math.max(1, Math.min(4, Math.floor(Math.max(160, width - 32) / 160)));
}

export function photoAlbumRows(albums: NasPhotoAlbum[], columns: number, previous: PhotoAlbumRow[] = []): PhotoAlbumRow[] {
  if (albums.length === 0) { return previous; }
  const rows = previous.slice();
  const tail = rows.length === 0 ? undefined : rows[rows.length - 1];
  const remaining = albums.slice();
  if (tail !== undefined && tail.albums.length < columns) {
    rows[rows.length - 1] = { key: tail.key, albums: tail.albums.concat(remaining.splice(0, columns - tail.albums.length)) };
  }
  for (let offset = 0; offset < remaining.length; offset += columns) {
    const album = remaining[offset];
    rows.push({ key: album.space.toString() + ':' + album.id.toString(), albums: remaining.slice(offset, offset + columns) });
  }
  return rows;
}

/** 取出 origin 里的主机（含 IPv6 方括号），非法输入返回空串。 */
function originHost(origin: string): string {
  const trimmed = origin.trim();
  const marker = trimmed.indexOf('://');
  const rest = marker < 0 ? trimmed : trimmed.slice(marker + 3);
  const end = rest.search(/[\/?#]/);
  const authority = end < 0 ? rest : rest.slice(0, end);
  const at = authority.lastIndexOf('@');
  return (at < 0 ? authority : authority.slice(at + 1)).toLowerCase();
}

/** 内网地址：IPv4 私有段、IPv6 link-local/ULA、单段主机名、.local/.lan/.home 后缀。 */
function isPrivateHost(host: string): boolean {
  if (host.length === 0) { return false; }
  if (host.startsWith('[')) {
    const inside = host.slice(1, host.indexOf(']') < 0 ? undefined : host.indexOf(']'));
    return /^fe80:/i.test(inside) || /^f[cd][0-9a-f]{2}:/i.test(inside) || inside === '::1';
  }
  const name = host.split(':')[0];
  if (name.endsWith('.local') || name.endsWith('.lan') || name.endsWith('.home') || name.endsWith('.internal')) { return true; }
  const parts = name.split('.');
  if (parts.length === 1) { return true; }
  if (parts.length === 4 && parts.every((part: string): boolean => /^\d{1,3}$/.test(part))) {
    const first = Number(parts[0]);
    const second = Number(parts[1]);
    return first === 10 || first === 127 || (first === 169 && second === 254) ||
      (first === 172 && second >= 16 && second <= 31) || (first === 192 && second === 168);
  }
  return false;
}

/**
 * 连接方式文案（四字以内）：优先用地址簿登记的类型，否则按主机判断内网/公网。
 * 类型只是标记，不会真正探测链路，所以文案不带"连接"这类承诺性后缀。
 */
export function connectionRouteLabel(origin: string, kind?: string): string {
  if (kind === 'lan') { return '局域网'; }
  if (kind === 'remote') { return '公网'; }
  if (kind === 'private') { return '专网'; }
  return isPrivateHost(originHost(origin)) ? '局域网' : '公网';
}

export type WorkbenchUsageLevel = 'normal' | 'warning' | 'danger';

/** 存储与资源占用水位线分级：75% 告警、90% 危险。 */
export function workbenchUsageLevel(percentage: number | undefined): WorkbenchUsageLevel {
  if (percentage === undefined || !Number.isFinite(percentage)) { return 'normal'; }
  return percentage >= 90 ? 'danger' : percentage >= 75 ? 'warning' : 'normal';
}

/** 文件修改时间友好格式：同日显示今天，昨日显示昨天，其余显示年月日。 */
export function workbenchRelativeDate(seconds: number | undefined, nowMs: number = Date.now()): string {
  if (seconds === undefined || !Number.isFinite(seconds) || seconds <= 0) { return ''; }
  const date = new Date(Math.trunc(seconds * 1000));
  const now = new Date(nowMs);
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const startOfTarget = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
  const dayDiff = Math.round((startOfToday - startOfTarget) / 86400000);
  const pad = (value: number): string => value < 10 ? '0' + value.toString() : value.toString();
  if (dayDiff === 0) {
    return '今天 ' + pad(date.getHours()) + ':' + pad(date.getMinutes());
  }
  if (dayDiff === 1) {
    return '昨天 ' + pad(date.getHours()) + ':' + pad(date.getMinutes());
  }
  return date.getFullYear().toString() + '/' + pad(date.getMonth() + 1) + '/' + pad(date.getDate());
}

/** 登录地址栏协议与端口提示，让省略协议或端口时的实际连接方式一目了然。 */
export function workbenchProtocolHint(address: string, useHttps: boolean): string {
  const trimmed = address.trim();
  if (trimmed.length === 0) {
    return useHttps ? '默认使用 HTTPS 加密连接（端口 443，可附加 :5001）' :
      '当前选择 HTTP 明文连接（端口 80，可附加 :5000）';
  }
  const withoutScheme = trimmed.replace(/^https?:\/\//i, '').replace(/\/+$/, '');
  const scheme = useHttps ? 'https://' : 'http://';
  const hasPort = /:[0-9]{1,5}$/.test(withoutScheme);
  return '将通过 ' + scheme + withoutScheme + ' 连接' +
    (hasPort ? '' : useHttps ? '（未指定端口，若使用 DSM 默认端口请加 :5001）' : '（未指定端口，若使用 DSM 默认端口请加 :5000）');
}
