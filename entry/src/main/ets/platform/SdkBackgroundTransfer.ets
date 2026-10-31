import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { NasErrorKind, NasFailure } from '../core/domain/DsmProtocol';
import { SdkTransferNetwork } from './SdkTransferNetwork';

/** 进程内 RCP 的长时任务租约；不是系统代理，进程终止后不能继续执行。 */
export class SdkBackgroundTransfer {
  private network: SdkTransferNetwork = new SdkTransferNetwork();
  private context: common.UIAbilityContext | undefined = undefined;
  private notification: backgroundTaskManager.ContinuousTaskNotification | undefined = undefined;
  private cancelListener: ((info: backgroundTaskManager.ContinuousTaskCancelInfo) => void) | undefined = undefined;
  private timer: number = -1;
  private stopping: boolean = false;
  private lastBytes: number = 0;
  private lastProgressAt: number = 0;
  private lastPublishAt: number = 0;
  private title: string = '';
  private interrupted: () => void = (): void => {};
  private failure: NasFailure | undefined = undefined;
  private publishing: Promise<void> = Promise.resolve();

  static available(): boolean {
    return SdkTransferNetwork.available() && canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask') &&
      canIUse('SystemCapability.Notification.Notification');
  }
  get active(): boolean { return this.notification !== undefined && this.failure === undefined; }

  async start(context: common.UIAbilityContext, title: string, interrupted: () => void): Promise<void> {
    if (!SdkBackgroundTransfer.available() || this.context !== undefined) {
      throw new NasFailure(NasErrorKind.Unsupported, '当前无法申请应用后台传输，请停止原任务或明确选择前台传输。');
    }
    this.stopping = false;
    this.context = context; this.title = title; this.interrupted = interrupted;
    this.failure = undefined; this.lastBytes = 0; this.lastProgressAt = Date.now(); this.lastPublishAt = 0;
    try {
      await this.network.start((): void => this.interrupt('网络已变化，应用后台传输已停止；请使用非计费 Wi-Fi 后继续。'));
      const agent: WantAgent = await wantAgent.getWantAgent({ wants: [{ bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name, parameters: { driveTransfers: true } }],
        operationType: wantAgent.OperationType.START_ABILITY, requestCode: 731,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG] });
      this.network.check();
      this.cancelListener = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
        if (!this.stopping && this.notification?.continuousTaskId === info.id) {
          this.notification = undefined;
          this.interrupt('应用后台任务已被用户或系统取消，请核对传输结果后继续。');
        }
      };
      backgroundTaskManager.on('continuousTaskCancel', this.cancelListener);
      this.notification = await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent);
      this.check();
      await this.publish(0);
      this.timer = setInterval((): void => {
        try {
          this.check();
          if (Date.now() - this.lastProgressAt > 180000) { this.interrupt('传输已超过三分钟没有进展，请检查网络后继续。'); }
        } catch (_) { this.interrupt('网络已变化，应用后台传输已停止；请检查后继续。'); }
      }, 1000);
    } catch (error) {
      try { await this.stop(); } catch (_) {}
      throw error instanceof NasFailure ? error : new NasFailure(NasErrorKind.Unsupported,
        '无法申请后台任务或更新实况窗，请检查系统设置，或明确选择前台传输。');
    }
  }

  check(): void {
    if (this.failure !== undefined) { throw this.failure as Error; }
    this.network.check();
    if (this.notification === undefined) { throw new NasFailure(NasErrorKind.Cancelled, '后台传输资格已失效。'); }
  }

  progress(processed: number, total?: number): void {
    this.check();
    if (!Number.isFinite(processed) || processed < 0) { return; }
    if (processed > this.lastBytes) { this.lastBytes = processed; this.lastProgressAt = Date.now(); }
    const now = Date.now();
    if (now - this.lastPublishAt < 1000) { return; }
    this.lastPublishAt = now;
    const value = total !== undefined && total > 0 ? Math.min(99, Math.floor(processed / total * 100)) : 0;
    this.publishing = this.publishing.then((): Promise<void> => this.publish(value))
      .catch((): void => this.interrupt('实况窗进度更新失败，后台传输已停止，请检查系统设置。'));
  }

  async stop(): Promise<void> {
    this.stopping = true;
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
    await this.publishing;
    const notification = this.notification;
    const context = this.context;
    if (notification !== undefined && context !== undefined) {
      if (notification.continuousTaskId !== undefined) {
        await backgroundTaskManager.stopBackgroundRunning(context, notification.continuousTaskId);
      } else { await backgroundTaskManager.stopBackgroundRunning(context); }
      this.notification = undefined;
    }
    if (this.cancelListener !== undefined) {
      backgroundTaskManager.off('continuousTaskCancel', this.cancelListener); this.cancelListener = undefined;
    }
    await this.network.stop();
    this.context = undefined;
  }

  private interrupt(message: string): void {
    if (this.failure !== undefined) { return; }
    this.failure = new NasFailure(NasErrorKind.Cancelled, message); this.interrupted();
  }
  private async publish(value: number): Promise<void> {
    const notification = this.notification;
    if (notification === undefined) { return; }
    await notificationManager.publish({ id: notification.notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: { typeCode: 8, title: this.title, text: '非计费 Wi-Fi，进程终止后传输会中断' } },
      template: { name: 'downloadTemplate', data: { title: this.title, fileName: 'Drive 文件传输', progressValue: value } } });
  }
}
