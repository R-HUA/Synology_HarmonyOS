import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { encodeNasForm, NasErrorKind, NasFailure, NasFormField, NasLoginSession } from '../domain/DsmProtocol';
import { PHOTO_ORIGINAL_MAX_BYTES, PHOTO_THUMBNAIL_MAX_BYTES, validatePhotoMediaResponse } from '../domain/PhotosProtocol';
import { NasHttpReply, NasTransport, NasTransferPlan } from './NasConnector';

export class RcpNasTransport implements NasTransport {
  private session: rcp.Session = rcp.createSession({
    requestConfiguration: { transfer: { autoRedirect: false, timeout: { connectMs: 10000, transferMs: 20000 } } }
  });
  private closed: boolean = false;

  async post(address: string, body: string, authorization?: NasLoginSession): Promise<NasHttpReply> {
    const request = this.request(address, body, authorization, 'application/json');
    const chunks: Uint8Array[] = [];
    let bytes = 0;
    let overflow = false;
    request.destination = (chunk: ArrayBuffer): void => {
      if (bytes + chunk.byteLength > 1024 * 1024) { overflow = true; this.session.cancel(request); return; }
      if (!overflow) { chunks.push(new Uint8Array(chunk)); bytes += chunk.byteLength; }
    };
    try {
      const reply = await this.session.fetch(request);
      if (overflow) { throw new NasFailure(NasErrorKind.Protocol, '服务器业务响应过大。'); }
      const data = new Uint8Array(bytes);
      let offset = 0;
      for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.length; }
      return { status: reply.statusCode, text: new util.TextDecoder().decodeWithStream(data) };
    } catch (error) {
      if (overflow) { throw new NasFailure(NasErrorKind.Protocol, '服务器业务响应过大。'); }
      throw this.failure(error as Error);
    }
  }

  /** 回调逐块写私有文件，原图不在内存中聚合；取消和越界会立即停止当前请求。 */
  async downloadMedia(plan: NasTransferPlan, destination: string, thumbnail: boolean, expectedBytes: number | undefined,
    current: () => boolean): Promise<number> {
    const maximum = thumbnail ? PHOTO_THUMBNAIL_MAX_BYTES : PHOTO_ORIGINAL_MAX_BYTES;
    if (expectedBytes !== undefined && (!Number.isSafeInteger(expectedBytes) || expectedBytes < 0 || expectedBytes > maximum)) {
      throw new NasFailure(NasErrorKind.InvalidInput, '原图超过 256 MiB 的前台读取限制。');
    }
    const request = this.request(plan.address, encodeNasForm(plan.fields), plan.session, thumbnail ? 'image/*' : 'image/*,video/*,application/octet-stream');
    request.configuration = { transfer: { autoRedirect: false, timeout: { connectMs: 10000, transferMs: 120000 } } };
    if (fileIo.accessSync(destination)) { throw new NasFailure(NasErrorKind.Protocol, '照片临时路径已被占用。'); }
    const output = fileIo.openSync(destination, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
    let bytes = 0;
    let prefix = new Uint8Array(0);
    let callbackFailure: NasFailure | undefined = undefined;
    request.destination = (chunk: ArrayBuffer): void => {
      if (callbackFailure !== undefined) { return; }
      try {
        if (!current() || this.closed) { throw new NasFailure(NasErrorKind.Cancelled, '照片读取已取消。'); }
        if (bytes + chunk.byteLength > maximum) { throw new NasFailure(NasErrorKind.Protocol, '照片媒体超过读取大小限制。'); }
        if (prefix.length < 65536) {
          const size = Math.min(65536 - prefix.length, chunk.byteLength);
          const next = new Uint8Array(prefix.length + size);
          next.set(prefix);
          next.set(new Uint8Array(chunk, 0, size), prefix.length);
          prefix = next;
        }
        let offset = 0;
        while (offset < chunk.byteLength) {
          const written = fileIo.writeSync(output.fd, chunk.slice(offset));
          if (written <= 0) { throw new NasFailure(NasErrorKind.Protocol, '照片文件写入未完成。'); }
          offset += written;
        }
        bytes += chunk.byteLength;
      } catch (error) {
        callbackFailure = error instanceof NasFailure ? error : new NasFailure(NasErrorKind.Protocol, '照片文件写入失败。');
        this.session.cancel(request);
      }
    };
    let completed = false;
    try {
      const reply = await this.session.fetch(request);
      if (callbackFailure !== undefined) { throw callbackFailure as Error; }
      if (!current() || this.closed) { throw new NasFailure(NasErrorKind.Cancelled, '照片读取已取消。'); }
      const api = plan.fields.find((field: NasFormField): boolean => field.name === 'api');
      validatePhotoMediaResponse(api === undefined ? '' : api.content, reply.statusCode,
        this.header(reply.headers, 'content-type'), this.header(reply.headers, 'content-length'), bytes, prefix,
        new util.TextDecoder().decodeWithStream(prefix), thumbnail, expectedBytes);
      if (fileIo.statSync(output.fd).size !== bytes) { throw new NasFailure(NasErrorKind.Protocol, '照片文件大小校验失败。'); }
      completed = true;
      return bytes;
    } catch (error) {
      if (callbackFailure !== undefined) { throw callbackFailure as Error; }
      if (!current() || this.closed) { throw new NasFailure(NasErrorKind.Cancelled, '照片读取已取消。'); }
      throw this.failure(error as Error);
    } finally {
      fileIo.closeSync(output);
      if (!completed && fileIo.accessSync(destination)) { fileIo.unlinkSync(destination); }
    }
  }

  close(): void {
    if (this.closed) { return; }
    this.closed = true;
    this.session.cancel();
    this.session.close();
  }

  private request(address: string, body: string, authorization: NasLoginSession | undefined, accept: string): rcp.Request {
    if (this.closed) { throw new NasFailure(NasErrorKind.Cancelled, '连接已关闭。'); }
    const headers: rcp.RequestHeaders = { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'Accept': accept, 'Cache-Control': 'no-store' };
    if (authorization !== undefined && authorization.synoToken.length > 0) { headers['X-SYNO-TOKEN'] = authorization.synoToken; }
    const request = new rcp.Request(address, 'POST', headers, body);
    request.cacheControl = { noStore: true };
    if (authorization !== undefined) { request.cookies = { id: authorization.sid }; }
    return request;
  }

  private header(headers: rcp.ResponseHeaders, name: string): string {
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() === name) {
        const value = headers[key];
        if (typeof value === 'string') { return value; }
        if (value !== undefined) { throw new NasFailure(NasErrorKind.Protocol, '照片媒体响应头重复，无法验证。'); }
      }
    }
    return '';
  }

  private failure(error: Error): NasFailure {
    if (error instanceof NasFailure) { return error; }
    const code = (error as BusinessError).code;
    if ([1007900035, 1007900058, 1007900059, 1007900060, 1007900077, 1007900090].includes(code)) {
      return new NasFailure(NasErrorKind.Tls, 'HTTPS 证书验证失败，请检查域名、证书链和有效期。', code);
    }
    return new NasFailure(NasErrorKind.Network, '连接 NAS 失败，请检查网络与服务器地址。', code);
  }
}
