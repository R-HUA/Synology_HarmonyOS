import { vibrator } from '@kit.SensorServiceKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 手势确认只触发一次短反馈，设备不具备振动能力时保持原交互。 */
export function interactionFeedback(): void {
  if (!canIUse('SystemCapability.Sensors.MiscDevice')) { return; }
  vibrator.startVibration({ type: 'time', duration: 15 }, { usage: 'touch' })
    .catch((error: Error): void => { hilog.warn(0, 'NasInteraction', 'operation=haptic result=failed message=%{public}s', error.message); });
}
