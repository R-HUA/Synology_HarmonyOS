import { ContainerModel } from './ContainerModel';
import { ContainerItem, ContainerState, filterContainers } from './ContainerProtocol';
import { WorkbenchEmptyState, WorkbenchInfoRow, WorkbenchMetrics } from '../workbench/WorkbenchUi';
import { workbenchBytes } from '../workbench/WorkbenchPresentation';

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

  @Builder
  filters() {
    Search({ value: this.model.query, placeholder: '搜索容器名称' }).onChange((value: string): void => { this.model.query = value; })
    Row({ space: 8 }) {
      Button('全部').buttonStyle(this.model.filter === 'all' ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
        .onClick((): void => { this.model.filter = 'all'; })
      Button('运行中').buttonStyle(this.model.filter === 'running' ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
        .onClick((): void => { this.model.filter = 'running'; })
      Button('已停止').buttonStyle(this.model.filter === 'stopped' ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
        .onClick((): void => { this.model.filter = 'stopped'; })
      Blank()
      Button('刷新').enabled(!this.model.loading).onClick((): void => { this.model.refresh(); })
    }.width('100%')
  }

  @Builder
  list() {
    this.filters()
    if (this.model.loading) { LoadingProgress().width(32).height(32) }
    if (this.model.checkedAt > 0) { Text('读取时间：' + new Date(this.model.checkedAt).toLocaleString()).fontSize(14).fontColor($r('sys.color.font_secondary')) }
    if (this.model.errorText.length > 0) { Text(this.model.errorText).fontSize(14).fontColor($r('app.color.workbench_danger')) }
    if (this.model.loaded && this.model.items.length === 0) { WorkbenchEmptyState({ title: '暂无容器' }) }
    else if (this.model.loaded && filterContainers(this.model.items, this.model.query, this.model.filter).length === 0) {
      WorkbenchEmptyState({ title: '没有符合条件的容器' })
    }
    ForEach(filterContainers(this.model.items, this.model.query, this.model.filter), (item: ContainerItem): void => {
      Button() {
        Column({ space: 6 }) {
          WorkbenchInfoRow({ label: item.name, value: stateLabel(item.state), copyable: false })
          Text(item.image || '未提供镜像').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        }.padding(16).width('100%')
      }.type(ButtonType.Normal).width('100%').borderRadius(WorkbenchMetrics.cardRadius)
        .backgroundColor($r('app.color.workbench_surface')).onClick((): void => { this.model.select(item); })
    }, (item: ContainerItem): string => JSON.stringify(item))
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
    if (this.model.detailError.length > 0) { Text(this.model.detailError).fontColor($r('app.color.workbench_danger')) }
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
          WorkbenchInfoRow({ label: '采样时间', value: new Date(this.model.resource.sampledAt).toLocaleString() })
        }
      }.width('100%').padding(16).borderRadius(16).backgroundColor($r('app.color.workbench_surface'))
      if (this.model.resourceError.length > 0) { Text(this.model.resourceError).fontColor($r('app.color.workbench_danger')) }
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
    if (this.model.logsCheckedAt > 0) { Text('读取时间：' + new Date(this.model.logsCheckedAt).toLocaleString()).fontSize(14).fontColor($r('sys.color.font_secondary')) }
    if (this.model.logsError.length > 0) { Text(this.model.logsError).fontColor($r('app.color.workbench_danger')) }
    if (this.model.logsTruncated) { Text('仅显示最新 500 行或 512 KiB，超出部分已截断。').fontSize(14).fontColor($r('sys.color.font_secondary')) }
    if (this.model.logsLoaded) {
      Text(this.model.logs.length > 0 ? this.model.logs : '暂无日志').fontFamily('monospace').fontSize(14)
        .copyOption(CopyOptions.InApp).width('100%')
    }
  }

  build() {
    Row() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          if (this.model.selected === undefined) { this.list() } else { this.detail() }
          Button('在浏览器中管理').buttonStyle(ButtonStyleMode.NORMAL).onClick(this.onManagement)
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, left: 16, right: 16, bottom: this.bottomInset })
      }.width('100%').height('100%').constraintSize({ maxWidth: 960 }).align(Alignment.Top)
        .onScrollStart((): void => { this.model.stopFollowing(); })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
