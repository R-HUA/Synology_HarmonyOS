import { NasApiDescriptor, NasErrorKind, NasFailure, NasFileEntry, NasFilePage, nasOriginScheme, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import { NasConnector } from '../../core/network/NasConnector';
import { RcpNasTransport } from '../../core/network/RcpNasTransport';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasSessionStore, NasSessionStoreFailure } from './NasSessionStore';
import { common } from '@kit.AbilityKit';
import { NasPhotoAlbum, NasPhotoItem, NasSharedAlbum, PhotosSpace } from '../../core/domain/PhotosProtocol';
import { TransferQueue, TransferUploadSource } from '../transfers/TransferQueue';
import { FileEditResult, FileTaskItem, FileTaskState, NasFileSortBy, NasFileSortDirection, NasFileTask } from '../../core/domain/FileOperations';
import { SharedUploadFile, SharedUploadInbox, sharedUploadInbox } from '../sharing/SharedUploadInbox';
import { FileTaskStore } from './FileTaskStore';
import { util } from '@kit.ArkTS';
import { PhotoLibrary } from '../photos/PhotoLibrary';
import { TelemetryMonitor } from '../telemetry/TelemetryMonitor';
import { ConnectionAddressBook } from './ConnectionAddressBook';
import { SystemControlModel } from '../control/SystemControlModel';
import { NasExtensionsModel } from '../extensions/NasExtensionsModel';
import { DriveBrowserModel } from '../drive/DriveBrowserModel';
import { DriveTransferModel } from '../drive/DriveTransferModel';
import type { NasConnectionAddress } from '../../core/domain/ConnectionRoutes';

export { FileEditResult, FileTaskItem } from '../../core/domain/FileOperations';

@ObservedV2
export class ConnectionViewModel {
  @Trace address: string = '';
  @Trace account: string = '';
  @Trace password: string = '';
  @Trace otp: string = '';
  @Trace needsOtp: boolean = false;
  @Trace busy: boolean = false;
  @Trace connected: boolean = false;
  @Trace authenticated: boolean = false;
  @Trace savedSession: boolean = false;
  @Trace errorText: string = '';
  /** 登录页开关：地址未写明协议时使用的协议。 */
  @Trace useHttps: boolean = true;
  /** 登录页开关：仅 https 有效，跳过服务器证书校验以支持自签名证书。 */
  @Trace insecureTls: boolean = false;
  @Trace capabilities: NasApiDescriptor[] = [];
  @Trace entries: NasFileEntry[] = [];
  @Trace directory: string = '';
  @Trace pageOffset: number = 0;
  @Trace total: number = 0;
  @Trace fileSort: string = 'name';
  @Trace sortDescending: boolean = false;
  @Trace actionNotice: string = '';
  @Trace fileTasks: FileTaskItem[] = [];
  @Trace fileTasksReady: boolean = false;
  @Trace fileTasksErrorText: string = '';
  @Trace directoryErrorText: string = '';
  readonly queue: TransferQueue = new TransferQueue();
  readonly sharedInbox: SharedUploadInbox = sharedUploadInbox;
  readonly photoLibrary: PhotoLibrary = new PhotoLibrary();
  readonly telemetry: TelemetryMonitor = new TelemetryMonitor();
  readonly addressBook: ConnectionAddressBook = new ConnectionAddressBook();
  readonly systemControl: SystemControlModel = new SystemControlModel();
  readonly extensions: NasExtensionsModel = new NasExtensionsModel();
  /** Drive 只读浏览；与 File Station 状态完全独立，来源切换由界面决定。 */
  readonly drive: DriveBrowserModel = new DriveBrowserModel();
  readonly driveTransfers: DriveTransferModel = new DriveTransferModel();
  @Trace deviceCheckText: string = '尚未登记设备身份';
  /** 首页设备卡：型号与服务器名称（设备名称），任一读不到就留空由界面兜底。 */
  @Trace deviceModel: string = '';
  @Trace deviceName: string = '';
  get deviceTitle(): string {
    return this.deviceName.length > 0 ? this.deviceName : this.deviceModel.length > 0 ? this.deviceModel : '我的 NAS';
  }
  @Trace photosOpened: boolean = false;
  get photosErrorText(): string { return this.photoLibrary.errorText; }
  get photosSpace(): PhotosSpace { return this.photoLibrary.space; }
  get photoItems(): NasPhotoItem[] { return this.photoLibrary.items; }
  get sharedAlbums(): NasSharedAlbum[] { return this.photoLibrary.albums; }
  get selectedAlbum(): NasSharedAlbum | undefined { return this.photoLibrary.selectedAlbum; }
  get photosOffset(): number { return this.photosPageCount(); }
  get photosMore(): boolean { return this.photoLibrary.hasMore; }
  private connector: NasConnector | undefined = undefined;
  private generation: number = 0;
  private connectedOrigin: string = '';
  private connectedInsecure: boolean = false;
  private history: string[] = [];
  private pageHistory: number[] = [];
  private store: NasSessionStore = new NasSessionStore();
  private fileTaskStore: FileTaskStore = new FileTaskStore();
  private context: common.UIAbilityContext | undefined = undefined;
  private submittedShares: string[] = [];

  async restore(context?: common.UIAbilityContext): Promise<void> {
    if (context !== undefined) { this.context = context; }
    if (this.busy || this.authenticated) { return; }
    const ticket = ++this.generation;
    this.busy = true;
    this.errorText = '';
    let restored = false;
    try {
      if (this.context !== undefined && !this.addressBook.ready && !await this.addressBook.load(this.context)) {
        throw new NasFailure(NasErrorKind.Protocol, this.addressBook.errorText);
      }
      const saved = await this.store.load();
      if (ticket !== this.generation || saved === undefined) { return; }
      this.savedSession = true;
      this.address = saved.origin;
      this.account = saved.account;
      this.useHttps = nasOriginScheme(saved.origin) === 'https';
      this.insecureTls = saved.insecureTls === true && this.useHttps;
      this.connector?.close();
      const connector = new NasConnector(new RcpNasTransport(saved.insecureTls));
      this.connector = connector;
      const capabilities = await connector.discover(saved.origin);
      if (ticket !== this.generation) { return; }
      this.capabilities = capabilities;
      this.connected = true;
      this.connectedOrigin = saved.origin;
      this.connectedInsecure = saved.insecureTls;
      connector.restoreSession(saved.sessions);
      await this.verifyDevice(connector, saved.origin, saved.account);
      if (ticket !== this.generation) { return; }
      this.authenticated = true;
      await this.attachQueue(connector);
      if (ticket !== this.generation) { return; }
      restored = true;
    } catch (error) {
      if (ticket === this.generation) {
        this.connector?.close();
        this.connector = undefined;
        this.connected = false;
        this.connectedOrigin = '';
        if (error instanceof NasSessionStoreFailure) { this.savedSession = true; }
        await this.showFailure(error as Error, 'restore');
      }
    } finally { if (ticket === this.generation) { this.busy = false; } }
    // 初始目录加载与登录路径一致放在 busy 结束后：目录加载自身会置 busy，恢复期间调用会被忙检查吞掉。
    if (restored && ticket === this.generation) {
      await this.loadInitialDirectory();
      hilog.info(0x0000, 'NasConnection', 'operation=restore result=success');
    }
  }

  /** 登录页地址输入；写明的协议会同步 HTTPS 开关。 */
  setAddress(text: string): void {
    if (this.busy || this.authenticated) { return; }
    this.address = text;
    const match = /^(https?):\/\//i.exec(text.trim());
    if (match === null) { return; }
    this.useHttps = match[1].toLowerCase() !== 'http';
    if (!this.useHttps) { this.insecureTls = false; }
  }

  /** 切换协议时同步改写已写明的协议前缀，避免开关与输入框不一致。 */
  setUseHttps(enabled: boolean): void {
    if (this.busy || this.authenticated) { return; }
    this.useHttps = enabled;
    if (!enabled) { this.insecureTls = false; }
    const raw = this.address.trim();
    if (/^https?:\/\//i.test(raw)) {
      this.address = (enabled ? 'https://' : 'http://') + raw.replace(/^https?:\/\//i, '');
    }
  }

  /** 仅 https 允许跳过证书校验；http 无证书可校验。 */
  setInsecureTls(enabled: boolean): void {
    if (this.busy || this.authenticated || !this.useHttps) { return; }
    this.insecureTls = enabled;
  }

  /** 输入框可省略协议；已写明的协议优先，否则按 HTTPS 开关补全。 */
  private resolveOrigin(): string {
    const raw = this.address.trim();
    return normalizeNasOrigin(/^https?:\/\//i.test(raw) ? raw : (this.useHttps ? 'https://' : 'http://') + raw);
  }

  /** 当前连接是否仍对应当前地址与证书策略；地址或开关改动后需要重建连接。 */
  private connectionMatchesCurrent(): boolean {
    if (this.connectedOrigin.length === 0) { return false; }
    let origin: string;
    try { origin = this.resolveOrigin(); }
    catch { return false; }
    return origin === this.connectedOrigin && this.connectedInsecure === this.insecureTls;
  }

  /** 退出启动等待；保留已保存的登录信息，交由用户在登录页重试。 */
  cancelRestore(): void {
    if (!this.busy || this.authenticated) { return; }
    this.generation++;
    this.busy = false;
    this.connector?.close();
    this.connector = undefined;
    this.connected = false;
    this.connectedOrigin = '';
    this.capabilities = [];
  }

  /** 登录页主操作：地址、账号与密码一次提交；地址或证书策略变化时先重建连接。 */
  async submitLogin(): Promise<void> {
    if (this.busy || this.authenticated) { return; }
    if (this.address.trim().length === 0 || this.account.trim().length === 0 || this.password.length === 0) { return; }
    if (this.connected && !this.connectionMatchesCurrent()) {
      this.connector?.close();
      this.connector = undefined;
      this.connected = false;
      this.connectedOrigin = '';
      this.capabilities = [];
    }
    if (!this.connected && !await this.connect()) { return; }
    await this.login();
  }

  async connect(): Promise<boolean> {
    if (this.busy) { return false; }
    if (this.connected) { return this.connectionMatchesCurrent(); }
    if (!this.addressBook.ready) { this.errorText = '请先在连接地址中成功读取配置，再建立连接。'; return false; }
    const ticket = ++this.generation;
    this.busy = true;
    this.errorText = '';
    try {
      const origin = this.resolveOrigin();
      this.address = origin;
      this.connector?.close();
      const connector = new NasConnector(new RcpNasTransport(this.insecureTls));
      this.connector = connector;
      const capabilities = await connector.discover(origin);
      if (ticket !== this.generation) { return false; }
      this.capabilities = capabilities;
      this.connected = true;
      this.connectedOrigin = origin;
      this.connectedInsecure = this.insecureTls;
      return true;
    } catch (error) {
      if (ticket === this.generation) {
        this.connector?.close();
        this.connector = undefined;
        this.connected = false;
        this.connectedOrigin = '';
        await this.showFailure(error as Error, 'discover');
      }
      return false;
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }

  async login(): Promise<void> {
    const connector = this.connector;
    if (this.busy || connector === undefined) { return; }
    const ticket = this.generation;
    this.busy = true;
    this.errorText = '';
    let authorized = false;
    try {
      await connector.login(this.account, this.password, this.otp);
      authorized = true;
      if (ticket !== this.generation) { return; }
      this.password = '';
      this.otp = '';
      this.needsOtp = false;
      await this.verifyDevice(connector, this.address, this.account);
      if (ticket !== this.generation) { return; }
      this.authenticated = true;
      hilog.info(0x0000, 'NasConnection', 'operation=login result=success');
    } catch (error) {
      if (ticket === this.generation) {
        if (authorized) {
          connector.close();
          this.connector = undefined;
          this.connected = false;
          this.capabilities = [];
          this.clearAccount();
        }
        await this.showFailure(error as Error, 'login');
      }
    }
    finally { if (ticket === this.generation) { this.busy = false; } }
    if (this.authenticated && ticket === this.generation) {
      await this.attachQueue(connector);
      if (ticket !== this.generation) { return; }
      const sessions = connector.sessionSnapshot();
      if (sessions.length === 0 || ticket !== this.generation) { return; }
      this.busy = true;
      let sessionSaved = false;
      try {
        await this.store.save({ origin: this.address, account: this.account.trim(), sessions: sessions,
          insecureTls: this.insecureTls });
        sessionSaved = true;
        if (ticket === this.generation) {
          this.savedSession = true;
          hilog.info(0x0000, 'NasConnection', 'operation=save-session result=success');
        }
      } catch (error) { if (ticket === this.generation) { await this.showFailure(error as Error, 'save-session'); } }
      finally { if (ticket === this.generation) { this.busy = false; } }
      // 保存失败时保留错误提示：目录加载会重置横幅，保存失败比目录不可用更值得先展示。
      if (sessionSaved && ticket === this.generation) { await this.loadInitialDirectory(); }
    }
  }

  /**
   * 非 File Station 账号入口：文件浏览不可用不阻断登录、会话保存与任务恢复，
   * 仅在文件页给出明确提示；能力存在时仍按原有目录加载路径执行。
   */
  private async loadInitialDirectory(): Promise<void> {
    if (!this.supports('SYNO.FileStation.List')) {
      this.directoryErrorText = '当前服务器未提供可用的 File Station 接口，文件浏览暂不可用；其他功能不受影响。';
      return;
    }
    await this.load('', 0);
  }

  async openDirectory(entry: NasFileEntry): Promise<void> {
    if (!entry.isDirectory || this.busy) { return; }
    const oldPath = this.directory;
    if (await this.load(entry.path, 0)) {
      this.history.push(oldPath);
      this.pageHistory = [];
    }
  }

  async reloadAddressBook(): Promise<void> {
    if (this.context !== undefined && !this.busy) { await this.addressBook.load(this.context); }
  }

  async useSavedAddress(origin: string): Promise<boolean> {
    if (this.busy || this.queue.busy || this.addressBook.busy || !this.addressBook.ready) { return false; }
    let normalized: string;
    try { normalized = normalizeNasOrigin(origin); }
    catch (error) { await this.showFailure(error as Error, 'select-address'); return false; }
    if (!this.addressBook.addresses.some((address: NasConnectionAddress): boolean => address.origin === normalized)) {
      this.errorText = '请先保存并确认该连接地址。';
      return false;
    }
    if (this.authenticated && this.address === normalized) { return true; }
    this.addressBook.cancelProbe();
    const previousGeneration = this.generation;
    await this.disconnect();
    if (this.generation !== previousGeneration + 1 || this.busy || this.authenticated || this.savedSession) { return false; }
    const previousNotice = this.errorText;
    const saved = this.addressBook.addresses.find((address: NasConnectionAddress): boolean => address.origin === normalized);
    this.address = normalized;
    this.account = '';
    this.password = '';
    this.otp = '';
    this.useHttps = nasOriginScheme(normalized) === 'https';
    this.insecureTls = saved?.insecureTls === true && this.useHttps;
    this.actionNotice = previousNotice;
    await this.connect();
    return this.connected;
  }

  async saveCurrentAddress(): Promise<void> {
    const connector = this.connector;
    if (connector === undefined || !this.authenticated || this.busy || this.addressBook.busy || this.addressBook.probing) { return; }
    const ticket = this.generation;
    this.busy = true;
    try {
      const saved = await this.addressBook.saveCurrent(connector, this.address, this.account, this.insecureTls);
      if (saved && ticket === this.generation) { this.deviceCheckText = this.addressBook.notice; }
    } catch (error) { if (ticket === this.generation) { await this.showFailure(error as Error, 'register-device'); } }
    finally { if (ticket === this.generation) { this.busy = false; } }
  }

  private async verifyDevice(connector: NasConnector, origin: string, account: string): Promise<void> {
    const ticket = this.generation;
    const model = await this.addressBook.verifyExpectedDevice(connector, origin, account);
    if (ticket !== this.generation) { return; }
    this.deviceCheckText = model === undefined ? '当前账号未登记设备身份；地址间不合并登录和任务。' :
      '设备身份已核验 · ' + model;
    await this.loadDeviceIdentity(connector);
  }

  /** 首页设备卡用的型号与服务器名称；读不到就留空，不阻塞后续流程。 */
  private async loadDeviceIdentity(connector: NasConnector): Promise<void> {
    const ticket = this.generation;
    try {
      const identity = await connector.deviceIdentity();
      if (ticket !== this.generation) { return; }
      this.deviceModel = identity.model;
      this.deviceName = identity.serverName;
    } catch {
      if (ticket !== this.generation) { return; }
      this.deviceModel = '';
      this.deviceName = '';
    }
  }

  async openSystemControl(): Promise<void> {
    const connector = this.connector;
    const context = this.context;
    if (this.busy || !this.authenticated || connector === undefined || context === undefined) { return; }
    const ticket = this.generation;
    const error = await this.systemControl.open(context, connector, this.address, this.insecureTls, (): void => {
      if (ticket !== this.generation || connector !== this.connector || !this.authenticated) {
        throw new NasFailure(NasErrorKind.Cancelled, '当前 NAS 连接已变化，请重新进入系统控制。');
      }
      if (!this.queue.ready || !this.fileTasksReady || !this.driveTransfers.ready) {
        throw new NasFailure(NasErrorKind.InvalidInput, '请先在任务页成功读取传输和文件操作记录，再进行系统控制。');
      }
      if (this.driveTransfers.busy || this.driveTransfers.items.some((item): boolean =>
        ['preparing', 'running', 'unknown'].includes(item.state)) || this.queue.busy || this.queue.items.some((item): boolean =>
        !['completed', 'cancelled', 'failed', 'closed'].includes(item.state)) ||
        this.fileTasks.some((item: FileTaskItem): boolean => !['completed', 'failed'].includes(item.state))) {
        throw new NasFailure(NasErrorKind.InvalidInput, '仍有进行中或结果待核对的传输、文件操作，请先处理任务；不会为系统控制自动停止或重试它们。');
      }
    });
    if (ticket === this.generation && error !== undefined) { await this.showFailure(error as Error, 'control-device-info'); }
  }

  async submitSystemControl(): Promise<void> {
    if (this.busy || !this.authenticated) { return; }
    const ticket = this.generation;
    this.busy = true;
    try { await this.systemControl.submit(); }
    finally { if (ticket === this.generation) { this.busy = false; } }
  }
  async goBack(): Promise<void> {
    if (this.busy || this.history.length === 0) { return; }
    const parent = this.history[this.history.length - 1];
    if (await this.load(parent, 0)) {
      this.history.pop();
      this.pageHistory = [];
    }
  }
  async refresh(): Promise<void> {
    if (await this.load(this.directory, 0)) { this.pageHistory = []; }
  }
  async nextPage(): Promise<void> {
    if (this.busy || this.pageOffset + this.entries.length >= this.total) { return; }
    const previousOffset = this.pageOffset;
    if (await this.load(this.directory, previousOffset + this.entries.length)) { this.pageHistory.push(previousOffset); }
  }
  async previousPage(): Promise<void> {
    if (this.busy || this.pageHistory.length === 0) { return; }
    if (await this.load(this.directory, this.pageHistory[this.pageHistory.length - 1])) { this.pageHistory.pop(); }
  }

  supports(apiName: string): boolean {
    const version = apiName === 'SYNO.FileStation.CopyMove' ? 3 :
      apiName.startsWith('SYNO.FileStation.') ? 2 : 1;
    return this.capabilities.some((api: NasApiDescriptor): boolean =>
      api.name === apiName && api.minVersion <= version && api.maxVersion >= version);
  }

  async setSort(sort: 'name' | 'size' | 'mtime', descending: boolean): Promise<void> {
    if (this.busy) { return; }
    const previousSort = this.fileSort;
    const previousDescending = this.sortDescending;
    this.fileSort = sort;
    this.sortDescending = descending;
    if (await this.load(this.directory, 0)) { this.pageHistory = []; }
    else { this.fileSort = previousSort; this.sortDescending = previousDescending; }
  }

  async createFolder(name: string): Promise<FileEditResult> {
    const connector = this.connector;
    const directory = this.directory;
    if (connector === undefined || directory.length === 0) { return 'failed'; }
    return this.editFiles(async (): Promise<FileEditResult> => { await connector.createFolder(directory, name); return 'completed'; }, '文件夹已创建');
  }

  async renameEntry(entry: NasFileEntry, name: string): Promise<FileEditResult> {
    const connector = this.connector;
    if (connector === undefined || this.directory.length === 0) { return 'failed'; }
    return this.editFiles(async (): Promise<FileEditResult> => { await connector.renameFile(entry.path, name); return 'completed'; }, '名称已更新');
  }

  async deleteEntry(entry: NasFileEntry): Promise<FileEditResult> {
    const connector = this.connector;
    if (connector === undefined || this.directory.length === 0 || !this.canStartFileTask()) { return 'failed'; }
    return this.editFiles(async (): Promise<FileEditResult> =>
      this.startFileTask(connector, (): Promise<NasFileTask> => connector.deleteFiles([entry.path]), '删除 ' + entry.name), '删除已完成');
  }

  async copyEntry(entry: NasFileEntry, directory: string): Promise<FileEditResult> {
    const connector = this.connector;
    if (connector === undefined || !this.canStartFileTask()) { return 'failed'; }
    return this.editFiles(async (): Promise<FileEditResult> =>
      this.startFileTask(connector, (): Promise<NasFileTask> => connector.copyFiles([entry.path], directory), '复制 ' + entry.name), '复制已完成');
  }

  async moveEntry(entry: NasFileEntry, directory: string): Promise<FileEditResult> {
    const connector = this.connector;
    if (connector === undefined || !this.canStartFileTask()) { return 'failed'; }
    return this.editFiles(async (): Promise<FileEditResult> =>
      this.startFileTask(connector, (): Promise<NasFileTask> => connector.moveFiles([entry.path], directory), '移动 ' + entry.name), '移动已完成');
  }

  private canStartFileTask(): boolean {
    if (this.busy || !this.authenticated) { return false; }
    if (!this.fileTasksReady) {
      this.errorText = this.fileTasksErrorText || '尚未读取文件操作记录，请在任务页重试读取后再操作。';
      return false;
    }
    if (this.fileTasks.length >= 1000 && !this.fileTasks.some((item: FileTaskItem): boolean =>
      item.state === 'completed' || item.state === 'failed')) {
      this.errorText = '待核对的文件操作任务已达保存上限，请先查询已有任务。';
      return false;
    }
    return true;
  }

  private async startFileTask(connector: NasConnector, start: () => Promise<NasFileTask>, label: string): Promise<FileEditResult> {
    const ticket = this.generation;
    const store = this.fileTaskStore;
    const expired = this.fileTasks.length < 1000 ? -1 : this.fileTasks.findIndex((item: FileTaskItem): boolean =>
      item.state === 'completed' || item.state === 'failed');
    const previous = this.fileTasks.filter((_item: FileTaskItem, index: number): boolean => index !== expired);
    const task = await start();
    const item: FileTaskItem = { id: util.generateRandomUUID(true), task: task, label: label, state: 'pending', errorText: '' };
    // start 已被 NAS 接受，立即保留标识；后续查询、存储错误均不得重发 start。
    const records = previous.concat([item]);
    if (ticket === this.generation) { this.fileTasks = records; }
    await this.saveFileTasks(store, records, ticket);
    if (ticket !== this.generation) { return 'failed'; }
    return this.waitFileTask(connector, item, store, ticket);
  }

  private async waitFileTask(connector: NasConnector, item: FileTaskItem, store: FileTaskStore, ticket: number): Promise<FileEditResult> {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      const result = await this.queryFileTask(connector, item, store, ticket);
      if (result !== 'pending' || this.fileTasks.some((task: FileTaskItem): boolean => task.id === item.id && task.state === 'unknown')) {
        return result;
      }
      if (Date.now() >= deadline) { break; }
      await new Promise<void>((resolve): void => { setTimeout(resolve, 500); });
    }
    if (ticket !== this.generation) { return 'failed'; }
    await this.updateFileTask(item.id, 'pending', '服务器仍在处理，可在任务页继续查询结果。', store, ticket);
    return 'pending';
  }

  /** 只查询已保存的 taskId，不重新提交复制、移动或删除。 */
  async checkFileTask(id: string): Promise<void> {
    const connector = this.connector;
    const item = this.fileTasks.find((task: FileTaskItem): boolean => task.id === id);
    if (this.busy || !this.authenticated || connector === undefined || item === undefined ||
      item.state === 'completed' || item.state === 'failed') { return; }
    const ticket = this.generation;
    this.busy = true;
    let result: FileEditResult = 'failed';
    try { result = await this.queryFileTask(connector, item, this.fileTaskStore, ticket); }
    finally { if (ticket === this.generation) { this.busy = false; } }
    if (ticket === this.generation && result === 'completed') {
      this.actionNotice = item.label + '已完成';
      await this.refreshAfterFileEdit();
    }
  }

  private async queryFileTask(connector: NasConnector, item: FileTaskItem, store: FileTaskStore, ticket: number): Promise<FileEditResult> {
    if (ticket !== this.generation) { return 'failed'; }
    try {
      const status = await connector.fileTaskStatus(item.task);
      if (ticket !== this.generation) { return 'failed'; }
      if (!status.finished) {
        const current = this.fileTasks.find((task: FileTaskItem): boolean => task.id === item.id);
        if (current !== undefined && (current.state !== 'pending' || current.errorText.length > 0)) {
          await this.updateFileTask(item.id, 'pending', '服务器仍在处理，可稍后继续查询结果。', store, ticket);
        }
        return 'pending';
      }
      await this.updateFileTask(item.id, 'completed', '', store, ticket);
      return ticket === this.generation ? 'completed' : 'failed';
    } catch (error) {
      if (ticket !== this.generation) { return 'failed'; }
      const failure = error as Error;
      // 查询被拒绝或服务器繁忙不能证明已经启动的写操作失败，仍保留查询入口。
      const rejectedQuery = error instanceof NasFailure &&
        (error.kind === NasErrorKind.Permission || error.kind === NasErrorKind.Server && error.code === 402);
      const unknown = !(error instanceof NasFailure) ||
        [NasErrorKind.Network, NasErrorKind.Http, NasErrorKind.Protocol, NasErrorKind.SessionExpired, NasErrorKind.Cancelled].includes(error.kind) || error.code === 599;
      const stateUnknown = unknown || rejectedQuery;
      const text = (error instanceof NasFailure ? error.message : '查询文件操作任务失败。') +
        (stateUnknown ? ' 结果尚未确认，可在任务页继续查询，请勿重复提交操作。' : ' 请先核对目录中的实际结果。');
      await this.updateFileTask(item.id, stateUnknown ? 'unknown' : 'failed', text, store, ticket);
      if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) {
        await this.showFailure(failure, 'file-task');
        return 'failed';
      }
      if (!unknown) { await this.showFailure(failure, 'file-task'); }
      return stateUnknown ? 'pending' : 'failed';
    }
  }

  private async updateFileTask(id: string, state: FileTaskState, errorText: string, store: FileTaskStore, ticket: number): Promise<void> {
    if (ticket !== this.generation) { return; }
    this.fileTasks = this.fileTasks.map((item: FileTaskItem): FileTaskItem => item.id === id ?
      { id: item.id, task: item.task, label: item.label, state: state, errorText: errorText } : item);
    await this.saveFileTasks(store, this.fileTasks, ticket);
  }

  private async saveFileTasks(store: FileTaskStore, tasks: FileTaskItem[], ticket: number): Promise<void> {
    try {
      await store.save(tasks);
      if (ticket === this.generation) { this.fileTasksReady = true; this.fileTasksErrorText = ''; }
    } catch {
      if (ticket === this.generation) {
        this.fileTasksReady = false;
        this.fileTasksErrorText = '文件操作记录保存失败，已启动的任务仍可查询；请重试保存后再启动新任务，退出应用可能丢失未保存的记录。';
        this.errorText = this.fileTasksErrorText;
      }
    }
  }

  async reloadFileTasks(): Promise<void> {
    if (this.busy || !this.authenticated) { return; }
    const ticket = this.generation;
    this.busy = true;
    try {
      if (this.fileTasks.length > 0) { await this.saveFileTasks(this.fileTaskStore, this.fileTasks, ticket); }
      else { await this.attachFileTasks(); }
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }

  async uploadFiles(): Promise<void> {
    if (!this.authenticated || this.busy || this.directory.length === 0) { return; }
    try { await this.queue.pickAndUpload(this.directory); }
    catch (error) { await this.showFailure(error as Error, 'upload'); }
  }

  async downloadFile(entry: NasFileEntry): Promise<void> {
    if (!this.authenticated || this.busy || entry.isDirectory) { return; }
    try { await this.queue.download(entry); }
    catch (error) { await this.showFailure(error as Error, 'download'); }
  }

  async uploadSharedFiles(): Promise<void> {
    if (!this.authenticated || this.busy || this.queue.busy || this.sharedInbox.receiving || this.directory.length === 0) { return; }
    const ticket = this.generation;
    const files = this.sharedInbox.files.filter((file: SharedUploadFile): boolean => !this.submittedShares.includes(file.id));
    this.busy = true;
    this.errorText = '';
    this.actionNotice = '';
    try {
      if (files.length > 0) {
        const result = await this.queue.uploadSources(this.directory, files.map((file: SharedUploadFile): TransferUploadSource =>
          ({ uri: file.uri, name: file.fileName, bytes: file.size })));
        for (const index of result.acceptedIndices) { this.submittedShares.push(files[index].id); }
        if (ticket !== this.generation) { return; }
        if (result.acceptedIndices.length > 0) { this.actionNotice = '已将 ' + result.acceptedIndices.length.toString() + ' 个文件加入传输队列'; }
        if (result.issues.length > 0) { this.errorText = result.issues[0].errorText; }
      }
      // 清理失败的条目下次只重试清理，不再次创建上传；新入站文件不在此快照内。
      await this.sharedInbox.consume(this.submittedShares);
      this.submittedShares = [];
    } catch (error) {
      if (ticket === this.generation) { this.errorText = error instanceof Error ? error.message : '处理分享文件失败，请重试。'; }
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }

  async discardSharedFiles(): Promise<void> {
    if (this.busy || this.queue.busy) { return; }
    try { await this.sharedInbox.clear(); this.submittedShares = []; }
    catch (error) { this.errorText = error instanceof Error ? error.message : '清理分享文件失败，请重试。'; }
  }

  private async attachQueue(connector: NasConnector): Promise<void> {
    const extensionTicket = this.generation;
    // Drive 复用 File Station 会话（实测 cookie-header-only），但状态独立：
    // 只有在套件通告可用时才允许切到 Drive 来源。
    const driveTicket = this.generation;
    this.drive.attach(connector, async (error: NasFailure): Promise<void> => {
      if (driveTicket === this.generation && connector === this.connector) { await this.showFailure(error as Error, 'drive'); }
    });
    await this.extensions.attach(connector, this.context, this.address, this.account.trim(), async (error: NasFailure): Promise<void> => {
      if (extensionTicket === this.generation && connector === this.connector) { await this.showFailure(error as Error, 'extensions'); }
    });
    if (extensionTicket !== this.generation) { return; }
    const telemetryTicket = this.generation;
    this.telemetry.attach(connector, async (error: NasFailure): Promise<void> => {
      if (telemetryTicket === this.generation && connector === this.connector) { await this.showFailure(error as Error, 'telemetry'); }
    });
    const photoTicket = this.generation;
    this.photoLibrary.attach(connector, this.context, async (error: NasFailure): Promise<void> => {
      if (photoTicket === this.generation && connector === this.connector) { await this.showFailure(error as Error, 'photos'); }
    }, this.insecureTls);
    if (this.context === undefined) { return; }
    const ticket = this.generation;
    await this.driveTransfers.attach(this.context, connector, this.address, this.account.trim(), async (error: NasFailure): Promise<void> => {
      if (ticket === this.generation && connector === this.connector) { await this.showFailure(error as Error, 'drive-transfer'); }
    });
    if (ticket !== this.generation) { return; }
    await this.attachFileTasks();
    if (ticket !== this.generation) { return; }
    try { await this.queue.attach(this.context, connector, this.address, this.account.trim()); }
    catch (error) {
      this.errorText = error instanceof NasFailure ? error.message : '无法读取传输记录，请在任务页重试。';
    }
  }

  private async attachFileTasks(): Promise<void> {
    const context = this.context;
    if (context === undefined) { return; }
    const ticket = this.generation;
    const store = new FileTaskStore();
    this.fileTasksReady = false;
    this.fileTaskStore = store;
    try {
      const tasks = await store.load(context, this.address, this.account.trim());
      if (ticket !== this.generation) { return; }
      this.fileTasks = tasks;
      this.fileTasksReady = true;
      this.fileTasksErrorText = '';
    } catch (error) {
      if (ticket === this.generation) {
        this.fileTasksErrorText = error instanceof NasFailure ? error.message :
          '无法读取文件操作记录，已保留原记录；请在任务页重试读取后再启动整理任务。';
        this.errorText = this.fileTasksErrorText;
      }
    }
  }

  /** 写操作只发送一次；失败后由用户核对目录，避免重试产生重复修改。 */
  private async editFiles(action: () => Promise<FileEditResult>, notice: string): Promise<FileEditResult> {
    if (this.busy || !this.authenticated) { return 'failed'; }
    const ticket = this.generation;
    this.busy = true;
    this.errorText = '';
    this.actionNotice = '';
    let result: FileEditResult = 'failed';
    try {
      result = await action();
      if (ticket !== this.generation) { return 'failed'; }
      if (result === 'completed') { this.actionNotice = notice; }
      else if (result === 'pending') { this.actionNotice = '操作已提交，可在任务页继续查询结果，请勿重复提交。'; }
    } catch (error) {
      if (ticket === this.generation) {
        await this.showFailure(error as Error, 'file-operation');
        if (error instanceof NasFailure &&
          [NasErrorKind.Network, NasErrorKind.Http, NasErrorKind.Protocol].includes(error.kind)) {
          this.errorText += ' 操作结果尚未确认，请先刷新目录核对，再决定是否重新操作。';
        }
      }
    } finally { if (ticket === this.generation) { this.busy = false; } }
    if (result === 'completed' && ticket === this.generation) { await this.refreshAfterFileEdit(); }
    return ticket === this.generation ? result : 'failed';
  }

  private async refreshAfterFileEdit(): Promise<void> {
    if (!await this.load(this.directory, 0)) {
      if (this.directoryErrorText.length > 0) {
        this.directoryErrorText = '操作已完成，但目录刷新失败：' + this.directoryErrorText;
        this.errorText = this.directoryErrorText;
      }
    } else { this.pageHistory = []; }
  }

  async disconnect(): Promise<void> {
    if (this.busy || this.queue.busy) { return; }
    this.busy = true;
    try { await this.driveTransfers.stopAll(); await this.queue.stopAll(); }
    catch (error) {
      this.errorText = error instanceof NasFailure ? error.message : '停止传输失败，请在任务页重试后再退出账号。';
      this.busy = false;
      return;
    }
    this.queue.detach();
    const oldConnector = this.connector;
    this.connector = undefined;
    const ticket = ++this.generation;
    this.clearAccount();
    this.connected = false;
    this.capabilities = [];
    this.busy = true;
    this.errorText = '';
    try {
      await this.store.clear();
      if (ticket === this.generation) {
        this.savedSession = false;
        hilog.info(0x0000, 'NasConnection', 'operation=clear-session result=success');
      }
    } catch (error) {
      if (ticket === this.generation) {
        this.savedSession = true;
        await this.showFailure(error as Error, 'clear-session');
      }
    }
    try {
      if (oldConnector !== undefined) {
        await oldConnector.logout();
        hilog.info(0x0000, 'NasConnection', 'operation=logout result=success');
      }
    } catch {
      if (ticket === this.generation) {
        this.errorText += this.savedSession ? ' 服务器登出也未确认，请重试。' :
          '本机会话已清除，服务器登出未确认；会话将在 DSM 到期。';
      }
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }
  async openPhotos(space: PhotosSpace = PhotosSpace.Personal, offset: number = 0): Promise<void> {
    if (this.busy || !this.authenticated || this.connector === undefined) { return; }
    this.photosOpened = true;
    if (offset > 0 && space === this.photoLibrary.space) { await this.photoLibrary.loadMore(); }
    else { await this.photoLibrary.open(space, space === PhotosSpace.WithMe ? 'albums' : 'timeline'); }
  }
  async previousPhotos(): Promise<void> { await this.photoLibrary.refresh(); }
  async openSharedAlbum(album: NasSharedAlbum): Promise<void> {
    const photosAlbum: NasPhotoAlbum = { id: album.id, name: album.name, itemCount: album.itemCount,
      passphrase: album.passphrase, space: PhotosSpace.WithMe };
    await this.photoLibrary.openAlbum(photosAlbum);
  }
  async backToAlbums(): Promise<void> { await this.photoLibrary.backToLibrary(); }
  photosPageCount(): number {
    return this.photoLibrary.section === 'albums' && this.photoLibrary.selectedAlbum === undefined ?
      this.photoLibrary.albums.length : this.photoLibrary.items.length;
  }
  closePhotos(): void {
    this.photosOpened = false;
    this.photoLibrary.closeDetail();
    this.photoLibrary.errorText = '';
  }
  async serverInfo(): Promise<string> {
    const connector = this.connector;
    if (this.busy || connector === undefined || !this.authenticated) { return ''; }
    const ticket = this.generation;
    this.busy = true;
    this.errorText = '';
    try {
      const info = await connector.environment();
      if (ticket !== this.generation) { return ''; }
      hilog.info(0x0000, 'NasEnvironment', 'model=%{public}s dsm=%{public}s fileStation=%{public}s photos=%{public}s administrator=%{public}d',
        info.model, info.dsmVersion, info.fileStationVersion, info.photosVersion, info.administrator ? 1 : 0);
      return info.model + '\n' + info.dsmVersion +
        '\nFile Station ' + (info.fileStationVersion.length > 0 ? info.fileStationVersion : '版本未知或未安装') +
        '\nPhotos ' + (info.photosVersion.length > 0 ? info.photosVersion : '版本未知或未安装') +
        '\n' + (info.administrator ? '具有 File Station 管理权限' : '无 File Station 管理权限（或未能读取）');
    } catch (error) { if (ticket === this.generation) { await this.showFailure(error as Error, 'environment'); } return ''; }
    finally { if (ticket === this.generation) { this.busy = false; } }
  }
  dispose(): void {
    this.addressBook.dispose();
    this.generation++;
    this.queue.detach();

    this.connector?.close();
    this.connector = undefined;
    this.clearAccount();
    this.connected = false;
    this.busy = false;
    this.capabilities = [];
  }

  private async load(path: string, offset: number): Promise<boolean> {
    const connector = this.connector;
    if (this.busy || !this.authenticated || connector === undefined) { return false; }
    const ticket = this.generation;
    this.busy = true;
    this.errorText = '';
    this.directoryErrorText = '';
    try {
      const sort = path.length === 0 && this.fileSort === 'size' ? NasFileSortBy.Name : this.fileSort as NasFileSortBy;
      const page = await connector.list(path, offset, sort,
        this.sortDescending ? NasFileSortDirection.Descending : NasFileSortDirection.Ascending);
      if (ticket !== this.generation) { return false; }
      this.fileSort = sort;
      this.applyPage(path, page);
      hilog.info(0x0000, 'NasConnection', 'operation=list result=success');
      return true;
    } catch (error) {
      if (ticket === this.generation) {
        await this.showFailure(error as Error, 'list');
        this.directoryErrorText = this.errorText;
      }
      return false;
    }
    finally { if (ticket === this.generation) { this.busy = false; } }
  }
  private applyPage(path: string, page: NasFilePage): void {
    this.entries = page.entries;
    this.directory = path;
    this.pageOffset = page.offset;
    this.total = page.total;
  }
  /** 只清理账号相关的会话状态；地址与证书策略由连接流程单独管理。 */
  private resetSessionState(): void {
    this.extensions.reset();
    this.systemControl.deactivate();
    this.deviceCheckText = '尚未登记设备身份';
    this.deviceModel = '';
    this.deviceName = '';
    this.telemetry.detach();
    this.queue.detach();
    this.drive.detach();
    this.driveTransfers.detach();
    this.fileSort = 'name';
    this.sortDescending = false;
    this.actionNotice = '';
    this.fileTasks = [];
    this.fileTasksReady = false;
    this.fileTasksErrorText = '';
    this.directoryErrorText = '';
    this.fileTaskStore = new FileTaskStore();
    this.photosOpened = false;
    this.photoLibrary.reset();
    this.authenticated = false;
    this.password = '';
    this.otp = '';
    this.needsOtp = false;
    this.entries = [];
    this.directory = '';
    this.history = [];
    this.pageHistory = [];
    this.pageOffset = 0;
    this.total = 0;
  }

  private clearAccount(): void {
    this.resetSessionState();
    this.connectedOrigin = '';
    this.connectedInsecure = false;
  }
  private async showFailure(error: Error, operation: string): Promise<void> {
    const ticket = this.generation;
    hilog.error(0x0000, 'NasConnection', 'operation=%{public}s kind=%{public}d code=%{public}d',
      operation, error instanceof NasFailure ? error.kind : -1, error instanceof NasFailure ? error.code : 0);
    this.errorText = error instanceof NasFailure || error instanceof NasSessionStoreFailure ? error.message : '请求未完成，请重试或检查服务器配置。';
    if (error instanceof NasFailure) {
      if (error.kind === NasErrorKind.OtpRequired || error.kind === NasErrorKind.OtpInvalid) { this.needsOtp = true; }
      if (error.kind === NasErrorKind.SessionExpired) {
        this.connector?.close();
        this.connector = undefined;
        this.connected = false;
        this.capabilities = [];
        this.clearAccount();
        try {
          await this.store.clear();
          if (ticket === this.generation) { this.savedSession = false; }
        }
        catch (storageError) {
          if (ticket === this.generation) {
            this.savedSession = true;
            this.errorText += storageError instanceof NasSessionStoreFailure ? ' ' + storageError.message : ' 清除保存的登录信息失败，请重试。';
          }
        }
      }
    }
  }
}
