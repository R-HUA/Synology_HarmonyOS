import { decodeNasSession, nasRecord, nasString, NasErrorKind, NasFailure } from '../domain/DsmProtocol';
import type { NasLoginSession } from '../domain/DsmProtocol';

/** DSM 登录会话按业务名称隔离授权；新增业务须在此登记，不开放任意会话名。 */
export type BusinessSessionName = 'FileStation' | 'DownloadStation' | 'NasControl';

/** 持久化用的业务会话记录；不含密码、OTP 或来源地址。 */
export interface BusinessSessionRecord { name: string; sid: string; synoToken: string; }

const KNOWN_SESSIONS: BusinessSessionName[] = ['FileStation', 'DownloadStation', 'NasControl'];

function invalidRecord(): NasFailure {
  return new NasFailure(NasErrorKind.Protocol, '保存的业务会话格式不符合预期。');
}

/** 解析单条业务会话记录；名称必须是已登记业务，凭据按 DSM 会话格式校验，synoToken 允许为空。 */
export function parseBusinessSessionRecord(input: Object): BusinessSessionRecord {
  const row = nasRecord(input);
  const name = nasString(row['name']);
  if (!KNOWN_SESSIONS.includes(name as BusinessSessionName)) { throw invalidRecord(); }
  const sid = nasString(row['sid']);
  const rawToken = row['synoToken'];
  if (rawToken !== undefined && typeof rawToken !== 'string') { throw invalidRecord(); }
  const synoToken = typeof rawToken === 'string' ? rawToken : '';
  const authorization: Record<string, Object> = { sid: sid };
  if (synoToken.length > 0) { authorization['synotoken'] = synoToken; }
  decodeNasSession(authorization);
  return { name: name, sid: sid, synoToken: synoToken };
}

/** 解析一组业务会话记录；不允许同名重复，数量不超过已登记业务数。 */
export function parseBusinessSessionRecords(input: Object): BusinessSessionRecord[] {
  if (!Array.isArray(input)) { throw invalidRecord(); }
  const rows = input as Object[];
  if (rows.length === 0 || rows.length > KNOWN_SESSIONS.length) { throw invalidRecord(); }
  const records = rows.map((row: Object): BusinessSessionRecord => parseBusinessSessionRecord(row));
  const names = new Set<string>();
  for (const record of records) {
    if (names.has(record.name)) { throw invalidRecord(); }
    names.add(record.name);
  }
  return records;
}

/**
 * 单个连接内的业务会话注册表：按业务名称保存 DSM 会话，套件会话失效只清除对应业务，
 * 不影响其他业务。注册表本身不发起登录、不保存密码；建立会话由连接器完成。
 */
export class SessionRegistry {
  private entries: Map<BusinessSessionName, NasLoginSession> = new Map<BusinessSessionName, NasLoginSession>();
  private changeCount: number = 0;
  private businessRevisions: Map<BusinessSessionName, number> = new Map<BusinessSessionName, number>();

  private changed(name: BusinessSessionName): void {
    this.businessRevisions.set(name, this.revision(name) + 1);
  }

  register(name: BusinessSessionName, authorization: NasLoginSession): void {
    // 未登记业务名的会话不会出现在快照里，必须在注册入口拒绝而不是静默丢弃。
    if (!KNOWN_SESSIONS.includes(name)) { throw invalidRecord(); }
    const validation: Record<string, Object> = { sid: authorization.sid };
    if (authorization.synoToken.length > 0) { validation['synotoken'] = authorization.synoToken; }
    decodeNasSession(validation);
    this.entries.set(name, { sid: authorization.sid, synoToken: authorization.synoToken });
    this.changed(name);
    this.changeCount++;
  }

  has(name: BusinessSessionName): boolean {
    return this.entries.has(name);
  }

  get(name: BusinessSessionName): NasLoginSession | undefined {
    const session = this.entries.get(name);
    return session === undefined ? undefined : { sid: session.sid, synoToken: session.synoToken };
  }

  /** 套件会话失效时只移除该业务；未注册时返回 false。 */
  invalidate(name: BusinessSessionName): boolean {
    const removed = this.entries.delete(name);
    if (removed) { this.changed(name); this.changeCount++; }
    return removed;
  }

  clear(): void {
    if (this.entries.size > 0) { this.changeCount++; }
    this.entries.forEach((_session: NasLoginSession, name: BusinessSessionName): void => { this.changed(name); });
    this.entries.clear();
  }

  /** 不传名称时返回快照变更计数；业务计数可用于拒绝旧授权下的迟到响应。 */
  revision(name?: BusinessSessionName): number {
    return name === undefined ? this.changeCount : this.businessRevisions.get(name) ?? 0;
  }

  /** 导出持久化快照；顺序按已登记业务固定。 */
  snapshot(): BusinessSessionRecord[] {
    const result: BusinessSessionRecord[] = [];
    for (const name of KNOWN_SESSIONS) {
      const session = this.entries.get(name);
      if (session !== undefined) {
        result.push({ name: name, sid: session.sid, synoToken: session.synoToken });
      }
    }
    return result;
  }

  /** 整组替换已保存的会话；任何一条无效都会拒绝整组恢复。 */
  restore(records: BusinessSessionRecord[]): void {
    const parsed = parseBusinessSessionRecords(records as Object[]);
    for (const name of KNOWN_SESSIONS) { this.changed(name); }
    this.entries.clear();
    for (const record of parsed) {
      const authorization: Record<string, Object> = { sid: record.sid };
      if (record.synoToken.length > 0) { authorization['synotoken'] = record.synoToken; }
      this.entries.set(record.name as BusinessSessionName, decodeNasSession(authorization));
    }
    this.changeCount++;
  }
}
