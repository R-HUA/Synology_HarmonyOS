import { ConnectionViewModel } from './ConnectionViewModel';
import { common } from '@kit.AbilityKit';
import { NasLanDiscovery } from './NasLanDiscovery';
import { NasConnectionAddress } from '../../core/domain/ConnectionRoutes';
import { telemetryTimestamp } from '../../core/domain/TelemetryProtocol';
import { connectionRouteLabel } from '../workbench/WorkbenchPresentation';
import { WorkbenchMetrics, WorkbenchEmptyState, WorkbenchIconTile, WorkbenchNotice } from '../workbench/WorkbenchUi';

@ComponentV2
export struct NasConnectionAddressPage {
  @Param model: ConnectionViewModel = new ConnectionViewModel();
  @Param scroller: Scroller = new Scroller();
  @Event onUseAddress: (address: NasConnectionAddress) => void = (_address: NasConnectionAddress): void => {};
  @Local private editorVisible: boolean = false;
  @Local private swipedOrigin: string = '';
  @Local private discovery: NasLanDiscovery = new NasLanDiscovery();
  private editorScroller: Scroller = new Scroller();

  aboutToDisappear(): void { this.discovery.stop(); }

  private edit(address?: NasConnectionAddress): void {
    if (address === undefined) { this.model.addressBook.beginDraft('', '', 'lan', false); }
    else { this.model.addressBook.edit(address); }
    this.editorVisible = true;
  }

  @Builder
  editor() {
    Scroll(this.editorScroller) {
      Column({ space: 12 }) {
        TextInput({ text: this.model.addressBook.draftName, placeholder: $r('app.string.connection_name') })
          .maxLength(40).height(48).onChange((text: string): void => { this.model.addressBook.draftName = text; })
        TextInput({ text: this.model.addressBook.draftOrigin, placeholder: $r('app.string.connection_origin') })
          .height(48).onChange((text: string): void => { this.model.addressBook.setDraftOrigin(text); })
        Row({ space: 8 }) {
          ForEach(['lan', 'remote', 'private'], (kind: string): void => {
            Button(kind === 'lan' ? '局域网' : kind === 'remote' ? '远程' : '私有网络')
              .buttonStyle(ButtonStyleMode.TEXTUAL).height(48)
              .backgroundColor(this.model.addressBook.draftKind === kind ? $r('app.color.workbench_accent_surface') : Color.Transparent)
              .onClick((): void => { this.model.addressBook.draftKind = kind as 'lan' | 'remote' | 'private'; })
          })
        }.width('100%')
        Row() {
          Text($r('app.string.connection_ignore_certificate')).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.model.addressBook.draftInsecureTls })
            .onChange((value: boolean): void => { this.model.addressBook.draftInsecureTls = value; })
        }.width('100%').height(48)
        WorkbenchNotice({ text: this.model.addressBook.errorText, warning: true })
        Button($r('app.string.action_confirm')).width('100%').height(48).enabled(!this.disabled())
          .onClick((): void => { this.model.addressBook.saveDraft(true).then((saved: boolean): void => { if (saved) { this.editorVisible = false; } }); })
      }.width('100%').padding(24)
    }.width('100%')
  }

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
      MenuItem({ content: $r('app.string.connection_edit') }).onClick((): void => { this.edit(address); })
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
              Row({ space: 6 }) {
                Text(address.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
                Text(connectionRouteLabel(address.origin, address.kind)).fontSize(11)
                  .fontColor($r('sys.color.font_emphasize'))
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(6)
                  .backgroundColor($r('app.color.workbench_accent_surface'))
              }.width('100%').alignItems(VerticalAlign.Center)
              if (address.insecureTls === true || this.model.authenticated && this.model.address === address.origin) {
                Text(this.model.authenticated && this.model.address === address.origin ?
                  (address.insecureTls === true ? '当前连接 · 忽略证书校验' : '当前连接') : '忽略证书校验')
                  .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
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
        Button() { SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(20).fontColor([$r('sys.color.icon_secondary')]) }
          .width(48).constraintSize({ minHeight: 48 }).type(ButtonType.Normal).padding(0).backgroundColor(Color.Transparent)
          .enabled(!this.disabled()).bindMenu(this.addressMenu(address)).accessibilityText(address.name + '，更多操作')
      }.width('100%')
      Text(address.origin).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%').copyOption(CopyOptions.InApp)
        .padding({ left: 52, right: 8 })
      if (address.device !== undefined) {
        Text(address.device.model + ' · ' + address.device.account)
          .fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%').padding({ left: 52, right: 8 })
      }
      if (address.lastLoginAt !== undefined) {
        Text($r('app.string.connection_last_login', telemetryTimestamp(address.lastLoginAt)))
          .fontSize(12).fontColor($r('sys.color.font_secondary')).padding({ left: 52 })
      }
      if (this.model.addressBook.probeResult?.origin === address.origin) {
        Row({ space: 6 }) {
          Circle().width(8).height(8).fill(this.model.addressBook.probeResult?.passed ? $r('app.color.workbench_success') : $r('app.color.workbench_danger'))
          Text($r('app.string.connection_latency', this.model.addressBook.probeResult!.elapsedMs)).fontSize(12)
        }.padding({ left: 52 })
        WorkbenchNotice({ text: this.model.addressBook.probeResult?.message ?? '',
          warning: this.model.addressBook.probeResult?.passed === false })
      }
      if (this.swipedOrigin === address.origin) {
        Row({ space: 12 }) {
          Button($r('app.string.connection_edit')).height(48).buttonStyle(ButtonStyleMode.TEXTUAL)
            .onClick((): void => { this.swipedOrigin = ''; this.edit(address); })
          Button($r('app.string.connection_history_remove')).height(48).buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontColor($r('app.color.workbench_danger')).onClick((): void => { this.confirmRemove(address); })
        }.width('100%').justifyContent(FlexAlign.End)
      }
    }.width('100%').padding({ left: 16, right: 8, bottom: 12 }).alignItems(HorizontalAlign.Start)
      .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent): void => {
        this.swipedOrigin = event.offsetX < -40 ? address.origin : '';
      }))
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          Button($r('app.string.connection_add')).height(48).layoutWeight(1).enabled(!this.disabled() && this.model.addressBook.ready)
            .onClick((): void => { this.edit(); })
          Button(this.discovery.searching ? $r('app.string.connection_searching') : $r('app.string.connection_discover'))
            .height(48).layoutWeight(1).enabled(!this.discovery.searching)
            .onClick((): void => { this.discovery.start(this.getUIContext().getHostContext() as common.UIAbilityContext); })
        }.width('100%')
        WorkbenchNotice({ text: this.discovery.errorText, warning: true })
        if (this.discovery.finished && this.discovery.results.length === 0 && this.discovery.errorText.length === 0) {
          Text($r('app.string.connection_discovery_empty')).fontSize(14).fontColor($r('sys.color.font_secondary'))
        }
        ForEach(this.discovery.results, (address: NasConnectionAddress): void => {
          Button(address.name + ' · ' + address.origin).height(56).width('100%').buttonStyle(ButtonStyleMode.TEXTUAL)
            .onClick((): void => { this.discovery.stop(); this.edit(address); })
        })
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
          Column({ space: 4 }) {
            Text(this.model.addressBook.probeResult.origin).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
            Text(this.model.addressBook.probeResult.message).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
            Text('测试时间 ' + telemetryTimestamp(this.model.addressBook.probeResult.observedAt)).fontSize(12)
              .fontColor($r('sys.color.font_tertiary')).width('100%')
            Text($r('app.string.connection_latency', this.model.addressBook.probeResult.elapsedMs)).fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
          }.width('100%').padding(14).borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        }
        if (this.model.addressBook.errorText.length > 0 && this.model.addressBook.ready) {
          WorkbenchNotice({ text: this.model.addressBook.errorText, warning: true })
        }
        if (this.model.addressBook.notice.length > 0) {
          Text(this.model.addressBook.notice).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        }
        if (this.model.addressBook.ready && this.model.addressBook.addresses.length === 0) {
          WorkbenchEmptyState({
            icon: $r('sys.symbol.arrow_counterclockwise_clock'),
            title: $r('app.string.connection_history_empty'),
            description: '登录成功后会自动保存 NAS 连接地址，方便下次快速切换或测试连通性。'
          })
        }
        if (this.model.addressBook.addresses.length > 0) {
          Column() {
            ForEach(this.model.addressBook.addresses, (address: NasConnectionAddress, index: number): void => {
              this.savedAddress(address)
              if (index < this.model.addressBook.addresses.length - 1) {
                Divider().color($r('app.color.workbench_divider')).margin({ left: 68, right: 16 })
              }
            }, (address: NasConnectionAddress): string => address.origin)
          }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
        }
      }.width('100%').constraintSize({ maxWidth: 840 }).padding({ left: 16, right: 16, top: 12, bottom: 32 })
        .alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto).align(Alignment.TopStart)
      .backgroundColor($r('app.color.workbench_background'))
      .bindSheet($$this.editorVisible, this.editor(), { height: SheetSize.FIT_CONTENT,
        title: { title: $r('app.string.connection_edit') }, showClose: true })
  }
}
