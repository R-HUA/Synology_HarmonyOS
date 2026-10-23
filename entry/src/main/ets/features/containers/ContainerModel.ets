import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasFailure, NasErrorKind } from '../../core/domain/DsmProtocol';
import { NasConnector } from '../../core/network/NasConnector';
import { ContainerDetail, ContainerItem, ContainerResource, ContainerState } from './ContainerProtocol';
import { ContainerRepository } from './ContainerRepository';

/** 缓存只属于当前连接，离页及后台同时取消跟随与迟到回写。 */
@ObservedV2
export class ContainerModel {
  @Trace items: ContainerItem[] = [];
  @Trace loaded: boolean = false;
  @Trace loading: boolean = false;
  @Trace checkedAt: number = 0;
  @Trace errorText: string = '';
  @Trace query: string = '';
  @Trace filter: ContainerState | 'all' = 'all';
  @Trace selected: ContainerItem | undefined = undefined;
  @Trace detail: ContainerDetail | undefined = undefined;
  @Trace detailLoading: boolean = false;
  @Trace detailError: string = '';
  @Trace resource: ContainerResource | undefined = undefined;
  @Trace resourceError: string = '';
  @Trace logs: string = '';
  @Trace logsLoaded: boolean = false;
  @Trace logsLoading: boolean = false;
  @Trace logsError: string = '';
  @Trace logsCheckedAt: number = 0;
  @Trace logsTruncated: boolean = false;
  @Trace following: boolean = false;
  private repository: ContainerRepository | undefined = undefined;
  private onExpired: (error: NasFailure) => Promise<void> = async (): Promise<void> => {};
  private generation: number = 0;
  private listRevision: number = 0;
  private detailRevision: number = 0;
  private visible: boolean = false;
  private timer: number = -1;

  attach(connector: NasConnector, onExpired: (error: NasFailure) => Promise<void>): void {
    this.reset(); this.repository = new ContainerRepository(connector); this.onExpired = onExpired;
  }

  reset(): void {
    this.generation++; this.setVisible(false); this.repository = undefined;
    this.items = []; this.loaded = false; this.checkedAt = 0; this.errorText = ''; this.query = ''; this.filter = 'all';
    this.back(); this.onExpired = async (): Promise<void> => {};
  }

  setVisible(visible: boolean): void {
    if (this.visible === visible) { return; }
    this.visible = visible;
    if (!visible) {
      this.listRevision++; this.detailRevision++; this.loading = false; this.detailLoading = false; this.logsLoading = false;
      this.stopFollowing();
    } else if (this.selected !== undefined && this.detail === undefined) { this.refreshDetail(); }
    else if (!this.loaded && this.errorText.length === 0) { this.refresh(); }
  }

  async refresh(): Promise<void> {
    const repository = this.repository;
    if (!this.visible || this.loading || repository === undefined) { return; }
    const generation = this.generation, revision = ++this.listRevision;
    this.loading = true; this.errorText = '';
    try {
      const items = await repository.list();
      if (generation !== this.generation || revision !== this.listRevision) { return; }
      this.items = items; this.loaded = true; this.checkedAt = Date.now();
    } catch (error) {
      if (generation === this.generation && revision === this.listRevision) {
        const message = await this.failure(error as Error, 'list');
        if (generation === this.generation && revision === this.listRevision) { this.errorText = message; }
      }
    } finally { if (generation === this.generation && revision === this.listRevision) { this.loading = false; } }
  }

  select(item: ContainerItem): void {
    this.back(); this.selected = item; this.refreshDetail();
  }

  back(): boolean {
    const selected = this.selected !== undefined;
    this.detailRevision++; this.stopFollowing(); this.selected = undefined; this.detail = undefined; this.resource = undefined;
    this.detailLoading = false; this.logsLoading = false; this.detailError = ''; this.resourceError = '';
    this.logs = ''; this.logsLoaded = false; this.logsError = ''; this.logsCheckedAt = 0; this.logsTruncated = false;
    return selected;
  }

  async refreshDetail(): Promise<void> {
    const repository = this.repository, item = this.selected;
    if (!this.visible || repository === undefined || item === undefined || this.detailLoading) { return; }
    const revision = ++this.detailRevision;
    this.stopFollowing(); this.logsLoading = false; this.detailLoading = true; this.detailError = ''; this.resourceError = '';
    const check = (): void => { if (revision !== this.detailRevision) { throw new NasFailure(NasErrorKind.Cancelled, '读取已取消。'); } };
    try {
      const detail = await repository.detail(item);
      if (revision !== this.detailRevision) { return; }
      this.detail = detail;
      try {
        const resource = await repository.resources(item, check);
        if (revision === this.detailRevision) { this.resource = resource; }
      } catch (error) {
        if (revision === this.detailRevision) {
          const message = await this.failure(error as Error, 'resources');
          if (revision === this.detailRevision) { this.resourceError = message; }
        }
      }
    } catch (error) {
      if (revision === this.detailRevision) {
        const message = await this.failure(error as Error, 'detail');
        if (revision === this.detailRevision) { this.detailError = message; }
      }
    }
    finally { if (revision === this.detailRevision) { this.detailLoading = false; } }
  }

  async refreshLogs(): Promise<void> {
    const repository = this.repository, item = this.selected;
    if (!this.visible || repository === undefined || item === undefined || this.logsLoading) { return; }
    const revision = this.detailRevision;
    this.logsLoading = true; this.logsError = '';
    try {
      const result = await repository.logs(item, (): void => {
        if (revision !== this.detailRevision) { throw new NasFailure(NasErrorKind.Cancelled, '读取已取消。'); }
      });
      if (revision !== this.detailRevision) { return; }
      this.logs = result.text; this.logsTruncated = result.truncated; this.logsLoaded = true; this.logsCheckedAt = Date.now();
    } catch (error) {
      if (revision === this.detailRevision) {
        this.stopFollowing(); const message = await this.failure(error as Error, 'logs');
        if (revision === this.detailRevision) { this.logsError = message; }
      }
    } finally { if (revision === this.detailRevision) { this.logsLoading = false; this.schedule(); } }
  }

  startFollowing(): void {
    if (!this.visible || this.selected === undefined) { return; }
    this.following = true; this.refreshLogs();
  }

  stopFollowing(): void {
    this.following = false;
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
  }

  private schedule(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    if (this.following && this.visible) {
      this.timer = setTimeout((): void => { this.timer = -1; this.refreshLogs(); }, 5000);
    }
  }

  private async failure(error: Error, operation: string): Promise<string> {
    hilog.error(0x0000, 'NasContainers', 'operation=%{public}s result=failed kind=%{public}d code=%{public}d', operation,
      error instanceof NasFailure ? error.kind : -1, error instanceof NasFailure ? error.code : -1);
    if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { await this.onExpired(error); }
    return error instanceof NasFailure ? error.message : '容器读取失败，请重试。';
  }
}
