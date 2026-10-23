import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure, NasFormField, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import { NasConnector } from '../../core/network/NasConnector';
import { InstalledPackage } from './PackageProtocol';
import { PackageRepository } from './PackageRepository';

/** 目录缓存只属于本次连接；页面离开后旧请求不能回写缓存或触发账号操作。 */
@ObservedV2
export class PackageCatalogModel {
  @Trace items: InstalledPackage[] = [];
  @Trace loaded: boolean = false;
  @Trace loading: boolean = false;
  @Trace error: Error | undefined = undefined;
  @Trace checkedAt: number = 0;
  @Trace query: string = '';
  @Trace supportedOnly: boolean = false;
  @Trace selected: InstalledPackage | undefined = undefined;
  @Trace detailLoading: boolean = false;
  @Trace detailError: Error | undefined = undefined;
  private connector: NasConnector | undefined = undefined;
  private expired: (error: NasFailure) => Promise<void> = async (): Promise<void> => {};
  private generation: number = 0;
  private listRevision: number = 0;
  private detailRevision: number = 0;
  private listVisible: boolean = false;
  private detailVisible: boolean = false;
  private origin: string = '';

  attach(connector: NasConnector, origin: string, expired: (error: NasFailure) => Promise<void>): void {
    this.reset();
    this.connector = connector;
    this.origin = normalizeNasOrigin(origin);
    this.expired = expired;
  }

  reset(): void {
    this.generation++;
    this.hideList(); this.hideDetail();
    this.connector = undefined; this.origin = '';
    this.expired = async (): Promise<void> => {};
    this.items = []; this.loaded = false; this.error = undefined; this.checkedAt = 0;
    this.query = ''; this.supportedOnly = false;
    this.selected = undefined; this.detailError = undefined;
  }

  managementOrigin(): string { return this.origin; }

  private repository(connector: NasConnector): PackageRepository {
    return new PackageRepository((method: 'list' | 'get', fields: NasFormField[]): Promise<Object> => connector.packageRequest(method, fields));
  }

  showList(): void {
    this.listVisible = true;
    if (!this.loaded && this.error === undefined) { this.refresh(); }
  }

  hideList(): void { this.listVisible = false; this.listRevision++; this.loading = false; }

  async refresh(): Promise<void> {
    const connector = this.connector;
    if (!this.listVisible || this.loading || connector === undefined) { return; }
    const generation = this.generation;
    const revision = ++this.listRevision;
    this.loading = true; this.error = undefined;
    try {
      const items = await connector.readPackageCatalog((): Promise<InstalledPackage[]> => this.repository(connector).list());
      if (generation !== this.generation || revision !== this.listRevision) { return; }
      this.items = items; this.loaded = true; this.checkedAt = Date.now();
    } catch (error) {
      if (generation !== this.generation || revision !== this.listRevision) { return; }
      this.error = error as Error;
      this.logFailure('list', error as Error);
      if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { await this.expired(error); }
    } finally {
      if (generation === this.generation && revision === this.listRevision) { this.loading = false; }
    }
  }

  select(item: InstalledPackage): void {
    this.hideDetail();
    this.selected = item; this.detailError = undefined;
  }

  showDetail(): void {
    this.detailVisible = true;
    this.refreshDetail();
  }

  hideDetail(): void { this.detailVisible = false; this.detailRevision++; this.detailLoading = false; }

  async refreshDetail(): Promise<void> {
    const connector = this.connector;
    const selected = this.selected;
    if (!this.detailVisible || this.detailLoading || connector === undefined || selected === undefined) { return; }
    const generation = this.generation;
    const revision = ++this.detailRevision;
    this.detailLoading = true; this.detailError = undefined;
    try {
      const item = await this.repository(connector).get(selected.id);
      if (generation !== this.generation || revision !== this.detailRevision) { return; }
      this.selected = item;
    } catch (error) {
      if (generation !== this.generation || revision !== this.detailRevision) { return; }
      this.detailError = error as Error;
      this.logFailure('get', error as Error);
      if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { await this.expired(error); }
    } finally {
      if (generation === this.generation && revision === this.detailRevision) { this.detailLoading = false; }
    }
  }

  private logFailure(operation: string, error: Error): void {
    hilog.error(0x0000, 'PackageCatalog', 'operation=%{public}s kind=%{public}d code=%{public}d', operation,
      error instanceof NasFailure ? error.kind : -1, error instanceof NasFailure ? error.code : 0);
  }
}
