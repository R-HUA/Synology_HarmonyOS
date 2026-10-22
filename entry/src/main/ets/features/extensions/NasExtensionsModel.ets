import { common } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { NasTransferCancellation } from '../../core/network/NasTransferTransport';
import { decodeDownloadCreateResult, validateDownloadDestination } from '../downloadStation/DownloadStationProtocol';
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
import { PhotoActionInput, PhotoActionResult } from '../../core/domain/PhotoActions';

@ObservedV2
export class NasExtensionsModel {
  @Trace busy: boolean = false;
  @Trace recordsReady: boolean = false;
  @Trace recordsError: string = '';
  @Trace shareError: string = '';
  @Trace downloadError: string = '';
  @Trace shareNotice: string = '';
  @Trace downloadNotice: string = '';
  @Trace photoError: string = '';
  @Trace photoNotice: string = '';
  @Trace photoShare: string = '';
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
  @Trace downloadsLoading: boolean = false;
  @Trace downloadHasMore: boolean = false;
  @Trace downloadListChanged: boolean = false;
  @Trace downloadRetryAppend: boolean = false;
  @Trace downloadListError: string = '';
  @Trace downloadDetailLoading: boolean = false;
  @Trace downloadDetailError: string = '';
  @Trace selectedDownload: DownloadTask | undefined = undefined;
  @Trace downloadUri: string = '';
  @Trace torrentName: string = '';
  private torrentPath: string = '';
  @Trace downloadDestination: string = '';
  @Trace downloadFreeBytes: number | undefined = undefined;
  @Trace downloadSpaceError: string = '';
  @Trace downloadFormRequested: boolean = false;
  @Trace canCreateDownload: boolean = false;
  @Trace downloadAuthenticationRequired: boolean = false;
  @Trace downloadPassword: string = '';
  @Trace downloadOtp: string = '';
  @Trace downloadNeedsOtp: boolean = false;
  private connector: NasConnector | undefined = undefined;
  private generation: number = 0;
  private downloadListRevision: number = 0;
  private downloadDetailRevision: number = 0;
  private store: ExtensionWriteStore = new ExtensionWriteStore();
  private context: common.UIAbilityContext | undefined = undefined;
  private origin: string = '';
  private account: string = '';
  private expired: (error: NasFailure) => Promise<void> = async (): Promise<void> => {};
  private writeAllowed: () => boolean = (): boolean => true;

  async attach(connector: NasConnector, context: common.UIAbilityContext | undefined, origin: string, account: string,
    expired: (error: NasFailure) => Promise<void>, writeAllowed: () => boolean = (): boolean => true): Promise<void> {
    this.reset();
    this.connector = connector;
    this.context = context;
    this.origin = origin;
    this.account = account;
    this.expired = expired;
    this.writeAllowed = writeAllowed;
    this.capabilities = connector.capabilitySnapshots();
    this.canCreateDownload = connector.supportsExtensionAction('nasDownloads', 'create');
    await this.reloadRecords();
  }

  reset(): void {
    this.clearTorrent();
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
    this.photoError = ''; this.photoNotice = ''; this.photoShare = '';
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
    this.downloadsLoading = false;
    this.downloadHasMore = false;
    this.downloadRetryAppend = false;
    this.downloadListError = '';
    this.downloadListChanged = false;
    this.downloadListRevision++;
    this.closeDownloadDetail();
    this.selectedDownload = undefined;
    this.downloadUri = '';
    this.downloadDestination = '';
    this.downloadFreeBytes = undefined; this.downloadSpaceError = '';
    this.downloadFormRequested = false;
    this.canCreateDownload = false;
    this.cancelDownloadAuthentication();
    this.downloadAuthenticationRequired = false;
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

  async refreshDownloads(offset: number = 0): Promise<boolean> {
    return this.loadDownloadPage(offset, false);
  }

  async loadMoreDownloads(): Promise<boolean> {
    if (!this.downloadsLoaded || !this.downloadHasMore) { return false; }
    return this.loadDownloadPage(this.downloadOffset, true);
  }

  /** 游标按原始响应推进，重复任务只更新内容，不改变已有顺序。 */
  private async loadDownloadPage(offset: number, append: boolean): Promise<boolean> {
    if (this.busy || this.downloadsLoading || this.connector === undefined) { return false; }
    const ticket = this.generation;
    const revision = ++this.downloadListRevision;
    this.downloadsLoading = true;
    this.downloadRetryAppend = append;
    this.downloadListError = '';
    const page = await this.read('nasDownloads', async (connector: NasConnector) => this.station(connector).list(offset),
      (): boolean => revision === this.downloadListRevision);
    if (ticket !== this.generation || revision !== this.downloadListRevision) { return false; }
    this.downloadsLoading = false;
    if (page === undefined) { this.downloadListError = this.downloadError; return false; }
    const merged = append ? this.downloads.slice() : [];
    let duplicate = false;
    for (const task of page.tasks) {
      const index = merged.findIndex((item: DownloadTask): boolean => item.id === task.id);
      if (index < 0) { merged.push(task); }
      else { merged[index] = task; duplicate = true; }
    }
    this.downloadListChanged = append && (this.downloadListChanged || duplicate || page.total !== this.downloadTotal);
    this.downloads = merged;
    this.downloadOffset = page.offset + page.tasks.length;
    this.downloadTotal = page.total;
    this.downloadHasMore = page.tasks.length > 0 && this.downloadOffset < page.total;
    this.downloadsLoaded = true;
    return true;
  }

  /** 页面退出使在途读取失效，保留已经显示的列表。 */
  deactivateDownloads(): void {
    this.downloadListRevision++;
    this.downloadsLoading = false;
    this.closeDownloadDetail();
  }

  closeDownloadDetail(): void {
    this.downloadDetailRevision++;
    this.selectedDownload = undefined;
    this.downloadDetailLoading = false;
    this.downloadDetailError = '';
  }

  async showDownload(id: string): Promise<void> {
    const revision = ++this.downloadDetailRevision;
    this.downloadDetailLoading = false;
    if (this.selectedDownload?.id !== id) {
      this.selectedDownload = this.downloads.find((item: DownloadTask): boolean => item.id === id);
    }
    if (this.busy) { this.downloadDetailError = '正在处理其他请求，请稍后刷新详情。'; return; }
    const ticket = this.generation;
    this.downloadDetailLoading = true;
    this.downloadDetailError = '';
    const task = await this.read('nasDownloads', async (connector: NasConnector) => this.station(connector).getInfo(id),
      (): boolean => revision === this.downloadDetailRevision && this.selectedDownload?.id === id);
    if (ticket !== this.generation || revision !== this.downloadDetailRevision || this.selectedDownload?.id !== id) { return; }
    this.downloadDetailLoading = false;
    if (task !== undefined && task.id === id) { this.selectedDownload = task; }
    else { this.downloadDetailError = this.downloadError; }
  }

  async createDownload(): Promise<boolean> {
    if (!this.canCreateDownload) { this.downloadError = '服务器接口版本不支持带链接和目标目录的创建。'; return false; }
    if (!this.canWrite('nasDownloads')) { return false; }
    const ticket = this.generation;
    const uri = this.downloadUri;
    const destination = this.downloadDestination;
    const torrentPath = this.torrentPath, torrentName = this.torrentName;
    const confirmed = await this.write('nasDownloads', 'create', async (connector: NasConnector): Promise<boolean> => {
      validateDownloadDestination(destination);
      const result = torrentPath.length > 0 ? decodeDownloadCreateResult(await connector.uploadDownloadTorrent(
        { path: torrentPath, bytes: fileIo.statSync(torrentPath).size }, torrentName, destination, new NasTransferCancellation())) :
        await this.station(connector).create(uri, destination);
      if (result.taskId === undefined) { return false; }
      await this.station(connector).getInfo(result.taskId);
      return true;
    });
    if (ticket !== this.generation) { return false; }
    if (confirmed || this.hasPending('nasDownloads')) { this.downloadUri = ''; this.clearTorrent(); }
    await this.refreshDownloads(0);
    return confirmed;
  }

  async chooseTorrent(): Promise<void> {
    const context = this.context;
    if (context === undefined || this.busy) { return; }
    this.downloadError = '';
    const ticket = this.generation;
    this.busy = true;
    let copiedPath = '';
    try {
      const options = new picker.DocumentSelectOptions(); options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['种子文件|.torrent'];
      const uris = await new picker.DocumentViewPicker(context).select(options);
      if (ticket !== this.generation) { return; }
      if (uris.length === 0) { return; }
      const name = new fileUri.FileUri(uris[0]).name;
      if (!name.toLowerCase().endsWith('.torrent')) { throw new NasFailure(NasErrorKind.InvalidInput, '请选择种子文件。'); }
      const source = await fileIo.open(uris[0], fileIo.OpenMode.READ_ONLY);
      try {
        const stat = await fileIo.stat(source.fd);
        if (!stat.isFile() || stat.size <= 0 || stat.size > 10 * 1024 * 1024) { throw new NasFailure(NasErrorKind.InvalidInput, '请选择不超过 10 MB 的有效种子文件。'); }
        this.clearTorrent();
        const path = context.cacheDir + '/download-torrent-' + util.generateRandomUUID();
        copiedPath = path;
        await fileIo.copyFile(source.fd, path);
        if (ticket !== this.generation) { await fileIo.unlink(path); return; }
        this.torrentPath = path;
        this.torrentName = name; this.downloadUri = '';
      } finally { await fileIo.close(source); }
    } catch (error) {
      if (copiedPath.length > 0 && fileIo.accessSync(copiedPath)) { fileIo.unlinkSync(copiedPath); }
      if (ticket === this.generation) { this.torrentPath = ''; this.torrentName = ''; this.downloadError = (error as Error).message; }
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }

  async setDownloadDestination(path: string): Promise<void> {
    this.downloadDestination = path; this.downloadFreeBytes = undefined; this.downloadSpaceError = '';
    const connector = this.connector, ticket = this.generation;
    if (connector === undefined || path.length === 0) { return; }
    try {
      let offset = 0;
      while (true) {
        const page = await connector.list('', offset);
        if (ticket !== this.generation || path !== this.downloadDestination) { return; }
        const share = page.entries.find((entry): boolean => entry.path === '/' + path.split('/')[0]);
        if (share !== undefined) {
          if (share.freeBytes === undefined) { throw new Error('服务器未返回此卷的可用空间。'); }
          this.downloadFreeBytes = share.freeBytes; return;
        }
        offset += page.entries.length;
        if (offset >= page.total) { throw new Error('所选目录的存储卷不可读取。'); }
        if (page.entries.length === 0) { throw new Error('服务器返回的共享目录分页未前进。'); }
      }
    } catch (error) { if (ticket === this.generation && path === this.downloadDestination) { this.downloadSpaceError = (error as Error).message; } }
  }

  clearTorrent(): void {
    if (this.torrentPath.length > 0 && fileIo.accessSync(this.torrentPath)) { fileIo.unlinkSync(this.torrentPath); }
    this.torrentPath = ''; this.torrentName = '';
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
    if (confirmed) {
      if (operation === 'delete' && this.selectedDownload?.id === id) { this.closeDownloadDetail(); }
      await this.refreshDownloads();
      if (this.selectedDownload?.id === id) { await this.showDownload(id); }
    }
  }

  hasPending(feature: ExtensionFeature): boolean {
    return this.pending.some((record: ExtensionPendingWrite): boolean => record.feature === feature);
  }

  canPhotoAction(input: PhotoActionInput): boolean {
    return this.canWrite('photos') && this.connector!.supportsPhotoAction(input);
  }

  /** 与其他扩展操作共用账号锁与先落盘规则，后台回执始终保留待确认状态。 */
  async performPhotoAction(input: PhotoActionInput): Promise<boolean> {
    if (!this.canPhotoAction(input)) { return false; }
    const ticket = this.generation;
    const result: PhotoActionResult[] = [];
    const confirmed = await this.write('photos', input.action, async (connector: NasConnector): Promise<boolean> => {
      const reply = await connector.photoAction(input); result.push(reply);
      if (ticket !== this.generation) { return false; }
      if (reply.taskId !== undefined) {
        const pending = this.pending.map((record: ExtensionPendingWrite): ExtensionPendingWrite =>
          record.feature === 'photos' ? { feature: record.feature, operation: record.operation, createdAt: record.createdAt,
            photoId: record.photoId, photoSpace: record.photoSpace, taskId: reply.taskId } : record);
        this.pending = pending;
        await this.store.save(pending);
      }
      return reply.completed;
    }, { feature: 'photos', operation: input.action, createdAt: Date.now(), photoId: input.item.id, photoSpace: input.item.space });
    if (ticket === this.generation && confirmed && result[0]?.sharePassphrase !== undefined) {
      this.photoShare = this.origin + '/mo/sharing/' + encodeURIComponent(result[0].sharePassphrase!);
    }
    return confirmed;
  }

  async refreshPhotoTask(): Promise<void> {
    const connector = this.connector, record = this.pending.find((item: ExtensionPendingWrite): boolean => item.feature === 'photos');
    if (this.busy || connector === undefined || record?.taskId === undefined) { return; }
    const ticket = this.generation;
    this.busy = true; this.photoError = '';
    try {
      if (!await connector.photoTaskDone(record.taskId) || ticket !== this.generation) { return; }
      const pending = this.pending.filter((item: ExtensionPendingWrite): boolean => item.feature !== 'photos');
      await this.store.save(pending);
      if (ticket === this.generation) { this.pending = pending; this.photoNotice = '操作已完成'; }
    } catch (error) { if (ticket === this.generation) { await this.reportFailure('photos', error as Error, ticket); } }
    finally { if (ticket === this.generation) { this.busy = false; } }
  }

  canWrite(feature: ExtensionFeature): boolean {
    const capability = this.capabilities.find((item: CapabilitySnapshot): boolean => item.feature === feature);
    return this.connector !== undefined && !this.busy && this.recordsReady && this.pending.length === 0 && this.writeAllowed() &&
      capability !== undefined && capability.apiVersion > 0 &&
      !['unauthorized', 'unreachable', 'schemaMismatch', 'unsupportedVersion'].includes(capability.state);
  }

  /** 套件重新认证不清除主会话，也不重放任何待确认操作。 */
  async authenticateDownloads(): Promise<boolean> {
    const connector = this.connector;
    if (connector === undefined || this.busy || this.downloadPassword.length === 0) { return false; }
    const ticket = this.generation;
    this.busy = true;
    this.downloadError = '';
    try {
      await connector.authenticateDownloadStation(this.account, this.downloadPassword, this.downloadOtp);
      if (ticket !== this.generation) { return false; }
      this.downloadAuthenticationRequired = false;
      this.downloadNeedsOtp = false;
      this.capabilities = connector.capabilitySnapshots();
      this.downloadNotice = '下载套件已重新验证。';
      return true;
    } catch (error) {
      if (ticket === this.generation) {
        this.downloadError = this.message(error as Error, '下载套件认证未完成，请重试。');
        this.downloadNeedsOtp = error instanceof NasFailure && [NasErrorKind.OtpRequired, NasErrorKind.OtpInvalid].includes(error.kind);
      }
      return false;
    } finally {
      if (ticket === this.generation) { this.busy = false; this.cancelDownloadAuthentication(); }
    }
  }

  cancelDownloadAuthentication(): void { this.downloadPassword = ''; this.downloadOtp = ''; }

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

  private async read<T>(feature: ExtensionFeature, action: (connector: NasConnector) => Promise<T>,
    current: () => boolean = (): boolean => true): Promise<T | undefined> {
    const connector = this.connector;
    if (this.busy || connector === undefined) { return undefined; }
    const ticket = this.generation;
    this.busy = true;
    this.setError(feature, '');
    try {
      const result = await connector.readExtension(feature, async (): Promise<T> => action(connector));
      if (ticket !== this.generation || !current()) { return undefined; }
      return result;
    } catch (error) {
      if (ticket === this.generation && current()) { await this.reportFailure(feature, error as Error, ticket); }
      return undefined;
    } finally {
      if (ticket === this.generation) {
        if (current()) { this.capabilities = connector.capabilitySnapshots(); }
        this.busy = false;
      }
    }
  }

  private async write(feature: ExtensionFeature, operation: string, action: (connector: NasConnector) => Promise<boolean>,
    record?: ExtensionPendingWrite): Promise<boolean> {
    const connector = this.connector;
    if (connector === undefined || !this.canWrite(feature)) { return false; }
    const ticket = this.generation;
    const store = this.store;
    const pending: ExtensionPendingWrite[] = [...this.pending, record ?? { feature: feature, operation: operation, createdAt: Date.now() }];
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
      this.downloadAuthenticationRequired = true;
      try { await this.connector.list(''); }
      catch (validationError) {
        if (ticket === this.generation && validationError instanceof NasFailure && validationError.kind === NasErrorKind.SessionExpired) {
          await this.expired(validationError);
        }
        return;
      }
      if (ticket === this.generation) { this.downloadError = '下载套件需要重新验证，其他模块仍可使用。'; }
    } else if (ticket === this.generation) { await this.expired(error); }
  }

  private setError(feature: ExtensionFeature, text: string): void {
    if (feature === 'fileSharing') { this.shareError = text; } else if (feature === 'photos') { this.photoError = text; } else { this.downloadError = text; }
  }
  private setNotice(feature: ExtensionFeature, text: string): void {
    if (feature === 'fileSharing') { this.shareNotice = text; } else if (feature === 'photos') { this.photoNotice = text; } else { this.downloadNotice = text; }
  }
  private message(error: Error, fallback: string): string { return error instanceof NasFailure ? error.message : fallback; }
}
