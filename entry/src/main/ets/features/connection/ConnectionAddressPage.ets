import { ConnectionViewModel } from './ConnectionViewModel';
import { NasConnectionAddress } from '../../core/domain/ConnectionRoutes';
import { telemetryTimestamp } from '../../core/domain/TelemetryProtocol';

import { WorkbenchMetrics, WorkbenchIconTile, WorkbenchNotice } from '../workbench/WorkbenchUi';

@ComponentV2
export struct NasConnectionAddressPage {
  @Param model: ConnectionViewModel = new ConnectionViewModel();
  @Param scroller: Scroller = new Scroller();
  @Event onUseAddress: (address: NasConnectionAddress) => void = (address: NasConnectionAddress): void => {};

  private disabled(): boolean {
    return this.model.busy || this.model.addressBook.busy || this.model.addressBook.probing;
  }

  private confirmRemove(address: NasConnectionAddress): void {
    this.getUIContext().showAlertDialog({ title: $r('app.string.connection_history_remove'),
      message: $r('app.string.connection_history_remove_detail', address.name),
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '移除', action: (): void => { this.model.addressBook.remove(address.origin); } } });
  }

  @Builder
  addressMenu(address: NasConnectionAddress) {
    Menu() {
      MenuItem({ content: '测试连接' }).onClick((): void => { this.model.addressBook.probe(address.origin, address.insecureTls === true); })
      MenuItem({ content: $r('app.string.connection_history_remove') }).onClick((): void => { this.confirmRemove(address); })
    }
  }

  @Builder
  savedAddress(address: NasConnectionAddress) {
    Column({ space: 4 }) {
      Row({ space: 4 }) {
        Button() {
          Row({ space: 12 }) {
            WorkbenchIconTile({ icon: $r('sys.symbol.externaldrive'), iconSize: 22, tileSize: 40, tileRadius: 12,
              iconColor: $r('sys.color.icon_emphasize'), tileColor: $r('app.color.workbench_accent_surface') })
            Column({ space: 2 }) {
              Text(address.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
                .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              if (address.insecureTls === true || this.model.authenticated && this.model.address === address.origin) {
                Text(address.insecureTls === true ? '忽略证书校验' : '当前连接')
                  .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
              }
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            if (!this.model.authenticated || this.model.address !== address.origin) {
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(WorkbenchMetrics.rowArrowSize)
                .fontColor([$r('sys.color.font_secondary')]).opacity(WorkbenchMetrics.rowArrowOpacity)
                .accessibilityLevel('no')
            }
          }.width('100%').padding({ top: 8, bottom: 8, right: 4 })
        }.layoutWeight(1).type(ButtonType.Normal).padding(0).constraintSize({ minHeight: 64 }).backgroundColor(Color.Transparent)
          .enabled(!this.disabled() && this.model.addressBook.ready && !this.model.queue.busy &&
            (!this.model.authenticated || this.model.address !== address.origin))
          .onClick((): void => { this.onUseAddress(address); })
          .accessibilityText(address.name + (this.model.authenticated && this.model.address === address.origin ? '，当前连接' : '，使用此地址'))
        Button() { SymbolGlyph($r('sys.symbol.more')).fontSize(22).fontColor([$r('sys.color.font_secondary')]) }
          .width(48).constraintSize({ minHeight: 48 }).type(ButtonType.Normal).padding(0).backgroundColor(Color.Transparent)
          .enabled(!this.disabled()).bindMenu(this.addressMenu(address)).accessibilityText(address.name + '，更多操作')
      }.width('100%')
      Text(address.origin).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%').copyOption(CopyOptions.InApp)
        .padding({ left: 52, right: 8 })
      if (address.device !== undefined) {
        Text(address.device.model + ' · ' + address.device.account)
          .fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%').padding({ left: 52, right: 8 })
      }
      if (this.model.addressBook.probeResult?.origin === address.origin) {
        WorkbenchNotice({ text: this.model.addressBook.probeResult?.message ?? '',
          warning: this.model.addressBook.probeResult?.passed === false })
      }
    }.width('100%').padding({ left: 16, right: 8, bottom: 12 }).alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 12 }) {
        if (!this.model.addressBook.ready) {
          Text(this.model.addressBook.errorText.length > 0 ? this.model.addressBook.errorText : '连接地址配置尚未读取成功。')
            .fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
          Button('重新读取配置').constraintSize({ minHeight: 48 }).enabled(!this.disabled())
            .onClick((): void => { this.model.reloadAddressBook(); })
          if (this.model.addressBook.corrupt) {
            Button($r('app.string.connection_rebuild')).constraintSize({ minHeight: 48 }).enabled(!this.disabled())
              .onClick((): void => {
                this.getUIContext().showAlertDialog({ title: $r('app.string.connection_rebuild'),
                  message: $r('app.string.connection_rebuild_detail'),
                  primaryButton: { value: $r('app.string.action_cancel'), action: (): void => {} },
                  secondaryButton: { value: $r('app.string.action_confirm'), action: (): void => { this.model.rebuildAddressBook(); } } });
              })
          }
        }
        if (this.model.addressBook.probeResult !== undefined) {
          Text(this.model.addressBook.probeResult.origin).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
          Text(this.model.addressBook.probeResult.message).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
          Text('测试时间 ' + telemetryTimestamp(this.model.addressBook.probeResult.observedAt)).fontSize(12)
            .fontColor($r('sys.color.font_tertiary')).width('100%')
        }
        if (this.model.addressBook.errorText.length > 0 && this.model.addressBook.ready) {
          WorkbenchNotice({ text: this.model.addressBook.errorText, warning: true })
        }
        if (this.model.addressBook.notice.length > 0) {
          Text(this.model.addressBook.notice).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        }
        if (this.model.addressBook.ready && this.model.addressBook.addresses.length === 0) {
          Text($r('app.string.connection_history_empty')).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
            .padding(WorkbenchMetrics.pageMargin)
        }
        Column() {
          ForEach(this.model.addressBook.addresses, (address: NasConnectionAddress): void => {
            this.savedAddress(address)
            Divider().color($r('app.color.workbench_divider')).margin({ left: 68, right: 16 })
          }, (address: NasConnectionAddress): string => address.origin)
        }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
      }.width('100%').constraintSize({ maxWidth: 840 }).padding({ left: 16, right: 16, top: 12, bottom: 32 })
        .alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto).align(Alignment.TopStart)
      .backgroundColor($r('app.color.workbench_background'))
  }
}
