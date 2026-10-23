import { NasApiDescriptor } from '../../core/domain/DsmProtocol';
import { WorkbenchIconTile, WorkbenchMetrics } from './WorkbenchUi';

@ComponentV2
export struct MoreFeaturesPage {
  @Param apis: NasApiDescriptor[] = [];
  @Param scroller: Scroller = new Scroller();
  @Param bottomInset: number = 16;
  @Event onManagement: () => void = (): void => {};
  @Event onOpen: (name: string) => void = (): void => {};

  @Builder
  feature(label: ResourceStr, icon: Resource, api: string, destination: string = '') {
    Button() {
    Row({ space: 12 }) {
      WorkbenchIconTile({ icon: icon })
      Text(label).fontSize(16).fontColor($r('sys.color.font_primary')).layoutWeight(1)
      Text(destination.length > 0 ? $r('app.string.package_open_native') : this.apis.some((item: NasApiDescriptor): boolean => item.name === api) ?
        $r('app.string.more_feature_unverified') : $r('app.string.more_feature_unavailable'))
        .fontSize(14).fontColor($r('sys.color.font_secondary'))
    }.width('100%').padding(16).constraintSize({ minHeight: WorkbenchMetrics.rowMinHeight })
      .borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
    }.type(ButtonType.Normal).width('100%').enabled(destination.length > 0).onClick((): void => { this.onOpen(destination); })
  }

  build() {
    Row() {
      Scroll(this.scroller) {
        Column({ space: WorkbenchMetrics.sectionGap }) {
          this.feature($r('app.string.more_feature_containers'), $r('sys.symbol.square_grid_2x2'), 'SYNO.Docker.Container', 'containers')
          this.feature($r('app.string.more_feature_cloud_sync'), $r('sys.symbol.folder'), 'SYNO.CloudSync', 'cloud-sync')
          this.feature($r('app.string.more_feature_system_logs'), $r('sys.symbol.list_bullet'), 'SYNO.Core.SyslogClient.Log', 'system-logs')
          this.feature($r('app.string.more_feature_notes'), $r('sys.symbol.doc_text'), 'SYNO.NoteStation.Note')
          Button($r('app.string.package_open_management')).buttonStyle(ButtonStyleMode.NORMAL)
            .width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).onClick(this.onManagement)
        }.width('100%').padding({ top: 12, left: 16, right: 16, bottom: this.bottomInset })
      }.width('100%').constraintSize({ maxWidth: 960 }).height('100%').align(Alignment.Top)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
