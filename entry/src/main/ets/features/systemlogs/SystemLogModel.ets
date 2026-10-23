import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasFailure, NasErrorKind } from '../../core/domain/DsmProtocol';
import { NasConnector } from '../../core/network/NasConnector';
import { SystemLogRecord, systemLogWindow } from './SystemLogProtocol';
import { SystemLogRepository } from './SystemLogRepository';

@ObservedV2
export class SystemLogModel {
  @Trace items: SystemLogRecord[] = [];
  @Trace loaded: boolean = false;
  @Trace loading: boolean = false;
  @Trace checkedAt: number = 0;
  @Trace errorText: string = '';
  @Trace more: boolean = false;
  @Trace truncated: boolean = false;
  @Trace query: string = '';
  @Trace level: string = '全部';
  @Trace source: string = '全部';
  @Trace hours: number = 0;
  @Trace selected: SystemLogRecord | undefined = undefined;
  private visible: boolean = false;
  private revision: number = 0;
  private offset: number = 0;
  private until: number = 0;
  private repository: SystemLogRepository | undefined = undefined;
  private onExpired: (error: NasFailure) => Promise<void> = async (): Promise<void> => {};
  attach(connector: NasConnector, expired: (error: NasFailure) => Promise<void>): void {
    this.reset(); this.repository = new SystemLogRepository(connector); this.onExpired = expired;
  }
  reset(): void {
    this.setVisible(false); this.revision++; this.items = []; this.loaded = false; this.loading = false; this.checkedAt = 0; this.errorText = '';
    this.more = false; this.truncated = false; this.offset = 0; this.until = 0; this.query = ''; this.level = '全部'; this.source = '全部'; this.hours = 0;
    this.selected = undefined; this.repository = undefined; this.onExpired = async (): Promise<void> => {};
  }
  setVisible(value: boolean): void {
    if (this.visible === value) { return; } this.visible = value;
    if (!value) { this.revision++; this.loading = false; }
    else if (!this.loaded && this.errorText.length === 0) { this.refresh(); }
  }
  back(): boolean { const selected = this.selected !== undefined; this.selected = undefined; return selected; }
  async refresh(append: boolean = false): Promise<void> {
    const repository = this.repository;
    if (!this.visible || this.loading || repository === undefined || append && (!this.more || this.truncated)) { return; }
    const revision = ++this.revision, offset = append ? this.offset : 0, until = append ? this.until : Math.floor(Date.now() / 1000);
    this.loading = true; this.errorText = '';
    try {
      const page = await repository.list(offset, until);
      if (revision !== this.revision) { return; }
      const all = (append ? this.items : []).concat(page.items), bounded = systemLogWindow(all);
      this.items = bounded; this.loaded = true; this.checkedAt = Date.now(); this.until = until; this.offset = offset + page.received;
      this.truncated = bounded.length < all.length || bounded.length >= 500 && page.more;
      this.more = page.more && this.offset < 500 && !this.truncated; this.selected = undefined;
    } catch (error) {
      if (revision === this.revision) {
        hilog.error(0, 'NasSystemLogs', 'operation=list kind=%{public}d code=%{public}d',
          error instanceof NasFailure ? error.kind : -1, error instanceof NasFailure ? error.code : -1);
        if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { await this.onExpired(error); }
        if (revision === this.revision) { this.errorText = error instanceof NasFailure ? error.message : '系统日志读取失败，请重试。'; }
      }
    } finally { if (revision === this.revision) { this.loading = false; } }
  }
}
