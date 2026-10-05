import { DriveTransferRecord, driveTransferStateText } from '../../core/domain/DriveTransferState';
import { DriveTransferModel } from './DriveTransferModel';
import { workbenchBytes } from '../workbench/WorkbenchPresentation';
import { WorkbenchChoice, WorkbenchMetrics, WorkbenchNotice } from '../workbench/WorkbenchUi';

@ComponentV2
export struct DriveUploadReview {
  @Param model: DriveTransferModel = new DriveTransferModel();
  @Event onStart: () => void = (): void => {};
  @Event onTasks: () => void = (): void => {};

  build() {
    Column({ space: 8 }) {
      if (this.model.draft !== undefined) {
        Text('确认上传').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
        Text(this.model.draft.name + ' · ' + workbenchBytes(this.model.draft.bytes))
          .fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
        Text('目标：' + (this.model.draft.parent.displayPath || this.model.draft.parent.name))
          .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        Text('同名文件处理').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          WorkbenchChoice({ label: '自动改名', selected: this.model.conflict === 'autorename', available: !this.model.busy,
            onSelect: (): void => { this.model.conflict = 'autorename'; } })
          WorkbenchChoice({ label: '保存新版本', selected: this.model.conflict === 'version', available: !this.model.busy,
            onSelect: (): void => { this.model.conflict = 'version'; } })
        }.width('100%')
        Text(this.model.conflict === 'version' ? '已有同名文件时，将上传内容保存为新版本。' : '已有同名文件时，为上传文件使用新名称。')
          .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          Button('开始上传').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .enabled(this.model.ready && !this.model.busy).onClick(this.onStart)
          Button('取消选择').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(!this.model.busy).onClick((): void => { this.model.clearDraft(); })
        }.width('100%')
      }
      if (this.model.available) {
        Text('每次传输一个文件，最大 512 MB；离开应用会停止传输。')
          .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
      }
      if (this.model.busy || this.model.items.length > 0 || !this.model.ready) {
        Button('查看 Drive 传输').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(this.onTasks)
      }
      WorkbenchNotice({ text: this.model.errorText, warning: true })
      WorkbenchNotice({ text: this.model.notice })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
export struct DriveTransferSummary {
  @Param model: DriveTransferModel = new DriveTransferModel();

  build() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Text('Drive 传输').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).layoutWeight(1)
        if (!this.model.ready) {
          Button('重新加载').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(!this.model.busy).onClick((): void => { this.model.reload(); })
        }
      }.width('100%')
      Text('请保持应用在前台。停止上传后，先在 NAS 核对目标文件，再关闭结果待确认的记录。')
        .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
      if (this.model.ready && this.model.items.length === 0) {
        Text('暂无 Drive 传输。在 Drive 目录菜单选择上传，或点击文件下载。')
          .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      }
      WorkbenchNotice({ text: this.model.errorText, warning: true })
      WorkbenchNotice({ text: this.model.notice })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
export struct DriveTransferCard {
  @Param model: DriveTransferModel = new DriveTransferModel();
  @Require @Param item: DriveTransferRecord;

  private confirmClose(): void {
    this.getUIContext().getPromptAction().showDialog({ title: '已核对上传结果',
      message: '请先在 NAS 核对“' + this.item.locationName + '”中的“' + this.item.name + '”。关闭记录后可重新选择上传。',
      buttons: [{ text: '取消', color: '#666666' }, { text: '已核对，关闭记录', color: '#0A59F7' }] })
      .then((result): void => { if (result.index === 1) { this.model.closeUnknown(this.item.id); } })
      .catch((): void => { this.model.errorText = '无法显示核对确认，请重试。'; });
  }

  build() {
    Column({ space: 8 }) {
      Text(this.item.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
      Text((this.item.direction === 'upload' ? '上传 · ' : '下载 · ') + workbenchBytes(this.item.bytes) + ' · ' + driveTransferStateText(this.item.state))
        .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      Text(this.item.locationName).fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
      if (this.model.activeId === this.item.id && this.model.progress !== undefined) {
        Progress({ value: this.model.progress, total: 100, type: ProgressType.Linear }).width('100%').height(4)
          .accessibilityText('传输进度 ' + this.model.progress.toFixed(0) + '%')
      } else if (this.item.state === 'preparing' || this.item.state === 'running') {
        LoadingProgress().width(24).height(24)
      }
      WorkbenchNotice({ text: this.item.errorText, warning: true })
      Flex({ wrap: FlexWrap.Wrap }) {
        if (this.model.activeId === this.item.id) {
          Button(this.item.direction === 'upload' ? '停止上传' : '取消下载').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => { this.model.cancel(); })
        }
        if (this.item.state === 'completed' && this.item.direction === 'download') {
          Button('保存到本机').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.model.exportDownload(this.item.id); })
        }
        if (this.item.state === 'unknown') {
          Button('已核对，关闭记录').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.confirmClose(); })
        } else if (!['preparing', 'running'].includes(this.item.state)) {
          Button('移除记录').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.model.remove(this.item.id); })
        }
      }.width('100%')
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      .borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
  }
}
