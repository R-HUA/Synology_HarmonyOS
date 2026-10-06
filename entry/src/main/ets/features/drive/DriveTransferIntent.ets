import { Want } from '@kit.AbilityKit';

let pending: boolean = false;

/** 冷启动时保留通知点击意图；页面出现后消费一次，不保存账号或任务凭证。 */
export function receiveDriveTransferIntent(want: Want): boolean {
  if (want.parameters?.driveTransfers !== true) { return false; }
  pending = true; return true;
}
export function takeDriveTransferIntent(): boolean {
  const value = pending; pending = false; return value;
}
