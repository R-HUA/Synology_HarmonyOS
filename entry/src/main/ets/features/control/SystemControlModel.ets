import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure, normalizeNasOrigin, selectNasApi } from '../../core/domain/DsmProtocol';
import { decodeNasDeviceIdentity } from '../../core/domain/ConnectionRoutes';
import { NasControlAction, NasControlRecord, NasControlRejection, nasControlUnresolved,
  validateNasControlAction } from '../../core/domain/SystemControl';
import { NasConnector } from '../../core/network/NasConnector';
import { RcpNasTransport } from '../../core/network/RcpNasTransport';
import { nasDeviceFingerprint } from '../connection/NasAddressBookStore';
import { NasControlRecordStore } from './NasControlRecordStore';

@ObservedV2
export class SystemControlModel {
  @Trace origin: string = '';
  @Trace model: string = '';
  @Trace account: string = '';
  @Trace password: string = '';
  @Trace otp: string = '';
  @Trace needsOtp: boolean = false;
  @Trace authorized: boolean = false;
  @Trace busy: boolean = false;
  @Trace ready: boolean = false;
  @Trace errorText: string = '';
  @Trace notice: string = '';
  @Trace record: NasControlRecord | undefined = undefined;
  @Trace selectedAction: NasControlAction | undefined = undefined;
  @Trace confirmationText: string = '';
  private store: NasControlRecordStore = new NasControlRecordStore();
  private expectedFingerprint: string = '';
  private insecureTls: boolean = false;
  private controlConnector: NasConnector | undefined = undefined;
  private authorizedAccount: string = '';
  private generation: number = 0;
  private active: boolean = false;
  private expiresAt: number = 0;
  private expiryTimer: number = -1;
  private assertIdle: () => void = (): void => { throw new NasFailure(NasErrorKind.InvalidInput, '请重新进入系统控制页面。'); };

  async open(context: common.UIAbilityContext, current: NasConnector, origin: string, insecureTls: boolean,
    assertIdle: () => void): Promise<NasFailure | undefined> {
    if (this.busy) { this.errorText = '上次控制操作尚未结束，请稍后重新读取。'; return undefined; }
    this.deactivate();
    const ticket = ++this.generation;
    this.active = true;
    this.assertIdle = assertIdle;
    this.busy = true;
    this.ready = false;
    this.errorText = '';
    this.notice = '';
    this.model = '';
    this.expectedFingerprint = '';
    this.insecureTls = insecureTls;
    try {
      this.origin = normalizeNasOrigin(origin);
      const record = await this.store.load(context);
      if (!this.isCurrent(ticket)) { return undefined; }
      this.record = record;
      this.ready = true;
      const identity = decodeNasDeviceIdentity(await current.telemetrySystem());
      const fingerprint = await nasDeviceFingerprint(identity);
      if (!this.isCurrent(ticket)) { return undefined; }
      this.model = identity.model;
      this.expectedFingerprint = fingerprint;
      if (nasControlUnresolved(this.record)) { this.notice = '先核对上一条操作结果，再进行新的系统控制。'; }
    } catch (error) {
      if (this.isCurrent(ticket)) {
        this.errorText = this.failureText(error as Error, '无法读取控制配置或设备标识，未开放系统控制。');
        if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { return error; }
      }
    } finally { this.busy = false; }
    return undefined;
  }

  canAuthorize(): boolean {
    return this.active && this.ready && !this.busy && this.expectedFingerprint.length > 0 && !nasControlUnresolved(this.record);
  }

  async authorize(): Promise<void> {
    if (!this.canAuthorize()) { return; }
    const ticket = this.generation;
    this.busy = true;
    this.errorText = '';
    this.notice = '';
    this.revokeAuthorization();
    const connector = new NasConnector(new RcpNasTransport(this.insecureTls), 'NasControl');
    this.controlConnector = connector;
    try {
      const capabilities = await connector.discover(this.origin);
      selectNasApi(capabilities, 'SYNO.Core.System', [1]);
      if (!this.isCurrent(ticket)) { return; }
      const account = this.account.trim();
      await connector.login(account, this.password, this.otp);
      if (!this.isCurrent(ticket)) { return; }
      const identity = decodeNasDeviceIdentity(await connector.telemetrySystem());
      const fingerprint = await nasDeviceFingerprint(identity);
      if (!this.isCurrent(ticket)) { return; }
      if (fingerprint !== this.expectedFingerprint) {
        throw new NasFailure(NasErrorKind.InvalidInput, '独立登录后的设备标识不一致，已停止授权。');
      }
      this.authorizedAccount = account;
      this.authorized = true;
      this.needsOtp = false;
      this.expiresAt = Date.now() + 120000;
      this.expiryTimer = setTimeout((): void => {
        if (this.isCurrent(ticket)) {
          this.revokeAuthorization();
          this.notice = '临时授权已到期，请重新登录。';
        }
      }, 120000);
      this.notice = '独立登录及设备身份已确认。控制权限由 NAS 在提交时校验；临时授权仅供一次操作，有效期两分钟。';
    } catch (error) {
      if (this.isCurrent(ticket)) {
        this.errorText = this.failureText(error as Error, '系统控制登录失败，请检查账号权限与网络。');
        this.needsOtp = error instanceof NasFailure && [NasErrorKind.OtpRequired, NasErrorKind.OtpInvalid].includes(error.kind);
      }
      this.revokeAuthorization();
    } finally {
      this.password = '';
      this.otp = '';
      this.busy = false;
    }
  }

  prepare(action: NasControlAction): void {
    if (this.busy) { return; }
    this.errorText = '';
    try {
      this.assertAuthorized();
      this.assertIdle();
      this.selectedAction = validateNasControlAction(action);
      this.confirmationText = '';
    } catch (error) { this.errorText = this.failureText(error as Error, '暂不能准备系统控制操作。'); }
  }

  confirmationWord(): string { return this.selectedAction === 'shutdown' ? '关机' : '重启'; }

  cancelPreparation(): void { this.selectedAction = undefined; this.confirmationText = ''; }

  async submit(): Promise<void> {
    if (this.busy) { return; }
    this.errorText = '';
    this.notice = '';
    let action: NasControlAction;
    try {
      this.assertAuthorized();
      this.assertIdle();
      if (this.selectedAction === undefined || this.confirmationText !== this.confirmationWord()) {
        throw new NasFailure(NasErrorKind.InvalidInput, '请先选择操作并输入完整确认文字。');
      }
      action = validateNasControlAction(this.selectedAction);
    } catch (error) { this.errorText = this.failureText(error as Error, '系统控制条件尚未满足。'); return; }
    const connector = this.controlConnector;
    if (connector === undefined) { return; }
    const ticket = this.generation;
    const now = Date.now();
    let id: string;
    try { id = util.generateRandomUUID(); }
    catch { this.errorText = '无法生成控制记录标识，未发送请求，请重试。'; return; }
    const pending: NasControlRecord = { id: id, origin: this.origin,
      account: this.authorizedAccount, model: this.model, fingerprint: this.expectedFingerprint,
      action: action, state: 'pending', createdAt: now, updatedAt: now };
    this.busy = true;
    try {
      try { await this.store.save(pending); }
      catch (error) {
        this.ready = false;
        this.record = pending;
        this.errorText = this.failureText(error as Error, '无法确认准备记录是否保存，已停止提交，请重新读取记录。');
        return;
      }
      this.record = pending;
      let outcome = pending;
      try {
        if (!this.isCurrent(ticket)) { throw new NasControlRejection(NasErrorKind.Cancelled, '页面已离开，未发送控制请求。'); }
        this.assertAuthorized(false);
        this.assertIdle();
      } catch (error) {
        outcome = this.withState(pending, 'rejected');
        this.errorText = this.failureText(error as Error, '提交前条件已变化，未发送控制请求。');
      }
      if (outcome.state === 'pending') {
        try {
          await connector.systemControl(action);
          outcome = this.withState(pending, 'accepted');
          this.notice = 'NAS 已接收请求，实际结果仍待核对。请在 DSM 或现场确认，不要重复提交。';
        } catch (error) {
          if (error instanceof NasControlRejection) {
            outcome = this.withState(pending, 'rejected');
            this.errorText = this.failureText(error as Error, 'NAS 未接受此操作。');
          } else {
            this.errorText = '请求结果待确认。连接中断、超时或离线不能证明操作成功或失败，请在 DSM 或现场核对，切勿重复提交。';
          }
        }
      }
      try { await this.store.save(outcome); this.record = outcome; }
      catch (error) {
        this.ready = false;
        this.record = pending;
        this.errorText = this.failureText(error as Error, '操作结果记录未确认保存，请保留原记录并重新读取。');
      }
    } finally {
      this.cancelPreparation();
      this.revokeAuthorization();
      this.busy = false;
    }
  }

  async resolve(id: string): Promise<void> {
    if (!this.active || !this.ready || this.busy || this.record?.id !== id || !nasControlUnresolved(this.record)) { return; }
    const record = this.record;
    if (record === undefined) { return; }
    this.busy = true;
    this.errorText = '';
    try {
      const resolved = this.withState(record, 'resolved');
      await this.store.save(resolved);
      this.record = resolved;
      this.notice = '已记录人工核对，未重新发送控制请求。需要新的操作时请重新授权。';
    } catch (error) {
      this.ready = false;
      this.errorText = this.failureText(error as Error, '核对记录未确认保存，请重新读取。');
    } finally { this.busy = false; }
  }

  deactivate(): void {
    this.active = false;
    this.generation++;
    this.password = '';
    this.otp = '';
    this.account = '';
    this.needsOtp = false;
    this.cancelPreparation();
    this.revokeAuthorization();
  }

  private revokeAuthorization(): void {
    if (this.expiryTimer !== -1) { clearTimeout(this.expiryTimer); this.expiryTimer = -1; }
    this.authorized = false;
    this.authorizedAccount = '';
    this.expiresAt = 0;
    this.cancelPreparation();
    const connector = this.controlConnector;
    this.controlConnector = undefined;
    if (connector !== undefined) {
      connector.logout().catch((): void => {
        connector.close();
        hilog.warn(0x0000, 'NasControl', 'operation=logout result=unconfirmed');
      });
    }
  }

  private assertAuthorized(checkRecord: boolean = true): void {
    if (!this.active || !this.ready || !this.authorized || this.controlConnector === undefined || Date.now() >= this.expiresAt) {
      throw new NasFailure(NasErrorKind.Permission, '临时授权不可用，请重新登录系统控制账号。');
    }
    if (checkRecord && nasControlUnresolved(this.record)) {
      throw new NasFailure(NasErrorKind.InvalidInput, '上一条操作结果尚未核对，不能再次提交。');
    }
  }

  private isCurrent(ticket: number): boolean { return this.active && ticket === this.generation; }

  private withState(record: NasControlRecord, state: 'accepted' | 'rejected' | 'resolved'): NasControlRecord {
    return { id: record.id, origin: record.origin, account: record.account, model: record.model,
      fingerprint: record.fingerprint, action: record.action, state: state,
      createdAt: record.createdAt, updatedAt: Math.max(record.createdAt, Date.now()) };
  }

  private failureText(error: Error, fallback: string): string {
    return error instanceof NasFailure ? error.message : fallback;
  }
}
