import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import type { DriveEntry } from '../../core/domain/DriveProtocol';
import { driveActionAllowed, driveActionFields } from '../../core/domain/DriveActionProtocol';
import type { DriveAction, DriveActionInput, DriveActionStatus } from '../../core/domain/DriveActionProtocol';
import { copyDriveAction } from '../../core/domain/DriveActionState';
import type { DriveActionRecord } from '../../core/domain/DriveActionState';
import { DriveActionAdapter } from '../../core/network/DriveActionAdapter';
import { NasConnector } from '../../core/network/NasConnector';
import { DriveActionStore } from './DriveActionStore';
import { DriveBrowserModel } from './DriveBrowserModel';

export interface DriveActionDraft { action: DriveAction; entry: DriveEntry; target?: DriveEntry; conflicts?: number; }
interface DriveActionSession {
  context: common.UIAbilityContext; origin: string; account: string; adapter: DriveActionAdapter;
  store: DriveActionStore; records: DriveActionRecord[]; onSessionFailure: (error: NasFailure) => Promise<void>;
  canWrite: () => boolean;
}

@ObservedV2
export class DriveActionModel {
  @Trace ready: boolean = false;
  @Trace available: boolean = false;
  @Trace busy: boolean = false;
  @Trace errorText: string = '';
  @Trace notice: string = '';
  @Trace items: DriveActionRecord[] = [];
  @Trace draft: DriveActionDraft | undefined = undefined;
  @Trace newName: string = '';
  readonly destinations: DriveBrowserModel = new DriveBrowserModel();
  private session: DriveActionSession | undefined = undefined;
  private tail: Promise<void> = Promise.resolve();
  private polling: boolean = false;
  private foreground: boolean = true;
  private timer: number = -1;
  private stopping: boolean = false;

  get hasPending(): boolean { return this.items.some((item: DriveActionRecord): boolean => item.state === 'unknown' || item.state === 'accepted'); }

  async attach(context: common.UIAbilityContext, connector: NasConnector, origin: string, account: string,
    onSessionFailure: (error: NasFailure) => Promise<void>, canWrite: () => boolean = (): boolean => true): Promise<void> {
    this.detach();
    const session: DriveActionSession = { context, origin: normalizeNasOrigin(origin), account: account.trim(),
      adapter: new DriveActionAdapter(connector), store: new DriveActionStore(), records: [], onSessionFailure, canWrite };
    this.session = session;
    this.stopping = false;
    this.available = session.adapter.available();
    this.destinations.attach(connector, onSessionFailure);
    if (session.account.length === 0) { this.errorText = '缺少账号，无法读取 Drive 操作记录。'; return; }
    await this.tail;
    if (this.session === session) { await this.reload(); }
  }

  detach(): void {
    this.stopTimer();
    this.session = undefined;
    this.items = [];
    this.draft = undefined;
    this.newName = '';
    this.ready = false;
    this.busy = false;
    this.available = false;
    this.errorText = '';
    this.notice = '';
    this.destinations.detach();
  }

  async stopAll(): Promise<void> {
    this.stopping = true; this.polling = false; this.stopTimer();
    try { await this.tail; } finally { this.stopping = false; }
  }
  setPolling(polling: boolean): void { this.polling = polling; this.schedule(); }
  setForeground(foreground: boolean): void { this.foreground = foreground; this.schedule(); }

  async reload(): Promise<void> {
    await this.run(async (session: DriveActionSession): Promise<void> => {
      this.ready = false;
      session.records = await session.store.load(session.context, session.origin, session.account);
      this.check(session);
      this.ready = true;
      this.publish(session);
    }, false);
  }

  async prepare(entry: DriveEntry, action: DriveAction): Promise<boolean> {
    let prepared = false;
    await this.run(async (session: DriveActionSession): Promise<void> => {
      this.requireWrite(session);
      if (!driveActionAllowed(entry, action)) { throw new NasFailure(NasErrorKind.Permission, '没有权限执行此操作。'); }
      this.draft = { action, entry };
      this.newName = action === 'create' ? '' : entry.name;
      this.destinations.reset();
      if (action === 'move' || action === 'copy') { await this.destinations.open(); this.check(session); }
      prepared = true;
    });
    return prepared;
  }

  clearDraft(): void { if (!this.busy) { this.draft = undefined; this.newName = ''; this.destinations.reset(); } }

  async selectDestination(target: DriveEntry): Promise<void> {
    await this.run(async (session: DriveActionSession): Promise<void> => {
      this.requireWrite(session);
      const draft = this.draft;
      if (draft === undefined || draft.action !== 'move' && draft.action !== 'copy') { return; }
      this.draft = { action: draft.action, entry: draft.entry };
      const conflicts = await session.adapter.preflight({ action: draft.action, entry: draft.entry, target });
      this.check(session);
      this.draft = { action: draft.action, entry: draft.entry, target, conflicts };
    });
  }

  async submit(): Promise<boolean> {
    const submittedSession = this.session;
    let sent = false;
    await this.run(async (session: DriveActionSession): Promise<void> => {
      this.requireWrite(session);
      const draft = this.draft;
      if (draft === undefined) { return; }
      const input: DriveActionInput = { action: draft.action, entry: draft.entry, name: this.newName, target: draft.target };
      driveActionFields(input);
      if ((input.action === 'move' || input.action === 'copy') && draft.conflicts === undefined) {
        throw new NasFailure(NasErrorKind.InvalidInput, '请先选择并检查目标文件夹。');
      }
      const record: DriveActionRecord = { id: util.generateRandomUUID(), action: input.action,
        resource: { nasOrigin: session.origin, account: session.account, fileId: input.entry.fileId },
        name: input.action === 'create' ? this.newName.trim() : input.entry.name,
        destination: input.action === 'create' ? input.entry.displayPath || input.entry.name :
          input.action === 'rename' ? this.newName.trim() : input.target?.displayPath || input.target?.name || '',
        state: 'unknown', errorText: '操作结果待确认，请先在 NAS 核对。' };
      const records = session.records.concat([record]);
      await this.save(session, records);
      session.records = records;
      this.check(session);
      this.publish(session);
      if (!this.foreground || this.stopping || !session.canWrite()) {
        record.state = 'failed'; record.errorText = '操作尚未发送，请返回前台并处理其他任务后重试。';
        await this.save(session, session.records); this.publish(session); return;
      }
      // 记录已落盘后才发送。任何模糊结果均保留 unknown，永远不重放 start。
      sent = true;
      try {
        record.taskId = await session.adapter.start(input);
        record.state = record.taskId === undefined ? 'completed' : 'accepted';
        record.errorText = '';
      } catch (error) {
        if (error instanceof NasFailure && [NasErrorKind.InvalidInput, NasErrorKind.Permission, NasErrorKind.Unsupported].includes(error.kind)) {
          record.state = 'failed'; record.errorText = error.message;
        }
        await this.save(session, session.records);
        this.publish(session);
        throw error as Error;
      }
      await this.save(session, session.records);
      this.check(session);
      this.publish(session);
      this.draft = undefined;
      this.newName = '';
      this.notice = record.state === 'completed' ? '操作已完成，请刷新目录核对。' : '操作已提交，可在任务页查看状态。';
    });
    return sent && this.session === submittedSession;
  }

  async refresh(id: string): Promise<void> {
    await this.run(async (session: DriveActionSession): Promise<void> => {
      const record = this.find(session, id);
      if (record.state !== 'accepted' || record.taskId === undefined) { return; }
      let status: DriveActionStatus;
      try { status = await session.adapter.status(record.taskId); }
      catch (error) {
        this.check(session);
        record.errorText = '任务状态未能查询，请稍后重查；若仍不可用，请先在 NAS 核对操作是否结束。';
        await this.save(session, session.records); this.publish(session);
        throw error as Error;
      }
      this.check(session);
      const records = session.records.map(copyDriveAction);
      const next = records.find((item: DriveActionRecord): boolean => item.id === id);
      if (next === undefined) { return; }
      next.state = status.state;
      next.progress = status.progress;
      next.errorText = status.state === 'failed' ? 'Drive 已结束此任务，但报告了操作错误，请在 NAS 核对。' :
        status.state === 'partial' ? '有项目被跳过，请在 NAS 核对结果。' : '';
      await this.save(session, records);
      session.records = records;
      this.publish(session);
    });
  }

  async closeUnknown(id: string): Promise<void> {
    await this.run(async (session: DriveActionSession): Promise<void> => {
      const record = this.find(session, id);
      if (record.state !== 'unknown' && !(record.state === 'accepted' && record.errorText.length > 0)) {
        throw new NasFailure(NasErrorKind.InvalidInput, '请通过查询确认此任务状态。');
      }
      const records = session.records.map(copyDriveAction);
      const next = records.find((item: DriveActionRecord): boolean => item.id === id);
      if (next !== undefined) { next.state = 'closed'; next.errorText = ''; }
      await this.save(session, records);
      session.records = records;
      this.publish(session);
    });
  }

  async remove(id: string): Promise<void> {
    await this.run(async (session: DriveActionSession): Promise<void> => {
      const record = this.find(session, id);
      if (record.state === 'unknown' || record.state === 'accepted') { throw new NasFailure(NasErrorKind.InvalidInput, '请先核对或查询任务结果。'); }
      const records = session.records.filter((item: DriveActionRecord): boolean => item.id !== id);
      await this.save(session, records);
      session.records = records;
      this.publish(session);
    });
  }

  private requireWrite(session: DriveActionSession): void {
    if (!this.available || !this.foreground || this.stopping || this.hasPending || !session.canWrite()) {
      throw new NasFailure(NasErrorKind.InvalidInput, '请在应用前台处理未结束的 Drive 任务后再操作。');
    }
  }
  private find(session: DriveActionSession, id: string): DriveActionRecord {
    const record = session.records.find((item: DriveActionRecord): boolean => item.id === id);
    if (record === undefined) { throw new NasFailure(NasErrorKind.InvalidInput, '此操作记录已移除。'); }
    return record;
  }
  private check(session: DriveActionSession): void {
    if (this.session !== session) { throw new NasFailure(NasErrorKind.Cancelled, '连接已切换。'); }
  }
  private async save(session: DriveActionSession, records: DriveActionRecord[]): Promise<void> {
    try { await session.store.save(records); }
    catch (_) {
      if (this.session === session) { this.ready = false; }
      throw new NasFailure(NasErrorKind.Protocol, 'Drive 操作记录未保存，已暂停新操作，请重新加载记录后核对结果。');
    }
  }
  private publish(session: DriveActionSession): void {
    if (this.session === session) { this.items = session.records.map(copyDriveAction).reverse(); }
  }
  private async run(action: (session: DriveActionSession) => Promise<void>, requireReady: boolean = true): Promise<void> {
    const session = this.session;
    if (session === undefined || this.busy) { return; }
    if (requireReady && !this.ready) { this.errorText = '请先重新加载 Drive 操作记录。'; return; }
    this.busy = true;
    this.errorText = '';
    this.notice = '';
    let failure: NasFailure | undefined = undefined;
    const job = async (): Promise<void> => {
      try { this.check(session); await action(session); }
      catch (error) {
        if (this.session !== session) { return; }
        this.publish(session);
        this.errorText = error instanceof NasFailure ? error.message : 'Drive 操作未完成，请保留记录后重试。';
        hilog.error(0x0000, 'NasDrive', 'operation=file_action kind=%{public}d', error instanceof NasFailure ? error.kind : -1);
        if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { failure = error; }
      } finally { if (this.session === session) { this.busy = false; this.schedule(); } }
    };
    this.tail = this.tail.then(job, job);
    await this.tail;
    if (failure !== undefined && this.session === session) { await session.onSessionFailure(failure); }
  }
  private stopTimer(): void { if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; } }
  private schedule(): void {
    this.stopTimer();
    if (!this.polling || !this.foreground || this.stopping || !this.ready || this.busy) { return; }
    const record = this.items.find((item: DriveActionRecord): boolean => item.state === 'accepted');
    if (record === undefined || record.errorText.length > 0 || this.errorText.length > 0) { return; }
    this.timer = setTimeout((): void => { this.timer = -1; this.refresh(record.id); }, 2000);
  }
}
