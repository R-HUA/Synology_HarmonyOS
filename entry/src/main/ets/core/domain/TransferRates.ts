interface RateSample { processed: number; at: number; rate?: number; }

/** 速率只取当前进程的相邻进度回调，不用历史文件大小推测。 */
export class TransferRates {
  private samples: Map<string, RateSample> = new Map();
  sample(id: string, processed: number, state: string, now: number = Date.now()): number | undefined {
    if (state !== 'running') { this.samples.delete(id); return undefined; }
    const previous = this.samples.get(id);
    if (previous === undefined || processed < previous.processed) {
      this.samples.set(id, { processed, at: now }); return undefined;
    }
    if (now - previous.at < 500) { return previous.rate; }
    const rate = Math.max(0, (processed - previous.processed) * 1000 / (now - previous.at));
    this.samples.set(id, { processed, at: now, rate });
    return rate;
  }
  clear(): void { this.samples.clear(); }
}

export function transferRemainingSeconds(total: number | undefined, processed: number | undefined,
  rate: number | undefined): number | undefined {
  return total !== undefined && processed !== undefined && rate !== undefined && rate > 0 && total > processed ?
    Math.ceil((total - processed) / rate) : undefined;
}
