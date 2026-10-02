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
  return Math.max(2, Math.min(6, Math.floor(Math.max(216, width - 32) / 108)));
}

export function photoTakenDate(item: NasPhotoItem): string {
  if (item.takenAt === undefined) { return '拍摄时间未提供'; }
  const date = new Date(item.takenAt * 1000);
  return date.getFullYear().toString() + '年' + (date.getMonth() + 1).toString() + '月' + date.getDate().toString() + '日';
}

export function photoTimelineRows(items: NasPhotoItem[], columns: number): PhotoTimelineRow[] {
  const result: PhotoTimelineRow[] = [];
  let previousMonth: string = '';
  for (const item of items) {
    const date = item.takenAt === undefined ? undefined : new Date(item.takenAt * 1000);
    const month = date === undefined ? '拍摄时间未提供' : date.getFullYear().toString() + '年' + (date.getMonth() + 1).toString() + '月';
    const last = result.length === 0 ? undefined : result[result.length - 1];
    if (month !== previousMonth || last === undefined || last.items.length >= columns) {
      result.push({ key: item.space.toString() + ':' + item.id.toString(), title: month !== previousMonth ? month : '', items: [item] });
    } else { last.items.push(item); }
    previousMonth = month;
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

export function workbenchShortcutColumns(width: number): number {
  return width >= 600 ? 4 : 2;
}

export function photoAlbumColumns(width: number): number {
  return Math.max(1, Math.min(4, Math.floor(Math.max(160, width - 32) / 160)));
}

export function photoAlbumRows(albums: NasPhotoAlbum[], columns: number): PhotoAlbumRow[] {
  const rows: PhotoAlbumRow[] = [];
  for (let offset = 0; offset < albums.length; offset += columns) {
    const album = albums[offset];
    rows.push({ key: album.space.toString() + ':' + album.id.toString(), albums: albums.slice(offset, offset + columns) });
  }
  return rows;
}
