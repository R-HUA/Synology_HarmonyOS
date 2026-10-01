import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NasErrorKind, NasFailure, NasLoginSession } from '../domain/DsmProtocol';
import { NasHttpReply, NasTransport } from './NasConnector';

export class RcpNasTransport implements NasTransport {
  private session: rcp.Session = rcp.createSession({
    requestConfiguration: { transfer: { autoRedirect: false, timeout: { connectMs: 10000, transferMs: 20000 } } }
  });

  async post(address: string, body: string, authorization?: NasLoginSession): Promise<NasHttpReply> {
    try {
      const headers: rcp.RequestHeaders = {
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'Accept': 'application/json', 'Cache-Control': 'no-store'
      };
      if (authorization !== undefined && authorization.synoToken.length > 0) {
        headers['X-SYNO-TOKEN'] = authorization.synoToken;
      }
      const request = new rcp.Request(address, 'POST', headers, body);
      if (authorization !== undefined) { request.cookies = { id: authorization.sid }; }
      const reply = await this.session.fetch(request);
      const text = reply.toString();
      if (text === null) { throw new NasFailure(NasErrorKind.Protocol, '服务器没有返回可读取的响应。'); }
      return { status: reply.statusCode, text: text };
    } catch (error) {
      if (error instanceof NasFailure) { throw error; }
      const code = (error as BusinessError).code;
      if ([1007900035, 1007900058, 1007900059, 1007900060, 1007900077, 1007900090].includes(code)) {
        throw new NasFailure(NasErrorKind.Tls, 'HTTPS 证书验证失败，请检查域名、证书链和有效期。', code);
      }
      throw new NasFailure(NasErrorKind.Network, '连接 NAS 失败，请检查网络与服务器地址。', code);
    }
  }

  close(): void { this.session.cancel(); this.session.close(); }

}
