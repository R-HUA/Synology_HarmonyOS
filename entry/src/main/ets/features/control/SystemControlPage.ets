import { NasControlRecord } from '../../core/domain/SystemControl';
import { telemetryTimestamp } from '../../core/domain/TelemetryProtocol';
import { SystemControlModel } from './SystemControlModel';

@ComponentV2
export struct NasSystemControlPage {
  @Param control: SystemControlModel = new SystemControlModel();
  @Param scroller: Scroller = new Scroller();
  @Event onRefresh: () => void = (): void => {};
  @Event onSubmit: () => void = (): void => {};

  private stateLabel(record: NasControlRecord): string {
    if (record.state === 'pending') { return '结果待确认'; }
    if (record.state === 'accepted') { return 'NAS 已接收，结果待核对'; }
    if (record.state === 'rejected') { return '未接受该操作'; }
    return '已人工核对';
  }

  private confirmSubmit(): void {
    if (this.control.busy || !this.control.authorized || this.control.selectedAction === undefined) { return; }
    const word = this.control.confirmationWord();
    this.getUIContext().showAlertDialog({ title: word + ' ' + this.control.model,
      message: '目标：' + this.control.origin + '\n授权账号：' + this.control.account.trim() +
        '\n' + (word === '关机' ? 'NAS 将停止所有服务，需要现场或其他受支持的方式重新开机。' : 'NAS 服务将中断，其他用户的传输和业务也会受到影响。') +
        '\n这里只能检查本 App 的任务，请另行确认其他用户和服务已做好准备。请求只发送一次；超时或离线时必须人工核对，不能盲目重试。',
      autoCancel: false,
      primaryButton: { value: '取消', defaultFocus: true, action: (): void => { this.control.cancelPreparation(); } },
      secondaryButton: { value: '确认' + word, defaultFocus: false, action: (): void => { this.onSubmit(); } } });
  }

  private confirmResolve(record: NasControlRecord): void {
    this.getUIContext().showAlertDialog({ title: '确认已核对结果',
      message: record.model + '\n' + record.origin + '\n' + (record.action === 'reboot' ? '重启' : '关机') +
        '\n仅记录你已在 DSM 或现场核对结果，不会重新发送请求。如果仍不确定，请取消。',
      primaryButton: { value: '取消', defaultFocus: true, action: (): void => {} },
      secondaryButton: { value: '我已核对', action: (): void => { this.control.resolve(record.id); } } });
  }

  @Builder
  targetCard() {
    Column({ space: 12 }) {
      Text(this.control.model.length > 0 ? this.control.model : '设备身份尚未确认')
        .fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary')).width('100%')
      Text(this.control.origin).fontSize(15).fontColor($r('sys.color.font_secondary')).width('100%')
      Text('系统控制会中断 NAS 上所有用户的服务。这里只提供重启与关机，不提供磁盘变更、系统升级或容器启停。')
        .fontSize(15).fontColor($r('sys.color.font_primary')).width('100%')
      Text('文件与相册登录不代表系统控制权限。独立授权不保存密码或会话，退出页面、退后台或两分钟到期后失效。')
        .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
    }.width('100%').padding(20).borderRadius(24).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('sys.color.comp_background_secondary'))
  }

  @Builder
  authorizationForm() {
    Column({ space: 12 }) {
      Text('独立登录授权').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary')).width('100%')
      Text('请输入具有 DSM 系统控制权限的账号。是否允许操作由 NAS 在提交时判定，不将 File Station 管理权限作为系统授权。')
        .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      TextInput({ text: this.control.account, placeholder: '系统控制账号' }).maxLength(128).constraintSize({ minHeight: 52 })
        .enabled(!this.control.busy && !this.control.authorized)
        .onChange((text: string): void => { this.control.account = text; }).accessibilityText('系统控制独立登录账号')
      if (!this.control.authorized) {
        TextInput({ text: this.control.password, placeholder: '密码' }).type(InputType.Password).constraintSize({ minHeight: 52 })
          .enabled(!this.control.busy).onChange((text: string): void => { this.control.password = text; })
          .accessibilityText('系统控制独立登录密码')
        if (this.control.needsOtp) {
          TextInput({ text: this.control.otp, placeholder: '6 位动态码；请同时重新输入密码' }).type(InputType.Number).maxLength(6)
            .constraintSize({ minHeight: 52 }).enabled(!this.control.busy)
            .onChange((text: string): void => { this.control.otp = text; }).accessibilityText('系统控制双重验证动态码')
        }
        Button(this.control.busy ? '正在处理…' : '登录并核验设备').width('100%').constraintSize({ minHeight: 48 })
          .enabled(this.control.canAuthorize() && this.control.account.trim().length > 0 && this.control.password.length > 0)
          .onClick((): void => { this.control.authorize(); })
      } else {
        Button('结束临时授权').width('100%').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL)
          .enabled(!this.control.busy).onClick((): void => { this.onRefresh(); })
      }
    }.width('100%').padding(20).borderRadius(24).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('sys.color.comp_background_secondary'))
  }

  @Builder
  actionCard() {
    Column({ space: 12 }) {
      Text('选择操作').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary')).width('100%')
      Text('本 App 内进行中、结果不确定或未读取的任务会阻止提交；不会为系统控制自动停止或重试任务。')
        .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      Button('重启 NAS').width('100%').constraintSize({ minHeight: 48 }).enabled(this.control.authorized && !this.control.busy)
        .onClick((): void => { this.control.prepare('reboot'); })
      Button('关闭 NAS').width('100%').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL)
        .enabled(this.control.authorized && !this.control.busy).onClick((): void => { this.control.prepare('shutdown'); })
      if (this.control.selectedAction !== undefined) {
        Text('请输入“' + this.control.confirmationWord() + '”，然后再次核对设备并确认。')
          .fontSize(15).fontColor($r('sys.color.font_primary')).width('100%')
        TextInput({ text: this.control.confirmationText, placeholder: this.control.confirmationWord() }).maxLength(8)
          .constraintSize({ minHeight: 52 }).enabled(!this.control.busy)
          .onChange((text: string): void => { this.control.confirmationText = text; }).accessibilityText('系统控制确认文字')
        Button('继续核对并确认').width('100%').constraintSize({ minHeight: 48 })
          .enabled(!this.control.busy && this.control.authorized && this.control.confirmationText === this.control.confirmationWord())
          .onClick((): void => { this.confirmSubmit(); })
        Button('取消准备').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.control.busy)
          .onClick((): void => { this.control.cancelPreparation(); })
      }
    }.width('100%').padding(20).borderRadius(24).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('sys.color.comp_background_secondary'))
  }

  @Builder
  recordCard(record: NasControlRecord) {
    Column({ space: 12 }) {
      Text('最近一次操作').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary')).width('100%')
      Text(this.stateLabel(record)).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
      Text(record.model + ' · ' + (record.action === 'reboot' ? '重启' : '关机')).fontSize(15).width('100%')
      Text(record.origin + '\n账号：' + record.account).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      Text('记录时间 ' + telemetryTimestamp(record.createdAt)).fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
      if (record.state === 'pending' || record.state === 'accepted') {
        Text('离线不证明操作已完成。请先在 DSM 或现场核对；未核对前不能再次提交。')
          .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        Button('已人工核对结果').width('100%').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL)
          .enabled(this.control.ready && !this.control.busy).onClick((): void => { this.confirmResolve(record); })
      }
    }.width('100%').padding(20).borderRadius(24).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('sys.color.comp_background_secondary'))
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 20 }) {
        this.targetCard()
        if (this.control.errorText.length > 0) {
          Text(this.control.errorText).fontSize(15).fontColor($r('sys.color.font_primary')).width('100%')
        }
        if (this.control.notice.length > 0) {
          Text(this.control.notice).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        }
        Button('重新读取并清除临时授权').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL)
          .enabled(!this.control.busy).onClick((): void => { this.onRefresh(); })
        if (this.control.record !== undefined) { this.recordCard(this.control.record) }
        this.authorizationForm()
        this.actionCard()
      }.width('100%').constraintSize({ maxWidth: 840 }).padding({ left: 16, right: 16, top: 16, bottom: 32 })
        .alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto)
  }
}
