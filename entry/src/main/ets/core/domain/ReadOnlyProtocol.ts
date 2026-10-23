import { decodeNasResponse, NasErrorKind, NasFailure } from './DsmProtocol';

export const READ_WINDOW_BYTES: number = 512 * 1024;
export const READ_WINDOW_ROWS: number = 500;

/** 不透明整数在 JSON 解析前转为字符串，不能先舍入再恢复身份。 */
export function decodeReadOnlyResponse(api: string, status: number, text: string): Record<string, Object> {
  const precise = text.replace(/"(?:\\.|[^"\\])*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g,
    (token: string): string => /^-?\d{16,}$/.test(token) && !Number.isSafeInteger(Number(token)) ? '"' + token + '"' : token);
  return decodeNasResponse(api, status, precise);
}

export function readId(value: Object | undefined): string {
  if (typeof value === 'string' && value.length > 0 && !/[\u0000-\u001f\u007f]/.test(value)) { return value; }
  if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 0) { return value.toString(); }
  throw new NasFailure(NasErrorKind.Protocol, '服务器返回了无效的条目标识。');
}

export function readText(value: Object | undefined): string {
  if (value === undefined || value === null) { return ''; }
  if (typeof value !== 'string') { throw new NasFailure(NasErrorKind.Protocol, '服务器返回的文字格式不正确。'); }
  return value;
}

export function readNumber(value: Object | undefined): number | undefined {
  if (value === undefined || value === null) { return undefined; }
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new NasFailure(NasErrorKind.Protocol, '服务器返回的数值格式不正确。');
  }
  return value;
}

export function readArray(value: Object | undefined): Object[] {
  if (!Array.isArray(value)) { throw new NasFailure(NasErrorKind.Protocol, '服务器返回的列表格式不正确。'); }
  return value as Object[];
}

export function utf8Bytes(text: string): number {
  let bytes = 0;
  for (const character of text) {
    const point = character.codePointAt(0)!;
    bytes += point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
  }
  return bytes;
}

/** 保留换行和制表符，终端转义与控制字符不进入日志阅读区。 */
export function readableLog(text: string): string {
  return text.replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, '').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '');
}

export interface TextWindow { text: string; truncated: boolean; }

export function limitLogText(text: string): TextWindow {
  const lines = readableLog(text).split('\n');
  let result = '', bytes = 0, count = 0;
  for (const line of lines) {
    if (count >= READ_WINDOW_ROWS) { return { text: result, truncated: true }; }
    const separator = count > 0 ? '\n' : '';
    for (const character of separator + line) {
      const length = utf8Bytes(character);
      if (bytes + length > READ_WINDOW_BYTES) { return { text: result, truncated: true }; }
      result += character; bytes += length;
    }
    count++;
  }
  return { text: result, truncated: false };
}
