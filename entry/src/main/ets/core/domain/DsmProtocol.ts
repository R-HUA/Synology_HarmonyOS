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

/** 来源：File Station 官方指南的公共错误码与各整理接口错误表。 */
function fileStationFailureMessage(api: string, code: number): string | undefined {
  switch (code) {
    case 105: case 403: case 404: case 405: case 407:
      return '当前账号没有执行此操作的权限。';
    case 400: return '文件操作参数不正确。';
    case 401: return 'NAS 执行文件操作时发生未知错误。';
    case 402: return 'NAS 当前繁忙，暂时无法执行文件操作。';
    case 406: return 'NAS 无法获取账号或用户组信息。';
    case 408: return '文件或文件夹不存在，请刷新目录后确认。';
    case 409: return '当前文件系统不支持此操作。';
    case 410: return 'NAS 无法连接远程文件系统。';
    case 411: return '当前文件系统为只读，无法修改文件。';
    case 412: return '文件名称过长，请缩短名称。';
    case 413: return '文件名称超过加密文件系统的长度限制，请缩短名称。';
    case 414: return '已存在同名文件或文件夹，请更换名称。';
    case 415: return '已超过磁盘配额，无法完成文件操作。';
    case 416: return '存储空间不足，无法完成文件操作。';
    case 417: return 'NAS 读写文件失败，请检查存储设备状态。';
    case 418: return '文件名称或路径不符合 NAS 的要求。';
    case 419: return '文件名称不符合 NAS 的要求。';
    case 420: return '文件名称不符合目标 FAT 文件系统的要求。';
    case 421: return '设备或文件资源正在使用中，暂时无法完成操作。';
    case 599: return '文件操作任务不存在，无法查询或停止，请刷新目录确认结果。';
  }
  if (api === 'SYNO.FileStation.Delete' && code === 900) {
    return '删除未全部完成，请刷新目录确认结果。';
  }
  if (api === 'SYNO.FileStation.CopyMove') {
    switch (code) {
      case 1000: return '复制未全部完成，请刷新目标目录确认结果。';
      case 1001: return '移动未全部完成，请刷新源目录和目标目录确认结果。';
      case 1002: return '目标目录发生错误，无法完成复制或移动。';
      case 1003: return '目标目录已存在同名文件或文件夹，请更换名称或目标目录。';
      case 1004: return '目标位置存在同名但类型不同的文件或文件夹，无法覆盖。';
      case 1006: return '目标 FAT32 文件系统不支持所选文件或文件夹名称中的字符。';
      case 1007: return '目标 FAT32 文件系统不支持超过 4 GB 的文件。';
    }
  }
  if (api === 'SYNO.FileStation.CreateFolder') {
    if (code === 1100) { return '文件夹创建失败。'; }
    if (code === 1101) { return '新建后该目录内的文件夹数量将超过系统限制，无法创建。'; }
  }
  if (api === 'SYNO.FileStation.Rename' && code === 1200) { return '重命名失败，请刷新目录确认结果。'; }
  return undefined;
}

function fileStationFailureDetail(api: string, errors: Object | undefined): string | undefined {
  if (!Array.isArray(errors)) { return undefined; }
  // 详情仅补充已知原因；缺失或不合规的详情不能掩盖已确认的主错误。
  for (const raw of errors as Object[]) {
    if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) { continue; }
    const code = (raw as Record<string, Object>)['code'];
    if (typeof code !== 'number' || !Number.isSafeInteger(code) || code < 0) { continue; }
    const message = fileStationFailureMessage(api, code);
    if (message !== undefined) { return message; }
  }
  return undefined;
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
  const fileMessage = api.startsWith('SYNO.FileStation.') ? fileStationFailureMessage(api, code) : undefined;
  if (code === 105 || code === 402 && api === 'SYNO.API.Auth' ||
    api.startsWith('SYNO.FileStation.') && [403, 404, 405, 407, 411].includes(code)) {
    return new NasFailure(NasErrorKind.Permission, fileMessage === undefined ? '当前账号没有执行此操作的权限。' : fileMessage, code);
  }
  if ([102, 103, 104].includes(code)) { return new NasFailure(NasErrorKind.Unsupported, '当前 DSM 不支持所需的接口或版本。', code); }
  return new NasFailure(NasErrorKind.Server, fileMessage === undefined ? 'DSM 未完成请求（错误码 ' + code.toString() + '）。' : fileMessage, code);
}

/** HTTP 成功与业务成功分别校验；不向 UI 传播原始响应或敏感数据。 */
export function decodeNasResponse(api: string, status: number, text: string): Record<string, Object> {
  if (status >= 300 && status < 400) { throw new NasFailure(NasErrorKind.Http, '服务器要求跳转，请直接填写最终的 HTTPS 地址。', status); }
  if (status !== 200) { throw new NasFailure(NasErrorKind.Http, '服务器 HTTP 请求失败（' + status.toString() + '）。', status); }
  let parsed: Object;
  try { parsed = JSON.parse(text) as Object; } catch { throw protocolError(); }
  const envelope = nasRecord(parsed);
  if (typeof envelope['success'] !== 'boolean') { throw protocolError(); }
  if (envelope['success'] === false) {
    const error = nasRecord(envelope['error']);
    const failure = dsmFailure(api, nasInteger(error['code']));
    if (api.startsWith('SYNO.FileStation.') && [900, 1000, 1001, 1002, 1100, 1200].includes(failure.code)) {
      const detail = fileStationFailureDetail(api, error['errors']);
      if (detail !== undefined && detail !== failure.message) { failure.message += ' 原因：' + detail; }
    }
    throw failure;
  }
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
