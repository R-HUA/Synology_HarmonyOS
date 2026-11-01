import { ContainerModel } from './ContainerModel';
import { ContainerItem, ContainerState, filterContainers } from './ContainerProtocol';
import { SegmentButtonV2Items, TabSegmentButtonV2 } from '@ohos.arkui.advanced.SegmentButtonV2';
import { WorkbenchEmptyState, WorkbenchInfoRow, WorkbenchMetrics, WorkbenchServiceError, WorkbenchSkeleton } from '../workbench/WorkbenchUi';
import { workbenchBytes } from '../workbench/WorkbenchPresentation';
import { telemetryTimestamp } from '../../core/domain/TelemetryProtocol';

function stateLabel(state: ContainerState): string {
  switch (state) {
    case 'running': return '运行中';
    case 'stopped': return '已停止';
    case 'paused': return '已暂停';
    case 'restarting': return '重新启动中';
    default: return '未知状态';
  }
}

@ComponentV2
export struct ContainerPage {
  @Require @Param model: ContainerModel = new ContainerModel();
  @Param scroller: Scroller = new Scroller();
  @Param bottomInset: number = 16;
  @Event onManagement: () => void = (): void => {};
  private filterItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: $r('app.string.containers_all') }, { text: $r('app.string.containers_running') }, { text: $r('app.string.containers_stopped') }
  ]);

  @Builder
  filters() {
    Search({ value: this.model.query, placeholder: $r('app.string.containers_search') }).defaultFocus(false)
      .onChange((value: string): void => { this.model.query = value; })
    TabSegmentButtonV2({ items: this.filterItems, selectedIndex: this.model.filter === 'running' ? 1 : this.model.filter === 'stopped' ? 2 : 0,
      $selectedIndex: (index: number): void => { this.model.filter = index === 1 ? 'running' : index === 2 ? 'stopped' : 'all'; } }).width('100%')
  }

  @Builder
  list() {
    this.filters()
    if (this.model.loading && this.model.items.length === 0) { WorkbenchSkeleton() }
    else if (this.model.errorText.length > 0) {
      WorkbenchServiceError({ message: this.model.errorText, title: $r('app.string.containers_unavailable'),
        retainedContent: this.model.items.length > 0,
        available: !this.model.loading, onRetry: (): void => { this.model.refresh(); }, onManagement: this.onManagement })
    } else if (this.model.loaded && this.model.items.length === 0) {
      WorkbenchEmptyState({ title: $r('app.string.containers_empty'), secondaryLabel: $r('app.string.package_open_management'), onSecondaryAction: this.onManagement })
    }
    if (this.model.loaded && this.model.items.length > 0 && filterContainers(this.model.items, this.model.query, this.model.filter).length === 0) {
      WorkbenchEmptyState({ title: $r('app.string.containers_no_matches') })
    }
    ForEach(filterContainers(this.model.items, this.model.query, this.model.filter), (item: ContainerItem): void => {
      Button() {
        Column({ space: 6 }) {
          WorkbenchInfoRow({ label: item.name, value: stateLabel(item.state), copyable: false })
          Text(item.image || '未提供镜像').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        }.padding(16).width('100%')
      }.type(ButtonType.Normal).buttonStyle(ButtonStyleMode.NORMAL).fontColor($r('sys.color.font_primary'))
        .width('100%').borderRadius(WorkbenchMetrics.cardRadius)
        .backgroundColor($r('app.color.workbench_surface')).onClick((): void => { this.model.select(item); })
    }, (item: ContainerItem): string => item.id)
  }

  @Builder
  detail() {
    Row({ space: 12 }) {
      Button('返回列表').buttonStyle(ButtonStyleMode.NORMAL).onClick((): void => { this.model.back(); })
      Blank()
      Button('刷新详情').enabled(!this.model.detailLoading).onClick((): void => { this.model.refreshDetail(); })
    }.width('100%')
    Text(this.model.selected!.name).fontSize(24).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
    if (this.model.detailLoading) { LoadingProgress().width(32).height(32) }
    if (this.model.detailError.length > 0) { WorkbenchServiceError({ message: this.model.detailError,
      title: $r('app.string.containers_unavailable'), available: !this.model.detailLoading,
      onRetry: (): void => { this.model.refreshDetail(); }, onManagement: this.onManagement }) }
    if (this.model.detail !== undefined) {
      Column() {
        WorkbenchInfoRow({ label: '状态', value: stateLabel(this.model.detail.item.state) })
        WorkbenchInfoRow({ label: '镜像', value: this.model.detail.item.image || '未提供' })
        WorkbenchInfoRow({ label: '创建时间', value: this.model.detail.created || '未提供' })
        WorkbenchInfoRow({ label: '启动时间', value: this.model.detail.started || '未提供' })
      }.width('100%').padding(16).borderRadius(16).backgroundColor($r('app.color.workbench_surface'))
      Text('资源').fontSize(18).fontWeight(FontWeight.Medium)
      Column() {
        WorkbenchInfoRow({ label: '处理器', value: this.model.resource?.cpu === undefined ? '未提供' : this.model.resource.cpu.toFixed(2) + '%' })
        WorkbenchInfoRow({ label: '内存', value: this.model.resource?.memory === undefined ? '未提供' : workbenchBytes(this.model.resource.memory) })
        if (this.model.resource !== undefined) {
          WorkbenchInfoRow({ label: '采样时间', value: telemetryTimestamp(this.model.resource.sampledAt) })
        }
      }.width('100%').padding(16).borderRadius(16).backgroundColor($r('app.color.workbench_surface'))
      if (this.model.resourceError.length > 0) { WorkbenchServiceError({ message: this.model.resourceError,
        title: $r('app.string.containers_unavailable'), onRetry: (): void => { this.model.refreshDetail(); }, onManagement: this.onManagement }) }
      Text('挂载').fontSize(18).fontWeight(FontWeight.Medium)
      Text(this.model.detail.mounts.length === 0 ? '未提供' : this.model.detail.mounts.join('\n')).width('100%').copyOption(CopyOptions.InApp)
      Text('端口').fontSize(18).fontWeight(FontWeight.Medium)
      Text(this.model.detail.ports.length === 0 ? '未提供' : this.model.detail.ports.join('\n')).width('100%').copyOption(CopyOptions.InApp)
    }
    Text('日志').fontSize(18).fontWeight(FontWeight.Medium)
    Row({ space: 12 }) {
      Button('读取日志').enabled(!this.model.logsLoading).onClick((): void => { this.model.refreshLogs(); })
      Button(this.model.following ? '停止跟随' : '每 5 秒跟随').buttonStyle(ButtonStyleMode.NORMAL)
        .onClick((): void => { if (this.model.following) { this.model.stopFollowing(); } else { this.model.startFollowing(); } })
    }
    if (this.model.logsLoading) { LoadingProgress().width(24).height(24) }
    if (this.model.logsCheckedAt > 0) { Text(telemetryTimestamp(this.model.logsCheckedAt)).fontSize(14).fontColor($r('sys.color.font_secondary')) }
    if (this.model.logsError.length > 0) { WorkbenchServiceError({ message: this.model.logsError,
      title: $r('app.string.containers_unavailable'), onRetry: (): void => { this.model.refreshLogs(); }, onManagement: this.onManagement }) }
    if (this.model.logsTruncated) { Text('仅显示最新 500 行或 512 KiB，超出部分已截断。').fontSize(14).fontColor($r('sys.color.font_secondary')) }
    if (this.model.logsLoaded) {
      Text(this.model.logs.length > 0 ? this.model.logs : '暂无日志').fontFamily('monospace').fontSize(14)
        .copyOption(CopyOptions.InApp).width('100%')
    }
  }

  build() {
    Row() {
      Refresh({ refreshing: this.model.loading || this.model.detailLoading }) {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          if (this.model.selected === undefined) { this.list() } else { this.detail() }
          if (this.model.items.length > 0 || this.model.selected !== undefined) {
            Button($r('app.string.package_open_management')).buttonStyle(ButtonStyleMode.NORMAL).onClick(this.onManagement)
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, left: 16, right: 16, bottom: this.bottomInset })
      }.width('100%').height('100%').constraintSize({ maxWidth: 960 }).align(Alignment.Top)
        .onScrollStart((): void => { this.model.stopFollowing(); })
      }.width('100%').height('100%').onRefreshing((): void => {
        if (this.model.selected === undefined) { this.model.refresh(); } else { this.model.refreshDetail(); }
      })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
