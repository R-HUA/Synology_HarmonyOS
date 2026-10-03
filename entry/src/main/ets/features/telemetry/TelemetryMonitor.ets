import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { NasConnector } from '../../core/network/NasConnector';
import { decodeTelemetrySystem, decodeTelemetryUtilization, decodeTelemetryVolumes,
  NasTelemetrySystem, NasTelemetryUtilization, NasTelemetryVolume } from '../../core/domain/TelemetryProtocol';
import { hilog } from '@kit.PerformanceAnalysisKit';

export type NasTelemetryMode = 'hidden' | 'home' | 'detail';
export type NasTelemetryStatus = 'idle' | 'ready' | 'empty' | 'unavailable' | 'error' | 'stale';
export interface NasTelemetrySection<Payload> {
  data?: Payload;
  observedAt: number;
  status: NasTelemetryStatus;
  notice: string;
}

@ObservedV2
export class TelemetryMonitor {
  @Trace system: NasTelemetrySection<NasTelemetrySystem> = { observedAt: 0, status: 'idle', notice: '尚未读取系统信息' };
  @Trace utilization: NasTelemetrySection<NasTelemetryUtilization> = { observedAt: 0, status: 'idle', notice: '尚未读取运行状态' };
  @Trace storage: NasTelemetrySection<NasTelemetryVolume[]> = { observedAt: 0, status: 'idle', notice: '尚未读取存储空间' };
  @Trace busy: boolean = false;
  @Trace mode: NasTelemetryMode = 'hidden';
  private connector: NasConnector | undefined = undefined;
  private onSessionFailure: ((error: NasFailure) => Promise<void>) | undefined = undefined;
  private generation: number = 0;
  private timer: number = -1;
  private inFlight: boolean = false;
  private refreshPending: boolean = false;
  private manualPending: boolean = false;
  private staticReadAt: number = 0;

  attach(connector: NasConnector, onSessionFailure: (error: NasFailure) => Promise<void>): void {
    this.detach();
    this.connector = connector;
    this.onSessionFailure = onSessionFailure;
    this.refreshPending = this.mode !== 'hidden';
    if (!this.inFlight && this.refreshPending) { this.refresh(); }
  }

  detach(): void {
    this.generation++;
    this.clearTimer();
    this.connector = undefined;
    this.onSessionFailure = undefined;
    this.staticReadAt = 0;
    this.refreshPending = false;
    this.manualPending = false;
    this.busy = false;
    this.system = { observedAt: 0, status: 'idle', notice: '尚未读取系统信息' };
    this.utilization = { observedAt: 0, status: 'idle', notice: '尚未读取运行状态' };
    this.storage = { observedAt: 0, status: 'idle', notice: '尚未读取存储空间' };
  }

  setMode(mode: NasTelemetryMode): void {
    if (mode === this.mode) { return; }
    const wasHidden = this.mode === 'hidden';
    this.mode = mode;
    hilog.info(0x0000, 'NasTelemetry', 'operation=visibility mode=%{public}s', mode);
    this.clearTimer();
    if (mode === 'hidden') {
      this.generation++;
      this.refreshPending = false;
      this.manualPending = false;
      this.busy = false;
      this.system = this.markStale(this.system);
      this.utilization = this.markStale(this.utilization);
      this.storage = this.markStale(this.storage);
      return;
    }
    this.refreshPending = true;
    if (wasHidden) { this.staticReadAt = 0; }
    if (!this.inFlight) { this.refresh(); }
  }

  async refresh(manual: boolean = false): Promise<void> {
    if (manual) { this.staticReadAt = 0; }
    if (this.mode === 'hidden' || this.connector === undefined) { return; }
    if (this.inFlight) {
      this.refreshPending = this.refreshPending || manual;
      this.manualPending = this.manualPending || manual;
      return;
    }
    this.clearTimer();
    const connector = this.connector;
    const ticket = this.generation;
    this.inFlight = true;
    this.busy = true;
    this.refreshPending = false;
    const readStatic = this.staticReadAt === 0 || Date.now() - this.staticReadAt >= 60000;
    try {
      if (manual || this.utilization.status !== 'unavailable') {
        const section = await this.readSection('utilization', connector, ticket, this.utilization,
          async (): Promise<NasTelemetryUtilization> => decodeTelemetryUtilization(await connector.telemetryUtilization()),
          (data: NasTelemetryUtilization): boolean => data.cpuPercent !== undefined || data.memoryTotalBytes !== undefined ||
            data.memoryUsagePercent !== undefined || data.diskReadBytesPerSecond !== undefined ||
            data.diskWriteBytesPerSecond !== undefined || data.networks.length > 0);
        if (ticket !== this.generation) { return; }
        this.utilization = section;
      }
      if (readStatic) {
        if (manual || this.system.status !== 'unavailable') {
          const section = await this.readSection('system', connector, ticket, this.system,
            async (): Promise<NasTelemetrySystem> => decodeTelemetrySystem(await connector.telemetrySystem()),
            (data: NasTelemetrySystem): boolean => data.model !== undefined || data.dsmVersion !== undefined ||
              data.temperatureC !== undefined || data.uptime !== undefined);
          if (ticket !== this.generation) { return; }
          this.system = section;
        }
        if (manual || this.storage.status !== 'unavailable') {
          const section = await this.readSection('storage', connector, ticket, this.storage,
            async (): Promise<NasTelemetryVolume[] | undefined> => decodeTelemetryVolumes(await connector.telemetryStorage()),
            (data: NasTelemetryVolume[]): boolean => data.length > 0);
          if (ticket !== this.generation) { return; }
          this.storage = section.status === 'empty' && section.data !== undefined ?
            { data: section.data, observedAt: section.observedAt, status: 'empty', notice: 'NAS 未返回存储空间' } : section;
        }
        this.staticReadAt = Date.now();
      }
    } finally {
      this.inFlight = false;
      this.busy = false;
      if (this.refreshPending && this.connector !== undefined && this.isVisible()) {
        const manualRefresh = this.manualPending;
        this.manualPending = false;
        this.refresh(manualRefresh);
      }
      else { this.schedule(); }
    }
  }

  private async readSection<Payload>(source: string, connector: NasConnector, ticket: number, previous: NasTelemetrySection<Payload>,
    read: () => Promise<Payload | undefined>, hasData: (data: Payload) => boolean): Promise<NasTelemetrySection<Payload>> {
    try {
      const data = await read();
      if (ticket !== this.generation || connector !== this.connector) { return previous; }
      const populated = data !== undefined && hasData(data);
      return { data: data, observedAt: Date.now(), status: populated ? 'ready' : 'empty',
        notice: populated ? '已读取 NAS 数据' : 'NAS 未提供可显示的数据' };
    } catch (error) {
      if (ticket !== this.generation || connector !== this.connector) { return previous; }
      const failure = error instanceof NasFailure ? error : undefined;
      hilog.error(0x0000, 'NasTelemetry', 'operation=read source=%{public}s kind=%{public}d code=%{public}d',
        source, failure === undefined ? -1 : failure.kind, failure === undefined ? 0 : failure.code);
      if (failure?.kind === NasErrorKind.SessionExpired) {
        this.generation++;
        this.clearTimer();
        const callback = this.onSessionFailure;
        this.connector = undefined;
        if (callback !== undefined) { await callback(failure); }
        return { observedAt: 0, status: 'error', notice: '登录已失效，请重新登录' };
      }
      if (failure?.kind === NasErrorKind.Permission || failure?.kind === NasErrorKind.Unsupported) {
        return { observedAt: 0, status: 'unavailable', notice: failure.kind === NasErrorKind.Permission ?
          '当前账号无权读取此项监控数据，文件和相册功能仍可使用' : '此 NAS 不支持已适配的监控接口' };
      }
      return { data: previous.data, observedAt: previous.observedAt, status: previous.data === undefined ? 'error' : 'stale',
        notice: failure?.kind === NasErrorKind.Protocol ? 'NAS 监控数据格式不兼容，未显示本次数据' :
          '无法更新监控数据，请检查连接后重试' };
    }
  }

  private markStale<Payload>(section: NasTelemetrySection<Payload>): NasTelemetrySection<Payload> {
    return section.status === 'ready' ? { data: section.data, observedAt: section.observedAt, status: 'stale',
      notice: '采样已暂停，以下为上次读取的数据' } : section;
  }

  private schedule(): void {
    this.clearTimer();
    if (this.connector === undefined || this.mode === 'hidden' ||
      this.system.status === 'unavailable' && this.utilization.status === 'unavailable' && this.storage.status === 'unavailable') { return; }
    this.timer = setTimeout((): void => { this.timer = -1; this.refresh(); }, this.mode === 'detail' ? 5000 : 15000);
  }

  private clearTimer(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
  }

  private isVisible(): boolean {
    return this.mode !== 'hidden';
  }
}
