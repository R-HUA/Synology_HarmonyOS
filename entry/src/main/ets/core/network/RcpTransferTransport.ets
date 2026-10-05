import { rcp } from '@kit.RemoteCommunicationKit';
import { fileIo } from '@kit.CoreFileKit';
import { NasErrorKind, NasFailure, encodeNasForm } from '../domain/DsmProtocol';
import { NAS_TRANSFER_PREFIX_BYTES, NAS_TRANSFER_UPLOAD_REPLY_BYTES, validateNasDownloadTarget,
  validateNasTransferFilename, validateNasUploadSource } from './NasTransferTransport';
import type { NasHttpReply } from './DsmRpcClient';
import type { NasBinaryReply, NasDownloadReceipt, NasDownloadTarget, NasTransferControl,
  NasTransferRequest, NasTransferTransport, NasUploadSource } from './NasTransferTransport';
import { decodeResponsePrefix, decodeUtf8Complete } from '../../platform/Utf8Codec';

/**
 * 共用连接的 RCP Session：不创建第二套证书策略、不跟随任何重定向，
 * 也不使用 Content-Disposition 决定本地路径。
 */
export class RcpTransferTransport implements NasTransferTransport {
  private session: rcp.Session;
  private closed: () => boolean;
  private failure: (error: Error) => NasFailure;

  constructor(session: rcp.Session, closed: () => boolean, failure: (error: Error) => NasFailure) {
    this.session = session;
    this.closed = closed;
    this.failure = failure;
  }

  async upload(plan: NasTransferRequest, source: NasUploadSource, filename: string,
    control: NasTransferControl): Promise<NasHttpReply> {
    this.check(control);
    validateNasUploadSource(source);
    validateNasTransferFilename(filename);
    try {
      const stat = fileIo.statSync(source.path);
      if (!stat.isFile() || stat.size !== source.bytes) { throw new Error('source changed'); }
    } catch (_) { throw new NasFailure(NasErrorKind.InvalidInput, '上传文件已变化，请重新选择。'); }
    const formFields: rcp.MultipartFormFields = {};
    const keys: string[] = [];
    for (const field of plan.fields) { formFields[field.name] = field.content; keys.push(field.name); }
    // file 固定放最后；整文件交给 RCP 从本地路径读取，不在内存里聚合。
    formFields['file'] = { contentOrPath: source.path, remoteFileName: filename, contentType: 'application/octet-stream' };
    keys.push('file');
    const form = new rcp.MultipartForm(formFields);
    form.keys = keys;
    const request = this.request(plan, form);
    const chunks: Uint8Array[] = [];
    let bytes = 0;
    let callbackFailure: NasFailure | undefined = undefined;
    request.destination = (chunk: ArrayBuffer): void => {
      if (callbackFailure !== undefined) { return; }
      try {
        this.check(control);
        if (bytes + chunk.byteLength > NAS_TRANSFER_UPLOAD_REPLY_BYTES) {
          throw new NasFailure(NasErrorKind.Protocol, '上传结果未能确认，请检查目标文件。');
        }
        chunks.push(new Uint8Array(chunk)); bytes += chunk.byteLength;
      } catch (error) {
        callbackFailure = error instanceof NasFailure ? error :
          new NasFailure(NasErrorKind.Protocol, '上传结果未能确认，请检查目标文件。');
        this.session.cancel(request);
      }
    };
    request.configuration = { transfer: { autoRedirect: false, timeout: { connectMs: 10000, transferMs: 120000 } },
      tracing: { httpEventsHandler: {
        onUploadProgress: (total: number, processed: number): void => {
          if (callbackFailure !== undefined) { return; }
          try {
            this.check(control);
            // 上传进度含 multipart 开销，只作传输进度，不充当文件字节确认。
            if (control.onProgress !== undefined) {
              control.onProgress({ direction: 'upload', processed, total: total > 0 ? total : undefined });
            }
          } catch (error) {
            callbackFailure = error instanceof NasFailure ? error :
              new NasFailure(NasErrorKind.Protocol, '上传已停止，请检查目标文件以确认结果。');
            this.session.cancel(request);
          }
        }
      } } };
    const unsubscribe = control.cancellation.subscribe((): void => { this.session.cancel(request); });
    try {
      this.check(control);
      const response = await this.session.fetch(request);
      this.check(control);
      if (callbackFailure !== undefined) { throw callbackFailure as Error; }
      const data = new Uint8Array(bytes);
      let offset = 0;
      for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.length; }
      return { status: response.statusCode, text: decodeUtf8Complete(data) };
    } catch (error) {
      // 停止时请求可能已经送达，不能断言服务端没有落盘。
      if (control.cancellation.cancelled || this.closed()) {
        throw new NasFailure(NasErrorKind.Cancelled, '上传已停止，请检查目标文件以确认结果。');
      }
      // 回调侧已经给出准确原因，不再送进网络错误映射。
      if (callbackFailure !== undefined) { throw callbackFailure as Error; }
      const failure = this.failure(error as Error);
      if (failure.kind === NasErrorKind.Network) {
        throw new NasFailure(failure.kind, '上传结果未能确认，请检查目标文件后再试。', failure.code);
      }
      throw failure as Error;
    } finally { unsubscribe(); }
  }

  async download(plan: NasTransferRequest, target: NasDownloadTarget, control: NasTransferControl,
    validate: (reply: NasBinaryReply) => void): Promise<NasDownloadReceipt> {
    this.check(control);
    validateNasDownloadTarget(target);
    const request = this.request(plan);
    const destination = target.directory + '/content';
    // 独占创建：目录已存在就退出，不触碰调用前可能已有的文件。
    try { fileIo.mkdirSync(target.directory); }
    catch (_) { throw new NasFailure(NasErrorKind.Protocol, '无法创建下载临时目录。'); }
    let owned = true;
    const discard = (): void => {
      if (!owned) { return; }
      try {
        if (fileIo.accessSync(destination)) { fileIo.unlinkSync(destination); }
        fileIo.rmdirSync(target.directory);
        owned = false;
      } catch (_) { throw new NasFailure(NasErrorKind.Protocol, '下载未完成，临时文件清理失败。'); }
    };
    let descriptor: number = -1;
    let bytes = 0;
    let prefix = new Uint8Array(0);
    let callbackFailure: NasFailure | undefined = undefined;
    let failure: NasFailure | undefined = undefined;
    let unsubscribe = (): void => {};
    try {
      try { descriptor = fileIo.openSync(destination, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE).fd; }
      catch (_) { throw new NasFailure(NasErrorKind.Protocol, '无法创建下载临时文件。'); }
      const fd = descriptor;
      request.destination = (chunk: ArrayBuffer): void => {
        if (callbackFailure !== undefined) { return; }
        try {
          this.check(control);
          if (bytes + chunk.byteLength > target.maximumBytes) {
            throw new NasFailure(NasErrorKind.Protocol, '下载文件超过大小限制。');
          }
          if (prefix.length < NAS_TRANSFER_PREFIX_BYTES) {
            const size = Math.min(NAS_TRANSFER_PREFIX_BYTES - prefix.length, chunk.byteLength);
            const next = new Uint8Array(prefix.length + size);
            next.set(prefix); next.set(new Uint8Array(chunk, 0, size), prefix.length); prefix = next;
          }
          let offset = 0;
          while (offset < chunk.byteLength) {
            const written = fileIo.writeSync(fd, chunk.slice(offset));
            if (!Number.isSafeInteger(written) || written <= 0 || written > chunk.byteLength - offset) {
              throw new NasFailure(NasErrorKind.Protocol, '下载文件写入失败。');
            }
            offset += written;
          }
          bytes += chunk.byteLength;
          if (control.onProgress !== undefined) {
            control.onProgress({ direction: 'download', processed: bytes, total: target.expectedBytes });
          }
        } catch (error) {
          callbackFailure = error instanceof NasFailure ? error :
            new NasFailure(NasErrorKind.Protocol, '下载文件写入失败。');
          this.session.cancel(request);
        }
      };
      unsubscribe = control.cancellation.subscribe((): void => { this.session.cancel(request); });
      this.check(control);
      const reply = await this.session.fetch(request);
      this.check(control);
      if (callbackFailure !== undefined) { throw callbackFailure as Error; }
      // 不跟随重定向：3xx 一律显式失败，绝不把认证信息转发到别的地址。
      if (reply.statusCode >= 300 && reply.statusCode < 400) {
        throw new NasFailure(NasErrorKind.Http, '下载未完成，请稍后重试。', reply.statusCode);
      }
      validate({ status: reply.statusCode, contentType: this.header(reply.headers, 'content-type'),
        contentLength: this.header(reply.headers, 'content-length'),
        contentDisposition: this.header(reply.headers, 'content-disposition'),
        bytes, prefix, prefixText: decodeResponsePrefix(prefix) });
      try {
        if (fileIo.statSync(fd).size !== bytes) { throw new NasFailure(NasErrorKind.Protocol, '下载文件不完整，请重试。'); }
        fileIo.fsyncSync(fd);
      } catch (error) {
        throw error instanceof NasFailure ? error :
          new NasFailure(NasErrorKind.Protocol, '下载文件保存失败，请重试。');
      }
      this.check(control);
    } catch (error) {
      if (control.cancellation.cancelled || this.closed()) {
        failure = new NasFailure(NasErrorKind.Cancelled, '下载已取消。');
      } else if (callbackFailure !== undefined) {
        // 回调侧已经给出准确原因，不再送进网络错误映射。
        failure = callbackFailure;
      } else {
        failure = this.failure(error as Error);
      }
    } finally {
      unsubscribe();
      if (descriptor >= 0) {
        try { fileIo.closeSync(descriptor); }
        catch (_) { failure = new NasFailure(NasErrorKind.Protocol, '下载文件保存失败，请重试。'); }
      }
    }
    if (failure !== undefined) {
      // 只清理本次独占创建的临时文件；清理异常不得掩盖真正的失败原因。
      try { discard(); } catch (_) {}
      throw failure as Error;
    }
    return { path: destination, bytes, discard };
  }

  private check(control: NasTransferControl): void {
    control.cancellation.check();
    if (this.closed()) { throw new NasFailure(NasErrorKind.Cancelled, '连接已关闭。'); }
  }

  private request(plan: NasTransferRequest, body?: rcp.RequestContent): rcp.Request {
    const headers: rcp.RequestHeaders = { 'Accept': '*/*', 'Cache-Control': 'no-store',
      'Accept-Encoding': 'identity' };
    if (plan.session.synoToken.length > 0) { headers['X-SYNO-TOKEN'] = plan.session.synoToken; }
    const address = plan.method === 'GET' ? plan.address + '?' + encodeNasForm(plan.fields) : plan.address;
    const request = new rcp.Request(address, plan.method, headers, body);
    request.cookies = { id: plan.session.sid };
    request.cacheControl = { noStore: true };
    request.configuration = { transfer: { autoRedirect: false, timeout: { connectMs: 10000, transferMs: 120000 } } };
    return request;
  }

  private header(headers: rcp.ResponseHeaders, name: string): string {
    let result = '';
    let found = false;
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() !== name) { continue; }
      const value = headers[key];
      if (found || typeof value !== 'string') { throw new NasFailure(NasErrorKind.Protocol, '无法确认下载响应，请重试。'); }
      found = true; result = value;
    }
    return result;
  }
}
