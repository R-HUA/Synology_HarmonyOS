import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { decodeDriveNotifications, driveNotificationFields, DRIVE_NOTIFICATIONS_API, DRIVE_NOTIFICATIONS_VERSION } from '../../core/domain/DriveCollaborationProtocol';
import type { DriveNotification } from '../../core/domain/DriveCollaborationProtocol';
import type { DriveKernelPort } from '../../core/network/DriveAdapter';

export interface DriveNotificationItem extends DriveNotification { read: boolean; }
interface DriveNotificationsSession {
  kernel: DriveKernelPort; readIds: string[]; onSessionFailure: (error: NasFailure) => Promise<void>;
}

/** 本机已读仅保留在本次 attach 会话；detach/切换账号/重新登录均清空，不写服务器通知。 */
@ObservedV2
export class DriveNotificationsModel {
  @Trace available: boolean = false;
  @Trace busy: boolean = false;
  @Trace loaded: boolean = false;
  @Trace errorText: string = '';
  @Trace items: DriveNotificationItem[] = [];
  @Trace total: number = 0;
  private session: DriveNotificationsSession | undefined = undefined;

  attach(kernel: DriveKernelPort, onSessionFailure: (error: NasFailure) => Promise<void>): void {
    this.detach();
    this.session = { kernel, readIds: [], onSessionFailure };
    this.available = kernel.supportsDriveApi(DRIVE_NOTIFICATIONS_API, DRIVE_NOTIFICATIONS_VERSION);
  }
  detach(): void {
    this.session = undefined; this.available = false; this.busy = false; this.loaded = false;
    this.errorText = ''; this.items = []; this.total = 0;
  }
  async refresh(): Promise<boolean> {
    const session = this.session;
    if (session === undefined || this.busy) { return false; }
    if (!this.available) { this.errorText = '此 NAS 未提供可用的 Drive 通知功能。'; return false; }
    this.busy = true; this.errorText = '';
    try {
      const page = await session.kernel.readDriveFeature('driveNotifications', async () => decodeDriveNotifications(
        await session.kernel.requestDrive(DRIVE_NOTIFICATIONS_API, DRIVE_NOTIFICATIONS_VERSION, 'list', driveNotificationFields())));
      if (this.session !== session) { return false; }
      this.items = page.items.map((item: DriveNotification): DriveNotificationItem => this.copyItem(item, session.readIds.includes(item.id)));
      this.total = page.total; this.loaded = true; return true;
    } catch (error) {
      if (this.session !== session) { return false; }
      this.errorText = error instanceof NasFailure ? error.message : 'Drive 通知未能加载，请稍后刷新。';
      hilog.error(0x0000, 'NasDrive', 'operation=notifications kind=%{public}d', error instanceof NasFailure ? error.kind : -1);
      if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { await session.onSessionFailure(error); }
      return false;
    } finally { if (this.session === session) { this.busy = false; } }
  }
  markRead(id: string): void {
    const session = this.session;
    if (session === undefined || !this.items.some((item: DriveNotificationItem): boolean => item.id === id)) { return; }
    if (!session.readIds.includes(id)) { session.readIds.push(id); }
    this.items = this.items.map((item: DriveNotificationItem): DriveNotificationItem => this.copyItem(item, item.read || item.id === id));
  }
  markAllRead(): void { for (const item of this.items) { this.markRead(item.id); } }
  private copyItem(item: DriveNotification, read: boolean): DriveNotificationItem {
    return { id: item.id, type: item.type, time: item.time, title: item.title, name: item.name,
      senderName: item.senderName, known: item.known, read };
  }
}
