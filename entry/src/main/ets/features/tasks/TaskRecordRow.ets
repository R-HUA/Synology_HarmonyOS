import { TaskRecordView, taskEnded } from '../../core/domain/TaskPresentation';
import { workbenchBytes } from '../workbench/WorkbenchPresentation';
import { WorkbenchIconTile } from '../workbench/WorkbenchUi';
import { transferRemainingSeconds } from '../../core/domain/TransferRates';

@ComponentV2
export struct TaskRecordRow {
  @Require @Param record: TaskRecordView;
  @Param focused: boolean = false;
  @Param canCancel: boolean = false;
  @Param canPause: boolean = false;
  @Param canResume: boolean = false;
  @Param canRetry: boolean = false;
  @Param actionsEnabled: boolean = true;
  @Event onDetail: () => void = (): void => {};
  @Event onCancel: () => void = (): void => {};
  @Event onPause: () => void = (): void => {};
  @Event onRetry: () => void = (): void => {};

  /** 结束状态以业务回执为准，进度达到百分之百仍可能处于核验中。 */
  @Computed
  private get hasProgress(): boolean { return this.record.progress !== undefined && !taskEnded(this.record.state); }

  private fileIcon(): Resource {
    if (/\.(jpg|jpeg|png|gif|webp|heic)$/i.test(this.record.name)) { return $r('sys.symbol.picture'); }
    if (/\.(mp4|mov|mkv|avi)$/i.test(this.record.name)) { return $r('sys.symbol.video'); }
    return $r('sys.symbol.doc');
  }

  @Builder
  action(icon: Resource, label: Resource, callback: () => void) {
    Button() { SymbolGlyph(icon).fontSize(22).fontColor([$r('sys.color.icon_secondary')]).fontWeight(FontWeight.Regular) }
      .width(44).height(44).type(ButtonType.Circle).backgroundColor(Color.Transparent).padding(0)
      .enabled(this.actionsEnabled).accessibilityText(label).onClick(callback)
  }

  build() {
    Row({ space: 4 }) {
      Button() {
        Row({ space: 12 }) {
          WorkbenchIconTile({ icon: this.fileIcon(), iconSize: 22, tileSize: 40, tileRadius: 12,
            iconColor: $r('sys.color.icon_emphasize'), tileColor: $r('app.color.workbench_accent_surface') })
          Column({ space: 6 }) {
            Text(this.record.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
              .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.hasProgress) {
              Progress({ value: this.record.progress!, total: 100, type: ProgressType.Linear }).width('100%').height(4)
            }
            Row({ space: 8 }) {
              Text(this.record.group === 'processing' ? this.record.path : this.record.processed !== undefined && !taskEnded(this.record.state) ?
                workbenchBytes(this.record.processed) + (this.record.bytes === undefined ? '' : ' / ' + workbenchBytes(this.record.bytes)) : workbenchBytes(this.record.bytes))
                .fontSize(12).fontColor($r('sys.color.font_secondary')).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.record.state !== 'completed' || this.record.group === 'processing') {
                Text(this.record.stateText).fontSize(12).fontColor(this.record.state === 'failed' ?
                  $r('app.color.workbench_danger') : $r('sys.color.font_secondary')).maxLines(1)
              }
            }.width('100%')
            if (this.record.state === 'running' && this.record.bytesPerSecond !== undefined) {
              Text(workbenchBytes(this.record.bytesPerSecond) + '/s' +
                (transferRemainingSeconds(this.record.bytes, this.record.processed, this.record.bytesPerSecond) === undefined ? '' :
                  ' · ' + Math.ceil(transferRemainingSeconds(this.record.bytes, this.record.processed, this.record.bytesPerSecond)! / 60).toString() + ' 分钟'))
                .fontSize(12).fontColor($r('sys.color.font_emphasize'))
            }
            if (this.record.state === 'failed' && this.record.errorText.length > 0) {
              Text(this.record.errorText).fontSize(12).fontColor($r('app.color.workbench_danger')).maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%')
      }.type(ButtonType.Normal).backgroundColor(Color.Transparent).layoutWeight(1).padding(0).onClick(this.onDetail)
        .accessibilityText(this.record.name + '，' + this.record.stateText)
      if (this.canRetry) { this.action($r('sys.symbol.arrow_clockwise'), $r('app.string.task_retry'), this.onRetry) }
      if (this.canCancel) { this.action($r('sys.symbol.xmark_circle'), $r('app.string.task_cancel'), this.onCancel) }
      if (this.canPause || this.canResume) {
        this.action(this.canResume ? $r('sys.symbol.play_circle') : $r('sys.symbol.pause_circle'),
          this.canResume ? $r('app.string.task_resume') : $r('app.string.task_pause'), this.onPause)
      }
      if (!this.canRetry && !this.canCancel && !this.canPause && !this.canResume) {
        this.action($r('sys.symbol.ellipsis_circle'), $r('app.string.task_details'), this.onDetail)
      }
    }.width('100%').constraintSize({ minHeight: this.hasProgress ? 96 : 72 }).padding({ left: 12, right: 8, top: 10, bottom: 10 })
      .borderRadius(16).backgroundColor(this.focused ? $r('app.color.workbench_accent_surface') : $r('app.color.workbench_surface'))
  }
}
