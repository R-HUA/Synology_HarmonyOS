import { pasteboard } from '@kit.BasicServicesKit';
import { driveCollaborationTime, driveLinkStateText, validateDriveFileLink } from '../../core/domain/DriveCollaborationProtocol';
import type { DriveLinkRecord } from '../../core/domain/DriveCollaborationProtocol';
import { DriveSharingModel } from './DriveSharingModel';
import { DriveNotificationsModel } from './DriveNotificationsModel';
import type { DriveNotificationItem } from './DriveNotificationsModel';
import { WorkbenchMetrics, WorkbenchNotice } from '../workbench/WorkbenchUi';

/** 作为 HdsNavDestination 内容；宿主将同一个 scroller 绑定到标题栏。 */
@ComponentV2
export struct DriveSharingPage {
  @Param model: DriveSharingModel = new DriveSharingModel();
  @Param scroller: Scroller = new Scroller();
  @Event onCancel: () => void = (): void => {};
  @Event onSubmitted: () => void = (): void => {};

  private async submit(): Promise<void> { if (await this.model.submit()) { this.onSubmitted(); } }
  build() {
    List({ space: 8, scroller: this.scroller }) {
      ListItem() {
        Column({ space: 8 }) {
          if (this.model.draft !== undefined) {
            Text('获取“' + this.model.draft.name + '”的文件链接')
              .fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
            Text('链接访问以 NAS 当前权限为准。')
              .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              Button(this.model.busy ? '正在获取…' : '确认获取文件链接')
                .constraintSize({ minHeight: WorkbenchMetrics.touchSize })
                .enabled(this.model.ready && this.model.available && !this.model.busy && !this.model.hasPending)
                .onClick((): void => { this.submit(); })
              Button('取消').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
                .enabled(!this.model.busy).onClick((): void => { this.model.clearDraft(); this.onCancel(); })
            }.width('100%')
          }
          if (this.model.draft !== undefined) {
            Text('已获取的链接').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
          }
          Text('当前账号在本机获取的文件链接。')
            .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
          if (!this.model.available) {
            WorkbenchNotice({ text: '此 NAS 未提供可用的 Drive 文件链接功能。', warning: true })
          }
          if (!this.model.ready) {
            Button('重新加载记录').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .enabled(!this.model.busy).onClick((): void => { this.model.reload(); })
          } else if (this.model.items.length === 0) {
            Text('暂无本机文件链接记录。').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
          }
          WorkbenchNotice({ text: this.model.errorText, warning: true })
          WorkbenchNotice({ text: this.model.notice })
        }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 }).alignItems(HorizontalAlign.Start)
      }
      ForEach(this.model.items, (item: DriveLinkRecord): void => {
        ListItem() { DriveLinkCard({ model: this.model, item }) }
      }, (item: DriveLinkRecord): string => JSON.stringify(item))
    }.width('100%').height('100%').scrollBar(BarState.Auto).contentEndOffset(16)
  }
}

@ComponentV2
struct DriveLinkCard {
  @Param model: DriveSharingModel = new DriveSharingModel();
  @Param item: DriveLinkRecord = { id: '', nasOrigin: '', account: '', fileId: '', name: '', createdAt: 0, state: 'unknown' };
  @Local private copyNotice: string = '';
  @Local private copyError: string = '';
  private async copy(): Promise<void> {
    this.copyNotice = ''; this.copyError = '';
    const url = this.item.url;
    if (url === undefined) { return; }
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, validateDriveFileLink(url)));
      this.copyNotice = '文件链接已复制。';
    } catch (_) { this.copyError = '文件链接未能复制，请重试。'; }
  }
  private confirmClose(): void {
    this.getUIContext().showAlertDialog({ title: '已在 Drive 网页核对？',
      message: '请先在 Drive 网页核对文件链接的获取结果。关闭仅更新本机记录，不会撤销链接，也不会重新获取链接。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '已核对，关闭', action: (): void => { this.model.closeUnknown(this.item.id); } } });
  }
  build() {
    Column({ space: 4 }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.link')).fontSize(20).fontColor([$r('sys.color.icon_emphasize')])
        Column({ space: 4 }) {
          Text(this.item.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
            .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(driveLinkStateText(this.item.state) + ' · ' + driveCollaborationTime(this.item.createdAt / 1000))
            .fontSize(12).fontColor(this.item.state === 'unknown' ? $r('app.color.workbench_danger') :
              $r('sys.color.font_secondary')).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      if (this.item.url !== undefined) {
        Text(this.item.url).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%').copyOption(CopyOptions.None)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (this.item.state === 'unknown') {
        WorkbenchNotice({ text: '获取结果待确认，请先在 Drive 网页核对，应用不会自动重试。', warning: true })
      }
      Flex({ wrap: FlexWrap.Wrap }) {
        if (this.item.url !== undefined) {
          Button('复制链接').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .enabled(!this.model.busy).onClick((): void => { this.copy(); }).accessibilityText('复制“' + this.item.name + '”的文件链接')
        }
        if (this.item.state === 'unknown') {
          Button('核对结果').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.confirmClose(); })
        } else {
          Button('移除本机记录').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.model.remove(this.item.id); })
        }
      }.width('100%')
      WorkbenchNotice({ text: this.copyNotice })
      WorkbenchNotice({ text: this.copyError, warning: true })
    }.width('100%').padding(12).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
      .alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
export struct DriveNotificationsPage {
  @Param model: DriveNotificationsModel = new DriveNotificationsModel();
  @Param scroller: Scroller = new Scroller();
  build() {
    List({ space: 8, scroller: this.scroller }) {
      ListItem() {
        Column({ space: 8 }) {
          Text('已读标记保留到本次连接结束。').fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            Button(this.model.busy ? '正在刷新…' : '刷新通知').buttonStyle(ButtonStyleMode.TEXTUAL)
              .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).enabled(this.model.available && !this.model.busy)
              .onClick((): void => { this.model.refresh(); })
            Button('全部标为已读').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .enabled(!this.model.busy && this.model.items.some((item: DriveNotificationItem): boolean => !item.read))
              .onClick((): void => { this.model.markAllRead(); })
          }.width('100%')
          if (!this.model.available) {
            WorkbenchNotice({ text: '此 NAS 未提供可用的 Drive 通知功能。', warning: true })
          } else if (this.model.loaded && !this.model.busy && this.model.errorText.length === 0 && this.model.total === 0 && this.model.items.length === 0) {
            Text('暂无 Drive 通知。').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
          }
          if (this.model.total > this.model.items.length) {
            WorkbenchNotice({ text: '还有更多通知，可在 Drive 网页查看。' })
          }
          WorkbenchNotice({ text: this.model.errorText, warning: true })
        }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 }).alignItems(HorizontalAlign.Start)
      }
      ForEach(this.model.items, (item: DriveNotificationItem): void => {
        ListItem() {
          Column({ space: 4 }) {
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.bell')).fontSize(20).fontColor([item.read ? $r('sys.color.font_secondary') :
                $r('sys.color.icon_emphasize')])
              Text(item.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).layoutWeight(1)
              Button(item.read ? '已读' : '标为已读').buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(12)
                .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).enabled(!item.read && !this.model.busy)
                .onClick((): void => { this.model.markRead(item.id); }).accessibilityText(item.read ? '已读通知' : '将此通知标为已读')
            }.width('100%')
            if (item.name.length > 0) {
              Text(item.name).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
            }
            Text((item.senderName.length > 0 ? item.senderName + ' · ' : '') + driveCollaborationTime(item.time))
              .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
            if (!item.known) {
              Text('请前往 Drive 网页查看详情。').fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
            }
          }.width('100%').padding(12).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
            .alignItems(HorizontalAlign.Start)
        }
      }, (item: DriveNotificationItem): string => JSON.stringify(item))
    }.width('100%').height('100%').scrollBar(BarState.Auto).contentEndOffset(16)
  }
}
