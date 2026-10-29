import { decodeNasSession, nasRecord, NasErrorKind, NasFailure } from '../domain/DsmProtocol';
import type { NasLoginSession } from '../domain/DsmProtocol';

/** 所有原生业务与官方网页共享同一份主会话。 */
export function parseNasSession(input: Object): NasLoginSession {
  const row = nasRecord(input);
  const sid = row['sid'], token = row['synoToken'];
  if (typeof sid !== 'string' || typeof token !== 'string') {
    throw new NasFailure(NasErrorKind.Protocol, '保存的登录信息格式无效，请清除后重新登录。');
  }
  const authorization: Record<string, Object> = { sid: sid };
  if (token.length > 0) { authorization['synotoken'] = token; }
  return decodeNasSession(authorization);
}

/** 会话只由连接器持有；修订号用于拒收退出或重新登录后的旧回执。 */
export class SessionRegistry {
  private authorization: NasLoginSession | undefined = undefined;
  private changeCount: number = 0;

  register(authorization: NasLoginSession): void {
    this.authorization = parseNasSession(authorization);
    this.changeCount++;
  }

  has(): boolean { return this.authorization !== undefined; }

  get(): NasLoginSession | undefined {
    return this.authorization === undefined ? undefined :
      { sid: this.authorization.sid, synoToken: this.authorization.synoToken };
  }

  clear(): void {
    this.authorization = undefined;
    this.changeCount++;
  }

  revision(): number { return this.changeCount; }
}
