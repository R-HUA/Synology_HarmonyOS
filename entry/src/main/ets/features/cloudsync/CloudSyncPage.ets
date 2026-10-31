import { CloudSyncModel } from './CloudSyncModel';
import { CloudConnection, CloudFolder, CloudHistory } from './CloudSyncProtocol';
import { WorkbenchEmptyState, WorkbenchInfoRow, WorkbenchServiceError, WorkbenchSkeleton } from '../workbench/WorkbenchUi';
import { workbenchBytes } from '../workbench/WorkbenchPresentation';
import { telemetryTimestamp } from '../../core/domain/TelemetryProtocol';

@ComponentV2
export struct CloudSyncPage {
  @Require @Param model: CloudSyncModel = new CloudSyncModel();
  @Param scroller: Scroller = new Scroller();
  @Param bottomInset: number = 16;
  @Event onManagement: () => void = (): void => {};
  @Builder
  list() {
    if (this.model.loading && this.model.items.length === 0) { WorkbenchSkeleton() }
    else if (this.model.errorText.length > 0) {
      WorkbenchServiceError({ message: this.model.errorText, title: $r('app.string.cloud_sync_unavailable'), available: !this.model.loading, retainedContent: this.model.items.length > 0,
        onRetry: (): void => { this.model.refresh(); }, onManagement: this.onManagement })
    } else if (this.model.loaded && this.model.items.length === 0) {
      WorkbenchEmptyState({ title: $r('app.string.cloud_sync_empty'), secondaryLabel: $r('app.string.package_open_management'), onSecondaryAction: this.onManagement })
    }
    ForEach(this.model.items, (item: CloudConnection): void => {
      Button() {
        Column() {
          WorkbenchInfoRow({ label: item.name, value: item.status })
          WorkbenchInfoRow({ label: item.provider, value: item.account })
        }.padding(16).width('100%')
      }.type(ButtonType.Normal).width('100%').backgroundColor($r('app.color.workbench_surface')).borderRadius(16)
        .onClick((): void => { this.model.select(item); })
    }, (item: CloudConnection): string => item.id)
  }
  @Builder
  detail() {
    Row({ space: 12 }) {
      Button('返回列表').buttonStyle(ButtonStyleMode.NORMAL).onClick((): void => { this.model.back(); })
      Button('刷新详情').enabled(!this.model.detailLoading).onClick((): void => { this.model.refreshDetail(); })
    }
    Text(this.model.selected!.name).fontSize(24).fontWeight(FontWeight.Medium)
    WorkbenchInfoRow({ label: '服务商', value: this.model.selected!.provider })
    WorkbenchInfoRow({ label: '账号', value: this.model.selected!.account })
    WorkbenchInfoRow({ label: '状态', value: this.model.selected!.status })
    WorkbenchInfoRow({ label: '总容量', value: this.model.quota?.total === undefined ? '未提供' : workbenchBytes(this.model.quota.total) })
    WorkbenchInfoRow({ label: '已用容量', value: this.model.quota?.used === undefined ? '未提供' : workbenchBytes(this.model.quota.used) })
    WorkbenchInfoRow({ label: '当前速率', value: '未提供' })
    if (this.model.quotaError.length > 0) { WorkbenchServiceError({ message: this.model.quotaError,
      title: $r('app.string.cloud_sync_unavailable'), onRetry: (): void => { this.model.refreshDetail(); }, onManagement: this.onManagement }) }
    Text('同步目录').fontSize(18).fontWeight(FontWeight.Medium)
    if (this.model.detailLoading) { LoadingProgress().width(24).height(24) }
    if (this.model.detailError.length > 0) { WorkbenchServiceError({ message: this.model.detailError,
      title: $r('app.string.cloud_sync_unavailable'), onRetry: (): void => { this.model.refreshDetail(); }, onManagement: this.onManagement }) }
    if (this.model.detailLoaded && this.model.folders.length === 0) { Text('暂无同步目录') }
    ForEach(this.model.folders, (folder: CloudFolder): void => {
      Column() {
        WorkbenchInfoRow({ label: '同步方向', value: folder.direction })
        WorkbenchInfoRow({ label: '本地路径', value: folder.local || '未提供' })
        WorkbenchInfoRow({ label: '远端路径', value: folder.remote || '未提供' })
        WorkbenchInfoRow({ label: '状态', value: folder.status })
        if (folder.error.length > 0) { WorkbenchServiceError({ message: folder.error,
          title: $r('app.string.cloud_sync_unavailable'), onRetry: (): void => { this.model.refreshDetail(); }, onManagement: this.onManagement }) }
      }.padding(16).width('100%').backgroundColor($r('app.color.workbench_surface')).borderRadius(16)
    }, (folder: CloudFolder): string => JSON.stringify(folder))
    Text('同步历史').fontSize(18).fontWeight(FontWeight.Medium)
    Button('刷新历史').enabled(!this.model.historyLoading).onClick((): void => { this.model.readHistory(); })
    if (this.model.historyLoading) { LoadingProgress().width(24).height(24) }
    if (this.model.historyAt > 0) { Text(telemetryTimestamp(this.model.historyAt)).fontSize(14) }
    if (this.model.historyError.length > 0) { WorkbenchServiceError({ message: this.model.historyError,
      title: $r('app.string.cloud_sync_unavailable'), onRetry: (): void => { this.model.readHistory(); }, onManagement: this.onManagement }) }
    if (this.model.historyLoaded && this.model.history.length === 0) { Text('暂无历史记录') }
    ForEach(this.model.history, (item: CloudHistory): void => {
      Column({ space: 6 }) {
        Text(item.action).fontWeight(FontWeight.Medium)
        Text(item.level).fontSize(14).fontColor($r('sys.color.font_secondary'))
        Text(item.file || item.path || '未提供文件名').copyOption(CopyOptions.InApp)
        Text(item.time === undefined ? '未提供时间' : telemetryTimestamp(item.time * 1000)).fontSize(14)
        if (item.error.length > 0) { WorkbenchServiceError({ message: item.error,
          title: $r('app.string.cloud_sync_unavailable'), onRetry: (): void => { this.model.readHistory(); }, onManagement: this.onManagement }) }
      }.alignItems(HorizontalAlign.Start).padding(16).width('100%').backgroundColor($r('app.color.workbench_surface')).borderRadius(16)
    }, (item: CloudHistory): string => JSON.stringify(item))
    if (this.model.more) { Button('加载更多').enabled(!this.model.historyLoading).onClick((): void => { this.model.readHistory(true); }) }
    if (this.model.truncated) { Text('已达到 500 条或 512 KiB 的读取上限，请刷新查看最新记录。').fontSize(14) }
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
      }.width('100%').height('100%').onRefreshing((): void => {
        if (this.model.selected === undefined) { this.model.refresh(); } else { this.model.refreshDetail(); }
      })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
