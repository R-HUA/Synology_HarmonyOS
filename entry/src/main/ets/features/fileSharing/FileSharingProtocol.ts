import { dsmFailure, nasInteger, nasRecord, nasString, NasErrorKind, NasFailure,
  normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import type { NasFormField } from '../../core/domain/DsmProtocol';

export const FILE_SHARING_API = 'SYNO.FileStation.Sharing';
export const FILE_SHARING_VERSION = 3;
export const SHARE_PASSWORD_MAX_LENGTH = 16;

export type SharePasswordMode = 'retain' | 'set' | 'remove';
export interface SharePasswordChange { mode: SharePasswordMode; value?: string; }
export interface ShareLinkOptions {
  password?: SharePasswordChange;
  availableDate?: string;
  expiredDate?: string;
}

export interface ShareLink {
  id: string;
  name: string;
  path: string;
  url: string;
  isFolder: boolean;
  hasPassword: boolean;
  availableDate: string;
  expiredDate: string;
  status: string;
  owner: string;
}

export interface ShareLinkPage { links: ShareLink[]; offset: number; total: number; }
export interface ShareCreateResult { path: string; id?: string; url?: string; failure?: NasFailure; }
export interface ShareIdResult { id: string; failure?: NasFailure; }

function invalid(message: string): NasFailure { return new NasFailure(NasErrorKind.InvalidInput, message); }
function malformed(): NasFailure {
  return new NasFailure(NasErrorKind.Protocol, '分享链接响应不符合预期，请刷新后核对结果。');
}

function validId(value: Object | undefined): boolean {
  return typeof value === 'string' && value.trim().length > 0 && !/[\u0000-\u001f\u007f-\u009f]/.test(value);
}

function validPath(value: Object | undefined): boolean {
  return typeof value === 'string' && value.startsWith('/') && value !== '/' &&
    !/[\u0000-\u001f\u007f-\u009f]/.test(value) &&
    value.slice(1).split('/').every((part: string): boolean => part.length > 0 && part !== '.' && part !== '..');
}

function validateIds(ids: string[]): void {
  if (!Array.isArray(ids) || ids.length === 0 || !Array.from(ids).every(validId) || new Set(ids).size !== ids.length) {
    throw invalid('请选择有效且不重复的分享链接。');
  }
}

function validDate(value: Object | undefined): boolean {
  if (value === '0') { return true; }
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) { return false; }
  const year = Number(value.slice(0, 4));
  const month = Number(value.slice(5, 7));
  const day = Number(value.slice(8, 10));
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return year > 0 && month >= 1 && month <= 12 && day >= 1 && day <= days[month - 1];
}

function optionFields(options: ShareLinkOptions): NasFormField[] {
  if (options === null || typeof options !== 'object' || Array.isArray(options)) {
    throw invalid('分享设置格式不正确。');
  }
  const fields: NasFormField[] = [];
  const password = options.password;
  if (password !== undefined) {
    if (password === null || typeof password !== 'object' || Array.isArray(password) ||
      !['retain', 'set', 'remove'].includes(password.mode)) { throw invalid('请选择保留、设置或移除分享口令。'); }
    if (password.mode === 'set') {
      if (typeof password.value !== 'string' || password.value.length === 0 ||
        Array.from(password.value).length > SHARE_PASSWORD_MAX_LENGTH ||
        /[\u0000-\u001f\u007f-\u009f]/.test(password.value)) {
        throw invalid('分享口令必须为 1 到 16 个字符，且不能包含控制字符。');
      }
      fields.push({ name: 'password', content: JSON.stringify(password.value) });
    } else {
      if (password.value !== undefined) { throw invalid('保留或移除口令时不能同时提供新口令。'); }
      if (password.mode === 'remove') { fields.push({ name: 'password', content: JSON.stringify('') }); }
    }
  }
  for (const name of ['availableDate', 'expiredDate']) {
    const value = name === 'availableDate' ? options.availableDate : options.expiredDate;
    if (value !== undefined) {
      if (!validDate(value)) { throw invalid('日期须为有效的 YYYY-MM-DD；填写 0 表示立即生效或永不过期。'); }
      fields.push({ name: name === 'availableDate' ? 'date_available' : 'date_expired',
        content: value === '0' ? '0' : JSON.stringify(value) });
    }
  }
  if (options.availableDate !== undefined && options.expiredDate !== undefined &&
    options.availableDate !== '0' && options.expiredDate !== '0' && options.availableDate > options.expiredDate) {
    throw invalid('生效日期不能晚于过期日期；日期按 NAS 端规则生效。');
  }
  return fields;
}

export function sharingListFields(offset: number, limit: number): NasFormField[] {
  if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 0) {
    throw invalid('分页起点和数量须为非负整数。');
  }
  return [{ name: 'offset', content: offset.toString() }, { name: 'limit', content: limit.toString() }];
}

export function sharingInfoFields(id: string): NasFormField[] {
  validateIds([id]);
  return [{ name: 'id', content: JSON.stringify(id) }];
}

export function sharingCreateFields(paths: string[], options: ShareLinkOptions): NasFormField[] {
  if (!Array.isArray(paths) || paths.length === 0 || !Array.from(paths).every(validPath) || new Set(paths).size !== paths.length) {
    throw invalid('请选择有效且不重复的文件或文件夹路径。');
  }
  return [{ name: 'path', content: JSON.stringify(paths) }].concat(optionFields(options));
}

export function sharingEditFields(id: string, options: ShareLinkOptions): NasFormField[] {
  const fields = sharingRemoveFields([id]);
  const changes = optionFields(options);
  if (changes.length === 0) { throw invalid('请至少修改一项分享设置。'); }
  return fields.concat(changes);
}

export function sharingRemoveFields(ids: string[]): NasFormField[] {
  validateIds(ids);
  return [{ name: 'id', content: JSON.stringify(ids) }];
}

export function sharingFailure(code: number): NasFailure {
  switch (code) {
    case 2000: return new NasFailure(NasErrorKind.Server, '分享链接不存在或已被撤销。', code);
    case 2001: return new NasFailure(NasErrorKind.Server, '分享链接数量已达 NAS 上限，请先撤销不需要的链接。', code);
    case 2002: return new NasFailure(NasErrorKind.Server, '无法访问分享链接，请确认链接状态与账号权限。', code);
    default: return dsmFailure(FILE_SHARING_API, code);
  }
}

function responseData(input: Object): Record<string, Object> {
  const envelope = nasRecord(input);
  let data = envelope;
  if (envelope['success'] !== undefined) {
    if (typeof envelope['success'] !== 'boolean') { throw malformed(); }
    if (envelope['success'] === false) {
      const code = nasInteger(nasRecord(envelope['error'])['code']);
      if (code === 0) { throw malformed(); }
      throw sharingFailure(code);
    }
    if (envelope['error'] !== undefined) { throw malformed(); }
    data = envelope['data'] === undefined ? {} : nasRecord(envelope['data']);
  }
  if (data['error'] !== undefined) {
    const code = nasInteger(nasRecord(data['error'])['code']);
    if (code === 0) { throw malformed(); }
    throw sharingFailure(code);
  }
  if (data['errors'] !== undefined) { throw malformed(); }
  return data;
}

export function validateShareUrl(value: string): string {
  if (typeof value !== 'string' || /[\s\u0000-\u001f\u007f-\u009f\\]/.test(value)) { throw malformed(); }
  const match = /^https?:\/\/([^/?#]+)(?:[/?#]|$)/i.exec(value);
  if (match === null || /[@%]/.test(match[1])) { throw malformed(); }
  try { normalizeNasOrigin('https://' + match[1]); } catch { throw malformed(); }
  let decoded: string;
  try { decoded = decodeURIComponent(value); } catch { throw malformed(); }
  if (/[\u0000-\u001f\u007f-\u009f\\]/.test(decoded)) { throw malformed(); }
  const sensitive = ['sid', '_sid', 'synotoken', 'syno_token', 'token', 'access_token', 'refresh_token',
    'authorization', 'auth', 'password', 'passwd', 'cookie', 'username', 'user', 'account', 'apikey',
    'api_key', 'secret', 'otp', 'csrf', 'csrf_token', 'x-syno-token'];
  const start = value.search(/[?#]/);
  if (start >= 0) {
    for (const part of value.slice(start + 1).split(/[?&#;]/)) {
      let key: string;
      try { key = decodeURIComponent(part.split('=')[0].replace(/\+/g, ' ')).toLowerCase(); }
      catch { throw malformed(); }
      if (key.includes('%') || sensitive.includes(key)) { throw malformed(); }
    }
  }
  return value;
}

function decodeLink(input: Object): ShareLink {
  const row = nasRecord(input);
  const id = nasString(row['id']);
  const path = nasString(row['path']);
  const available = nasString(row['date_available']);
  const expired = nasString(row['date_expired']);
  const folder = row['isFolder'];
  if (row['error'] !== undefined || !validId(id) || !validPath(path) || !validDate(available) || !validDate(expired) ||
    typeof row['has_password'] !== 'boolean' ||
    typeof folder !== 'boolean' && folder !== 'true' && folder !== 'false') { throw malformed(); }
  return { id: id, name: nasString(row['name']), path: path, url: validateShareUrl(nasString(row['url'])),
    isFolder: folder === true || folder === 'true', hasPassword: row['has_password'] === true,
    availableDate: available, expiredDate: expired, status: nasString(row['status']), owner: nasString(row['link_owner']) };
}

export function decodeShareInfo(input: Object, id: string): ShareLink {
  const link = decodeLink(responseData(input));
  if (link.id !== id) { throw malformed(); }
  return link;
}

export function decodeSharePage(input: Object, requestedOffset: number, limit: number): ShareLinkPage {
  const data = responseData(input);
  const offset = nasInteger(data['offset']);
  const total = nasInteger(data['total']);
  if (offset !== requestedOffset || !Array.isArray(data['links'])) { throw malformed(); }
  const links = (data['links'] as Object[]).map(decodeLink);
  if (limit > 0 && links.length > limit || links.length > 0 && offset + links.length > total ||
    new Set(links.map((link: ShareLink): string => link.id)).size !== links.length) { throw malformed(); }
  return { links: links, offset: offset, total: total };
}

export function decodeShareCreateResults(input: Object, paths: string[]): ShareCreateResult[] {
  const data = responseData(input);
  if (!Array.isArray(data['links']) || data['links'].length !== paths.length) { throw malformed(); }
  const results: ShareCreateResult[] = [];
  const identities = new Set<string>();
  for (const raw of data['links'] as Object[]) {
    const row = nasRecord(raw);
    const path = nasString(row['path']);
    const code = nasInteger(row['error']);
    if (!paths.includes(path) || results.some((result: ShareCreateResult): boolean => result.path === path)) {
      throw malformed();
    }
    if (code !== 0) { results.push({ path: path, failure: sharingFailure(code) }); }
    else {
      const id = nasString(row['id']);
      if (!validId(id) || identities.has(id)) { throw malformed(); }
      identities.add(id);
      results.push({ path: path, id: id, url: validateShareUrl(nasString(row['url'])) });
    }
  }
  return paths.map((path: string): ShareCreateResult => results.find((result: ShareCreateResult): boolean => result.path === path)!);
}

function mutationErrors(input: Object): Object[] {
  const envelope = nasRecord(input);
  let data = envelope;
  if (envelope['success'] !== undefined) {
    if (typeof envelope['success'] !== 'boolean') { throw malformed(); }
    if (envelope['success'] === false) {
      const error = nasRecord(envelope['error']);
      const code = nasInteger(error['code']);
      if (code === 0) { throw malformed(); }
      if (error['errors'] === undefined) { throw sharingFailure(code); }
      if (!Array.isArray(error['errors']) || error['errors'].length === 0) { throw malformed(); }
      return error['errors'] as Object[];
    }
    if (envelope['error'] !== undefined) { throw malformed(); }
    data = envelope['data'] === undefined ? {} : nasRecord(envelope['data']);
  }
  if (data['error'] !== undefined) {
    const error = nasRecord(data['error']);
    const code = nasInteger(error['code']);
    if (code === 0) { throw malformed(); }
    if (error['errors'] === undefined) { throw sharingFailure(code); }
    if (!Array.isArray(error['errors']) || error['errors'].length === 0 || Object.keys(data).length !== 1) {
      throw malformed();
    }
    return error['errors'] as Object[];
  }
  if (Object.keys(data).some((name: string): boolean => name !== 'errors') ||
    data['errors'] !== undefined && !Array.isArray(data['errors'])) { throw malformed(); }
  return data['errors'] === undefined ? [] : data['errors'] as Object[];
}

export function decodeShareIdResults(input: Object, ids: string[]): ShareIdResult[] {
  const failures = new Map<string, NasFailure>();
  for (const raw of mutationErrors(input)) {
    const row = nasRecord(raw);
    const id = nasString(row['id']);
    const code = nasInteger(row['code']);
    if (!ids.includes(id) || failures.has(id) || code === 0) { throw malformed(); }
    failures.set(id, sharingFailure(code));
  }
  return ids.map((id: string): ShareIdResult => {
    const failure = failures.get(id);
    return failure === undefined ? { id: id } : { id: id, failure: failure };
  });
}
