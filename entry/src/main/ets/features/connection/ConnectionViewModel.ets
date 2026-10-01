import { NasApiDescriptor, NasErrorKind, NasFailure, NasFileEntry, NasFilePage, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import { NasConnector } from '../../core/network/NasConnector';
import { RcpNasTransport } from '../../core/network/RcpNasTransport';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasSessionStore, NasSessionStoreFailure } from './NasSessionStore';
import { common } from '@kit.AbilityKit';
import { TransferProbe } from './TransferProbe';

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
  @Trace capabilities: NasApiDescriptor[] = [];
  @Trace entries: NasFileEntry[] = [];
  @Trace directory: string = '';
  @Trace pageOffset: number = 0;
  @Trace total: number = 0;
  readonly transfer: TransferProbe = new TransferProbe();
  private connector: NasConnector | undefined = undefined;
  private generation: number = 0;
  private history: string[] = [];
  private pageHistory: number[] = [];
  private store: NasSessionStore = new NasSessionStore();
  private context: common.UIAbilityContext | undefined = undefined;

  async restore(context?: common.UIAbilityContext): Promise<void> {
    if (context !== undefined) { this.context = context; }
    if (this.busy || this.authenticated) { return; }
    const ticket = ++this.generation;
    this.busy = true;
    this.errorText = '';
    try {
      const saved = await this.store.load();
      if (ticket !== this.generation || saved === undefined) { return; }
      this.savedSession = true;
      this.address = saved.origin;
      this.account = saved.account;
      this.connector?.close();
      const connector = new NasConnector(new RcpNasTransport());
      this.connector = connector;
      const capabilities = await connector.discover(saved.origin);
      if (ticket !== this.generation) { return; }
      this.capabilities = capabilities;
      connector.restoreSession({ sid: saved.sid, synoToken: saved.synoToken });
      const page = await connector.list('', 0);
      if (ticket !== this.generation) { return; }
      this.applyPage('', page);
      this.connected = true;
      this.authenticated = true;
      hilog.info(0x0000, 'NasConnection', 'operation=restore result=success');
      await this.inspectTransfer();
    } catch (error) {
      if (ticket === this.generation) {
        this.connector?.close();
        this.connector = undefined;
        this.connected = false;
        if (error instanceof NasSessionStoreFailure) { this.savedSession = true; }
        await this.showFailure(error as Error, 'restore');
      }
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }

  async connect(): Promise<void> {
    if (this.busy || this.connected) { return; }
    const ticket = ++this.generation;
    this.busy = true;
    this.errorText = '';
    try {
      this.address = normalizeNasOrigin(this.address);
      this.connector?.close();
      const connector = new NasConnector(new RcpNasTransport());
      this.connector = connector;
      const capabilities = await connector.discover(this.address);
      if (ticket !== this.generation) { return; }
      this.capabilities = capabilities;
      this.connected = true;
    } catch (error) {
      if (ticket === this.generation) {
        this.connector?.close();
        this.connector = undefined;
        await this.showFailure(error as Error, 'discover');
      }
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }

  async login(): Promise<void> {
    const connector = this.connector;
    if (this.busy || connector === undefined) { return; }
    const ticket = this.generation;
    this.busy = true;
    this.errorText = '';
    try {
      await connector.login(this.account, this.password, this.otp);
      if (ticket !== this.generation) { return; }
      this.password = '';
      this.otp = '';
      this.needsOtp = false;
      this.authenticated = true;
      hilog.info(0x0000, 'NasConnection', 'operation=login result=success');
    } catch (error) { if (ticket === this.generation) { await this.showFailure(error as Error, 'login'); } }
    finally { if (ticket === this.generation) { this.busy = false; } }
    if (this.authenticated && ticket === this.generation && await this.load('', 0)) {
      if (ticket !== this.generation) { return; }
      const session = connector.sessionSnapshot();
      if (session === undefined || ticket !== this.generation) { return; }
      this.busy = true;
      try {
        await this.store.save({ origin: this.address, account: this.account.trim(), sid: session.sid, synoToken: session.synoToken });
        if (ticket === this.generation) {
          this.savedSession = true;
          hilog.info(0x0000, 'NasConnection', 'operation=save-session result=success');
          await this.inspectTransfer();
        }
      } catch (error) { if (ticket === this.generation) { await this.showFailure(error as Error, 'save-session'); } }
      finally { if (ticket === this.generation) { this.busy = false; } }
    }
  }

  async openDirectory(entry: NasFileEntry): Promise<void> {
    if (!entry.isDirectory || this.busy) { return; }
    const oldPath = this.directory;
    if (await this.load(entry.path, 0)) {
      this.history.push(oldPath);
      this.pageHistory = [];
    }
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

  async disconnect(): Promise<void> {
    if (this.busy) { return; }
    const oldConnector = this.connector;
    this.connector = undefined;
    const ticket = ++this.generation;
    this.clearAccount();
    this.connected = false;
    this.capabilities = [];
    this.busy = true;
    this.errorText = '';
    try {
      if (this.context !== undefined) { await this.transfer.cancelPending(this.context); }
    } catch (error) {
      if (ticket === this.generation) { await this.showFailure(error as Error, 'cancel-transfer'); }
    }
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
  async verifyTransfer(recheck: boolean = false): Promise<void> {
    const connector = this.connector;
    const context = this.context;
    if (this.busy || !this.authenticated || connector === undefined || context === undefined) { return; }
    const ticket = this.generation;
    this.busy = true;
    this.errorText = '';
    let verified = false;
    try {
      const current = (): boolean => ticket === this.generation;
      if (recheck) { await this.transfer.reconcile(context, connector, this.address, this.account, current); }
      else { await this.transfer.run(context, connector, this.address, this.account, this.directory, current); }
      verified = true;
    } catch (error) { if (ticket === this.generation) { await this.showFailure(error as Error, 'transfer'); } }
    finally { if (ticket === this.generation) { this.busy = false; } }
    if (verified && ticket === this.generation && this.authenticated) { await this.refresh(); }
  }
  async discardTransfer(): Promise<void> {
    if (this.busy || this.context === undefined) { return; }
    const ticket = this.generation;
    this.busy = true;
    this.errorText = '';
    try { await this.transfer.cancelPending(this.context); }
    catch (error) { if (ticket === this.generation) { await this.showFailure(error as Error, 'cancel-transfer'); } }
    finally { if (ticket === this.generation) { this.busy = false; } }
  }
  private async inspectTransfer(): Promise<void> {
    if (this.context === undefined) { return; }
    const ticket = this.generation;
    try { await this.transfer.inspectSaved(this.context, this.address, this.account); }
    catch (error) { if (ticket === this.generation) { await this.showFailure(error as Error, 'read-transfer-record'); } }
  }
  dispose(): void {
    this.generation++;
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
    try {
      const page = await connector.list(path, offset);
      if (ticket !== this.generation) { return false; }
      this.applyPage(path, page);
      hilog.info(0x0000, 'NasConnection', 'operation=list result=success');
      return true;
    } catch (error) { if (ticket === this.generation) { await this.showFailure(error as Error, 'list'); } return false; }
    finally { if (ticket === this.generation) { this.busy = false; } }
  }
  private applyPage(path: string, page: NasFilePage): void {
    this.entries = page.entries;
    this.directory = path;
    this.pageOffset = page.offset;
    this.total = page.total;
  }
  private clearAccount(): void {
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
