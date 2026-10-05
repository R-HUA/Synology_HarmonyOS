import { decodeNasResponse, dsmFailure, nasInteger, nasRecord, NasErrorKind, NasFailure } from './DsmProtocol';

export function decodeExtensionResponse(api: string, method: string, status: number, text: string): Object {
  if (status !== 200) { return decodeNasResponse(api, status, text); }
  let parsed: Object;
  try { parsed = JSON.parse(text) as Object; }
  catch { throw new NasFailure(NasErrorKind.Protocol, '套件响应不是有效的 JSON，请核对操作结果。'); }
  const envelope = nasRecord(parsed);
  if (envelope['success'] === false) {
    const error = nasRecord(envelope['error']);
    const code = nasInteger(error['code']);
    if (code === 0) { throw new NasFailure(NasErrorKind.Protocol, '套件响应缺少明确结果，请核对操作是否已执行。'); }
    const failure = dsmFailure(api, code);
    // 分享编辑/删除保留逐项错误；会话失效必须先交回内核统一清除授权。
    if (api === 'SYNO.FileStation.Sharing' && failure.kind !== NasErrorKind.SessionExpired) { return envelope; }
    throw failure;
  }
  if (envelope['success'] !== true || envelope['error'] !== undefined) {
    throw new NasFailure(NasErrorKind.Protocol, '套件响应缺少明确结果，请核对操作是否已执行。');
  }
  if (api === 'SYNO.FileStation.Sharing') { return envelope; }
  const data = envelope['data'];
  if (data === undefined) { return {}; }
  if (data === null || typeof data !== 'object') {
    throw new NasFailure(NasErrorKind.Protocol, '套件响应格式不符合预期。');
  }
  if (Array.isArray(data) && !['pause', 'resume', 'delete'].includes(method)) {
    throw new NasFailure(NasErrorKind.Protocol, '套件返回了不符合当前操作的结果。');
  }
  return data;
}
