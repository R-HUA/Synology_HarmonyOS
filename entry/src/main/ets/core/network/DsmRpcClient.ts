import { encodeNasForm, NasErrorKind, NasFailure, normalizeNasOrigin, validateApiPath } from '../domain/DsmProtocol';
import type { NasApiDescriptor, NasFormField, NasLoginSession } from '../domain/DsmProtocol';
import { selectVerifiedApi } from './ApiVersionPolicy';

export interface NasHttpReply { status: number; text: string; }
export interface NasTransport {
  post(address: string, body: string, session?: NasLoginSession): Promise<NasHttpReply>;
  close(): void;
}

export class DsmRpcClient {
  constructor(private transport: NasTransport) {}

  request(origin: string, descriptor: NasApiDescriptor, version: number, method: string,
    parameters: NasFormField[], session?: NasLoginSession): Promise<NasHttpReply> {
    const api = selectVerifiedApi([descriptor], descriptor.name, [version]).api;
    const address = normalizeNasOrigin(origin) + '/webapi/' + validateApiPath(api.path);
    const names = new Set<string>(['api', 'version', 'method', '_sid', 'synotoken']);
    const fields: NasFormField[] = [
      { name: 'api', content: api.name }, { name: 'version', content: version.toString() },
      { name: 'method', content: method }
    ];
    for (const parameter of parameters) {
      const name = parameter.name.toLowerCase();
      if (names.has(name)) { throw new NasFailure(NasErrorKind.InvalidInput, '请求参数重复或包含受保护的认证字段。'); }
      names.add(name);
      fields.push({ name: parameter.name, content: parameter.content });
    }
    const authorization = session === undefined ? undefined : { sid: session.sid, synoToken: session.synoToken };
    return this.transport.post(address, encodeNasForm(fields), authorization);
  }

  discover(origin: string, query: string): Promise<NasHttpReply> {
    return this.request(origin, { name: 'SYNO.API.Info', path: 'query.cgi', minVersion: 1, maxVersion: 1,
      jsonParameters: false }, 1, 'query', [{ name: 'query', content: query }]);
  }
}
