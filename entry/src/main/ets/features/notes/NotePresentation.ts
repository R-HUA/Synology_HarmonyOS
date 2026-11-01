import { NoteFolder, NoteSummary } from './NoteProtocol';
import { workbenchRelativeDate } from '../workbench/WorkbenchPresentation';

/** 笔记列表行的展示数据：业务身份 id 作为列表键，副标题由已加载的笔记本／标签名称派生。 */
export interface NoteRowView { id: string; title: string; subtitle: string; item: NoteSummary; }

/** 仅展示能匹配的名称与已提供的修改时间，缺失元数据不占位。 */
export function noteSubtitle(item: NoteSummary, notebooks: NoteFolder[], tags: NoteFolder[]): string {
  const parts: string[] = [];
  const notebook = notebooks.find((folder: NoteFolder): boolean => folder.id === item.notebook);
  if (notebook !== undefined) { parts.push(notebook.title); }
  const titles = new Set<string>(tags.map((folder: NoteFolder): string => folder.title));
  const named = item.tags.filter((tag: string): boolean => titles.has(tag));
  if (named.length > 0) { parts.push(named.join('、')); }
  const modified = workbenchRelativeDate(item.modified);
  if (modified.length > 0) { parts.push(modified); }
  return parts.join('  ');
}

export function noteRows(items: NoteSummary[], notebooks: NoteFolder[], tags: NoteFolder[]): NoteRowView[] {
  return items.map((item: NoteSummary): NoteRowView => ({ id: item.id, title: item.title, subtitle: noteSubtitle(item, notebooks, tags), item }));
}

/** 当前筛选值对应的名称；未选或已不在列表中时返回空串，由界面显示“全部…”。 */
export function folderTitle(folders: NoteFolder[], id: string): string {
  if (id.length === 0) { return ''; }
  return folders.find((folder: NoteFolder): boolean => folder.id === id)?.title ?? '';
}

/** 正文块键：笔记身份 + 版本 + 序号，不再整块 JSON 序列化。 */
export function noteBlockKey(noteId: string, version: string, index: number): string {
  return noteId + ':' + version + ':' + index.toString();
}
