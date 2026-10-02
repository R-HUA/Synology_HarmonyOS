import { ConnectionViewModel } from './ConnectionViewModel';
import { NasConnectionAddress, NasConnectionRouteKind } from '../../core/domain/ConnectionRoutes';
import { telemetryTimestamp } from '../../core/domain/TelemetryProtocol';

@ComponentV2
export struct NasConnectionAddressPage {
  @Param model: ConnectionViewModel = new ConnectionViewModel();
  @Param scroller: Scroller = new Scroller();
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

  @Builder
  currentConnection() {
    Column({ space: 12 }) {
      Text(this.model.authenticated ? '当前连接' : '登录与地址切换').fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary')).width('100%')
      if (this.model.authenticated) {
        Text(this.model.address).fontSize(16).fontColor($r('sys.color.font_primary')).width('100%')
        Text(this.model.deviceCheckText).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      }
      Text('手动选择可信 HTTPS 地址。每个地址重新登录，不自动切换，也不在地址间复制登录凭据、任务或照片缓存。')
        .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
    }.width('100%').padding(20).borderRadius(24).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('sys.color.comp_background_secondary'))
  }

  @Builder
  addressForm() {
    Column({ space: 12 }) {
      Text('保存连接地址').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary')).width('100%')
      TextInput({ text: this.model.addressBook.draftName, placeholder: '名称，例如家中 NAS' }).maxLength(40)
        .constraintSize({ minHeight: 52 }).enabled(!this.disabled())
        .onChange((text: string): void => { this.model.addressBook.draftName = text; }).accessibilityText('连接地址名称')
      TextInput({ text: this.model.addressBook.draftOrigin, placeholder: 'https://nas.example.com:5001' }).maxLength(512)
        .constraintSize({ minHeight: 52 }).enabled(!this.disabled())
        .onChange((text: string): void => { this.model.addressBook.setDraftOrigin(text); }).accessibilityText('连接 HTTPS 地址')
      Row({ space: 12 }) {
        Text('地址类型').fontSize(15).fontColor($r('sys.color.font_secondary')).layoutWeight(1)
        Select([{ value: '局域网' }, { value: '远程访问' }, { value: '专网' }])
          .selected(this.kindIndex()).value(this.kindLabel(this.model.addressBook.draftKind)).enabled(!this.disabled())
          .onSelect((index: number, text: string): void => {
            this.model.addressBook.draftKind = index === 0 ? 'lan' : index === 1 ? 'remote' : 'private';
          })
      }.width('100%')
      Text('类型仅作标记，不会自动连接 Wi-Fi、VPN 或发现服务器。证书错误不能通过关闭验证绕过。')
        .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
      Row({ space: 12 }) {
        Button('测试连接').layoutWeight(1).constraintSize({ minHeight: 48 }).enabled(!this.disabled())
          .onClick((): void => { this.model.addressBook.probe(); })
        Button('保存地址').layoutWeight(1).constraintSize({ minHeight: 48 }).enabled(!this.disabled() && this.model.addressBook.ready)
          .onClick((): void => { this.model.addressBook.saveDraft(); })
      }.width('100%')
      if (this.model.addressBook.probing) {
        Button('取消测试').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => { this.model.addressBook.cancelProbe(); })
      }
      if (this.model.authenticated) {
        Button('保存当前连接并登记设备').width('100%').constraintSize({ minHeight: 48 })
          .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.disabled() && this.model.addressBook.ready)
          .onClick((): void => { this.model.saveCurrentAddress(); })
        Text('此操作保存当前已登录的地址，使用上方名称与类型；标识不可读取时仅保存地址，不冒称身份已核验。')
          .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
      }
    }.width('100%').padding(20).borderRadius(24).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('sys.color.comp_background_secondary'))
  }

  private confirmRemove(address: NasConnectionAddress): void {
    this.getUIContext().showAlertDialog({ title: '移除连接地址',
      message: '将移除“' + address.name + '”及设备身份登记。当前连接不会自动断开，文件、照片和任务记录不会删除。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '移除', action: (): void => { this.model.addressBook.remove(address.origin); } } });
  }

  @Builder
  savedAddress(address: NasConnectionAddress) {
    Column({ space: 12 }) {
      Text(address.name).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
      Text(this.kindLabel(address.kind) + (this.model.authenticated && this.model.address === address.origin ? ' · 当前地址' : ''))
        .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      Text(address.origin).fontSize(15).fontColor($r('sys.color.font_primary')).width('100%')
      Text(address.device === undefined ? '未登记设备身份；不会与其他地址合并记录。' :
        '已登记 ' + address.device.model + ' · 账号 ' + address.device.account + '，该账号登录时重新核验。')
        .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      Button('使用此地址').width('100%').constraintSize({ minHeight: 48 })
        .enabled(!this.disabled() && this.model.addressBook.ready && !this.model.queue.busy)
        .onClick((): void => { this.onUseAddress(address); })
      Row({ space: 12 }) {
        Button('测试').layoutWeight(1).constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.disabled())
          .onClick((): void => { this.model.addressBook.probe(address.origin); })
        Button('编辑').layoutWeight(1).constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.disabled())
          .onClick((): void => { this.model.addressBook.edit(address); this.scroller.scrollTo({ xOffset: 0, yOffset: 0 }); })
        Button('移除').layoutWeight(1).constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.disabled())
          .onClick((): void => { this.confirmRemove(address); })
      }.width('100%')
    }.width('100%').padding(20).borderRadius(24).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('sys.color.comp_background_secondary'))
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 20 }) {
        this.currentConnection()
        if (this.model.errorText.length > 0) {
          Text(this.model.errorText).fontSize(15).fontColor($r('sys.color.font_primary')).width('100%')
        }
        if (!this.model.addressBook.ready) {
          Text(this.model.addressBook.errorText.length > 0 ? this.model.addressBook.errorText : '连接地址配置尚未读取成功。')
            .fontSize(15).fontColor($r('sys.color.font_primary')).width('100%')
          Button('重新读取配置').constraintSize({ minHeight: 48 }).enabled(!this.disabled())
            .onClick((): void => { this.model.reloadAddressBook(); })
        }
        this.addressForm()
        if (this.model.addressBook.probeResult !== undefined) {
          Text(this.model.addressBook.probeResult.origin).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
          Text(this.model.addressBook.probeResult.message).fontSize(15).fontColor($r('sys.color.font_primary')).width('100%')
          Text('测试时间 ' + telemetryTimestamp(this.model.addressBook.probeResult.observedAt)).fontSize(13)
            .fontColor($r('sys.color.font_secondary')).width('100%')
        }
        if (this.model.addressBook.errorText.length > 0 && this.model.addressBook.ready) {
          Text(this.model.addressBook.errorText).fontSize(15).fontColor($r('sys.color.font_primary')).width('100%')
        }
        if (this.model.addressBook.notice.length > 0) {
          Text(this.model.addressBook.notice).fontSize(15).fontColor($r('sys.color.font_secondary')).width('100%')
        }
        Text('已保存地址').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary')).width('100%')
        if (this.model.addressBook.ready && this.model.addressBook.addresses.length === 0) {
          Text('尚未保存连接地址。').fontSize(15).fontColor($r('sys.color.font_secondary')).width('100%')
        }
        ForEach(this.model.addressBook.addresses, (address: NasConnectionAddress): void => {
          this.savedAddress(address)
        }, (address: NasConnectionAddress): string => address.origin)
      }.width('100%').constraintSize({ maxWidth: 840 }).padding({ left: 16, right: 16, top: 16, bottom: 32 })
        .alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto)
  }
}
