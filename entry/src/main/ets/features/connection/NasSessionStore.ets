import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { nasOriginScheme, nasRecord, nasString, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import type { NasLoginSession } from '../../core/domain/DsmProtocol';
import { parseNasSession } from '../../core/network/SessionRegistry';

/** 统一主会话，仅接受当前负载版本。 */
export interface SavedNasSession {
  origin: string;
  account: string;
  /** 仅 https 会话有效：恢复连接时沿用用户显式选择的跳过证书校验。 */
  insecureTls: boolean;
  session: NasLoginSession;
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

/** 持久化只接受当前统一会话版本。 */
interface PersistedSessionPayload {
  version: number;
  origin: string;
  account: string;
  insecureTls: boolean;
  session: NasLoginSession;
}

/** 密码、动态码和网页 Cookie 不进入负载。 */
function sessionPayload(session: SavedNasSession): PersistedSessionPayload {
  const payload: PersistedSessionPayload = { version: 3, origin: session.origin, account: session.account,
    insecureTls: session.insecureTls, session: session.session };
  return payload;
}

/** 负载必须是完整对象：来源、账号与会话记录任一无效都拒绝恢复，不允许部分恢复。 */
function validateSession(input: Object): SavedNasSession {
  const row = nasRecord(input);
  const origin = normalizeNasOrigin(nasString(row['origin']));
  const account = decodeAccount(row['account']);
  const insecureTls = row['insecureTls'];
  if (typeof insecureTls !== 'boolean') { throw invalidSession(); }
  if (row['version'] !== 3) { throw invalidSession(); }
  const session = parseNasSession(row['session']);
  return { origin: origin, account: account, session: session,
    insecureTls: insecureTls === true && nasOriginScheme(origin) === 'https' };
}

function storageFailure(operation: string, error: BusinessError): NasSessionStoreFailure {
  if (error.code === asset.ErrorCode.STATUS_MISMATCH) {
    return new NasSessionStoreFailure('请解锁手机后重试读取或保存登录信息。', error.code);
  }
  return new NasSessionStoreFailure(operation + '登录信息失败，请重试。', error.code);
}

/** 保存与清除串行，防止退出后被迟到的写入恢复旧账号。 */
export class NasSessionStore {
  private pendingWrite: Promise<void> = Promise.resolve();

  async save(session: SavedNasSession): Promise<void> {
    const value = validateSession(sessionPayload(session));
    const write = this.pendingWrite.then((): Promise<void> => this.write(value));
    // 调用者仍收到原错误；队列只释放排它权，确保失败的写入不阻断后续清除。
    this.pendingWrite = write.catch((): void => {});
    return write;
  }

  private async write(session: SavedNasSession): Promise<void> {
    const secret = encodeText(JSON.stringify(sessionPayload(session)));
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
    await this.pendingWrite;
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
    const write = this.pendingWrite.then((): Promise<void> => this.remove());
    this.pendingWrite = write.catch((): void => {});
    return write;
  }

  private async remove(): Promise<void> {
    try { await asset.remove(sessionQuery()); }
    catch (error) {
      const failure = error as BusinessError;
      if (failure.code === asset.ErrorCode.NOT_FOUND) { return; }
      throw storageFailure('清除', failure);
    }
  }
}
