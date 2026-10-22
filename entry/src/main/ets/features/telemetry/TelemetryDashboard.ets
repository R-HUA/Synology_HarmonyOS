import { TelemetryMonitor, NasTelemetryStatus } from './TelemetryMonitor';
import { NasTelemetryNetwork, NasTelemetryVolume, telemetryBytes, telemetryPercent,
  telemetryVolumeLabel, telemetryVolumesSorted } from '../../core/domain/TelemetryProtocol';
import { workbenchUsageLevel } from '../workbench/WorkbenchPresentation';
import { WorkbenchMetrics, WorkbenchSectionTitle, WorkbenchInfoRow, WorkbenchMetric } from '../workbench/WorkbenchUi';

/** 三列小卡片宽度有限，缺失值用短占位符，避免把列宽撑破。 */
const TELEMETRY_PLACEHOLDER = '—';
/** 小卡片单行高度：固定下来才能让只有一行取值的卡片与两行的卡片底部对齐。 */
const TELEMETRY_TILE_ROW_HEIGHT = 18;

function volumeProgressColor(percentage: number): ResourceColor {
  const level = workbenchUsageLevel(percentage);
  if (level === 'danger') { return $r('app.color.workbench_danger'); }
  if (level === 'warning') { return $r('app.color.workbench_warning'); }
  return $r('sys.color.icon_emphasize');
}

/**
 * 小卡片取值行。这里必须是 @Param 子组件，不能用带值参数的 @Builder：
 * @Builder 按值传参时参数变化不会刷新内部 UI，速率/温度这类后到的数据会永远停在首次渲染的占位符上。
 */
@ComponentV2
struct TelemetrySmallTile {
  @Param title: string = '';
  @Param firstLabel: string = '';
  @Param firstValue: string = '';
  @Param secondLabel: string = '';
  @Param secondValue: string = '';

  build() {
    Column({ space: 8 }) {
      Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
      Column({ space: 4 }) {
        Text() {
          Span(this.firstLabel + ' ').fontSize(12).fontColor($r('sys.color.font_secondary'))
          Span(this.firstValue).fontSize(12).fontColor($r('sys.color.font_primary'))
        }.width('100%').height(TELEMETRY_TILE_ROW_HEIGHT).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text() {
          Span(this.secondLabel + ' ').fontSize(12).fontColor($r('sys.color.font_secondary'))
          Span(this.secondValue).fontSize(12).fontColor($r('sys.color.font_primary'))
        }.width('100%').height(TELEMETRY_TILE_ROW_HEIGHT).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')
    }.width('100%').padding(12).borderRadius(WorkbenchMetrics.innerRadius)
      .backgroundColor($r('app.color.workbench_subtle')).alignItems(HorizontalAlign.Start)
  }
}

/** 仅在分区数据不可用或读取失败时显示原因。 */
@ComponentV2
struct TelemetrySectionNotice {
  @Param status: NasTelemetryStatus = 'idle';
  @Param notice: string = '';

  build() {
    if (this.status !== 'ready') {
      Text(this.notice).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
    }
  }
}

@ComponentV2
export struct NasTelemetrySummary {
  @Param monitor: TelemetryMonitor = new TelemetryMonitor();
  @Event onOpen: () => void = (): void => {};

  private cpuText(): string {
    const cpu = this.monitor.utilization.data?.cpuPercent;
    return cpu === undefined ? TELEMETRY_PLACEHOLDER : telemetryPercent(cpu);
  }

  private memoryText(): string {
    const usage = this.monitor.utilization.data?.memoryUsagePercent;
    return usage === undefined ? TELEMETRY_PLACEHOLDER : telemetryPercent(usage);
  }

  private totalNetwork(): NasTelemetryNetwork | undefined {
    return this.monitor.utilization.data?.networks.find((item: NasTelemetryNetwork): boolean => item.id === 'total');
  }

  private rateText(bytes: number | undefined): string {
    return bytes === undefined ? TELEMETRY_PLACEHOLDER : telemetryBytes(bytes) + '/s';
  }

  private temperatureText(): string {
    const temperature = this.monitor.system.data?.temperatureC;
    return temperature === undefined ? TELEMETRY_PLACEHOLDER : temperature.toString() + ' °C';
  }

  build() {
    Button() {
      Column({ space: 12 }) {
        Text('资源监控').fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary')).width('100%')
        Row({ space: 12 }) {
          WorkbenchMetric({ label: 'CPU', value: this.cpuText(),
            percentage: this.monitor.utilization.data?.cpuPercent }).layoutWeight(1)
          WorkbenchMetric({ label: '内存', value: this.memoryText(),
            percentage: this.monitor.utilization.data?.memoryUsagePercent }).layoutWeight(1)
        }.width('100%').alignItems(VerticalAlign.Top)
        Row({ space: 8 }) {
          TelemetrySmallTile({ title: '网络', firstLabel: '↑',
            firstValue: this.rateText(this.totalNetwork()?.sendBytesPerSecond), secondLabel: '↓',
            secondValue: this.rateText(this.totalNetwork()?.receiveBytesPerSecond) }).layoutWeight(1)
          TelemetrySmallTile({ title: '硬盘', firstLabel: '读',
            firstValue: this.rateText(this.monitor.utilization.data?.diskReadBytesPerSecond), secondLabel: '写',
            secondValue: this.rateText(this.monitor.utilization.data?.diskWriteBytesPerSecond) }).layoutWeight(1)
          if (!this.monitor.system.permissionDenied) {
            TelemetrySmallTile({ title: '温度', firstLabel: '系统',
              firstValue: this.temperatureText(), secondLabel: '', secondValue: '' }).layoutWeight(1)
          }
        }.width('100%').alignItems(VerticalAlign.Top)
        if (this.monitor.utilization.data === undefined) {
          Text(this.monitor.utilization.notice).fontSize(14)
            .fontColor($r('sys.color.font_secondary')).width('100%')
        }
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
    }.type(ButtonType.Normal).width('100%').padding(0).borderRadius(WorkbenchMetrics.cardRadius)
      .backgroundColor($r('app.color.workbench_surface')).stateEffect(false).onClick(this.onOpen)
      .accessibilityText('资源监控，查看详情')
  }
}

@ComponentV2
export struct NasTelemetryStorageCard {
  @Param monitor: TelemetryMonitor = new TelemetryMonitor();
  @Event onOpen: () => void = (): void => {};

  private volumes(): NasTelemetryVolume[] {
    const data = this.monitor.storage.data;
    return data === undefined ? [] : telemetryVolumesSorted(data);
  }

  build() {
    Button() {
      Column({ space: 12 }) {
        Text('存储空间').fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary')).width('100%')
        ForEach(this.volumes(), (volume: NasTelemetryVolume): void => {
          Column({ space: 6 }) {
            WorkbenchInfoRow({ label: telemetryVolumeLabel(volume.id), copyable: false,
              value: telemetryBytes(volume.usedBytes) + ' / ' + telemetryBytes(volume.totalBytes) })
            if (volume.totalBytes > 0) {
              Progress({ value: volume.usedBytes / volume.totalBytes * 100, total: 100, type: ProgressType.Linear })
                .width('100%').height(4)
                .color(volumeProgressColor(volume.usedBytes / volume.totalBytes * 100))
                .backgroundColor($r('app.color.workbench_divider'))
                .accessibilityText(telemetryVolumeLabel(volume.id) + ' 已用 ' +
                  telemetryPercent(volume.usedBytes / volume.totalBytes * 100))
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }, (volume: NasTelemetryVolume): string => volume.id)
        if (this.volumes().length === 0) {
          Text(this.monitor.storage.notice).fontSize(14)
            .fontColor($r('sys.color.font_secondary')).width('100%')
        }
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
    }.type(ButtonType.Normal).width('100%').padding(0).borderRadius(WorkbenchMetrics.cardRadius)
      .backgroundColor($r('app.color.workbench_surface')).stateEffect(false).onClick(this.onOpen)
      .accessibilityText('存储空间，查看详情')
  }
}

@ComponentV2
export struct NasTelemetryDashboard {
  @Param monitor: TelemetryMonitor = new TelemetryMonitor();
  @Param scroller: Scroller = new Scroller();
  @Param topInset: number = 0;
  @Local private viewportTop: number = 0;
  /** 底部系统安全区高度（导航条）。列表末项必须让开它，否则会被屏幕圆角裁切。 */
  @Param bottomInset: number = 0;

  private metricPercent(percentage: number | undefined): string {
    return percentage === undefined ? '未提供' : telemetryPercent(percentage);
  }

  private metricRate(bytes: number | undefined): string {
    return bytes === undefined ? '未提供' : telemetryBytes(bytes) + '/s';
  }

  private networks(): NasTelemetryNetwork[] {
    const networks = this.monitor.utilization.data?.networks;
    if (networks === undefined) { return []; }
    const total = networks.find((network: NasTelemetryNetwork): boolean => network.id === 'total');
    return total === undefined ? networks : [total];
  }

  private volumes(): NasTelemetryVolume[] {
    const data = this.monitor.storage.data;
    return data === undefined ? [] : telemetryVolumesSorted(data);
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
  systemCard() {
    Column({ space: 6 }) {
      WorkbenchSectionTitle({ title: '总览' })
      if (this.monitor.system.data !== undefined) {
        WorkbenchInfoRow({ label: '设备型号', minHeight: 32,
          value: this.monitor.system.data?.model === undefined ? '未提供' : this.monitor.system.data.model })
        WorkbenchInfoRow({ label: 'DSM 版本', minHeight: 32,
          value: this.monitor.system.data?.dsmVersion === undefined ? '未提供' : this.monitor.system.data.dsmVersion })
        if (this.monitor.system.data?.temperatureC !== undefined) {
          WorkbenchInfoRow({ label: '系统温度', minHeight: 32,
            value: this.monitor.system.data.temperatureC.toString() + ' °C' })
        }
      }
      TelemetrySectionNotice({ status: this.monitor.system.status, notice: this.monitor.system.notice })
    }.width('100%').padding(12).borderRadius(WorkbenchMetrics.cardRadius).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.workbench_surface'))
  }

  @Builder
  utilizationCard() {
    Column({ space: 8 }) {
      WorkbenchSectionTitle({ title: 'CPU 与内存' })
      if (this.monitor.utilization.data !== undefined) {
        Row({ space: 12 }) {
          WorkbenchMetric({ label: 'CPU', value: this.metricPercent(this.monitor.utilization.data?.cpuPercent),
            percentage: this.monitor.utilization.data?.cpuPercent }).layoutWeight(1)
          WorkbenchMetric({ label: '内存', value: this.metricPercent(this.monitor.utilization.data?.memoryUsagePercent),
            percentage: this.monitor.utilization.data?.memoryUsagePercent }).layoutWeight(1)
        }.width('100%').alignItems(VerticalAlign.Top)
      }
      TelemetrySectionNotice({ status: this.monitor.utilization.status, notice: this.monitor.utilization.notice })
    }.width('100%').padding(12).borderRadius(WorkbenchMetrics.cardRadius).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.workbench_surface'))
  }

  @Builder
  networkCard() {
    Column({ space: 6 }) {
      WorkbenchSectionTitle({ title: '网络' })
      if (this.networks().length === 0 && this.monitor.utilization.data !== undefined) {
        Text('NAS 未提供网络速率').fontSize(14).fontColor($r('sys.color.font_secondary'))
      }
      ForEach(this.networks(), (network: NasTelemetryNetwork): void => {
        Column({ space: 4 }) {
          if (network.id !== 'total') {
            Text('网络接口 ' + network.id).fontSize(14)
              .fontColor($r('sys.color.font_secondary')).width('100%')
          }
          WorkbenchInfoRow({ label: '接收', minHeight: 32, value: telemetryBytes(network.receiveBytesPerSecond) + '/s' })
          WorkbenchInfoRow({ label: '发送', minHeight: 32, value: telemetryBytes(network.sendBytesPerSecond) + '/s' })
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (network: NasTelemetryNetwork): string => network.id)
      TelemetrySectionNotice({ status: this.monitor.utilization.status, notice: this.monitor.utilization.notice })
    }.width('100%').padding(12).borderRadius(WorkbenchMetrics.cardRadius).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.workbench_surface'))
  }

  @Builder
  diskCard() {
    Column({ space: 6 }) {
      WorkbenchSectionTitle({ title: '硬盘' })
      if (this.monitor.utilization.data !== undefined) {
        WorkbenchInfoRow({ label: '读取', minHeight: 32, value: this.metricRate(this.monitor.utilization.data?.diskReadBytesPerSecond) })
        WorkbenchInfoRow({ label: '写入', minHeight: 32, value: this.metricRate(this.monitor.utilization.data?.diskWriteBytesPerSecond) })
      }
      TelemetrySectionNotice({ status: this.monitor.utilization.status, notice: this.monitor.utilization.notice })
    }.width('100%').padding(12).borderRadius(WorkbenchMetrics.cardRadius).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.workbench_surface'))
  }

  @Builder
  storageCard() {
    Column({ space: 12 }) {
      WorkbenchSectionTitle({ title: '存储空间' }).margin({ bottom: 4 })
      ForEach(this.volumes(), (volume: NasTelemetryVolume): void => {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text(telemetryVolumeLabel(volume.id)).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary')).flexShrink(0)
            Text(this.volumeState(volume.status)).fontSize(12).fontColor($r('sys.color.font_secondary'))
              .flexShrink(1)
          }.width('100%').alignItems(VerticalAlign.Center)
          Row({ space: 8 }) {
            Text(telemetryBytes(volume.usedBytes) + ' / ' + telemetryBytes(volume.totalBytes))
              .fontSize(12).fontColor($r('sys.color.font_secondary')).layoutWeight(1)
            if (volume.totalBytes > 0) {
              Text(telemetryPercent(volume.usedBytes / volume.totalBytes * 100))
                .fontSize(12).fontColor($r('sys.color.font_tertiary')).flexShrink(0)
            }
          }.width('100%').alignItems(VerticalAlign.Center)
          if (volume.totalBytes > 0) {
            Progress({ value: volume.usedBytes / volume.totalBytes * 100, total: 100, type: ProgressType.Linear })
              .width('100%').height(4)
              .color(volumeProgressColor(volume.usedBytes / volume.totalBytes * 100))
              .backgroundColor($r('app.color.workbench_divider'))
              .accessibilityText(telemetryVolumeLabel(volume.id) + ' 已用 ' +
                telemetryPercent(volume.usedBytes / volume.totalBytes * 100))
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (volume: NasTelemetryVolume): string => volume.id)
      TelemetrySectionNotice({ status: this.monitor.storage.status, notice: this.monitor.storage.notice })
    }.width('100%').padding(12).borderRadius(WorkbenchMetrics.cardRadius).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.workbench_surface'))
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 8 }) {
        if (!this.monitor.system.permissionDenied) { this.systemCard() }
        if (!this.monitor.utilization.permissionDenied) {
          this.utilizationCard()
          this.networkCard()
          this.diskCard()
        }
        if (!this.monitor.storage.permissionDenied) { this.storageCard() }
      }.width('100%').constraintSize({ maxWidth: 840 })
        // 滚动区本身已延伸到屏幕下沿（见下方 ignoreLayoutSafeArea），末行仍需按底部安全区让位，
        // 否则会贴到屏幕圆角弧线上被裁切；+16 与项目「无悬浮页签页面」的底部让位口径一致。
        // 只补视口尚未让出的标题区域，避免父容器已避让的部分被重复计算。
        .padding({ left: 16, right: 16, top: Math.max(0, this.topInset - this.viewportTop) + 8,
          bottom: this.bottomInset + 16 })
        .alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto)
      .onAreaChange((_oldArea: Area, newArea: Area): void => {
        this.viewportTop = Number(newArea.globalPosition.y);
      })
      // 滚动区默认被底部系统安全区（导航条）抬高，底边会留一条内容到不了的灰带；
      // 详情页要沉浸到屏幕下沿，这里显式让滚动区延伸到非安全区域。
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
      .backgroundColor($r('app.color.workbench_background'))
  }
}
