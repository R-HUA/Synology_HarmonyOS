import { WorkbenchActionRow, WorkbenchMetrics } from './WorkbenchUi';

@ComponentV2
export struct MoreFeaturesPage {
  @Param scroller: Scroller = new Scroller();
  @Param bottomInset: number = 16;
  @Param showDownloads: boolean = false;
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
          if (this.showDownloads) { this.feature($r('app.string.nas_downloads_title'), $r('sys.symbol.arrow_down_circle'), 'nas-downloads') }
        }.divider({ strokeWidth: 1, color: $r('app.color.workbench_divider'), startMargin: 68, endMargin: 16 })
          .width('100%').margin({ left: 0, right: 0 })
          .borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() {
            WorkbenchActionRow({ label: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.package_open_management').id),
              icon: $r('sys.symbol.arrow_up_right'), onAction: this.onManagement })
          }
        }.width('100%').margin({ left: 0, right: 0 })
          .borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
      }.width('100%').constraintSize({ maxWidth: 960 }).height('100%')
        .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin })
        .contentStartOffset(12).contentEndOffset(this.bottomInset)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
