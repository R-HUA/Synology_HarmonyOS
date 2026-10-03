import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { decodeUtf8Complete, decodeResponsePrefix } from '../../platform/Utf8Codec';
import { encodeNasForm, NasErrorKind, NasFailure, NasFormField, NasLoginSession } from '../domain/DsmProtocol';
import { PHOTO_ORIGINAL_MAX_BYTES, PHOTO_THUMBNAIL_MAX_BYTES, validatePhotoMediaResponse } from '../domain/PhotosProtocol';
import { NasHttpReply, NasTransport, NasTransferPlan } from './NasConnector';

export class RcpNasTransport implements NasTransport {
  private session: rcp.Session;
  private closed: boolean = false;

  /**
   * insecureTls 只在用户显式选择“忽略 SSL 验证”时为 true；此时跳过服务器证书校验，
   * 用于自签名证书的内网 NAS。默认仍使用系统 CA。
   */
  constructor(insecureTls: boolean = false) {
    const requestConfiguration: rcp.Configuration = {
      transfer: { autoRedirect: false, timeout: { connectMs: 10000, transferMs: 20000 } }
    };
    if (insecureTls) { requestConfiguration.security = { remoteValidation: 'skip' }; }
    this.session = rcp.createSession({ requestConfiguration: requestConfiguration });
  }

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
      return { status: reply.statusCode, text: decodeUtf8Complete(data) };
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
    let output: fileIo.File;
    try {
      if (fileIo.accessSync(destination)) { throw new NasFailure(NasErrorKind.Protocol, '照片临时路径已被占用。'); }
      output = fileIo.openSync(destination, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
    } catch (error) {
      if (error instanceof NasFailure) { throw error; }
      throw new NasFailure(NasErrorKind.Protocol, '无法创建照片临时文件。', (error as BusinessError).code);
    }
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
    let failure: NasFailure | undefined = undefined;
    try {
      const reply = await this.session.fetch(request);
      if (callbackFailure !== undefined) { throw callbackFailure as Error; }
      if (!current() || this.closed) { throw new NasFailure(NasErrorKind.Cancelled, '照片读取已取消。'); }
      const api = plan.fields.find((field: NasFormField): boolean => field.name === 'api');
      validatePhotoMediaResponse(api === undefined ? '' : api.content, reply.statusCode,
        this.header(reply.headers, 'content-type'), this.header(reply.headers, 'content-length'), bytes, prefix,
        decodeResponsePrefix(prefix), thumbnail, expectedBytes);
      try {
        if (fileIo.statSync(output.fd).size !== bytes) { throw new NasFailure(NasErrorKind.Protocol, '照片文件大小校验失败。'); }
      } catch (error) {
        if (error instanceof NasFailure) { throw error; }
        throw new NasFailure(NasErrorKind.Protocol, '无法校验照片临时文件。', (error as BusinessError).code);
      }
    } catch (error) {
      if (callbackFailure !== undefined) { failure = callbackFailure; }
      else if (!current() || this.closed) { failure = new NasFailure(NasErrorKind.Cancelled, '照片读取已取消。'); }
      else { failure = this.failure(error as Error); }
    } finally {
      try { fileIo.closeSync(output); }
      catch (error) {
        const code = (error as BusinessError).code;
        hilog.error(0x0000, 'NasPhotos', 'operation=media_close result=failed code=%{public}d', code);
        if (failure === undefined) { failure = new NasFailure(NasErrorKind.Protocol, '照片临时文件关闭失败，无法安全使用。', code); }
      }
      if (failure !== undefined) {
        try { if (fileIo.accessSync(destination)) { fileIo.unlinkSync(destination); } }
        catch (error) {
          hilog.error(0x0000, 'NasPhotos', 'operation=media_cleanup result=failed code=%{public}d', (error as BusinessError).code);
        }
      }
    }
    if (failure !== undefined) { throw failure; }
    return bytes;
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
      return new NasFailure(NasErrorKind.Tls, '服务器证书校验未通过。请检查域名与证书有效期；内网自签名证书可在登录页开启“忽略 SSL 验证”；也可改用 http 地址。', code);
    }
    return new NasFailure(NasErrorKind.Network, '连接 NAS 失败，请检查网络与服务器地址。', code);
  }
}
