import { connection } from '@kit.NetworkKit';
import { NasErrorKind, NasFailure } from '../core/domain/DsmProtocol';

function networkFailure(): NasFailure {
  return new NasFailure(NasErrorKind.Cancelled, '应用后台传输仅使用非计费 Wi-Fi；网络已变化或无法确认，请返回前台检查后继续。');
}

/** 监听默认路由，不修改应用全局网络；状态未知时关闭，不以网络名称推断是否计费。 */
export class SdkTransferNetwork {
  private observer: connection.NetConnection | undefined = undefined;
  private netId: number = 0;
  private stopped: boolean = true;

  static available(): boolean { return canIUse('SystemCapability.Communication.NetManager.Core'); }

  async start(onLost: () => void): Promise<void> {
    if (this.observer !== undefined) { throw networkFailure(); }
    if (!SdkTransferNetwork.available()) { throw networkFailure(); }
    const observer = connection.createNetConnection();
    this.observer = observer; this.stopped = false;
    const check = (): void => {
      if (this.stopped) { return; }
      try { this.check(); } catch (_) { this.stopped = true; onLost(); }
    };
    try {
      await new Promise<void>((resolve, reject): void => {
        observer.register((error): void => { if (error) { reject(error); } else { resolve(); } });
      });
      observer.on('netAvailable', check);
      observer.on('netCapabilitiesChange', check);
      observer.on('netLost', (): void => { if (!this.stopped) { this.stopped = true; onLost(); } });
      observer.on('netUnavailable', (): void => { if (!this.stopped) { this.stopped = true; onLost(); } });
      this.check();
    } catch (error) { await this.stop(); throw error as Error; }
  }

  check(): void {
    if (this.stopped) { throw networkFailure(); }
    try {
      const net = connection.getDefaultNetSync();
      const caps = connection.getNetCapabilitiesSync(net);
      if (net.netId <= 0 || this.netId > 0 && net.netId !== this.netId ||
        !caps.bearerTypes.includes(connection.NetBearType.BEARER_WIFI) ||
        caps.bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR) ||
        caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN) ||
        caps.networkCap === undefined || !caps.networkCap.includes(connection.NetCap.NET_CAPABILITY_NOT_METERED) || connection.isDefaultNetMeteredSync()) {
        throw networkFailure();
      }
      this.netId = net.netId;
    } catch (_) { throw networkFailure(); }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    const observer = this.observer;
    if (observer === undefined) { return; }
    await new Promise<void>((resolve, reject): void => {
      observer.unregister((error): void => { if (error) { reject(error); } else { resolve(); } });
    });
    this.observer = undefined; this.netId = 0;
  }
}
