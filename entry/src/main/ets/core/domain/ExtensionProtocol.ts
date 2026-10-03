import { decodeNasResponse, dsmFailure, nasInteger, nasRecord, NasErrorKind, NasFailure } from './DsmProtocol';

export function decodeExtensionResponse(api: string, method: string, status: number, text: string): Object {
  if (status !== 200) { return decodeNasResponse(api, status, text); }
  let parsed: Object;
  try { parsed = JSON.parse(text) as Object; }
  catch { throw new NasFailure(NasErrorKind.Protocol, '套件响应不是有效的 JSON，请核对操作结果。'); }
  const envelope = nasRecord(parsed);
  if (api === 'SYNO.FileStation.Sharing' && typeof envelope['success'] === 'boolean') { return envelope; }
  if (envelope['success'] === false) {
    const error = nasRecord(envelope['error']);
    throw dsmFailure(api, nasInteger(error['code']));
  }
  if (envelope['success'] !== true || envelope['error'] !== undefined) {
    throw new NasFailure(NasErrorKind.Protocol, '套件响应缺少明确结果，请核对操作是否已执行。');
  }
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
