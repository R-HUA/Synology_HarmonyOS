import { uiMaterial } from '@kit.ArkUI';
import { ImmersiveMaterials } from '../../platform/ImmersiveMaterials';
import { DriveTransferRecord, driveTransferStateText } from '../../core/domain/DriveTransferState';
import { DriveTransferModel } from './DriveTransferModel';
import { workbenchBytes } from '../workbench/WorkbenchPresentation';
import { WorkbenchChoice, WorkbenchMetrics, WorkbenchNotice } from '../workbench/WorkbenchUi';

@ComponentV2
export struct DriveTransferModePicker {
  @Param model: DriveTransferModel = new DriveTransferModel();
  build() {
    Column({ space: 8 }) {
      if (this.model.backgroundAvailable) {
        Flex({ wrap: FlexWrap.Wrap }) {
          WorkbenchChoice({ label: this.model.applicationBackground ? '应用后台' : '系统后台',
            selected: this.model.useBackground, available: !this.model.busy,
            onSelect: (): void => { this.model.useBackground = true; } })
          WorkbenchChoice({ label: '前台', selected: !this.model.useBackground, available: !this.model.busy,
            onSelect: (): void => { this.model.useBackground = false; } })
        }.width('100%')
      }
      Text(!this.model.useBackground || !this.model.backgroundAvailable ? '单个文件最大 512 MB；前台传输需保持应用打开。' :
        this.model.applicationBackground ? '单个文件最大 512 MB；可切换应用，进程终止后会中断。仅使用非计费 Wi-Fi，网络变化时停止。' :
          '单个文件最大 512 MB；系统后台仅使用非计费网络，不使用漫游网络。')
        .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
export struct DriveUploadReview {
  @Param model: DriveTransferModel = new DriveTransferModel();
  @Event onStart: () => void = (): void => {};
  @Event onCancel: () => void = (): void => {};

  build() {
    Column({ space: 8 }) {
      if (this.model.draft !== undefined) {
        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.doc')).fontSize(24).fontColor([$r('sys.color.icon_emphasize')])
          Column({ space: 4 }) {
            Text(this.model.draft.name).fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary')).width('100%')
            Text(workbenchBytes(this.model.draft.bytes)).fontSize(12).fontColor($r('sys.color.font_secondary'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%')
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
        if (this.model.available) { DriveTransferModePicker({ model: this.model }) }
        Flex({ wrap: FlexWrap.Wrap }) {
          Button('开始上传').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .enabled(this.model.ready && !this.model.busy).onClick(this.onStart)
          Button('取消').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(!this.model.busy).onClick((): void => { this.model.clearDraft(); this.onCancel(); })
        }.width('100%')
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
      if (this.model.ready && this.model.items.length === 0) {
        Text('暂无 Drive 传输。')
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
  @Param detailsOnly: boolean = false;
  @Local private detailsVisible: boolean = false;
  private sheetMaterial: uiMaterial.Material | undefined = ImmersiveMaterials.SHEET_ULTRA_THICK;
  private sheetMaterialAvailable: boolean = ImmersiveMaterials.supported;

  private confirmClose(): void {
    this.getUIContext().getPromptAction().showDialog({ title: '已核对上传结果',
      message: '请先在 NAS 核对“' + this.item.locationName + '”中的“' + this.item.name + '”。关闭记录后可重新选择上传。',
      buttons: [{ text: '取消', color: $r('sys.color.font_secondary') }, { text: '已核对，关闭记录', color: $r('sys.color.font_emphasize') }] })
      .then((result): void => { if (result.index === 1) { this.detailsVisible = false; this.model.closeUnknown(this.item.id); } })
      .catch((): void => { this.model.errorText = '无法显示核对确认，请重试。'; });
  }
  private confirmResume(): void {
    this.getUIContext().getPromptAction().showDialog({ title: '继续原上传',
      message: '请先确认目标文件尚未完成上传。将检查原上传进度，再发送剩余内容；原上传已结束或失效时，请核对结果后关闭记录。',
      buttons: [{ text: '取消', color: $r('sys.color.font_secondary') }, { text: '确认继续', color: $r('sys.color.font_emphasize') }] })
      .then((result): void => { if (result.index === 1) { this.model.resume(this.item.id); } })
      .catch((): void => { this.model.errorText = '无法显示继续上传确认，请重试。'; });
  }

  private confirmVerify(): void {
    this.getUIContext().getPromptAction().showDialog({ title: '校验已下载文件',
      message: '将使用非计费 Wi-Fi 再次读取完整文件并比较内容，可能产生与文件大小相当的传输量。校验完成后才能保存到本机。',
      buttons: [{ text: '取消', color: $r('sys.color.font_secondary') }, { text: '开始校验', color: $r('sys.color.font_emphasize') }] })
      .then((result): void => { if (result.index === 1) { this.model.verifyDownload(this.item.id); } })
      .catch((): void => { this.model.errorText = '无法显示校验确认，请重试。'; });
  }

  @Builder
  transferProgress() {
    if (this.model.activeId === this.item.id && this.model.progress !== undefined) {
      Progress({ value: this.model.progress, total: 100, type: ProgressType.Linear }).width('100%').height(4)
        .accessibilityText('传输进度 ' + this.model.progress.toFixed(0) + '%')
    } else if (this.item.state === 'preparing' || this.item.state === 'running') {
      if (this.item.background !== undefined && this.item.bytes !== undefined && this.item.bytes > 0) {
        Progress({ value: Math.min(99, this.item.background.processed / this.item.bytes * 100), total: 100, type: ProgressType.Linear }).width('100%').height(4)
      } else { LoadingProgress().width(24).height(24) }
    }
  }

  @Builder
  transferActions() {
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
          .enabled(this.model.ready && !this.model.busy).onClick(async (): Promise<void> => {
            if (await this.model.exportDownload(this.item.id)) {
              this.getUIContext().getPromptAction().showToast({ message: $r('app.string.task_saved') });
            }
          })
      }
      if (this.item.state === 'unknown') {
        Button('核对结果').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
          .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.confirmClose(); })
      } else if (!['preparing', 'creating', 'waiting', 'running', 'paused'].includes(this.item.state)) {
        Button('移除记录').constraintSize({ minHeight: WorkbenchMetrics.touchSize }).buttonStyle(ButtonStyleMode.TEXTUAL)
          .enabled(this.model.ready && !this.model.busy)
          .onClick((): void => { this.detailsVisible = false; this.model.remove(this.item.id); })
      }
    }.width('100%')
  }

  @Builder
  transferDetails() {
    Scroll() {
      Column({ space: 12 }) {
        Text(this.item.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
        Text((this.item.direction === 'upload' ? '上传，' : '下载，') + workbenchBytes(this.item.bytes) +
          '，' + driveTransferStateText(this.item.state))
          .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        Text(this.item.executor === 'rcpBackground' ? '应用后台传输，进程终止后会中断' :
          this.item.background !== undefined ? '系统后台传输' : '前台传输')
          .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        Text((this.item.direction === 'upload' ? '目标：' : '本地路径：') + (this.item.direction === 'upload' ?
          this.item.locationName : this.model.downloadLocalPath(this.item.id)))
          .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        this.transferProgress()
        if (this.item.state === 'unknown') {
          Text('上传结果待确认。请先在 NAS 核对目标文件，再关闭记录或继续原上传。')
            .fontSize(14).fontColor($r('app.color.workbench_danger')).width('100%')
        } else if (this.item.direction === 'download' && ['cancelled', 'failed'].includes(this.item.state)) {
          Text('请返回文件列表重新选择下载。').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        }
        WorkbenchNotice({ text: this.item.errorText, warning: true })
        WorkbenchNotice({ text: this.model.errorText, warning: true })
        this.transferActions()
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 24 }).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto)
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
  }

  build() {
    if (this.detailsOnly) { this.transferDetails() }
    else {
    Column({ space: 4 }) {
      Button() {
        Row({ space: 12 }) {
          SymbolGlyph(this.item.direction === 'upload' ? $r('sys.symbol.arrow_up') : $r('sys.symbol.arrow_down'))
            .fontSize(20).fontColor([$r('sys.color.icon_emphasize')])
          Column({ space: 4 }) {
            Text(this.item.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
              .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(workbenchBytes(this.item.bytes) + '，' + driveTransferStateText(this.item.state))
              .fontSize(12).fontColor(this.item.state === 'unknown' || this.item.state === 'failed' ?
                $r('app.color.workbench_danger') : $r('sys.color.font_secondary')).width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(WorkbenchMetrics.rowArrowSize)
            .fontColor([$r('sys.color.font_secondary')]).opacity(WorkbenchMetrics.rowArrowOpacity)
        }.width('100%').padding({ top: 4, bottom: 4 })
      }.width('100%').type(ButtonType.Normal).backgroundColor(Color.Transparent)
        .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).onClick((): void => { this.detailsVisible = true; })
        .accessibilityText(this.item.name + '，' + driveTransferStateText(this.item.state) + '，传输详情')
      this.transferProgress()
      this.transferActions()
    }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
      .borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
      .bindSheet($$this.detailsVisible, this.transferDetails(), {
        height: SheetSize.MEDIUM, detents: [SheetSize.MEDIUM, SheetSize.LARGE], title: { title: '传输详情' },
        showClose: true, backgroundColor: this.sheetMaterialAvailable ? Color.Transparent : $r('app.color.workbench_surface_elevated'),
        systemMaterial: this.sheetMaterial
      })
    }
  }
}
