import { statfs } from '@kit.CoreFileKit';
import { NasErrorKind, NasFailure } from '../core/domain/DsmProtocol';

const STORAGE_MARGIN_BYTES = 32 * 1024 * 1024;

/** 已写入的文件由文件系统计数，这里只保留各模块尚未写入的字节。 */
export class LocalSpaceBudget {
  private remaining: Map<string, number> = new Map();
  private tail: Promise<void> = Promise.resolve();

  async reserve(directory: string, key: string, bytes: number): Promise<void> {
    const work = this.tail.then(async (): Promise<void> => {
      const free = await statfs.getFreeSize(directory);
      let reserved = 0;
      this.remaining.forEach((value: number, id: string): void => { if (id !== key) { reserved += value; } });
      if (free - reserved - STORAGE_MARGIN_BYTES < bytes) {
        throw new NasFailure(NasErrorKind.InvalidInput, '本机空间不足，请清理已结束任务或释放空间后重试。');
      }
      this.remaining.set(key, bytes);
    });
    // 串行锁只承接完成信号，实际错误仍交给本次调用者。
    this.tail = work.then((): void => {}, (): void => {});
    await work;
  }

  advance(key: string, remainingBytes: number): void {
    const previous = this.remaining.get(key);
    if (previous !== undefined) { this.remaining.set(key, Math.min(previous, Math.max(0, remainingBytes))); }
  }

  release(key: string): void { this.remaining.delete(key); }
}

export const localSpaceBudget = new LocalSpaceBudget();
