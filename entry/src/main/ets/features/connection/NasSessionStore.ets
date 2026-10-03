import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { decodeNasSession, nasOriginScheme, nasRecord, nasString, normalizeNasOrigin } from '../../core/domain/DsmProtocol';

export interface SavedNasSession {
  origin: string;
  account: string;
  sid: string;
  synoToken: string;
  /** 仅 https 会话有效：恢复连接时沿用用户显式选择的跳过证书校验。 */
  insecureTls: boolean;
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

interface SessionPayload { sid: string; synotoken?: string; }

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

function validateSession(input: Object): SavedNasSession {
  const row = nasRecord(input);
  const origin = normalizeNasOrigin(nasString(row['origin']));
  const account = nasString(row['account']);
  const sid = nasString(row['sid']);
  const synoToken = row['synoToken'];
  const insecureTls = row['insecureTls'];
  if (account.trim().length === 0 || /[\u0000-\u001f\u007f]/.test(account) ||
    /[\u0000-\u0020\u007f]/.test(sid) || typeof synoToken !== 'string' ||
    /[\u0000-\u0020\u007f]/.test(synoToken as string) ||
    (insecureTls !== undefined && typeof insecureTls !== 'boolean')) {
    throw invalidSession();
  }
  const authorization: SessionPayload = { sid: sid };
  if ((synoToken as string).length > 0) { authorization.synotoken = synoToken as string; }
  decodeNasSession(nasRecord(authorization));
  return { origin: origin, account: account, sid: sid, synoToken: synoToken as string,
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
    const value = validateSession(session);
    const secret = encodeText(JSON.stringify(value));
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
