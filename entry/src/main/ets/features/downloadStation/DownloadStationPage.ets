import { NasExtensionsModel } from '../extensions/NasExtensionsModel';
import { ExtensionStatusPanel } from '../extensions/ExtensionStatusPanel';
import { DownloadTask, DownloadTaskFile } from './DownloadStationProtocol';
import { workbenchBytes } from '../workbench/WorkbenchPresentation';
import { WorkbenchChoice, WorkbenchInfoRow, WorkbenchNotice } from '../workbench/WorkbenchUi';

@ComponentV2
export struct DownloadStationPage {
  @Param model: NasExtensionsModel = new NasExtensionsModel();
  @Param scroller: Scroller = new Scroller();
  @Event onChooseDirectory: () => void = (): void => {};
  @Local private filter: string = 'all';
  @Local private creating: boolean = false;
  @Local private showingDetail: boolean = false;

  aboutToAppear(): void {
    this.creating = this.model.downloadFormRequested || this.model.downloadUri.length > 0;
    this.model.downloadFormRequested = false;
  }
  private tasks(): DownloadTask[] {
    return this.model.downloads.filter((task: DownloadTask): boolean => this.filter === 'all' ||
      (this.filter === 'finished' ? task.status === 'finished' || task.status === 'seeding' :
        task.status !== 'finished' && task.status !== 'seeding'));
  }
  private statusText(task: DownloadTask): string {
    switch (task.status) {
      case 'waiting': return '排队中';
      case 'downloading': return '下载中';
      case 'paused': return '已暂停';
      case 'processing': return '处理中';
      case 'finished': return '已完成';
      case 'seeding': return '做种中';
      case 'error': return '下载失败';
      default: return '状态待核对';
    }
  }
  private progress(task: DownloadTask): number {
    return task.totalBytes === undefined || task.totalBytes <= 0 || task.downloadedBytes === undefined ? 0 :
      Math.min(100, task.downloadedBytes / task.totalBytes * 100);
  }
  private bytes(task: DownloadTask): string {
    return (task.downloadedBytes === undefined ? '已下载大小未知' : workbenchBytes(task.downloadedBytes)) +
      ' / ' + (task.totalBytes === undefined ? '总大小未知' : workbenchBytes(task.totalBytes));
  }
  private rate(task: DownloadTask): string {
    return task.downloadBytesPerSecond === undefined ? '速率未提供' : workbenchBytes(task.downloadBytesPerSecond) + '/s';
  }
  private canPause(task: DownloadTask): boolean {
    return ['waiting', 'downloading', 'seeding'].includes(task.status);
  }
  private async openDetail(task: DownloadTask): Promise<void> {
    await this.model.showDownload(task.id);
    if (this.model.selectedDownload !== undefined) { this.showingDetail = true; }
  }
  private confirmRemove(task: DownloadTask): void {
    this.getUIContext().showAlertDialog({ title: '移除 NAS 下载任务',
      message: '移除“' + task.title + '”？未完成数据可能由套件清理，已下载文件请在 NAS 上核对。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '移除任务', action: (): void => { this.model.controlDownload(task.id, 'delete'); } } });
  }
  private confirmCreate(): void {
    this.getUIContext().showAlertDialog({ title: '由 NAS 执行下载',
      message: '下载将保存到 NAS 的 /' + this.model.downloadDestination + '，不会下载到手机。确认提交？',
      primaryButton: { value: '返回编辑', action: (): void => {} },
      secondaryButton: { value: '确认创建', action: (): void => { this.submit(); } } });
  }
  private async submit(): Promise<void> {
    const completed = await this.model.createDownload();
    if (completed || this.model.hasPending('nasDownloads')) { this.creating = false; }
  }

  @Builder
  taskMenu(task: DownloadTask) {
    Menu() {
      MenuItem({ content: '查看详情' }).onClick((): void => { this.openDetail(task); })
      MenuItem({ content: '移除任务' }).enabled(this.model.canWrite('nasDownloads'))
        .onClick((): void => { this.confirmRemove(task); })
    }
  }

  @Builder
  taskRow(task: DownloadTask) {
    Row({ space: 4 }) {
      Button() {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.arrow_down_circle')).fontSize(22).fontColor([$r('sys.color.icon_emphasize')])
            .width(36).height(36).borderRadius(10).backgroundColor($r('app.color.workbench_accent_surface'))
          Column({ space: 4 }) {
            Text(task.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
              .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Progress({ value: this.progress(task), total: 100, type: ProgressType.Linear }).width('100%').height(4)
              .visibility(task.totalBytes !== undefined && task.totalBytes > 0 && task.downloadedBytes !== undefined ? Visibility.Visible : Visibility.Hidden)
            Row({ space: 6 }) {
              Text(this.bytes(task)).fontSize(12).fontColor($r('sys.color.font_secondary')).layoutWeight(1)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.rate(task)).fontSize(12).fontColor($r('sys.color.font_secondary')).maxLines(1)
            }.width('100%')
            Text(this.statusText(task)).fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%')
      }.layoutWeight(1).type(ButtonType.Normal).backgroundColor(Color.Transparent).padding(0)
        .constraintSize({ minHeight: 48 }).enabled(!this.model.busy).onClick((): void => { this.openDetail(task); })
        .accessibilityText(task.title + '，' + this.statusText(task) + '，查看详情')
      if (this.canPause(task) || task.status === 'paused' || task.status === 'error') {
        Button(this.canPause(task) ? '暂停' : '恢复').fontSize(12).width(48).constraintSize({ minHeight: 48 })
          .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(this.model.canWrite('nasDownloads'))
          .onClick((): void => { this.model.controlDownload(task.id, this.canPause(task) ? 'pause' : 'resume'); })
      } else { Blank().width(48) }
      Button() { SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(20).fontColor([$r('sys.color.font_secondary')]) }
        .width(48).constraintSize({ minHeight: 48 }).type(ButtonType.Circle).backgroundColor(Color.Transparent)
        .enabled(!this.model.busy).bindMenu(this.taskMenu(task)).accessibilityText(task.title + '，更多操作')
    }.width('100%').padding({ left: 12, right: 4, top: 10, bottom: 10 })
  }

  @Builder
  createForm() {
    Scroll() {
      Column({ space: 12 }) {
        Text('由当前 NAS 执行，不下载到手机。关闭手机页面不会停止 NAS 下载。')
          .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        TextInput({ text: this.model.downloadUri, placeholder: 'HTTP(S)、FTP 或 magnet 下载链接' }).enabled(!this.model.busy)
          .onChange((value: string): void => { this.model.downloadUri = value; })
        WorkbenchInfoRow({ label: 'NAS 目标目录', value: this.model.downloadDestination.length === 0 ? '尚未选择' : '/' + this.model.downloadDestination })
        Button('浏览并选择 NAS 目录').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 48 }).enabled(!this.model.busy)
          .onClick((): void => { this.creating = false; this.onChooseDirectory(); })
        Text('目标目录权限由 NAS 在提交时验证。链接和认证参数不会保存到普通任务记录。')
          .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
        ExtensionStatusPanel({ model: this.model, feature: 'nasDownloads' })
        if (!this.model.canCreateDownload) {
          WorkbenchNotice({ text: '此服务器尚未发现支持链接与目标目录创建的接口版本，可继续查看和控制已有任务。', warning: true })
        }
        Button('创建 NAS 下载').width('100%').constraintSize({ minHeight: 48 })
          .enabled(this.model.canCreateDownload && this.model.canWrite('nasDownloads') && this.model.downloadUri.trim().length > 0 &&
            this.model.downloadDestination.length > 0).onClick((): void => { this.confirmCreate(); })
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
    }.width('100%')
  }

  @Builder
  detail() {
    Scroll() {
      Column({ space: 8 }) {
        if (this.model.selectedDownload !== undefined) {
          WorkbenchInfoRow({ label: '任务', value: this.model.selectedDownload.title })
          WorkbenchInfoRow({ label: '状态', value: this.statusText(this.model.selectedDownload) })
          WorkbenchInfoRow({ label: '下载大小', value: this.bytes(this.model.selectedDownload) })
          WorkbenchInfoRow({ label: '下载速率', value: this.rate(this.model.selectedDownload) })
          WorkbenchInfoRow({ label: '上传速率', value: this.model.selectedDownload.uploadBytesPerSecond === undefined ? '未提供' :
            workbenchBytes(this.model.selectedDownload.uploadBytesPerSecond) + '/s' })
          WorkbenchInfoRow({ label: 'NAS 目录', value: this.model.selectedDownload.destination ?? '未提供' })
          WorkbenchNotice({ text: this.model.selectedDownload.errorMessage ?? '', warning: true })
          ForEach(this.model.selectedDownload.files ?? [], (file: DownloadTaskFile): void => {
            WorkbenchInfoRow({ label: file.name, value: file.totalBytes === undefined ? '大小未知' : workbenchBytes(file.totalBytes) })
          }, (file: DownloadTaskFile): string => file.name)
        }
      }.width('100%').padding(16)
    }.width('100%')
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 12 }) {
        Row() {
          Text('由 NAS 执行').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary')).layoutWeight(1)
          Button('刷新').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 48 }).enabled(!this.model.busy)
            .onClick((): void => { this.model.refreshDownloads(); })
          Button('新增').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 48 }).enabled(!this.model.busy)
            .onClick((): void => { this.creating = true; })
        }.width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(['all', 'active', 'finished'], (filter: string): void => {
            WorkbenchChoice({ label: filter === 'all' ? '全部' : filter === 'active' ? '进行中' : '下载完成', selected: this.filter === filter,
              onSelect: (): void => { this.filter = filter; } })
          }, (filter: string): string => filter)
        }.width('100%')
        ExtensionStatusPanel({ model: this.model, feature: 'nasDownloads' })
        Text('状态和速率为最近一次刷新采样。做种表示仍在上传，不等于任务已停止。')
          .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
        if (this.model.downloadsLoaded && this.model.downloadError.length === 0 && this.tasks().length === 0) {
          Text('当前页此分类暂无下载任务。').fontSize(15).fontColor($r('sys.color.font_secondary'))
        }
        Column() {
          ForEach(this.tasks(), (task: DownloadTask): void => { this.taskRow(task); Divider().color($r('app.color.workbench_divider')) },
            (task: DownloadTask): string => task.id)
        }.width('100%').borderRadius(16).backgroundColor($r('app.color.workbench_surface'))
        Row() {
          Button('上一页').buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.model.busy && this.model.downloadOffset > 0)
            .onClick((): void => { this.model.refreshDownloads(Math.max(0, this.model.downloadOffset - 50)); })
          Text(this.model.downloadsLoaded ? '共 ' + this.model.downloadTotal.toString() + ' 个任务' : '尚未读取').fontSize(13).fontColor($r('sys.color.font_secondary')).layoutWeight(1).textAlign(TextAlign.Center)
          Button('下一页').buttonStyle(ButtonStyleMode.TEXTUAL)
            .enabled(!this.model.busy && this.model.downloadOffset + this.model.downloads.length < this.model.downloadTotal)
            .onClick((): void => { this.model.refreshDownloads(this.model.downloadOffset + 50); })
        }.width('100%')
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto)
      .bindSheet($$this.creating, this.createForm(), { height: SheetSize.LARGE, showClose: true, title: { title: '新增 NAS 下载' },
        keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL })
      .bindSheet($$this.showingDetail, this.detail(), { height: SheetSize.LARGE, showClose: true, title: { title: 'NAS 下载详情' } })
  }
}
