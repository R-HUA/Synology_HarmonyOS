import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import type { DriveEntry } from '../../core/domain/DriveProtocol';
import { copyDriveLink, copyDriveLinkEntry, decodeDriveFileLink, driveFileLinkFields, DRIVE_SHARING_API, DRIVE_SHARING_VERSION } from '../../core/domain/DriveCollaborationProtocol';
import type { DriveLinkRecord, DriveLinkState } from '../../core/domain/DriveCollaborationProtocol';
import type { DriveKernelPort } from '../../core/network/DriveAdapter';
import { DriveSharingStore } from './DriveSharingStore';

export interface DriveLinkDraft { fileId: string; name: string; }
interface DriveSharingSession {
  context: common.UIAbilityContext; kernel: DriveKernelPort; origin: string; account: string;
  store: DriveSharingStore; records: DriveLinkRecord[]; canWrite: () => boolean;
  onSessionFailure: (error: NasFailure) => Promise<void>;
}

@ObservedV2
export class DriveSharingModel {
  @Trace ready: boolean = false;
  @Trace available: boolean = false;
  @Trace busy: boolean = false;
  @Trace errorText: string = '';
  @Trace notice: string = '';
  @Trace items: DriveLinkRecord[] = [];
  @Trace draft: DriveLinkDraft | undefined = undefined;
  private draftEntry: DriveEntry | undefined = undefined;
  private session: DriveSharingSession | undefined = undefined;
  private tail: Promise<void> = Promise.resolve();
  private foreground: boolean = true;
  private stopping: boolean = false;

  get hasPending(): boolean { return this.items.some((record: DriveLinkRecord): boolean => record.state === 'unknown'); }

  async attach(context: common.UIAbilityContext, kernel: DriveKernelPort, origin: string, account: string,
    onSessionFailure: (error: NasFailure) => Promise<void>, canWrite: () => boolean = (): boolean => true): Promise<void> {
    this.detach();
    const session: DriveSharingSession = { context, kernel, origin: normalizeNasOrigin(origin), account: account.trim(),
      store: new DriveSharingStore(), records: [], onSessionFailure, canWrite };
    this.session = session;
    this.available = kernel.supportsDriveApi(DRIVE_SHARING_API, DRIVE_SHARING_VERSION);
    await this.tail;
    if (this.session === session) { await this.reload(); }
  }

  detach(): void {
    this.session = undefined; this.items = []; this.draft = undefined; this.draftEntry = undefined;
    this.ready = false; this.available = false; this.busy = false; this.errorText = ''; this.notice = '';
  }
  setForeground(foreground: boolean): void { this.foreground = foreground; }
  async stopAll(): Promise<void> { this.stopping = true; try { await this.tail; } finally { this.stopping = false; } }

  async reload(): Promise<void> {
    await this.run(async (session: DriveSharingSession): Promise<void> => {
      this.ready = false;
      session.records = await session.store.load(session.context, session.origin, session.account);
      this.check(session); this.ready = true; this.publish(session);
    }, false);
  }

  /** 仅准备确认界面；选择项目不会调用 create_link。 */
  prepare(entry: DriveEntry): boolean {
    const session = this.session;
    if (session === undefined || this.busy) { return false; }
    this.errorText = ''; this.notice = '';
    try {
      this.requireWrite(session); driveFileLinkFields(entry);
      this.draftEntry = copyDriveLinkEntry(entry);
      this.draft = { fileId: entry.fileId, name: entry.name };
      return true;
    } catch (error) { this.errorText = error instanceof NasFailure ? error.message : '此项目的文件链接无法获取。'; return false; }
  }
  clearDraft(): void { if (!this.busy) { this.draft = undefined; this.draftEntry = undefined; } }

  /** 确认后先落盘 unknown，再发送唯一一次 create_link；unknown 只能人工核对关闭。 */
  async submit(): Promise<boolean> {
    let completed = false;
    const submittedSession = this.session;
    await this.run(async (session: DriveSharingSession): Promise<void> => {
      this.requireWrite(session);
      const entry = this.draftEntry;
      if (entry === undefined) { return; }
      const fields = driveFileLinkFields(entry);
      const record: DriveLinkRecord = { id: util.generateRandomUUID(), nasOrigin: session.origin, account: session.account,
        fileId: entry.fileId, name: entry.name, createdAt: Date.now(), state: 'unknown' };
      await this.save(session, session.records.concat([record]));
      this.check(session); this.publish(session);
      if (!this.foreground || this.stopping || !session.canWrite()) {
        await this.replace(session, record.id, 'failed');
        throw new NasFailure(NasErrorKind.Cancelled, '链接尚未获取，请返回前台并处理其他任务后重试。');
      }
      // dispatch 前再次检查会话。迟到的结果只可写回原账号的私有记录，不可发布到新连接。
      this.check(session);
      this.draft = undefined; this.draftEntry = undefined;
      let url: string;
      try { url = decodeDriveFileLink(await session.kernel.requestDrive(DRIVE_SHARING_API, DRIVE_SHARING_VERSION, 'create_link', fields)); }
      catch (error) {
        if (error instanceof NasFailure && [NasErrorKind.Permission, NasErrorKind.Unsupported, NasErrorKind.InvalidInput].includes(error.kind)) {
          await this.replace(session, record.id, 'failed');
        }
        throw error as Error;
      }
      await this.replace(session, record.id, 'completed', url);
      this.check(session); this.publish(session);
      this.notice = '文件链接已获取，访问权限以 NAS 当前设置为准。'; completed = true;
    });
    return completed && this.session === submittedSession;
  }

  /** 调用方须先让用户确认已在 Drive 网页核对；此方法不再请求服务器。 */
  async closeUnknown(id: string): Promise<void> {
    await this.run(async (session: DriveSharingSession): Promise<void> => {
      if (this.find(session, id).state !== 'unknown') { throw new NasFailure(NasErrorKind.InvalidInput, '此链接记录无需核对关闭。'); }
      await this.replace(session, id, 'closed'); this.check(session); this.publish(session);
    });
  }
  async remove(id: string): Promise<void> {
    await this.run(async (session: DriveSharingSession): Promise<void> => {
      if (this.find(session, id).state === 'unknown') { throw new NasFailure(NasErrorKind.InvalidInput, '请先在 Drive 网页核对获取结果。'); }
      await this.save(session, session.records.filter((record: DriveLinkRecord): boolean => record.id !== id));
      this.check(session); this.publish(session);
    });
  }

  private requireWrite(session: DriveSharingSession): void {
    if (!this.ready) { throw new NasFailure(NasErrorKind.InvalidInput, '请先重新加载本机文件链接记录。'); }
    if (!this.available) { throw new NasFailure(NasErrorKind.Unsupported, '此 NAS 未提供可用的 Drive 文件链接功能。'); }
    if (!this.foreground || this.stopping || !session.canWrite()) { throw new NasFailure(NasErrorKind.InvalidInput, '请在应用前台处理其他任务后获取文件链接。'); }
    if (this.hasPending) { throw new NasFailure(NasErrorKind.InvalidInput, '有文件链接的获取结果待确认，请先在 Drive 网页核对并关闭记录。'); }
  }
  private find(session: DriveSharingSession, id: string): DriveLinkRecord {
    const record = session.records.find((item: DriveLinkRecord): boolean => item.id === id);
    if (record === undefined) { throw new NasFailure(NasErrorKind.InvalidInput, '此文件链接记录已移除。'); }
    return record;
  }
  private async replace(session: DriveSharingSession, id: string, state: DriveLinkState, url?: string): Promise<void> {
    const records = session.records.map(copyDriveLink);
    const record = records.find((item: DriveLinkRecord): boolean => item.id === id);
    if (record === undefined) { throw new NasFailure(NasErrorKind.Protocol, '文件链接记录无法确认，请先在 Drive 网页核对。'); }
    record.state = state; record.url = url;
    await this.save(session, records);
  }
  private check(session: DriveSharingSession): void { if (this.session !== session) { throw new NasFailure(NasErrorKind.Cancelled, '连接已切换。'); } }
  private async save(session: DriveSharingSession, records: DriveLinkRecord[]): Promise<void> {
    try { await session.store.save(records); session.records = records; }
    catch (_) {
      if (this.session === session) { this.ready = false; }
      throw new NasFailure(NasErrorKind.Protocol, '文件链接记录未保存，已暂停获取，请重新加载后核对结果。');
    }
  }
  private publish(session: DriveSharingSession): void { if (this.session === session) { this.items = session.records.map(copyDriveLink).reverse(); } }
  private async run(action: (session: DriveSharingSession) => Promise<void>, requireReady: boolean = true): Promise<void> {
    const session = this.session;
    if (session === undefined || this.busy) { return; }
    if (requireReady && !this.ready) { this.errorText = '请先重新加载本机文件链接记录。'; return; }
    this.busy = true; this.errorText = ''; this.notice = '';
    let failure: NasFailure | undefined = undefined;
    const job = async (): Promise<void> => {
      try { this.check(session); await action(session); }
      catch (error) {
        if (this.session !== session) { return; }
        this.publish(session);
        this.errorText = error instanceof NasFailure ? error.message : '文件链接获取未完成，请先在 Drive 网页核对。';
        hilog.error(0x0000, 'NasDrive', 'operation=file_link kind=%{public}d', error instanceof NasFailure ? error.kind : -1);
        if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { failure = error; }
      } finally { if (this.session === session) { this.busy = false; } }
    };
    this.tail = this.tail.then(job, job); await this.tail;
    if (failure !== undefined && this.session === session) { await session.onSessionFailure(failure); }
  }
}
