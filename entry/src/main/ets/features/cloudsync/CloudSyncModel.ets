import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasFailure, NasErrorKind } from '../../core/domain/DsmProtocol';
import { NasConnector } from '../../core/network/NasConnector';
import { CloudConnection, CloudFolder, CloudHistory, CloudQuota, cloudHistoryWindow } from './CloudSyncProtocol';
import { CloudSyncRepository } from './CloudSyncRepository';

/** 目录与历史各自保留读取结果，次要请求失败不清空已成功内容。 */
@ObservedV2
export class CloudSyncModel {
  @Trace items: CloudConnection[] = [];
  @Trace loaded: boolean = false;
  @Trace loading: boolean = false;
  @Trace checkedAt: number = 0;
  @Trace errorText: string = '';
  @Trace selected: CloudConnection | undefined = undefined;
  @Trace folders: CloudFolder[] = [];
  @Trace detailLoaded: boolean = false;
  @Trace detailLoading: boolean = false;
  @Trace detailError: string = '';
  @Trace quota: CloudQuota | undefined = undefined;
  @Trace quotaError: string = '';
  @Trace history: CloudHistory[] = [];
  @Trace historyLoaded: boolean = false;
  @Trace historyLoading: boolean = false;
  @Trace historyError: string = '';
  @Trace historyAt: number = 0;
  @Trace more: boolean = false;
  @Trace truncated: boolean = false;
  private repository: CloudSyncRepository | undefined = undefined;
  private visible: boolean = false;
  private revision: number = 0;
  private detailRevision: number = 0;
  private historyRevision: number = 0;
  private offset: number = 0;
  private until: number = 0;
  private onExpired: (error: NasFailure) => Promise<void> = async (): Promise<void> => {};

  attach(connector: NasConnector, expired: (error: NasFailure) => Promise<void>): void {
    this.reset(); this.repository = new CloudSyncRepository(connector); this.onExpired = expired;
  }
  reset(): void {
    this.setVisible(false); this.revision++; this.back(); this.repository = undefined;
    this.items = []; this.loaded = false; this.checkedAt = 0; this.errorText = ''; this.onExpired = async (): Promise<void> => {};
  }
  setVisible(value: boolean): void {
    if (this.visible === value) { return; } this.visible = value;
    if (!value) { this.revision++; this.detailRevision++; this.historyRevision++; this.loading = false; this.detailLoading = false; this.historyLoading = false; }
    else if (this.selected !== undefined && !this.detailLoaded) { this.refreshDetail(); }
    else if (!this.loaded && this.errorText.length === 0) { this.refresh(); }
  }
  async refresh(): Promise<void> {
    const repository = this.repository;
    if (!this.visible || this.loading || repository === undefined) { return; }
    const revision = ++this.revision; this.loading = true; this.errorText = '';
    try { const items = await repository.list(); if (revision === this.revision) { this.items = items; this.loaded = true; this.checkedAt = Date.now(); } }
    catch (error) { if (revision === this.revision) { const text = await this.failure(error as Error, 'connections'); if (revision === this.revision) { this.errorText = text; } } }
    finally { if (revision === this.revision) { this.loading = false; } }
  }
  select(item: CloudConnection): void { this.back(); this.selected = item; this.refreshDetail(); }
  back(): boolean {
    const selected = this.selected !== undefined; this.detailRevision++; this.historyRevision++; this.selected = undefined;
    this.folders = []; this.detailLoaded = false; this.detailLoading = false; this.detailError = ''; this.quota = undefined; this.quotaError = '';
    this.history = []; this.historyLoaded = false; this.historyLoading = false; this.historyError = ''; this.historyAt = 0;
    this.offset = 0; this.until = 0; this.more = false; this.truncated = false; return selected;
  }
  async refreshDetail(): Promise<void> {
    const repository = this.repository, item = this.selected;
    if (!this.visible || this.detailLoading || repository === undefined || item === undefined) { return; }
    const revision = ++this.detailRevision; this.detailLoading = true; this.detailError = ''; this.quotaError = '';
    try {
      const folders = await repository.folders(item.id, (): void => {
        if (revision !== this.detailRevision) { throw new NasFailure(NasErrorKind.Cancelled, '读取已取消。'); }
      });
      if (revision !== this.detailRevision) { return; } this.folders = folders; this.detailLoaded = true;
      try { const quota = await repository.quota(item.id); if (revision === this.detailRevision) { this.quota = quota; } }
      catch (error) { if (revision === this.detailRevision) { const text = await this.failure(error as Error, 'quota'); if (revision === this.detailRevision) { this.quotaError = text; } } }
    } catch (error) { if (revision === this.detailRevision) { const text = await this.failure(error as Error, 'folders'); if (revision === this.detailRevision) { this.detailError = text; } } }
    finally { if (revision === this.detailRevision) { this.detailLoading = false; } }
  }
  async readHistory(append: boolean = false): Promise<void> {
    const repository = this.repository, item = this.selected;
    if (!this.visible || this.historyLoading || repository === undefined || item === undefined || append && (!this.more || this.truncated)) { return; }
    const revision = ++this.historyRevision, offset = append ? this.offset : 0, until = append ? this.until : Math.floor(Date.now() / 1000);
    this.historyLoading = true; this.historyError = '';
    try {
      const page = await repository.history(item.id, offset, until);
      if (revision !== this.historyRevision) { return; }
      const all = (append ? this.history : []).concat(page.items), bounded = cloudHistoryWindow(all);
      this.history = bounded; this.historyLoaded = true; this.historyAt = Date.now(); this.offset = offset + page.received; this.until = until;
      this.truncated = bounded.length < all.length || bounded.length >= 500 && page.more; this.more = page.more && !this.truncated;
    } catch (error) { if (revision === this.historyRevision) { const text = await this.failure(error as Error, 'history'); if (revision === this.historyRevision) { this.historyError = text; } } }
    finally { if (revision === this.historyRevision) { this.historyLoading = false; } }
  }
  private async failure(error: Error, operation: string): Promise<string> {
    hilog.error(0, 'NasCloudSync', 'operation=%{public}s kind=%{public}d code=%{public}d', operation,
      error instanceof NasFailure ? error.kind : -1, error instanceof NasFailure ? error.code : -1);
    if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { await this.onExpired(error); }
    return error instanceof NasFailure ? error.message : '云同步读取失败，请重试。';
  }
}
