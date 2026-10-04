import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasConnector } from '../../core/network/NasConnector';
import { NasErrorKind, NasFailure, NasFormField } from '../../core/domain/DsmProtocol';
import { FileSharingRepository } from '../fileSharing/FileSharingRepository';
import { ShareLink, ShareLinkOptions, ShareCreateResult } from '../fileSharing/FileSharingProtocol';
import { DownloadStationRepository } from '../downloadStation/DownloadStationRepository';
import { DownloadTask, DownloadTaskActionResult } from '../downloadStation/DownloadStationProtocol';
import { CapabilitySnapshot } from '../../core/capabilities/CapabilityRegistry';
import { ExtensionFeature, ExtensionPendingWrite, extensionWriteIsUncertain } from '../../core/domain/ExtensionWriteState';
import { ExtensionWriteStore } from './ExtensionWriteStore';

@ObservedV2
export class NasExtensionsModel {
  @Trace busy: boolean = false;
  @Trace recordsReady: boolean = false;
  @Trace recordsError: string = '';
  @Trace shareError: string = '';
  @Trace downloadError: string = '';
  @Trace shareNotice: string = '';
  @Trace downloadNotice: string = '';
  @Trace pending: ExtensionPendingWrite[] = [];
  @Trace capabilities: CapabilitySnapshot[] = [];
  @Trace shares: ShareLink[] = [];
  @Trace shareOffset: number = 0;
  @Trace shareTotal: number = 0;
  @Trace sharesLoaded: boolean = false;
  @Trace selectedShare: ShareLink | undefined = undefined;
  @Trace shareDraftPaths: string[] = [];
  @Trace shareResults: ShareCreateResult[] = [];
  @Trace downloads: DownloadTask[] = [];
  @Trace downloadOffset: number = 0;
  @Trace downloadTotal: number = 0;
  @Trace downloadsLoaded: boolean = false;
  @Trace selectedDownload: DownloadTask | undefined = undefined;
  @Trace downloadUri: string = '';
  @Trace downloadDestination: string = '';
  @Trace downloadFormRequested: boolean = false;
  @Trace canCreateDownload: boolean = false;
  private connector: NasConnector | undefined = undefined;
  private generation: number = 0;
  private store: ExtensionWriteStore = new ExtensionWriteStore();
  private context: common.UIAbilityContext | undefined = undefined;
  private origin: string = '';
  private account: string = '';
  private expired: (error: NasFailure) => Promise<void> = async (): Promise<void> => {};

  async attach(connector: NasConnector, context: common.UIAbilityContext | undefined, origin: string, account: string,
    expired: (error: NasFailure) => Promise<void>): Promise<void> {
    this.reset();
    this.connector = connector;
    this.context = context;
    this.origin = origin;
    this.account = account;
    this.expired = expired;
    this.capabilities = connector.capabilitySnapshots();
    this.canCreateDownload = connector.supportsExtensionAction('nasDownloads', 'create');
    await this.reloadRecords();
  }

  reset(): void {
    this.generation++;
    this.connector = undefined;
    this.context = undefined;
    this.origin = '';
    this.account = '';
    this.store = new ExtensionWriteStore();
    this.busy = false;
    this.recordsReady = false;
    this.recordsError = '';
    this.shareError = '';
    this.downloadError = '';
    this.shareNotice = '';
    this.downloadNotice = '';
    this.pending = [];
    this.capabilities = [];
    this.shares = [];
    this.shareOffset = 0;
    this.shareTotal = 0;
    this.sharesLoaded = false;
    this.selectedShare = undefined;
    this.shareDraftPaths = [];
    this.shareResults = [];
    this.downloads = [];
    this.downloadOffset = 0;
    this.downloadTotal = 0;
    this.downloadsLoaded = false;
    this.selectedDownload = undefined;
    this.downloadUri = '';
    this.downloadDestination = '';
    this.downloadFormRequested = false;
    this.canCreateDownload = false;
  }

  private sharing(connector: NasConnector): FileSharingRepository {
    return new FileSharingRepository(async (method: string, fields: NasFormField[]): Promise<Object> => connector.extensionRequest('fileSharing', method, fields));
  }

  private station(connector: NasConnector): DownloadStationRepository {
    return new DownloadStationRepository(async (method: string, fields: NasFormField[]): Promise<Object> => connector.extensionRequest('nasDownloads', method, fields));
  }

  async refreshShares(offset: number = this.shareOffset): Promise<void> {
    const ticket = this.generation;
    const page = await this.read('fileSharing', async (connector: NasConnector) => this.sharing(connector).list(offset));
    if (page === undefined || ticket !== this.generation) { return; }
    this.shares = page.links;
    this.shareOffset = page.offset;
    this.shareTotal = page.total;
    this.sharesLoaded = true;
  }

  async showShare(id: string): Promise<void> {
    this.selectedShare = undefined;
    const ticket = this.generation;
    const link = await this.read('fileSharing', async (connector: NasConnector) => this.sharing(connector).getInfo(id));
    if (link !== undefined && ticket === this.generation) { this.selectedShare = link; }
  }

  async createShares(options: ShareLinkOptions): Promise<boolean> {
    const ticket = this.generation;
    const paths = this.shareDraftPaths.slice();
    let results: ShareCreateResult[] = [];
    const confirmed = await this.write('fileSharing', 'create', async (connector: NasConnector): Promise<boolean> => {
      results = await this.sharing(connector).create(paths, options);
      return true;
    });
    if (ticket !== this.generation || results.length === 0) { return false; }
    this.shareResults = results;
    const failed = results.filter((item: ShareCreateResult): boolean => item.failure !== undefined);
    this.shareNotice = '已创建 ' + (results.length - failed.length).toString() + ' 个链接' + (failed.length > 0 ? '，' + failed.length.toString() + ' 项未成功。' : '。');
    if (confirmed) { this.shareDraftPaths = []; }
    await this.refreshShares(0);
    return confirmed;
  }

  async editShare(id: string, options: ShareLinkOptions): Promise<boolean> {
    const ticket = this.generation;
    let failure: NasFailure | undefined = undefined;
    const confirmed = await this.write('fileSharing', 'edit', async (connector: NasConnector): Promise<boolean> => {
      const result = await this.sharing(connector).edit(id, options);
      failure = result.failure;
      return true;
    });
    if (ticket !== this.generation) { return false; }
    if (failure !== undefined) { await this.reportFailure('fileSharing', failure as Error, ticket); return false; }
    if (confirmed) { await this.showShare(id); if (ticket === this.generation) { await this.refreshShares(); } }
    return confirmed;
  }

  async revokeShare(id: string): Promise<void> {
    const ticket = this.generation;
    let failure: NasFailure | undefined = undefined;
    const confirmed = await this.write('fileSharing', 'delete', async (connector: NasConnector): Promise<boolean> => {
      const result = (await this.sharing(connector).remove([id]))[0];
      failure = result.failure;
      return true;
    });
    if (ticket !== this.generation) { return; }
    if (failure !== undefined) { await this.reportFailure('fileSharing', failure as Error, ticket); return; }
    if (confirmed) { this.selectedShare = undefined; await this.refreshShares(0); }
  }

  async refreshDownloads(offset: number = this.downloadOffset): Promise<void> {
    const ticket = this.generation;
    const page = await this.read('nasDownloads', async (connector: NasConnector) => this.station(connector).list(offset));
    if (page === undefined || ticket !== this.generation) { return; }
    this.downloads = page.tasks;
    this.downloadOffset = page.offset;
    this.downloadTotal = page.total;
    this.downloadsLoaded = true;
  }

  async showDownload(id: string): Promise<void> {
    this.selectedDownload = undefined;
    const ticket = this.generation;
    const task = await this.read('nasDownloads', async (connector: NasConnector) => this.station(connector).getInfo(id));
    if (task !== undefined && ticket === this.generation) { this.selectedDownload = task; }
  }

  async createDownload(): Promise<boolean> {
    if (!this.canCreateDownload) { this.downloadError = '服务器接口版本不支持带链接和目标目录的创建。'; return false; }
    if (!this.canWrite('nasDownloads')) { return false; }
    const ticket = this.generation;
    const uri = this.downloadUri;
    const destination = this.downloadDestination;
    const confirmed = await this.write('nasDownloads', 'create', async (connector: NasConnector): Promise<boolean> => {
      const result = await this.station(connector).create(uri, destination);
      if (result.taskId === undefined) { return false; }
      await this.station(connector).getInfo(result.taskId);
      return true;
    });
    if (ticket !== this.generation) { return false; }
    if (confirmed || this.hasPending('nasDownloads')) { this.downloadUri = ''; }
    await this.refreshDownloads(0);
    return confirmed;
  }

  async controlDownload(id: string, operation: 'pause' | 'resume' | 'delete'): Promise<void> {
    const ticket = this.generation;
    let failure: NasFailure | undefined = undefined;
    const confirmed = await this.write('nasDownloads', operation, async (connector: NasConnector): Promise<boolean> => {
      const station = this.station(connector);
      let results: DownloadTaskActionResult[];
      if (operation === 'pause') { results = await station.pause([id]); }
      else if (operation === 'resume') { results = await station.resume([id]); }
      else { results = await station.remove([id]); }
      const result = results[0];
      if (!result.success) { failure = new NasFailure(result.errorKind ?? NasErrorKind.Server, result.message, result.errorCode); }
      return true;
    });
    if (ticket !== this.generation) { return; }
    if (failure !== undefined) { await this.reportFailure('nasDownloads', failure as Error, ticket); return; }
    if (confirmed) { this.selectedDownload = undefined; await this.refreshDownloads(); }
  }

  hasPending(feature: ExtensionFeature): boolean {
    return this.pending.some((record: ExtensionPendingWrite): boolean => record.feature === feature);
  }

  canWrite(feature: ExtensionFeature): boolean {
    const capability = this.capabilities.find((item: CapabilitySnapshot): boolean => item.feature === feature);
    return this.connector !== undefined && !this.busy && this.recordsReady && !this.hasPending(feature) &&
      capability !== undefined && capability.apiVersion > 0 &&
      !['unauthorized', 'unreachable', 'schemaMismatch', 'unsupportedVersion'].includes(capability.state);
  }

  capabilityText(feature: ExtensionFeature): string {
    const capability = this.capabilities.find((item: CapabilitySnapshot): boolean => item.feature === feature);
    if (capability === undefined || capability.reason === 'apiNotDiscovered') { return '服务器未发现此接口，无法确认套件是否安装或当前账号是否有权访问。'; }
    if (capability.state === 'unsupportedVersion') { return '服务器接口版本不在已支持范围内。'; }
    if (capability.state === 'unauthorized') { return '当前账号的套件权限或会话未通过验证。'; }
    if (capability.state === 'unreachable') { return '暂时无法连接服务器，请检查网络后刷新。'; }
    if (capability.state === 'schemaMismatch') { return '套件响应与已支持格式不符，不能将其当作空列表。'; }
    return '';
  }

  async reloadRecords(): Promise<void> {
    if (this.busy || this.context === undefined || this.connector === undefined) { return; }
    const ticket = this.generation;
    const store = new ExtensionWriteStore();
    this.busy = true;
    this.recordsReady = false;
    try {
      const pending = await store.load(this.context, this.origin, this.account);
      if (ticket !== this.generation) { return; }
      this.store = store;
      this.pending = pending;
      this.recordsReady = true;
      this.recordsError = '';
    } catch (error) {
      if (ticket === this.generation) { this.recordsError = this.message(error as Error, '操作记录无法读取，新的操作已暂停。'); }
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }

  async acknowledge(feature: ExtensionFeature): Promise<void> {
    if (this.busy || !this.recordsReady || !this.hasPending(feature)) { return; }
    const ticket = this.generation;
    const pending = this.pending.filter((record: ExtensionPendingWrite): boolean => record.feature !== feature);
    this.busy = true;
    try {
      await this.store.save(pending);
      if (ticket !== this.generation) { return; }
      this.pending = pending;
      this.setNotice(feature, '已关闭待核对记录，不代表远端操作成功；如需重做，请另行确认。');
    } catch (error) {
      if (ticket === this.generation) { this.recordsError = this.message(error as Error, '未能保存核对结果，操作仍保持待确认。'); }
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }

  private async read<T>(feature: ExtensionFeature, action: (connector: NasConnector) => Promise<T>): Promise<T | undefined> {
    const connector = this.connector;
    if (this.busy || connector === undefined) { return undefined; }
    const ticket = this.generation;
    this.busy = true;
    this.setError(feature, '');
    try {
      const result = await connector.readExtension(feature, async (): Promise<T> => action(connector));
      if (ticket !== this.generation) { return undefined; }
      return result;
    } catch (error) {
      if (ticket === this.generation) { await this.reportFailure(feature, error as Error, ticket); }
      return undefined;
    } finally {
      if (ticket === this.generation) { this.capabilities = connector.capabilitySnapshots(); this.busy = false; }
    }
  }

  private async write(feature: ExtensionFeature, operation: string, action: (connector: NasConnector) => Promise<boolean>): Promise<boolean> {
    const connector = this.connector;
    if (connector === undefined || !this.canWrite(feature)) { return false; }
    const ticket = this.generation;
    const store = this.store;
    const pending: ExtensionPendingWrite[] = [...this.pending, { feature: feature, operation: operation, createdAt: Date.now() }];
    let submitted = false;
    this.busy = true;
    this.setError(feature, '');
    this.setNotice(feature, '');
    try {
      await store.save(pending);
      if (ticket !== this.generation) { return false; }
      this.pending = pending;
      submitted = true;
      const confirmed = await action(connector);
      if (ticket !== this.generation) { return false; }
      if (!confirmed) {
        this.setNotice(feature, '服务器已接受请求，但尚未关联到唯一结果。请刷新列表或在 DSM 核对，不要重复提交。');
        return false;
      }
      const cleared = pending.filter((record: ExtensionPendingWrite): boolean => record.feature !== feature);
      this.setNotice(feature, '服务器已确认操作结果。');
      await store.save(cleared);
      if (ticket !== this.generation) { return false; }
      this.pending = cleared;
      return true;
    } catch (error) {
      if (ticket !== this.generation) { return false; }
      if (!submitted) {
        this.recordsReady = false;
        this.recordsError = this.message(error as Error, '操作记录保存失败，未发送远端操作。');
        return false;
      }
      if (!extensionWriteIsUncertain(error as Error)) {
        try {
          const cleared = pending.filter((record: ExtensionPendingWrite): boolean => record.feature !== feature);
          await store.save(cleared);
          if (ticket !== this.generation) { return false; }
          this.pending = cleared;
        } catch (storageError) {
          if (ticket === this.generation) { this.recordsError = this.message(storageError as Error, '拒绝结果未能保存，记录仍待核对。'); }
        }
      }
      if (ticket === this.generation) { await this.reportFailure(feature, error as Error, ticket); }
      return false;
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }

  private async reportFailure(feature: ExtensionFeature, error: Error, ticket: number): Promise<void> {
    this.setError(feature, this.message(error, '请求未完成，请刷新列表或在 DSM 核对。'));
    hilog.error(0x0000, 'NasExtensions', 'feature=%{public}s kind=%{public}d code=%{public}d', feature,
      error instanceof NasFailure ? error.kind : -1, error instanceof NasFailure ? error.code : 0);
    if (!(error instanceof NasFailure) || error.kind !== NasErrorKind.SessionExpired) { return; }
    if (feature === 'nasDownloads' && this.connector !== undefined) {
      try { await this.connector.list(''); }
      catch (validationError) {
        if (ticket === this.generation && validationError instanceof NasFailure && validationError.kind === NasErrorKind.SessionExpired) {
          await this.expired(validationError);
        }
        return;
      }
      if (ticket === this.generation) { this.downloadError = 'Download Station 套件会话未建立或已失效，请退出并重新登录；NAS 文件会话仍有效。'; }
    } else if (ticket === this.generation) { await this.expired(error); }
  }

  private setError(feature: ExtensionFeature, text: string): void {
    if (feature === 'fileSharing') { this.shareError = text; } else { this.downloadError = text; }
  }
  private setNotice(feature: ExtensionFeature, text: string): void {
    if (feature === 'fileSharing') { this.shareNotice = text; } else { this.downloadNotice = text; }
  }
  private message(error: Error, fallback: string): string { return error instanceof NasFailure ? error.message : fallback; }
}
