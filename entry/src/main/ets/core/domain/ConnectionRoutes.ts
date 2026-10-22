import { nasRecord, nasInteger, nasOriginScheme, NasErrorKind, NasFailure, normalizeNasOrigin } from './DsmProtocol';

export type NasConnectionRouteKind = 'lan' | 'remote' | 'private';

export interface NasConnectionDeviceBinding { account: string; fingerprint: string; model: string; }

export interface NasConnectionAddress {
  origin: string;
  name: string;
  kind: NasConnectionRouteKind;
  /** 仅 https 地址有效：用户显式选择跳过服务器证书校验。 */
  insecureTls?: boolean;
  /** 风险确认只适用于本记录的完整地址与证书策略。 */
  riskConfirmedAt?: number;
  device?: NasConnectionDeviceBinding;
  lastLoginAt?: number;
}

export interface NasConnectionDeviceIdentity { model: string; serial: string; }

interface ConnectionAddressBookSnapshot { version: number; addresses: NasConnectionAddress[]; }

export const MAX_NAS_CONNECTION_ADDRESSES = 8;

function addressRecord(input: Object): Record<string, Object> {
  if (input === null || typeof input !== 'object' || Array.isArray(input)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '连接地址记录格式不正确。');
  }
  return input as Record<string, Object>;
}

function validateFields(row: Record<string, Object>, fields: string[]): void {
  if (Object.keys(row).some((field: string): boolean => !fields.includes(field))) {
    throw new NasFailure(NasErrorKind.InvalidInput, '连接地址记录包含不支持的字段，请勿保存密码或登录凭据。');
  }
}

function addressText(input: Object | undefined, label: string, limit: number, trim: boolean): string {
  if (typeof input !== 'string' || /[\u0000-\u001f\u007f-\u009f]/.test(input as string)) {
    throw new NasFailure(NasErrorKind.InvalidInput, label + '格式不正确，不能包含控制字符。');
  }
  const text = trim ? (input as string).trim() : input as string;
  if (text.trim().length === 0 || text.length > limit) {
    throw new NasFailure(NasErrorKind.InvalidInput, label + '不能为空，且不能超过 ' + limit.toString() + ' 个字符。');
  }
  return text;
}

function validateDeviceBinding(input: Object): NasConnectionDeviceBinding {
  const row = addressRecord(input);
  validateFields(row, ['account', 'fingerprint', 'model']);
  const fingerprint = row['fingerprint'];
  if (typeof fingerprint !== 'string' || !/^[0-9a-f]{64}$/.test(fingerprint as string)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '设备指纹格式不正确，不能保存此连接地址。');
  }
  return {
    account: addressText(row['account'], '账号', 128, true),
    fingerprint: fingerprint as string,
    model: addressText(row['model'], '设备型号', 128, false)
  };
}

function addressInsecureTls(input: Object | undefined, origin: string): boolean {
  if (input === undefined) { return false; }
  if (typeof input !== 'boolean') {
    throw new NasFailure(NasErrorKind.InvalidInput, '忽略 SSL 验证标记必须是布尔值。');
  }
  // 明文 http 没有证书可校验；保留该标记会造成误导，直接归零。
  return input === true && nasOriginScheme(origin) === 'https';
}

export function validateConnectionAddress(input: Object): NasConnectionAddress {
  const row = addressRecord(input);
  validateFields(row, ['origin', 'name', 'kind', 'insecureTls', 'riskConfirmedAt', 'device', 'lastLoginAt']);
  if (typeof row['origin'] !== 'string') {
    throw new NasFailure(NasErrorKind.InvalidInput, '请输入连接地址。');
  }
  const kind = row['kind'];
  if (kind !== 'lan' && kind !== 'remote' && kind !== 'private') {
    throw new NasFailure(NasErrorKind.InvalidInput, '请选择局域网、远程或私有网络连接类型。');
  }
  const origin = normalizeNasOrigin(row['origin'] as string);
  const address: NasConnectionAddress = {
    origin: origin,
    name: addressText(row['name'], '连接名称', 40, true),
    kind: kind as NasConnectionRouteKind
  };
  if (addressInsecureTls(row['insecureTls'], origin)) { address.insecureTls = true; }
  if (row['riskConfirmedAt'] !== undefined) {
    const confirmedAt = row['riskConfirmedAt'];
    if (typeof confirmedAt !== 'number' || !Number.isSafeInteger(confirmedAt) || confirmedAt <= 0) {
      throw new NasFailure(NasErrorKind.InvalidInput, '连接风险确认时间不正确。');
    }
    address.riskConfirmedAt = confirmedAt;
  }
  if (row['device'] !== undefined) { address.device = validateDeviceBinding(row['device']); }
  if (row['lastLoginAt'] !== undefined) { address.lastLoginAt = nasInteger(row['lastLoginAt']); }
  return address;
}

function validateAddresses(input: Object): NasConnectionAddress[] {
  if (!Array.isArray(input)) { throw new NasFailure(NasErrorKind.InvalidInput, '连接地址列表格式不正确。'); }
  const rows = input as Object[];
  if (rows.length > MAX_NAS_CONNECTION_ADDRESSES) {
    throw new NasFailure(NasErrorKind.InvalidInput, '最多可保存 8 个连接地址。');
  }
  const origins: string[] = [];
  return rows.map((row: Object): NasConnectionAddress => {
    const address = validateConnectionAddress(row);
    if (origins.includes(address.origin)) {
      throw new NasFailure(NasErrorKind.InvalidInput, '此连接地址已存在，请勿重复添加。');
    }
    origins.push(address.origin);
    return address;
  });
}

export function decodeConnectionAddressBook(text: string): NasConnectionAddress[] {
  try {
    if (typeof text !== 'string') { throw new NasFailure(NasErrorKind.Protocol, '连接地址记录格式不正确。'); }
    const root = addressRecord(JSON.parse(text) as Object);
    validateFields(root, ['version', 'addresses']);
    if (root['version'] !== 1 && root['version'] !== 2) { throw new NasFailure(NasErrorKind.Protocol, '连接地址记录版本不受支持。'); }
    return validateAddresses(root['addresses']);
  } catch {
    throw new NasFailure(NasErrorKind.Protocol, '连接地址记录损坏或版本不受支持，请保留记录并重试读取。');
  }
}

export function encodeConnectionAddressBook(addresses: NasConnectionAddress[]): string {
  const snapshot: ConnectionAddressBookSnapshot = { version: 2, addresses: validateAddresses(addresses) };
  return JSON.stringify(snapshot);
}

function identityText(input: Object | undefined): string {
  if (typeof input !== 'string' || (input as string).trim().length === 0 || (input as string).length > 128 ||
    /[\u0000-\u001f\u007f-\u009f]/.test(input as string)) {
    throw new NasFailure(NasErrorKind.Protocol, 'NAS 返回的设备标识无效，暂不能登记或核验设备身份。');
  }
  return input as string;
}

export function decodeNasDeviceIdentity(input: Record<string, Object>): NasConnectionDeviceIdentity {
  const row = nasRecord(input);
  if (row['model'] === undefined || row['serial'] === undefined) {
    throw new NasFailure(NasErrorKind.Unsupported, 'NAS 未提供完整的设备标识，暂不能登记或核验设备身份。');
  }
  return { model: identityText(row['model']), serial: identityText(row['serial']) };
}
