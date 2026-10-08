import { ConnectionViewModel } from './ConnectionViewModel';
import { NasConnectionAddress, NasConnectionRouteKind } from '../../core/domain/ConnectionRoutes';
import { normalizeNasOrigin, nasOriginScheme, NasFailure } from '../../core/domain/DsmProtocol';
import { telemetryTimestamp } from '../../core/domain/TelemetryProtocol';

import { WorkbenchMetrics, WorkbenchIconTile, WorkbenchSectionTitle, WorkbenchInfoRow, WorkbenchNotice } from '../workbench/WorkbenchUi';

@ComponentV2
export struct NasConnectionAddressPage {
  @Param model: ConnectionViewModel = new ConnectionViewModel();
  @Param scroller: Scroller = new Scroller();
  @Local private formVisible: boolean = false;
  @Event onUseAddress: (address: NasConnectionAddress) => void = (address: NasConnectionAddress): void => {};

  private disabled(): boolean {
    return this.model.busy || this.model.addressBook.busy || this.model.addressBook.probing;
  }

  private kindLabel(kind: NasConnectionRouteKind): string {
    return kind === 'lan' ? '局域网' : kind === 'remote' ? '远程访问' : '专网';
  }

  private kindIndex(): number {
    return this.model.addressBook.draftKind === 'lan' ? 0 : this.model.addressBook.draftKind === 'remote' ? 1 : 2;
  }

  private openAddressForm(address?: NasConnectionAddress): void {
    if (address !== undefined) { this.model.addressBook.edit(address); }
    else {
      this.model.addressBook.beginDraft(this.model.address, '', 'lan', false);
    }
    this.formVisible = true;
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }

  private confirmSave(): void {
    let origin: string;
    try { origin = normalizeNasOrigin(this.model.addressBook.draftOrigin); }
    catch (error) {
      this.model.addressBook.errorText = error instanceof NasFailure ? error.message : '连接地址格式不正确。';
      return;
    }
    const save = (accepted: boolean): void => {
      this.model.addressBook.saveDraft(accepted).then((saved: boolean): void => { if (saved) { this.formVisible = false; } });
    };
    if (nasOriginScheme(origin) === 'https' && !this.model.addressBook.draftInsecureTls) { save(false); return; }
    this.getUIContext().showAlertDialog({ title: $r('app.string.connection_risk_title'),
      message: nasOriginScheme(origin) === 'http' ? $r('app.string.connection_http_risk', origin) : $r('app.string.connection_tls_risk', origin),
      primaryButton: { value: $r('app.string.action_cancel'), action: (): void => {} },
      secondaryButton: { value: $r('app.string.connection_accept_risk'), action: (): void => { save(true); } } });
  }

  @Builder
  currentConnection() {
    Column({ space: 8 }) {
      WorkbenchSectionTitle({ title: this.model.authenticated ? '当前连接' : '登录与地址切换' })
      if (this.model.authenticated) {
        WorkbenchInfoRow({ label: '地址', value: this.model.address })
        Text(this.model.deviceCheckText).fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%')
      }
      Text('切换地址后需重新登录，任务与照片记录保留在原连接下。')
        .fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%')
    }.width('100%').padding(16).borderRadius(WorkbenchMetrics.cardRadius).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.workbench_surface'))
  }

  @Builder
  addressForm() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text('保存连接地址').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).layoutWeight(1)
        Button('收起').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.disabled())
          .onClick((): void => { this.formVisible = false; })
      }.width('100%')
      TextInput({ text: this.model.addressBook.draftName, placeholder: '名称，例如家中 NAS' }).maxLength(40)
        .constraintSize({ minHeight: 48 }).enabled(!this.disabled())
        .onChange((text: string): void => { this.model.addressBook.draftName = text; }).accessibilityText('连接地址名称')
      TextInput({ text: this.model.addressBook.draftOrigin, placeholder: 'https://nas.example.com:5001' }).maxLength(512)
        .constraintSize({ minHeight: 48 }).enabled(!this.disabled())
        .onChange((text: string): void => { this.model.addressBook.setDraftOrigin(text); }).accessibilityText('连接地址')
      Row({ space: 12 }) {
        Text('地址类型').fontSize(14).fontColor($r('sys.color.font_secondary')).layoutWeight(1)
        Select([{ value: '局域网' }, { value: '远程访问' }, { value: '专网' }])
          .selected(this.kindIndex()).value(this.kindLabel(this.model.addressBook.draftKind)).enabled(!this.disabled())
          .onSelect((index: number, text: string): void => {
            this.model.addressBook.draftKind = index === 0 ? 'lan' : index === 1 ? 'remote' : 'private';
          })
      }.width('100%')
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text($r('app.string.connection_skip_certificate')).fontSize(16).fontColor($r('sys.color.font_primary')).width('100%')
          Text($r('app.string.connection_skip_certificate_detail')).fontSize(12)
            .fontColor($r('sys.color.font_tertiary')).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.model.addressBook.draftInsecureTls })
          .enabled(!this.disabled())
          .onChange((checked: boolean): void => { this.model.addressBook.draftInsecureTls = checked; })
          .accessibilityText($r('app.string.connection_skip_certificate'))
      }.width('100%').constraintSize({ minHeight: WorkbenchMetrics.rowMinHeight })
      Row({ space: 12 }) {
        Button('测试连接').layoutWeight(1).constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.disabled())
          .onClick((): void => { this.model.addressBook.probe(); })
        Button('保存地址').layoutWeight(1).constraintSize({ minHeight: 48 }).enabled(!this.disabled() && this.model.addressBook.ready)
          .onClick((): void => { this.confirmSave(); })
      }.width('100%')
      if (this.model.addressBook.probing) {
        Button('取消测试').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => { this.model.addressBook.cancelProbe(); })
      }
      if (this.model.authenticated) {
        Button('保存当前连接并登记设备').width('100%').constraintSize({ minHeight: 48 })
          .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.disabled() && this.model.addressBook.ready)
          .onClick((): void => { this.model.saveCurrentAddress(); })
      }
    }.width('100%').padding(16).borderRadius(WorkbenchMetrics.cardRadius).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.workbench_surface'))
  }

  private confirmRemove(address: NasConnectionAddress): void {
    this.getUIContext().showAlertDialog({ title: '移除连接地址',
      message: '将移除“' + address.name + '”及设备身份登记。当前连接不会自动断开，文件、照片和任务记录不会删除。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '移除', action: (): void => { this.model.addressBook.remove(address.origin); } } });
  }

  @Builder
  addressMenu(address: NasConnectionAddress) {
    Menu() {
      MenuItem({ content: '测试连接' }).onClick((): void => { this.model.addressBook.probe(address.origin, address.insecureTls === true); })
      MenuItem({ content: '编辑地址' }).onClick((): void => { this.openAddressForm(address); })
      MenuItem({ content: '移除地址' }).onClick((): void => { this.confirmRemove(address); })
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
              Text(this.kindLabel(address.kind) + (address.insecureTls === true ? ' · 跳过证书校验' : '') +
                (this.model.authenticated && this.model.address === address.origin ? ' · 当前连接' : ''))
                .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            if (!this.model.authenticated || this.model.address !== address.origin) {
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('sys.color.font_tertiary')])
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
      } else {
        Text('设备身份未登记').fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%').padding({ left: 52, right: 8 })
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
        this.currentConnection()
        if (this.model.errorText.length > 0) {
          WorkbenchNotice({ text: this.model.errorText, warning: true })
        }
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
        if (this.formVisible) { this.addressForm() }
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
        Row({ space: 12 }) {
          Text('已保存地址').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).layoutWeight(1)
          Button('添加地址').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(!this.disabled()).onClick((): void => { this.openAddressForm(); })
        }.width('100%')
        if (this.model.addressBook.ready && this.model.addressBook.addresses.length === 0) {
          Text('尚未保存连接地址。').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
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
