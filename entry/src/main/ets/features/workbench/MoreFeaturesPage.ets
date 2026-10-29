import { WorkbenchActionRow, WorkbenchMetrics } from './WorkbenchUi';

@ComponentV2
export struct MoreFeaturesPage {
  @Param scroller: Scroller = new Scroller();
  @Param bottomInset: number = 16;
  @Event onManagement: () => void = (): void => {};
  @Event onOpen: (name: string) => void = (): void => {};

  @Builder
  feature(label: Resource, icon: Resource, destination: string) {
    ListItem() {
      WorkbenchActionRow({ label: this.getUIContext().getHostContext()!.resourceManager.getStringSync(label.id),
        icon: icon, onAction: (): void => { this.onOpen(destination); } })
    }
  }

  build() {
    Row() {
      List({ scroller: this.scroller, space: WorkbenchMetrics.sectionGap }) {
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          this.feature($r('app.string.more_feature_containers'), $r('sys.symbol.square_grid_2x2'), 'containers')
          this.feature($r('app.string.more_feature_cloud_sync'), $r('sys.symbol.folder'), 'cloud-sync')
          this.feature($r('app.string.more_feature_system_logs'), $r('sys.symbol.list_bullet'), 'system-logs')
          this.feature($r('app.string.more_feature_notes'), $r('sys.symbol.doc_text'), 'notes')
        }.divider({ strokeWidth: 1, color: $r('app.color.workbench_divider'), startMargin: 68, endMargin: 16 })
          .width('100%').margin({ left: 0, right: 0 })
          .borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        ListItem() {
          Button($r('app.string.package_open_management')).buttonStyle(ButtonStyleMode.NORMAL)
            .width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).onClick(this.onManagement)
        }
      }.width('100%').constraintSize({ maxWidth: 960 }).height('100%')
        .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin })
        .contentStartOffset(12).contentEndOffset(this.bottomInset)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
