import { nasRecord, NasFailure, NasErrorKind } from '../../core/domain/DsmProtocol';
import { readArray, readId, readText, readNumber, readableLog } from '../../core/domain/ReadOnlyProtocol';

export interface NoteFolder { id: string; title: string; }
export interface NoteSummary { id: string; title: string; notebook: string; tags: string[]; modified?: number; }
export interface NotePage { items: NoteSummary[]; received: number; more: boolean; }
export interface NoteAttachment { noteId: string; version: string; fileId: string; name: string; bytes: number | undefined; type: string; ref: string; }
export interface NoteSpan { text: string; bold: boolean; italic: boolean; href: string; }
export interface NoteBlock { kind: string; level: number; spans: NoteSpan[]; attachmentId: string; }
export interface NoteBody { blocks: NoteBlock[]; complex: boolean; }
export interface NoteDetail { item: NoteSummary; version: string; body: NoteBody; attachments: NoteAttachment[]; bodyProvided: boolean; }

function unique(ids: string[]): void {
  if (new Set(ids).size !== ids.length) { throw new NasFailure(NasErrorKind.Protocol, '笔记条目标识重复。'); }
}
export function decodeNotebooks(data: Object): NoteFolder[] {
  const result = readArray(Array.isArray(data) ? data : data['notebooks']).map((value: Object): NoteFolder => {
    const row = nasRecord(value); return { id: readId(row['object_id']), title: readText(row['title']) || '未命名笔记本' };
  }); unique(result.map((row: NoteFolder): string => row.id)); return result;
}
export function decodeNoteTags(data: Object): NoteFolder[] {
  const result = readArray(Array.isArray(data) ? data : data['tags']).map((value: Object): NoteFolder => {
    const row = nasRecord(value), title = readText(row['title']);
    if (title.length === 0) { throw new NasFailure(NasErrorKind.Protocol, '服务器返回的标签名称无效。'); }
    return { id: readId(row['tag_id']), title };
  }); unique(result.map((row: NoteFolder): string => row.id)); return result;
}
function summary(row: Record<string, Object>): NoteSummary {
  const tag = row['tag'], modified = readNumber(row['mtime']);
  if (modified !== undefined && (modified < 0 || modified > 8640000000000)) {
    throw new NasFailure(NasErrorKind.Protocol, '笔记修改时间无效。');
  }
  return { id: readId(row['object_id']), title: readText(row['title']) || '未命名笔记',
    notebook: row['parent_id'] === undefined ? '' : readId(row['parent_id']),
    tags: tag === undefined || tag === null || tag === '' ? [] : (Array.isArray(tag) ? tag : [tag]).map((value: Object): string => readId(value)), modified };
}
export function decodeNotes(data: Object, offset: number): NotePage {
  const rows = readArray(Array.isArray(data) ? data : data['notes']);
  if (rows.length > 100) { throw new NasFailure(NasErrorKind.Protocol, '笔记列表超过单次读取范围。'); }
  const items = rows.map((value: Object): NoteSummary => summary(nasRecord(value))); unique(items.map((item: NoteSummary): string => item.id));
  const total = readNumber(data['total']);
  return { items, received: rows.length, more: rows.length === 100 && (total === undefined || offset + rows.length < total) };
}
export function decodeNoteDetail(data: Object, id: string): NoteDetail {
  const row = nasRecord(data), item = summary(row);
  if (item.id !== id) { throw new NasFailure(NasErrorKind.Protocol, '笔记详情与所选笔记不匹配。'); }
  const version = row['ver'] === undefined ? '' : readId(row['ver']);
  const attachments: NoteAttachment[] = [];
  const append = (fileId: string, value: Object): void => {
    const meta = nasRecord(value), bytes = readNumber(meta['size']);
    if (bytes !== undefined && (!Number.isSafeInteger(bytes) || bytes < 0)) { throw new NasFailure(NasErrorKind.Protocol, '附件大小无效。'); }
    attachments.push({ noteId: id, version, fileId, name: readText(meta['name']) || '笔记附件', bytes,
      type: readText(meta['type']), ref: readText(meta['ref']) });
  };
  if (Array.isArray(row['attachment'])) {
    for (const value of row['attachment'] as Object[]) { append(readId(nasRecord(value)['file_id']), value); }
  } else if (row['attachment'] !== undefined && row['attachment'] !== null) {
    const map = nasRecord(row['attachment']); for (const key of Object.keys(map)) { append(readId(key), map[key]); }
  }
  unique(attachments.map((item: NoteAttachment): string => item.fileId));
  const bodyProvided = typeof row['content'] === 'string' && row['encrypt'] !== true;
  if (row['content'] !== undefined && typeof row['content'] !== 'string') { throw new NasFailure(NasErrorKind.Protocol, '笔记正文格式无效。'); }
  return { item, version, body: bodyProvided ? parseNoteBody(readText(row['content']), attachments) : { blocks: [], complex: false }, attachments, bodyProvided };
}
export function noteAttachmentKey(item: NoteAttachment): string { return JSON.stringify([item.noteId, item.version, item.fileId]); }
export function assertNoteAttachment(detail: NoteDetail, attachment: NoteAttachment): void {
  const found = detail.attachments.find((item: NoteAttachment): boolean => item.fileId === attachment.fileId);
  if (detail.item.id !== attachment.noteId || detail.version !== attachment.version || found === undefined ||
    found.bytes !== attachment.bytes || found.name !== attachment.name || found.type !== attachment.type) {
    throw new NasFailure(NasErrorKind.Protocol, '笔记或附件已变化，请刷新笔记后重试。');
  }
}
/** 标签列表保留独立编号，笔记关联与群晖的标签查询均使用名称。 */
export function filterNotes(items: NoteSummary[], notebook: string, tag: string, query: string, tags: NoteFolder[]): NoteSummary[] {
  const selectedTag = tags.find((item: NoteFolder): boolean => item.id === tag);
  return items.filter((item: NoteSummary): boolean => (notebook.length === 0 || item.notebook === notebook) &&
    (tag.length === 0 || selectedTag !== undefined && item.tags.includes(selectedTag.title)) && item.title.toLowerCase().includes(query.trim().toLowerCase()));
}
export function noteLink(value: string): string {
  return /^https?:\/\/[^\s\u0000-\u001f<>"']+$/i.test(value) ? value : '';
}
function entities(text: string): string {
  return readableLog(text.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi, (whole: string, code: string): string => {
    if (code[0] === '#') {
      const point = code[1].toLowerCase() === 'x' ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
      return point > 0 && point <= 0x10ffff && !(point >= 0xd800 && point <= 0xdfff) ? String.fromCodePoint(point) : '';
    }
    switch (code.toLowerCase()) { case 'amp': return '&'; case 'lt': return '<'; case 'gt': return '>'; case 'quot': return '"'; case 'apos': return "'"; default: return ' '; }
  }));
}
function attribute(token: string, name: string): string {
  const match = new RegExp('\\s' + name + '\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))', 'i').exec(token);
  return match === null ? '' : entities(match[1] === undefined ? match[2] === undefined ? match[3] : match[2] : match[1]);
}

/** 仅转换原生基础块，图片必须对应当前笔记附件；正文不触发网络加载。 */
export function parseNoteBody(html: string, attachments: NoteAttachment[]): NoteBody {
  const blocks: NoteBlock[] = []; let spans: NoteSpan[] = [], kind = 'paragraph', level = 0, bold = 0, italic = 0;
  const links: string[] = [], lists: number[] = []; let complex = false;
  const clean = html.replace(/<!--[^]*?-->/g, '').replace(/<(script|style|iframe)\b[^>]*>[^]*?<\/\1\s*>/gi, '');
  const tokens = clean.match(/<[^>]*>|[^<]+|</g) || [];
  const flush = (): void => {
    if (spans.some((span: NoteSpan): boolean => span.text.trim().length > 0)) { blocks.push({ kind, level, spans, attachmentId: '' }); }
    spans = []; kind = 'paragraph'; level = 0;
  };
  for (const token of tokens) {
    if (token[0] !== '<' || token === '<') {
      const text = entities(token).replace(/\s+/g, ' ');
      if (text.length > 0) { spans.push({ text, bold: bold > 0, italic: italic > 0, href: links.length > 0 ? links[links.length - 1] : '' }); }
      continue;
    }
    const match = /^<\s*(\/?)\s*([a-z0-9]+)/i.exec(token); if (match === null) { complex = true; continue; }
    const closing = match[1] === '/', tag = match[2].toLowerCase();
    if (/^h[1-6]$/.test(tag)) { flush(); if (!closing) { kind = 'heading'; level = Number(tag[1]); } }
    else if (tag === 'p' || tag === 'div' || tag === 'br') { flush(); }
    else if (tag === 'ul' || tag === 'ol') { flush(); if (closing) { lists.pop(); } else { lists.push(tag === 'ol' ? 1 : 0); } }
    else if (tag === 'li') {
      flush(); if (!closing) { kind = 'list'; const index = lists.length - 1, count = lists[index] || 0;
        spans.push({ text: count > 0 ? count + '. ' : '• ', bold: false, italic: false, href: '' }); if (count > 0) { lists[index]++; } }
    }
    else if (tag === 'b' || tag === 'strong') { bold = Math.max(0, bold + (closing ? -1 : 1)); }
    else if (tag === 'i' || tag === 'em') { italic = Math.max(0, italic + (closing ? -1 : 1)); }
    else if (tag === 'a') { if (closing) { links.pop(); } else { links.push(noteLink(attribute(token, 'href'))); } }
    else if (tag === 'img' && !closing) {
      flush(); const ref = attribute(token, 'ref'), found = attachments.filter((item: NoteAttachment): boolean => ref.length > 0 && item.ref === ref && item.type.startsWith('image/'));
      if (found.length === 1) { blocks.push({ kind: 'image', level: 0, spans: [], attachmentId: found[0].fileId }); }
      else { complex = true; const alt = attribute(token, 'alt'); if (alt.length > 0) { spans.push({ text: alt, bold: false, italic: false, href: '' }); } }
    }
    else if (tag !== 'span' && tag !== 'body' && tag !== 'html') { complex = true; if (['table', 'tr', 'td', 'blockquote', 'pre'].includes(tag)) { flush(); } }
  }
  flush(); return { blocks, complex };
}
