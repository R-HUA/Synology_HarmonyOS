import { NasExtensionsModel } from './NasExtensionsModel';
import { ExtensionFeature } from '../../core/domain/ExtensionWriteState';
import { WorkbenchNotice } from '../workbench/WorkbenchUi';

@ComponentV2
export struct ExtensionStatusPanel {
  @Param model: NasExtensionsModel = new NasExtensionsModel();
  @Param feature: ExtensionFeature = 'fileSharing';

  private confirmAcknowledgement(): void {
    this.getUIContext().showAlertDialog({ title: '关闭待核对记录',
      message: '请先在 DSM 核对上一操作是否已执行。关闭记录只允许再次手动操作，不表示远端操作成功，也不会自动重做。',
      primaryButton: { value: '返回核对', action: (): void => {} },
      secondaryButton: { value: '已核对，关闭记录', action: (): void => { this.model.acknowledge(this.feature); } } });
  }

  build() {
    Column({ space: 8 }) {
      WorkbenchNotice({ text: this.model.capabilityText(this.feature), warning: true })
      WorkbenchNotice({ text: this.feature === 'fileSharing' ? this.model.shareError : this.feature === 'photos' ? this.model.photoError : this.model.downloadError, warning: true })
      WorkbenchNotice({ text: this.feature === 'fileSharing' ? this.model.shareNotice : this.feature === 'photos' ? this.model.photoNotice : this.model.downloadNotice })
      if (this.model.recordsError.length > 0 || !this.model.recordsReady) {
        WorkbenchNotice({ text: this.model.recordsError || '操作记录尚未加载，读取列表不受影响，新的修改已暂停。', warning: true })
        Button('重新加载操作记录').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 48 })
          .enabled(!this.model.busy).onClick((): void => { this.model.reloadRecords(); })
      }
      if (this.model.hasPending(this.feature)) {
        WorkbenchNotice({ text: '上一操作结果待确认。请刷新列表或在 DSM 核对，应用不会重复提交。', warning: true })
        Button('我已在 DSM 核对').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 48 })
          .enabled(!this.model.busy && this.model.recordsReady).onClick((): void => { this.confirmAcknowledgement(); })
      }
    }.width('100%')
  }
}
