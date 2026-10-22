import { common, wantAgent } from '@kit.AbilityKit';
import { liveViewManager } from '@kit.LiveViewKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 全局传输共用一个实况窗；串行提交，避免任务结束与创建回执交错。 */
@ObservedV2
export class TransferLiveView {
  @Trace errorText: string = '';
  private count: number = 0;
  private active: boolean = false;
  private id: number = Date.now() % 2147483647;
  private pending: Promise<void> = Promise.resolve();

  /** 仅数量变化时更新系统展示，不把每个进度回调转为通知请求。 */
  update(context: common.UIAbilityContext, count: number): void {
    if (count === this.count) { return; }
    this.count = count;
    this.pending = this.pending.then(async (): Promise<void> => {
      if (count !== this.count || count === 0 && !this.active) { return; }
      if (!canIUse('SystemCapability.LiveView.LiveViewService')) { return; }
      if (!this.active && !await liveViewManager.isLiveViewEnabled()) {
        throw new Error(context.resourceManager.getStringSync($r('app.string.live_view_disabled').id));
      }
      const clickAction = await wantAgent.getWantAgent({ wants: [{ bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name, parameters: { allTransfers: true } }],
        operationType: wantAgent.OperationType.START_ABILITY, requestCode: 732,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG] });
      const title = context.resourceManager.getStringSync($r('app.string.global_transfer_count').id, count);
      const view: liveViewManager.LiveView = { id: this.id, event: 'PROGRESS', isMute: true,
        lifeCycleMode: liveViewManager.LifeCycleMode.AUTO_STOP_WHEN_APP_TERMINATE,
        liveViewData: { primary: { title, clickAction, keepTime: 0 },
          capsule: { type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT, status: count > 0 ? 1 : -1,
            title: context.resourceManager.getStringSync($r('app.string.task_all_tasks').id), content: count.toString() } } };
      const result = count === 0 ? await liveViewManager.stopLiveView(view) : this.active ?
        await liveViewManager.updateLiveView(view) : await liveViewManager.startLiveView(view);
      if (result.resultCode !== 0) { throw new Error(result.resultCode.toString() + ': ' + result.message.toString()); }
      this.active = count > 0; this.errorText = '';
      hilog.info(0x0000, 'NasLiveView', 'operation=transfer_live_view result=success count=%{public}d', count);
    }).catch((error: BusinessError): void => {
      this.errorText = context.resourceManager.getStringSync($r('app.string.live_view_failed').id);
      hilog.error(0x0000, 'NasLiveView', 'operation=transfer_live_view result=failed code=%{public}d message=%{public}s',
        error.code ?? 0, error.message);
    });
  }
}
