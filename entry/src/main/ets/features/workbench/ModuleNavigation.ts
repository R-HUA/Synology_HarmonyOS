import { DriveView, driveViewLabel } from '../../core/domain/DriveProtocol';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';

export type WorkbenchModule = 'root' | 'drive' | 'photos';
export interface ModuleTab { id: string; label: string; view?: DriveView; }
export const ROOT_TASK_TAB = 2;
export const ROOT_SETTINGS_TAB = 3;
export const DRIVE_MORE_VIEWS: DriveView[] = [DriveView.Recent, DriveView.Starred,
  DriveView.SharedWithMe, DriveView.SharedWithOthers, DriveView.Trash];
export const PHOTO_EXTRA_TABS: string[] = ['backup', 'transfers'];

export class ModuleTabSettings {
  drivePinned: string[] = [];
  photoPinned: string[] = [];
  showPhotoShared: boolean = true;
}

export function rootTabs(): ModuleTab[] {
  return [{ id: 'home', label: '首页' }, { id: 'files', label: '文件' },
    { id: 'tasks', label: '任务' }, { id: 'settings', label: '设置' }];
}

export function drivePinnedViews(supports: (view: DriveView) => boolean, pinned: string[]): DriveView[] {
  return DRIVE_MORE_VIEWS.filter((view: DriveView): boolean => pinned.includes(view) && supports(view))
    .sort((left: DriveView, right: DriveView): number => pinned.indexOf(left) - pinned.indexOf(right)).slice(0, 2);
}

export function driveMoreViews(supports: (view: DriveView) => boolean, pinned: string[]): DriveView[] {
  const promoted = drivePinnedViews(supports, pinned);
  return DRIVE_MORE_VIEWS.filter((view: DriveView): boolean => supports(view) && !promoted.includes(view));
}

export function driveTabs(supports: (view: DriveView) => boolean, pinned: string[]): ModuleTab[] {
  const roots = [DriveView.MyDrive, DriveView.TeamFolders].filter(supports);
  if (roots.length === 0 && !DRIVE_MORE_VIEWS.some(supports)) { return []; }
  const views = roots.concat(drivePinnedViews(supports, pinned));
  const tabs = views.map((view: DriveView): ModuleTab => ({ id: view, view: view,
    label: view === DriveView.TeamFolders ? '团队文件' : view === DriveView.SharedWithOthers ? '我共享的' : driveViewLabel(view) }));
  tabs.push({ id: 'more', label: '更多' });
  return tabs;
}

export function supportsPhotoSharing(supports: (api: string) => boolean): boolean {
  return supports('SYNO.FotoTeam.Browse.Item') || supports('SYNO.Foto.Sharing.Misc') || supports('SYNO.Foto.Browse.Album');
}

export function supportsPhotos(supports: (api: string) => boolean): boolean {
  return supports('SYNO.Foto.Browse.Item') || supportsPhotoSharing(supports);
}

export function supportsPhotoBackup(supports: (api: string) => boolean): boolean {
  return supportsPhotos(supports) && supports('SYNO.FileStation.Upload');
}

export function photoTabs(supports: (api: string) => boolean, showShared: boolean, pinned: string[]): ModuleTab[] {
  const browse = supportsPhotos(supports);
  const backup = supportsPhotoBackup(supports);
  if (!browse) { return []; }
  const tabs: ModuleTab[] = [];
  if (browse) { tabs.push({ id: 'photos', label: '照片' }, { id: 'albums', label: '相册' }); }
  if (showShared && supportsPhotoSharing(supports)) { tabs.push({ id: 'shared', label: '共享' }); }
  const extras = PHOTO_EXTRA_TABS.filter((id: string): boolean => pinned.includes(id) && (id !== 'backup' || backup))
    .sort((left: string, right: string): number => pinned.indexOf(left) - pinned.indexOf(right)).slice(0, Math.min(2, 4 - tabs.length));
  extras.forEach((id: string): void => { tabs.push({ id: id, label: id === 'backup' ? '备份' : '传输' }); });
  tabs.push({ id: 'more', label: '更多' });
  return tabs;
}

/** 按页签身份恢复索引，能力变化后不能沿用旧的数字位置。 */
export function moduleTabIndex(tabs: ModuleTab[], id: string): number {
  return Math.max(0, tabs.findIndex((tab: ModuleTab): boolean => tab.id === id));
}

export function rootReturnIndex(index: number): number {
  return Number.isInteger(index) && index >= 0 && index < 4 ? index : 0;
}

export function decodeModuleTabSettings(text: string): ModuleTabSettings {
  let value: Object;
  try { value = JSON.parse(text) as Object; }
  catch (_) { throw new NasFailure(NasErrorKind.Protocol, '底栏设置无法读取，请重试。'); }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new NasFailure(NasErrorKind.Protocol, '底栏设置格式不正确，请重试。');
  }
  const data = value as Record<string, Object>;
  if (!Array.isArray(data['drivePinned']) || !Array.isArray(data['photoPinned']) || typeof data['showPhotoShared'] !== 'boolean' ||
    !(data['drivePinned'] as Object[]).every((id: Object): boolean => typeof id === 'string') ||
    !(data['photoPinned'] as Object[]).every((id: Object): boolean => typeof id === 'string')) {
    throw new NasFailure(NasErrorKind.Protocol, '底栏设置格式不正确，请重试。');
  }
  const settings = new ModuleTabSettings();
  settings.drivePinned = drivePinnedViews((): boolean => true, data['drivePinned'] as string[]);
  settings.photoPinned = PHOTO_EXTRA_TABS.filter((id: string): boolean => (data['photoPinned'] as string[]).includes(id))
    .sort((left: string, right: string): number => (data['photoPinned'] as string[]).indexOf(left) - (data['photoPinned'] as string[]).indexOf(right));
  settings.showPhotoShared = data['showPhotoShared'] as boolean;
  return settings;
}
