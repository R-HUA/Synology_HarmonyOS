import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { NasExtensionsModel } from '../extensions/NasExtensionsModel';
import { ExtensionStatusPanel } from '../extensions/ExtensionStatusPanel';
import { ShareCreateResult, ShareLink, ShareLinkOptions, SharePasswordMode, validateShareUrl } from './FileSharingProtocol';
import { WorkbenchMetrics, WorkbenchChoice, WorkbenchIconTile, WorkbenchInfoRow, WorkbenchNotice } from '../workbench/WorkbenchUi';

@ComponentV2
export struct ShareLinksPage {
  @Param model: NasExtensionsModel = new NasExtensionsModel();
  @Param scroller: Scroller = new Scroller();
  @Local private filter: string = 'all';
  @Local private editing: boolean = false;
  @Local private showingDetail: boolean = false;
  @Local private editingId: string = '';
  @Local private passwordMode: SharePasswordMode = 'retain';
  @Local private password: string = '';
  @Local private availableDate: string = '';
  @Local private expiredDate: string = '';
  @Local private platformError: string = '';

  aboutToAppear(): void {
    if (this.model.shareDraftPaths.length > 0) { this.openEditor(); }
  }
  aboutToDisappear(): void { this.password = ''; this.model.shareDraftPaths = []; }

  private links(): ShareLink[] {
    return this.model.shares.filter((link: ShareLink): boolean => this.filter === 'all' || link.status === this.filter);
  }
  private stateText(status: string): string {
    if (status === 'valid') { return '有效'; }
    if (status === 'expired') { return '已过期'; }
    if (status === 'invalid' || status === 'broken') { return '已失效'; }
    return '状态待核对';
  }
  private openEditor(link?: ShareLink): void {
    this.showingDetail = false;
    this.editingId = link?.id ?? '';
    this.passwordMode = 'retain';
    this.password = '';
    this.availableDate = link === undefined || link.availableDate === '0' ? '' : link.availableDate;
    this.expiredDate = link === undefined || link.expiredDate === '0' ? '' : link.expiredDate;
    this.editing = true;
  }
  private async openDetail(link: ShareLink): Promise<void> {
    await this.model.showShare(link.id);
    if (this.model.selectedShare?.id === link.id) { this.showingDetail = true; }
  }
  private async submit(): Promise<void> {
    const options: ShareLinkOptions = { password: { mode: this.passwordMode, value: this.passwordMode === 'set' ? this.password : undefined },
      availableDate: this.availableDate || '0', expiredDate: this.expiredDate || '0' };
    const completed = this.editingId.length === 0 ? await this.model.createShares(options) : await this.model.editShare(this.editingId, options);
    this.password = '';
    if (completed) { this.editing = false; }
  }
  private async copy(text: string): Promise<void> {
    this.platformError = '';
    try { await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, validateShareUrl(text))); }
    catch { this.platformError = '链接未能复制，请重试。'; }
  }
  private async copyPassword(): Promise<void> {
    this.platformError = '';
    try { await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.password)); }
    catch { this.platformError = '口令未能复制，请重试。'; }
  }
  private async share(link: ShareLink): Promise<void> {
    this.platformError = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const data = new systemShare.SharedData({ utd: uniformTypeDescriptor.UniformDataType.HYPERLINK,
        content: validateShareUrl(link.url), title: link.name });
      await new systemShare.ShareController(data).show(context, { selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DEFAULT });
    } catch { this.platformError = '未能打开系统分享面板，请重试。'; }
  }
  private confirmRevoke(link: ShareLink): void {
    this.getUIContext().showAlertDialog({ title: '撤销分享', message: '撤销“' + link.name + '”的分享链接？链接将失效，原文件不会删除。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '撤销链接', action: (): void => { this.model.revokeShare(link.id); } } });
  }

  @Builder
  editor() {
    Scroll() {
      Column({ space: 12 }) {
        Text(this.editingId.length === 0 ? this.model.shareDraftPaths.join('、') : this.model.selectedShare?.name ?? '分享链接')
          .fontSize(16).fontColor($r('sys.color.font_primary')).width('100%')
        Text('日期留空表示不限制，按 NAS 的日期生效。')
          .fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(['retain', 'set', 'remove'], (mode: string): void => {
            WorkbenchChoice({ label: mode === 'retain' ? '保留现有口令' : mode === 'set' ? '设置口令' : '移除口令',
              selected: this.passwordMode === mode, available: !this.model.busy,
              onSelect: (): void => { this.passwordMode = mode as SharePasswordMode; this.password = ''; } })
          }, (mode: string): string => mode)
        }.width('100%')
        if (this.passwordMode === 'set') {
          TextInput({ text: this.password, placeholder: '分享口令，1–16 个字符' }).type(InputType.Password).maxLength(16)
            .enabled(!this.model.busy).onChange((value: string): void => { this.password = value; })
          Button('仅复制新口令').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 48 })
            .enabled(this.password.length > 0 && !this.model.busy).onClick((): void => { this.copyPassword(); })
        }
        TextInput({ text: this.availableDate, placeholder: '可用日期 YYYY-MM-DD（可留空）' })
          .enabled(!this.model.busy).onChange((value: string): void => { this.availableDate = value; })
        TextInput({ text: this.expiredDate, placeholder: '过期日期 YYYY-MM-DD（可留空）' })
          .enabled(!this.model.busy).onChange((value: string): void => { this.expiredDate = value; })
        ExtensionStatusPanel({ model: this.model, feature: 'fileSharing' })
        WorkbenchNotice({ text: this.platformError, warning: true })
        Button(this.model.busy ? '正在提交…' : this.editingId.length === 0 ? '创建链接' : '保存设置')
          .width('100%').constraintSize({ minHeight: 48 }).enabled(this.model.canWrite('fileSharing'))
          .onClick((): void => { this.submit(); })
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
    }.width('100%')
  }

  @Builder
  detail(link: ShareLink) {
    Column({ space: 8 }) {
      WorkbenchInfoRow({ label: '分享对象', value: link.name })
      WorkbenchInfoRow({ label: '状态', value: this.stateText(link.status) })
      WorkbenchInfoRow({ label: '口令', value: link.hasPassword ? '已设置' : '未设置' })
      WorkbenchInfoRow({ label: '可用日期', value: link.availableDate === '0' ? '不限制' : link.availableDate })
      WorkbenchInfoRow({ label: '过期日期', value: link.expiredDate === '0' ? '不限制' : link.expiredDate })
      Text(link.url).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%').copyOption(CopyOptions.LocalDevice)
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('复制链接').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => { this.copy(link.url); })
        Button('系统分享').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => { this.share(link); })
        Button('编辑').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(this.model.canWrite('fileSharing'))
          .onClick((): void => { this.openEditor(link); })
        Button('撤销链接').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL).fontColor($r('app.color.workbench_danger'))
          .enabled(this.model.canWrite('fileSharing'))
          .onClick((): void => { this.confirmRevoke(link); })
      }.width('100%')
    }.width('100%').padding(16).borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
  }

  @Builder
  detailSheet() {
    Scroll() {
      Column() {
        if (this.model.selectedShare !== undefined) { this.detail(this.model.selectedShare) }
        WorkbenchNotice({ text: this.platformError, warning: true })
        ExtensionStatusPanel({ model: this.model, feature: 'fileSharing' })
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
    }.width('100%').scrollBar(BarState.Auto).align(Alignment.TopStart)
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 12 }) {
        Row() {
          Text('File Station 分享').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).layoutWeight(1)
          Button('刷新').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 48 }).enabled(!this.model.busy)
            .onClick((): void => { this.model.refreshShares(); })
        }.width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(['all', 'valid', 'expired'], (filter: string): void => {
            WorkbenchChoice({ label: filter === 'all' ? '全部' : filter === 'valid' ? '有效链接' : '已过期', selected: this.filter === filter,
              onSelect: (): void => { this.filter = filter; } })
          }, (filter: string): string => filter)
        }.width('100%')
        ExtensionStatusPanel({ model: this.model, feature: 'fileSharing' })
        WorkbenchNotice({ text: this.platformError, warning: true })
        if (this.model.sharesLoaded && this.model.shareError.length === 0 && this.links().length === 0) {
          Text('当前页此分类暂无分享链接。').fontSize(14).fontColor($r('sys.color.font_secondary'))
        }
        Column() {
          ForEach(this.links(), (link: ShareLink): void => {
            Button() {
              Row({ space: 12 }) {
                WorkbenchIconTile({ icon: $r('sys.symbol.link'), iconSize: 22, tileSize: 40, tileRadius: 12,
                  iconColor: $r('sys.color.icon_emphasize'), tileColor: $r('app.color.workbench_accent_surface') })
                Column({ space: 2 }) {
                  Text(link.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
                    .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text((link.hasPassword ? '口令保护 · ' : '无需口令 · ') + this.stateText(link.status))
                    .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(WorkbenchMetrics.rowArrowSize)
                  .fontColor([$r('sys.color.font_secondary')]).opacity(WorkbenchMetrics.rowArrowOpacity)
                  .accessibilityLevel('no')
              }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
            }.width('100%').type(ButtonType.Normal).padding(0).constraintSize({ minHeight: 64 })
              .backgroundColor(Color.Transparent).enabled(!this.model.busy).onClick((): void => { this.openDetail(link); })
              .accessibilityText(link.name + '，' + this.stateText(link.status) + '，查看详情')
            Divider().color($r('app.color.workbench_divider')).margin({ left: 68, right: 16 })
          }, (link: ShareLink): string => link.id)
        }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        if (this.model.shareOffset > 0 || this.model.shareOffset + this.model.shares.length < this.model.shareTotal) {
          Row() {
            Button('上一页').buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.busy && this.model.shareOffset > 0)
              .onClick((): void => { this.model.refreshShares(Math.max(0, this.model.shareOffset - 50)); })
            Text(this.model.sharesLoaded ? '共 ' + this.model.shareTotal.toString() + ' 个链接' : '尚未读取').fontSize(12).fontColor($r('sys.color.font_secondary')).layoutWeight(1).textAlign(TextAlign.Center)
            Button('下一页').buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(!this.model.busy && this.model.shareOffset + this.model.shares.length < this.model.shareTotal)
              .onClick((): void => { this.model.refreshShares(this.model.shareOffset + 50); })
          }.width('100%')
        }
        ForEach(this.model.shareResults, (result: ShareCreateResult): void => {
          Column({ space: 6 }) {
            Text(result.path).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
            if (result.failure !== undefined) { WorkbenchNotice({ text: result.failure.message, warning: true }) }
            else if (result.url !== undefined) {
              Text(result.url).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%').copyOption(CopyOptions.LocalDevice)
              Button('复制新链接').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 48 })
                .onClick((): void => { this.copy(result.url!); })
            }
          }.width('100%').padding(12).borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        }, (result: ShareCreateResult): string => result.path)
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto).align(Alignment.TopStart)
      .bindSheet($$this.editing, this.editor(), { height: SheetSize.LARGE, showClose: true,
        title: { title: this.editingId.length === 0 ? '创建分享链接' : '编辑分享链接' },
        keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL,
        onDisappear: (): void => { this.password = ''; } })
      .bindSheet($$this.showingDetail, this.detailSheet(), { height: SheetSize.LARGE, showClose: true,
        title: { title: '分享详情' } })
  }
}
