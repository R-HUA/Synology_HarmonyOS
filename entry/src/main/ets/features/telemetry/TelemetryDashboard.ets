import { TelemetryMonitor, NasTelemetryStatus } from './TelemetryMonitor';
import { NasTelemetryNetwork, NasTelemetryVolume, telemetryBytes, telemetryPercent,
  telemetryTimestamp } from '../../core/domain/TelemetryProtocol';

@ComponentV2
export struct NasTelemetrySummary {
  @Param monitor: TelemetryMonitor = new TelemetryMonitor();
  @Event onOpen: () => void = (): void => {};

  private cpuText(): string {
    const cpu = this.monitor.utilization.data?.cpuPercent;
    return cpu === undefined ? '未提供' : telemetryPercent(cpu);
  }

  private memoryText(): string {
    const usage = this.monitor.utilization.data?.memoryUsagePercent;
    return usage === undefined ? '未提供' : telemetryPercent(usage);
  }

  private memoryBytesText(): string {
    const memory = this.monitor.utilization.data;
    return (memory?.memoryUsedBytes === undefined ? '未提供' : telemetryBytes(memory.memoryUsedBytes)) + ' / ' +
      (memory?.memoryTotalBytes === undefined ? '未提供' : telemetryBytes(memory.memoryTotalBytes));
  }

  private networkText(): string {
    const network = this.monitor.utilization.data?.networks.find((item: NasTelemetryNetwork): boolean => item.id === 'total');
    return network === undefined ? '暂无合计速率，详情按网卡查看' : 'NAS 接收 ' + telemetryBytes(network.receiveBytesPerSecond) +
      '/s · 发送 ' + telemetryBytes(network.sendBytesPerSecond) + '/s';
  }

  build() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Text('运行状态').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary')).layoutWeight(1)
        Button('查看详情').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(this.onOpen)
      }.width('100%')
      if (this.monitor.utilization.data !== undefined) {
        Row({ space: 16 }) {
          Column({ space: 6 }) {
            Text('CPU 使用率').fontSize(14).fontColor($r('sys.color.font_secondary'))
            Text(this.cpuText()).fontSize(28).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Column({ space: 6 }) {
            Text('DSM 内存占用').fontSize(14).fontColor($r('sys.color.font_secondary'))
            Text(this.memoryText()).fontSize(28).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%')
        Text('物理内存已用 / 总量：' + this.memoryBytesText()).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        Text(this.networkText()).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      }
      ForEach(this.monitor.storage.data === undefined ? [] : this.monitor.storage.data.slice(0, 2), (volume: NasTelemetryVolume): void => {
        Text('卷 ' + volume.id + '：' + telemetryBytes(volume.usedBytes) + ' / ' + telemetryBytes(volume.totalBytes))
          .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      }, (volume: NasTelemetryVolume): string => volume.id)
      if (this.monitor.storage.data !== undefined && this.monitor.storage.observedAt > 0) {
        Text('容量采样 ' + telemetryTimestamp(this.monitor.storage.observedAt) + (this.monitor.storage.status === 'stale' ? ' · 数据已过期' : ''))
          .fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%')
      }
      Text(this.monitor.busy ? '正在更新监控数据' : this.monitor.utilization.status === 'ready' ?
        '上次采样 ' + telemetryTimestamp(this.monitor.utilization.observedAt) : this.monitor.utilization.notice)
        .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      if (this.monitor.utilization.status === 'stale' && this.monitor.utilization.observedAt > 0) {
        Text('上次采样 ' + telemetryTimestamp(this.monitor.utilization.observedAt) + '，数据已过期')
          .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
      }
    }.width('100%').padding(20).borderRadius(24).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('sys.color.comp_background_secondary'))
  }
}

@ComponentV2
export struct NasTelemetryDashboard {
  @Param monitor: TelemetryMonitor = new TelemetryMonitor();
  @Param scroller: Scroller = new Scroller();

  private metricBytes(bytes: number | undefined): string {
    return bytes === undefined ? '未提供' : telemetryBytes(bytes);
  }

  private metricPercent(percentage: number | undefined): string {
    return percentage === undefined ? '未提供' : telemetryPercent(percentage);
  }

  private networks(): NasTelemetryNetwork[] {
    const networks = this.monitor.utilization.data?.networks;
    if (networks === undefined) { return []; }
    const total = networks.find((network: NasTelemetryNetwork): boolean => network.id === 'total');
    return total === undefined ? networks : [total];
  }

  private volumeState(status: string | undefined): string {
    if (status === undefined) { return '状态未提供'; }
    if (status === 'normal') { return '正常'; }
    if (status === 'degraded') { return '降级'; }
    if (status === 'crashed') { return '故障'; }
    if (status === 'repairing' || status === 'rebuilding') { return '正在修复'; }
    if (status === 'readonly') { return '只读'; }
    return '当前状态暂未适配，请在 DSM 查看';
  }

  @Builder
  sectionNotice(status: NasTelemetryStatus, notice: string, observedAt: number, source: string) {
    if (status !== 'ready') {
      Text(notice).fontSize(14)
        .fontColor($r('sys.color.font_secondary')).width('100%')
    }
    if (observedAt > 0) {
      Text('上次采样 ' + telemetryTimestamp(observedAt) + (status === 'stale' ? ' · 数据已过期' : ''))
        .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
    }
    Text(source).fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%')
  }

  @Builder
  metricRow(label: string, displayedText: string) {
    Column({ space: 4 }) {
      Text(label).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      Text(displayedText).fontSize(22).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  systemCard() {
    Column({ space: 16 }) {
      Text('总览').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary'))
      if (this.monitor.system.data !== undefined) {
        this.metricRow('设备型号', this.monitor.system.data?.model === undefined ? '未提供' : this.monitor.system.data.model)
        this.metricRow('DSM 版本', this.monitor.system.data?.dsmVersion === undefined ? '未提供' : this.monitor.system.data.dsmVersion)
        if (this.monitor.system.data?.temperatureC !== undefined) {
          this.metricRow('系统温度', this.monitor.system.data.temperatureC.toString() + ' °C')
        }
      }
      this.sectionNotice(this.monitor.system.status, this.monitor.system.notice, this.monitor.system.observedAt,
        '来源：DSM 系统信息 · 只读')
    }.width('100%').padding(20).borderRadius(24).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('sys.color.comp_background_secondary'))
  }

  @Builder
  utilizationCard() {
    Column({ space: 16 }) {
      Text('CPU 与内存').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary'))
      if (this.monitor.utilization.data !== undefined) {
        this.metricRow('CPU 使用率', this.metricPercent(this.monitor.utilization.data?.cpuPercent))
        if (this.monitor.utilization.data?.cpuPercent !== undefined) {
          Progress({ value: this.monitor.utilization.data.cpuPercent, total: 100, type: ProgressType.Linear }).width('100%')
            .accessibilityText('CPU 使用率 ' + this.metricPercent(this.monitor.utilization.data.cpuPercent))
        }
        this.metricRow('DSM 内存占用', this.metricPercent(this.monitor.utilization.data?.memoryUsagePercent))
        this.metricRow('物理内存已用 / 总量', this.metricBytes(this.monitor.utilization.data?.memoryUsedBytes) + ' / ' +
          this.metricBytes(this.monitor.utilization.data?.memoryTotalBytes))
        Text('物理内存已用按总量减可用量计算，包含缓存；与 DSM 占用百分比的统计口径不同。')
          .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
      }
      this.sectionNotice(this.monitor.utilization.status, this.monitor.utilization.notice, this.monitor.utilization.observedAt,
        '来源：DSM 利用率 · 百分比与 IEC 容量单位')
    }.width('100%').padding(20).borderRadius(24).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('sys.color.comp_background_secondary'))
  }

  @Builder
  networkCard() {
    Column({ space: 16 }) {
      Text('网络').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary'))
      if (this.networks().length === 0 && this.monitor.utilization.data !== undefined) {
        Text('NAS 未提供网络速率').fontSize(14).fontColor($r('sys.color.font_secondary'))
      }
      ForEach(this.networks(), (network: NasTelemetryNetwork): void => {
        Column({ space: 12 }) {
          Text(network.id === 'total' ? '全部网络接口' : '网络接口 ' + network.id).fontSize(16)
            .fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
          this.metricRow('NAS 接收', telemetryBytes(network.receiveBytesPerSecond) + '/s')
          this.metricRow('NAS 发送', telemetryBytes(network.sendBytesPerSecond) + '/s')
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (network: NasTelemetryNetwork): string => network.id)
      this.sectionNotice(this.monitor.utilization.status, this.monitor.utilization.notice, this.monitor.utilization.observedAt,
        '来源：DSM 网络速率 · 服务端采样窗口未提供；不是手机传输速度')
    }.width('100%').padding(20).borderRadius(24).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('sys.color.comp_background_secondary'))
  }

  @Builder
  storageCard() {
    Column({ space: 16 }) {
      Text('存储卷').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary'))
      ForEach(this.monitor.storage.data === undefined ? [] : this.monitor.storage.data, (volume: NasTelemetryVolume): void => {
        Column({ space: 12 }) {
          Text('卷 ' + volume.id).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
          Text(this.volumeState(volume.status)).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
          this.metricRow('已用 / 总量', telemetryBytes(volume.usedBytes) + ' / ' + telemetryBytes(volume.totalBytes))
          if (volume.totalBytes > 0) {
            Progress({ value: volume.usedBytes / volume.totalBytes * 100, total: 100, type: ProgressType.Linear }).width('100%')
              .accessibilityText('卷已用 ' + telemetryPercent(volume.usedBytes / volume.totalBytes * 100))
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (volume: NasTelemetryVolume): string => volume.id)
      this.sectionNotice(this.monitor.storage.status, this.monitor.storage.notice, this.monitor.storage.observedAt,
        '来源：DSM 存储信息 · IEC 容量单位；不合并卷、存储池和物理磁盘')
    }.width('100%').padding(20).borderRadius(24).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('sys.color.comp_background_secondary'))
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 20 }) {
        Row({ space: 12 }) {
          Text(this.monitor.busy ? '正在读取 NAS 状态' : '只读监控').fontSize(15)
            .fontColor($r('sys.color.font_secondary')).layoutWeight(1)
          Button('刷新').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(!this.monitor.busy).onClick((): void => { this.monitor.refresh(true); })
        }.width('100%')
        this.systemCard()
        this.utilizationCard()
        this.networkCard()
        this.storageCard()
        Text('运行指标约每 5 秒更新，系统与容量约每分钟更新。离开监控页面或退后台后暂停采样；未提供的数据不以零代替。')
          .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
      }.width('100%').constraintSize({ maxWidth: 840 }).padding({ left: 16, right: 16, top: 16, bottom: 32 })
        .alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto)
  }
}
