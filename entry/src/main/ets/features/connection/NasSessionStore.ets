import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { decodeNasSession, nasOriginScheme, nasRecord, nasString, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import { parseBusinessSessionRecords } from '../../core/network/SessionRegistry';
import type { BusinessSessionRecord } from '../../core/network/SessionRegistry';

/** 会话记录 v2：按业务保存 DSM 会话；v1 旧负载读取时映射为 File Station 单会话。 */
export interface SavedNasSession {
  origin: string;
  account: string;
  /** 仅 https 会话有效：恢复连接时沿用用户显式选择的跳过证书校验。 */
  insecureTls: boolean;
  sessions: BusinessSessionRecord[];
}

export class NasSessionStoreFailure extends Error {
  public code: number;
  constructor(message: string, code: number = 0) {
    super(message);
    this.code = code;
    this.name = 'NasSessionStoreFailure';
  }
}

const SESSION_ALIAS = 'synology-harmonyos.nas-session.v1';
const MAX_SECRET_BYTES = 1024;
const MAX_ACCOUNT_LENGTH = 256;

function encodeText(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function sessionQuery(): asset.AssetMap {
  const query: asset.AssetMap = new Map();
  query.set(asset.Tag.ALIAS, encodeText(SESSION_ALIAS));
  return query;
}

function invalidSession(): NasSessionStoreFailure {
  return new NasSessionStoreFailure('保存的登录信息无效，请清除后重新登录。');
}

function decodeAccount(value: Object): string {
  const account = nasString(value);
  if (account.trim().length === 0 || account.length > MAX_ACCOUNT_LENGTH || /[\u0000-\u001f\u007f]/.test(account)) {
    throw invalidSession();
  }
  return account;
}

/** 持久化负载 v2 的显式形状；ArkTS 要求对象字面量对应显式声明的接口。 */
interface PersistedSessionPayload {
  version: number;
  origin: string;
  account: string;
  insecureTls: boolean;
  sessions: BusinessSessionRecord[];
}

/** DSM 会话字段在 .ets 里的显式形状；经 nasRecord 桥接为 Record 后交由协议校验。 */
interface SessionAuthorization {
  sid: string;
  synotoken?: string;
}

/** 保存前构造 v2 负载；字段逐一显式复制，不使用展开。 */
function sessionPayload(session: SavedNasSession): PersistedSessionPayload {
  const payload: PersistedSessionPayload = { version: 2, origin: session.origin, account: session.account,
    insecureTls: session.insecureTls, sessions: session.sessions };
  return payload;
}

function decodeLegacySession(row: Record<string, Object>): BusinessSessionRecord[] {
  const sid = nasString(row['sid']);
  const rawToken = row['synoToken'];
  const synoToken = typeof rawToken === 'string' ? rawToken : '';
  const authorization: SessionAuthorization = { sid: sid };
  if (synoToken.length > 0) { authorization.synotoken = synoToken; }
  decodeNasSession(nasRecord(authorization));
  // v1 记录由既有登录流程写入，均为主 File Station 会话；这是构造事实，不是对旧记录的猜测。
  const primary: BusinessSessionRecord = { name: 'FileStation', sid: sid, synoToken: synoToken };
  return [primary];
}

/** 负载必须是完整对象：来源、账号与会话记录任一无效都拒绝恢复，不允许部分恢复。 */
function validateSession(input: Object): SavedNasSession {
  const row = nasRecord(input);
  const origin = normalizeNasOrigin(nasString(row['origin']));
  const account = decodeAccount(row['account']);
  const insecureTls = row['insecureTls'];
  if (insecureTls !== undefined && typeof insecureTls !== 'boolean') { throw invalidSession(); }
  let sessions: BusinessSessionRecord[];
  if (row['version'] === 2) {
    sessions = parseBusinessSessionRecords(row['sessions'] as Object);
  } else if (row['version'] === undefined) {
    sessions = decodeLegacySession(row);
  } else {
    throw invalidSession();
  }
  return { origin: origin, account: account, sessions: sessions,
    insecureTls: insecureTls === true && nasOriginScheme(origin) === 'https' };
}

function storageFailure(operation: string, error: BusinessError): NasSessionStoreFailure {
  if (error.code === asset.ErrorCode.STATUS_MISMATCH) {
    return new NasSessionStoreFailure('请解锁手机后重试读取或保存登录信息。', error.code);
  }
  return new NasSessionStoreFailure(operation + '登录信息失败，请重试。', error.code);
}

/** 仅保存当前 NAS 会话，密码不入库；调用方按顺序等待保存与清除完成。 */
export class NasSessionStore {
  async save(session: SavedNasSession): Promise<void> {
    const value = validateSession(sessionPayload(session));
    // 序列化归一化后的 v2 负载：insecureTls 仅对 https 保留，会话记录已经过格式校验。
    const secret = encodeText(JSON.stringify(sessionPayload(value)));
    if (secret.length > MAX_SECRET_BYTES) {
      throw new NasSessionStoreFailure('登录信息超过安全存储容量，无法保存此会话。');
    }
    const attributes = sessionQuery();
    attributes.set(asset.Tag.SECRET, secret);
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attributes.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try { await asset.add(attributes); }
    catch (error) { throw storageFailure('保存', error as BusinessError); }
    finally { secret.fill(0); }
  }

  async load(): Promise<SavedNasSession | undefined> {
    const query = sessionQuery();
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    let results: asset.AssetMap[];
    try { results = await asset.query(query); }
    catch (error) {
      const failure = error as BusinessError;
      if (failure.code === asset.ErrorCode.NOT_FOUND) { return undefined; }
      throw storageFailure('读取', failure);
    }
    if (results.length !== 1) { throw invalidSession(); }
    const secret = results[0].get(asset.Tag.SECRET);
    if (!(secret instanceof Uint8Array) || secret.length === 0 || secret.length > MAX_SECRET_BYTES) {
      throw invalidSession();
    }
    try {
      const text = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(secret);
      return validateSession(JSON.parse(text) as Object);
    } catch { throw invalidSession(); }
    finally { secret.fill(0); }
  }

  async clear(): Promise<void> {
    try { await asset.remove(sessionQuery()); }
    catch (error) {
      const failure = error as BusinessError;
      if (failure.code === asset.ErrorCode.NOT_FOUND) { return; }
      throw storageFailure('清除', failure);
    }
  }
}
