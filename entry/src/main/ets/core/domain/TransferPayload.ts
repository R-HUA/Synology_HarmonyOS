import { NasErrorKind, NasFailure } from './DsmProtocol';

export const TRANSFER_CHUNK_BYTES = 256 * 1024;
export const LARGE_PROBE_BYTES = 64 * 1024 * 1024;

/** 按偏移重复随机种子，生成与文件大小无关的有界缓冲。 */
export function transferChunk(seed: Uint8Array, total: number, offset: number): Uint8Array {
  if (seed.length === 0 || !Number.isSafeInteger(total) || total < 1 ||
    !Number.isSafeInteger(offset) || offset < 0 || offset > total) {
    throw new NasFailure(NasErrorKind.InvalidInput, '测试文件参数不正确。');
  }
  const chunk = new Uint8Array(Math.min(TRANSFER_CHUNK_BYTES, total - offset));
  for (let i = 0; i < chunk.length; i++) { chunk[i] = seed[(offset + i) % seed.length]; }
  return chunk;
}

export function matchesTransferChunk(seed: Uint8Array, offset: number, chunk: Uint8Array): boolean {
  if (seed.length === 0 || !Number.isSafeInteger(offset) || offset < 0) {
    throw new NasFailure(NasErrorKind.InvalidInput, '测试文件参数不正确。');
  }
  return chunk.every((byte: number, index: number): boolean => byte === seed[(offset + index) % seed.length]);
}
