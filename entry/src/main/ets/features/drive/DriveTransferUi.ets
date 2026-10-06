import { DriveTransferRecord, driveTransferStateText } from '../../core/domain/DriveTransferState';
import { DriveTransferModel } from './DriveTransferModel';
import { workbenchBytes } from '../workbench/WorkbenchPresentation';
import { WorkbenchChoice, WorkbenchMetrics, WorkbenchNotice } from '../workbench/WorkbenchUi';

@ComponentV2
struct DriveTransferMode {
  @Param model: DriveTransferModel = new DriveTransferModel();
  build() {
    Column({ space: 8 }) {
      if (this.model.backgroundAvailable) {
        Flex({ wrap: FlexWrap.Wrap }) {
          WorkbenchChoice({ label: this.model.applicationBackground ? '应用后台传输' : '系统托管后台',
            selected: this.model.useBackground, available: !this.model.busy,
            onSelect: (): void => { this.model.useBackground = true; } })
          WorkbenchChoice({ label: '前台传输', selected: !this.model.useBackground, available: !this.model.busy,
            onSelect: (): void => { this.model.useBackground = false; } })
        }.width('100%')
      }
      Text(!this.model.useBackground || !this.model.backgroundAvailable ? '最大 512 MB；前台传输需保持应用打开。' :
        this.model.applicationBackground ? '最大 512 MB；忽略证书 HTTPS 使用应用后台传输，可切换应用，但进程终止后会中断。仅使用非计费 Wi-Fi，网络变化时停止。' :
          '最大 512 MB；系统托管后台传输仅使用非计费网络，不使用漫游网络。')
        .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

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
      if (this.model.available) { DriveTransferMode({ model: this.model }) }
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
        Button(this.model.ready ? '刷新' : '重新加载').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
          .enabled(!this.model.busy).onClick((): void => { if (this.model.ready) { this.model.refresh(); } else { this.model.reload(); } })
      }.width('100%')
      if (this.model.available) { DriveTransferMode({ model: this.model }) }
      Text('保存新版本的上传支持暂停和继续；下载请取消后重新下载。上传结果待确认时，请先在 NAS 核对目标文件。')
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
  private confirmResume(): void {
    this.getUIContext().getPromptAction().showDialog({ title: '继续原上传',
      message: '请先确认目标文件尚未完成上传。将检查原上传进度，再发送剩余内容；原上传已结束或失效时，请核对结果后关闭记录。',
      buttons: [{ text: '取消', color: '#666666' }, { text: '确认继续', color: '#0A59F7' }] })
      .then((result): void => { if (result.index === 1) { this.model.resume(this.item.id); } })
      .catch((): void => { this.model.errorText = '无法显示继续上传确认，请重试。'; });
  }

  private confirmVerify(): void {
    this.getUIContext().getPromptAction().showDialog({ title: '校验已下载文件',
      message: '将使用非计费 Wi-Fi 再次读取完整文件并比较内容，可能产生与文件大小相当的传输量。校验完成后才能保存到本机。',
      buttons: [{ text: '取消', color: '#666666' }, { text: '开始校验', color: '#0A59F7' }] })
      .then((result): void => { if (result.index === 1) { this.model.verifyDownload(this.item.id); } })
      .catch((): void => { this.model.errorText = '无法显示校验确认，请重试。'; });
  }

  build() {
    Column({ space: 8 }) {
      Text(this.item.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
      Text((this.item.direction === 'upload' ? '上传 · ' : '下载 · ') + workbenchBytes(this.item.bytes) + ' · ' + driveTransferStateText(this.item.state))
        .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      Text(this.item.executor === 'rcpBackground' ? '应用后台传输 · 进程终止后会中断' :
        this.item.background !== undefined ? '系统托管后台传输' : '前台传输')
        .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
      Text(this.item.locationName).fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
      if (this.model.activeId === this.item.id && this.model.progress !== undefined) {
        Progress({ value: this.model.progress, total: 100, type: ProgressType.Linear }).width('100%').height(4)
          .accessibilityText('传输进度 ' + this.model.progress.toFixed(0) + '%')
      } else if (this.item.state === 'preparing' || this.item.state === 'running') {
        if (this.item.background !== undefined && this.item.bytes !== undefined && this.item.bytes > 0) {
          Progress({ value: Math.min(99, this.item.background.processed / this.item.bytes * 100), total: 100, type: ProgressType.Linear }).width('100%').height(4)
        } else { LoadingProgress().width(24).height(24) }
      }
      WorkbenchNotice({ text: this.item.errorText, warning: true })
      Flex({ wrap: FlexWrap.Wrap }) {
        if (this.model.activeId === this.item.id) {
          if (this.item.direction === 'upload' && this.item.uploadSession !== undefined && this.item.state === 'running') {
            Button('暂停').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
              .onClick((): void => { this.model.pause(this.item.id); })
          }
          Button(this.item.direction === 'upload' ? '停止上传' : '取消下载').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => { this.model.cancel(); })
        }
        if (this.model.activeId !== this.item.id && (this.item.background !== undefined || this.item.state === 'paused') && ['running', 'creating', 'waiting', 'paused'].includes(this.item.state)) {
          if (this.item.state === 'running' && this.item.direction === 'upload' && this.item.uploadSession !== undefined) {
            Button('暂停').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.model.pause(this.item.id); })
          }
          Button('取消').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.model.cancelTask(this.item.id); })
        }
        if (this.item.direction === 'upload' && (this.item.state === 'paused' &&
          (this.item.uploadSession !== undefined || this.item.background?.startAttempted === false) ||
          this.item.state === 'unknown' && this.item.uploadSession !== undefined)) {
          Button('继续').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.confirmResume(); })
        }
        if (this.item.state === 'verifying') {
          Button('校验已下载文件').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.confirmVerify(); })
        }
        if (this.item.state === 'completed' && this.item.direction === 'download') {
          Button('保存到本机').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.model.exportDownload(this.item.id); })
        }
        if (this.item.state === 'unknown') {
          Button('已核对，关闭记录').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.confirmClose(); })
        } else if (!['preparing', 'creating', 'waiting', 'running', 'paused'].includes(this.item.state)) {
          Button('移除记录').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.model.remove(this.item.id); })
        }
      }.width('100%')
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      .borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
  }
}
