import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { decodeTransferQueue, TransferQueueRecord, TransferQueueSnapshot } from '../../core/domain/TransferQueueState';

const COPY_CHUNK_BYTES: number = 256 * 1024;
const PREFIX_BYTES: number = 64 * 1024;

export interface TransferFilePrefix { text: string; wholeFile: boolean; }

export function transferQueueDirectory(context: common.UIAbilityContext, scope: string): string {
  return context.filesDir + '/transfers/' + scope;
}

export async function ensureTransferDirectory(path: string): Promise<void> {
  try { await fileIo.mkdir(path, true); }
  catch (error) { if ((error as BusinessError).code !== 13900015) { throw error as Error; } }
}

export async function removeTransferFile(path: string): Promise<void> {
  try { await fileIo.unlink(path); }
  catch (error) { if ((error as BusinessError).code !== 13900002) { throw error as Error; } }
}

/** 仅清理该记录各次尝试的私有副本，不访问系统选择器授权的原文件。 */
export async function removeTransferArtifacts(directory: string, record: TransferQueueRecord): Promise<void> {
  const names = await fileIo.listFile(directory);
  const owned = new RegExp('^' + record.id + '-[1-9][0-9]*\\.bin(?:\\.tmp)?$');
  for (const name of names) {
    if (owned.test(name)) { await removeTransferFile(directory + '/' + name); }
  }
}

async function writeTransferBytes(fd: number, bytes: Uint8Array): Promise<void> {
  let written = 0;
  while (written < bytes.length) {
    const count = await fileIo.write(fd, bytes.slice(written).buffer as ArrayBuffer);
    if (count < 1) { throw new NasFailure(NasErrorKind.Protocol, '无法完整写入本机文件。'); }
    written += count;
  }
}

/** 每次拷贝最多分配一个 256 KiB 读块及有界写块，临时授权仅在此处使用。 */
export async function copyTransferFile(source: string, destination: string, bytes: number,
  current: () => void, exportFile: boolean = false): Promise<void> {
  const input = await fileIo.open(source, fileIo.OpenMode.READ_ONLY);
  try {
    const original = await fileIo.stat(input.fd);
    if (original.isDirectory() || original.size !== bytes) {
      throw new NasFailure(NasErrorKind.InvalidInput, '所选文件已变化，请重新选择。');
    }
    const output = await fileIo.open(destination,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      let copied = 0;
      const buffer = new ArrayBuffer(COPY_CHUNK_BYTES);
      while (copied < bytes) {
        current();
        const count = await fileIo.read(input.fd, buffer, { length: Math.min(COPY_CHUNK_BYTES, bytes - copied) });
        if (count < 1) { throw new NasFailure(NasErrorKind.Protocol, '无法完整读取所选文件。'); }
        await writeTransferBytes(output.fd, new Uint8Array(buffer).subarray(0, count));
        copied += count;
      }
      current();
      if ((await fileIo.stat(input.fd)).size !== bytes || (await fileIo.stat(output.fd)).size !== bytes) {
        throw new NasFailure(NasErrorKind.Protocol, '文件大小在拷贝期间发生变化，请重新选择。');
      }
      // 公共文件的 provider 不一定支持 fsync；私有持久副本在入队前必须落盘。
      if (!exportFile) { await fileIo.fsync(output.fd); }
    } finally { await fileIo.close(output); }
  } finally { await fileIo.close(input); }
}

export async function readTransferPrefix(path: string, bytes: number): Promise<TransferFilePrefix> {
  const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
  try {
    const length = Math.min(PREFIX_BYTES, bytes);
    const buffer = new ArrayBuffer(length);
    let offset = 0;
    while (offset < length) {
      const chunk = new ArrayBuffer(length - offset);
      const count = await fileIo.read(file.fd, chunk);
      if (count < 1) { throw new NasFailure(NasErrorKind.Protocol, '下载文件读取不完整。'); }
      new Uint8Array(buffer).set(new Uint8Array(chunk).subarray(0, count), offset);
      offset += count;
    }
    return { text: new util.TextDecoder().decodeWithStream(new Uint8Array(buffer)), wholeFile: bytes <= PREFIX_BYTES };
  } finally { await fileIo.close(file); }
}

/** 仅用于和 NAS 的文件摘要对照，以有界读块核对实际内容。 */
export async function hashTransferFile(path: string, bytes: number, current: () => void): Promise<string> {
  const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
  try {
    const before = await fileIo.stat(file.fd);
    if (before.isDirectory() || before.size !== bytes) { throw new NasFailure(NasErrorKind.Protocol, '本机副本大小不符，无法核验内容。'); }
    const digest = cryptoFramework.createMd('MD5');
    const buffer = new ArrayBuffer(COPY_CHUNK_BYTES);
    let processed = 0;
    while (processed < bytes) {
      current();
      const count = await fileIo.read(file.fd, buffer, { length: Math.min(COPY_CHUNK_BYTES, bytes - processed) });
      if (count < 1) { throw new NasFailure(NasErrorKind.Protocol, '本机副本读取不完整，无法核验内容。'); }
      await digest.update({ data: new Uint8Array(buffer).subarray(0, count) });
      processed += count;
    }
    current();
    if ((await fileIo.stat(file.fd)).size !== bytes) { throw new NasFailure(NasErrorKind.Protocol, '本机副本在核验期间发生变化。'); }
    return (await digest.digest()).data.reduce((text: string, byte: number): string => text + byte.toString(16).padStart(2, '0'), '');
  } finally { await fileIo.close(file); }
}

export async function readTransferRecords(directory: string, scope: string): Promise<TransferQueueRecord[]> {
  const path = directory + '/queue.json';
  let stat: fileIo.Stat;
  try {
    stat = await fileIo.stat(path);
  } catch (error) {
    if ((error as BusinessError).code === 13900002) { return []; }
    throw error as Error;
  }
  if (stat.size > 4 * 1024 * 1024) { throw new NasFailure(NasErrorKind.Protocol, '传输记录过大，无法安全恢复。'); }
  // 已存在的文件在读取期间消失也属于读取失败，不能被当作首次使用的空历史。
  return decodeTransferQueue(await fileIo.readText(path), scope);
}

/** 调用方串行化写入；任务 ID 的 fsync + rename 完成后才能 start。 */
export async function saveTransferRecords(directory: string, scope: string, records: TransferQueueRecord[]): Promise<void> {
  const snapshot: TransferQueueSnapshot = { version: 1, scope: scope, records: records };
  const path = directory + '/queue.json';
  const file = await fileIo.open(path + '.tmp', fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  try {
    await writeTransferBytes(file.fd, new util.TextEncoder().encodeInto(JSON.stringify(snapshot)));
    await fileIo.fsync(file.fd);
  } finally { await fileIo.close(file); }
  await fileIo.rename(path + '.tmp', path);
}
