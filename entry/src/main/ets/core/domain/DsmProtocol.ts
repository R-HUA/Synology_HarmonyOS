export enum NasErrorKind {
  InvalidInput, Network, Tls, Http, Protocol, Unsupported, Credentials, OtpRequired,
  OtpInvalid, Permission, SessionExpired, Cancelled, Server
}

export class NasFailure extends Error {
  constructor(public kind: NasErrorKind, message: string, public code: number = 0) {
    super(message);
    this.name = 'NasFailure';
  }
}

export interface NasApiDescriptor {
  name: string;
  path: string;
  minVersion: number;
  maxVersion: number;
  jsonParameters: boolean;
}

export interface NasFileEntry {
  path: string;
  name: string;
  isDirectory: boolean;
  bytes?: number;
}

export interface NasFileInfo extends NasFileEntry { bytes: number; }

export interface NasFilePage {
  entries: NasFileEntry[];
  offset: number;
  total: number;
}

export interface NasLoginSession {
  sid: string;
  synoToken: string;
}

export interface NasFormField { name: string; content: string; }

/** 连接只接受 HTTPS origin；禁止凭证、路径和跨 origin 跳转入口。 */
export function normalizeNasOrigin(input: string): string {
  const match = /^https:\/\/(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9.-]+)(?::([0-9]{1,5}))?\/?$/.exec(input.trim());
  if (match === null) {
    throw new NasFailure(NasErrorKind.InvalidInput, '请输入 HTTPS 地址，可包含端口，不包含路径或账号密码。');
  }
  const host = match[1].toLowerCase();
  if (!host.startsWith('[') && !host.split('.').every((part: string): boolean =>
    /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(part) && part.length <= 63)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '服务器域名格式不正确。');
  }
  const port = match[2] === undefined ? 443 : Number(match[2]);
  if (port < 1 || port > 65535) { throw new NasFailure(NasErrorKind.InvalidInput, '端口必须在 1 到 65535 之间。'); }
  return 'https://' + host + (port === 443 ? '' : ':' + port.toString());
}

export function validateApiPath(path: string): string {
  if (!/^[a-zA-Z0-9_-]+(?:\/[a-zA-Z0-9_-]+)*\.cgi$/.test(path)) {
    throw new NasFailure(NasErrorKind.Protocol, '服务器返回了不安全的 API 路径。');
  }
  return path;
}

export function encodeNasForm(fields: NasFormField[]): string {
  return fields.map((field: NasFormField): string =>
    encodeURIComponent(field.name) + '=' + encodeURIComponent(field.content)).join('&');
}

function protocolError(): NasFailure {
  return new NasFailure(NasErrorKind.Protocol, '服务器响应格式不符合预期，请检查 DSM 地址与套件版本。');
}

export function nasRecord(input: Object | null | undefined): Record<string, Object> {
  if (input === null || input === undefined || typeof input !== 'object' || Array.isArray(input)) { throw protocolError(); }
  return input as Record<string, Object>;
}

export function nasString(input: Object | undefined): string {
  if (typeof input !== 'string' || input.length === 0) { throw protocolError(); }
  return input as string;
}

export function nasInteger(input: Object | undefined): number {
  if (typeof input !== 'number' || !Number.isSafeInteger(input) || (input as number) < 0) { throw protocolError(); }
  return input as number;
}

export function dsmFailure(api: string, code: number): NasFailure {
  if (code === 150) { return new NasFailure(NasErrorKind.SessionExpired, '网络地址已变化，请重新登录 NAS。', code); }
  if ([106, 107, 119].includes(code)) { return new NasFailure(NasErrorKind.SessionExpired, '登录已失效，请重新登录。', code); }
  if (api === 'SYNO.API.Auth') {
    switch (code) {
      case 400: return new NasFailure(NasErrorKind.Credentials, '账号或密码不正确。', code);
      case 401: return new NasFailure(NasErrorKind.Permission, '该账号已停用。', code);
      case 403: case 406: return new NasFailure(NasErrorKind.OtpRequired, '请输入双重验证动态码。', code);
      case 404: return new NasFailure(NasErrorKind.OtpInvalid, '动态码验证失败，请输入新的动态码。', code);
      case 407: return new NasFailure(NasErrorKind.Permission, '当前网络地址已被 DSM 封锁，请在 DSM 检查。', code);
      case 408: case 409: case 410:
        return new NasFailure(NasErrorKind.Credentials, '密码已到期或需要修改，请先在 DSM 网页处理。', code);
    }
  }
  if (code === 105 || code === 402 && api === 'SYNO.API.Auth' ||
    api.startsWith('SYNO.FileStation.') && [403, 404, 405, 407, 411].includes(code)) {
    return new NasFailure(NasErrorKind.Permission, '当前账号没有执行此操作的权限。', code);
  }
  if ([102, 103, 104].includes(code)) { return new NasFailure(NasErrorKind.Unsupported, '当前 DSM 不支持所需的接口或版本。', code); }
  return new NasFailure(NasErrorKind.Server, 'DSM 未完成请求（错误码 ' + code.toString() + '）。', code);
}

/** HTTP 成功与业务成功分别校验；不向 UI 传播原始响应或敏感数据。 */
export function decodeNasResponse(api: string, status: number, text: string): Record<string, Object> {
  if (status >= 300 && status < 400) { throw new NasFailure(NasErrorKind.Http, '服务器要求跳转，请直接填写最终的 HTTPS 地址。', status); }
  if (status !== 200) { throw new NasFailure(NasErrorKind.Http, '服务器 HTTP 请求失败（' + status.toString() + '）。', status); }
  let parsed: Object;
  try { parsed = JSON.parse(text) as Object; } catch { throw protocolError(); }
  const envelope = nasRecord(parsed);
  if (typeof envelope['success'] !== 'boolean') { throw protocolError(); }
  if (envelope['success'] === false) { throw dsmFailure(api, nasInteger(nasRecord(envelope['error'])['code'])); }
  // 登出和上传的空 success 响应是公开合同的一部分。
  return envelope['data'] === undefined ? {} : nasRecord(envelope['data']);
}

export function decodeCapabilities(data: Record<string, Object>): NasApiDescriptor[] {
  return Object.keys(data).map((name: string): NasApiDescriptor => {
    const row = nasRecord(data[name]);
    const minimum = nasInteger(row['minVersion']);
    const maximum = nasInteger(row['maxVersion']);
    if (minimum < 1 || maximum < minimum) { throw protocolError(); }
    if (row['requestFormat'] !== undefined && typeof row['requestFormat'] !== 'string') { throw protocolError(); }
    return { name: name, path: validateApiPath(nasString(row['path'])), minVersion: minimum,
      maxVersion: maximum, jsonParameters: row['requestFormat'] === 'JSON' };
  });
}

/** 只选择客户端已核对的版本，不使用服务端最大版本作为默认值。 */
export function selectNasApi(capabilities: NasApiDescriptor[], name: string, versions: number[]): NasApiDescriptor {
  const api = capabilities.find((row: NasApiDescriptor): boolean => row.name === name);
  if (api === undefined || !versions.some((version: number): boolean => version >= api.minVersion && version <= api.maxVersion)) {
    throw new NasFailure(NasErrorKind.Unsupported, '服务器不支持已验证的 ' + name + ' 接口版本。');
  }
  return api;
}

export function decodeNasSession(data: Record<string, Object>): NasLoginSession {
  const sid = nasString(data['sid']);
  // RFC 6265 cookie-octet；拒绝能注入额外 Cookie 或请求头的分隔符与控制字符。
  if (!/^[\x21\x23-\x2b\x2d-\x3a\x3c-\x5b\x5d-\x7e]+$/.test(sid)) { throw protocolError(); }
  const token = data['synotoken'] === undefined ? '' : nasString(data['synotoken']);
  if (token.length > 0 && !/^[\x21-\x7e]+$/.test(token)) { throw protocolError(); }
  return { sid: sid, synoToken: token };
}

export function validateLogicalPath(path: string): string {
  if (!path.startsWith('/') || path === '/' || /[\u0000-\u001f]/.test(path) ||
    path.split('/').some((part: string): boolean => part === '.' || part === '..')) {
    throw new NasFailure(NasErrorKind.Protocol, '文件逻辑路径不正确。');
  }
  return path;
}

/** getinfo 必须匹配唯一目标并包含大小，防止错误对象或其它文件被当成校验结果。 */
export function decodeNasFileInfo(data: Record<string, Object>, requestedPath: string): NasFileInfo {
  validateLogicalPath(requestedPath);
  const files = data['files'];
  if (!Array.isArray(files) || files.length !== 1) { throw protocolError(); }
  const row = nasRecord((files as Object[])[0]);
  const path = validateLogicalPath(nasString(row['path']));
  if (path !== requestedPath || typeof row['isdir'] !== 'boolean' || row['error'] !== undefined) {
    throw protocolError();
  }
  return { path: path, name: nasString(row['name']), isDirectory: row['isdir'] === true,
    bytes: nasInteger(nasRecord(row['additional'])['size']) };
}

export function decodeNasFilePage(data: Record<string, Object>, shares: boolean, requestedOffset: number, limit: number): NasFilePage {
  const offset = nasInteger(data['offset']);
  const total = nasInteger(data['total']);
  const rawEntries = data[shares ? 'shares' : 'files'];
  if (!Array.isArray(rawEntries) || offset !== requestedOffset || offset > total) { throw protocolError(); }
  const entries = (rawEntries as Object[]).map((raw: Object): NasFileEntry => {
    const row = nasRecord(raw);
    if (!shares && typeof row['isdir'] !== 'boolean') { throw protocolError(); }
    const additional = row['additional'] === undefined ? undefined : nasRecord(row['additional']);
    return { path: validateLogicalPath(nasString(row['path'])), name: nasString(row['name']),
      isDirectory: shares || row['isdir'] === true,
      bytes: additional === undefined || additional['size'] === undefined ? undefined : nasInteger(additional['size']) };
  });
  const identities = new Set<string>();
  for (const entry of entries) {
    if (identities.has(entry.path)) { throw protocolError(); }
    identities.add(entry.path);
  }
  if (entries.length > limit || offset + entries.length > total || entries.length === 0 && offset < total) { throw protocolError(); }
  return { entries: entries, offset: offset, total: total };
}
