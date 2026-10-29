import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { NasErrorKind, NasFailure, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import { decodeNasDeviceIdentity } from '../../core/domain/ConnectionRoutes';
import { NasControlAction, NasControlRecord, NasControlRejection, nasControlUnresolved,
  validateNasControlAction } from '../../core/domain/SystemControl';
import { NasConnector } from '../../core/network/NasConnector';
import { nasDeviceFingerprint } from '../connection/NasAddressBookStore';
import { NasControlRecordStore } from './NasControlRecordStore';

@ObservedV2
export class SystemControlModel {
  @Trace origin: string = '';
  @Trace model: string = '';
  @Trace account: string = '';
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
  private controlConnector: NasConnector | undefined = undefined;
  private generation: number = 0;
  private active: boolean = false;
  private assertIdle: () => void = (): void => { throw new NasFailure(NasErrorKind.InvalidInput, '请重新进入系统控制页面。'); };

  async open(context: common.UIAbilityContext, current: NasConnector, origin: string, account: string,
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
    this.controlConnector = current;
    this.account = account;
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
      this.authorized = true;
      if (nasControlUnresolved(this.record)) { this.notice = '先核对上一条操作结果，再进行新的系统控制。'; }
    } catch (error) {
      if (this.isCurrent(ticket)) {
        this.errorText = this.failureText(error as Error, '无法读取控制配置或设备标识，未开放系统控制。');
        if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { return error; }
      }
    } finally { this.busy = false; }
    return undefined;
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

  async submit(): Promise<NasFailure | undefined> {
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
    let sessionFailure: NasFailure | undefined = undefined;
    const now = Date.now();
    let id: string;
    try { id = util.generateRandomUUID(); }
    catch { this.errorText = '无法生成控制记录标识，未发送请求，请重试。'; return; }
    const pending: NasControlRecord = { id: id, origin: this.origin,
      account: this.account, model: this.model, fingerprint: this.expectedFingerprint,
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
        const identity = decodeNasDeviceIdentity(await connector.telemetrySystem());
        const fingerprint = await nasDeviceFingerprint(identity);
        if (!this.isCurrent(ticket)) { throw new NasControlRejection(NasErrorKind.Cancelled, '当前连接已变化，未发送控制请求。'); }
        if (fingerprint !== this.expectedFingerprint) { throw new NasControlRejection(NasErrorKind.InvalidInput, '设备身份发生变化，未发送控制请求。'); }
        this.assertAuthorized(false);
        this.assertIdle();
      } catch (error) {
        if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { sessionFailure = error; }
        outcome = this.withState(pending, 'rejected');
        this.errorText = this.failureText(error as Error, '提交前条件已变化，未发送控制请求。');
      }
      if (outcome.state === 'pending') {
        try {
          await connector.systemControl(action);
          outcome = this.withState(pending, 'accepted');
          this.notice = 'NAS 已接收请求，实际结果仍待核对。请在 DSM 或现场确认，不要重复提交。';
        } catch (error) {
          if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { sessionFailure = error; }
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
    return this.isCurrent(ticket) ? sessionFailure : undefined;
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
      this.notice = '已记录核对结果。需要新的操作时请重新核验设备。';
    } catch (error) {
      this.ready = false;
      this.errorText = this.failureText(error as Error, '核对记录未确认保存，请重新读取。');
    } finally { this.busy = false; }
  }

  deactivate(): void {
    this.active = false;
    this.generation++;
    this.account = '';
    this.cancelPreparation();
    this.revokeAuthorization();
  }

  private revokeAuthorization(): void {
    this.authorized = false;
    this.cancelPreparation();
    this.controlConnector = undefined;
  }

  private assertAuthorized(checkRecord: boolean = true): void {
    if (!this.active || !this.ready || !this.authorized || this.controlConnector === undefined) {
      throw new NasFailure(NasErrorKind.Permission, '当前控制页面已失效，请重新进入。');
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
