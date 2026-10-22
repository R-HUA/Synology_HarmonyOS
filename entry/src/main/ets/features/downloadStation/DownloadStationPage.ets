import { NasExtensionsModel } from '../extensions/NasExtensionsModel';
import { ExtensionStatusPanel } from '../extensions/ExtensionStatusPanel';
import { DownloadTask, DownloadTaskFile, downloadMatchesFilter } from './DownloadStationProtocol';
import { pasteboard } from '@kit.BasicServicesKit';
import { workbenchBytes } from '../workbench/WorkbenchPresentation';
import { WorkbenchMetrics, WorkbenchChoice, WorkbenchEmptyState, WorkbenchIconTile, WorkbenchInfoRow, WorkbenchNotice } from '../workbench/WorkbenchUi';

@ComponentV2
export struct DownloadStationPage {
  @Param model: NasExtensionsModel = new NasExtensionsModel();
  @Param scroller: Scroller = new Scroller();
  @Param visible: boolean = true;
  @Param refreshRevision: number = 0;
  @Param bottomInset: number = 16;
  @Event onChooseDirectory: () => void = (): void => {};
  @Event onAuthenticate: () => void = (): void => {};
  @Local private filter: string = 'all';
  @Local private creating: boolean = false;
  @Local private showingDetail: boolean = false;
  @Local private refreshing: boolean = false;
  @Local private supplementing: boolean = false;
  @Local private fileDetail: DownloadTaskFile | undefined = undefined;
  @Local private showingFile: boolean = false;
  private filterRevision: number = 0;
  private reachArmed: boolean = false;

  aboutToAppear(): void {
    this.creating = this.model.downloadFormRequested || this.model.downloadUri.length > 0;
    this.model.downloadFormRequested = false;
  }
  @Monitor('visible', 'model.downloadFormRequested')
  private restoreDownloadForm(): void {
    if (!this.visible) { this.filterRevision++; this.model.cancelDownloadAuthentication(); this.showingDetail = false; }
    if (this.visible && this.model.downloadFormRequested) {
      this.creating = true;
      this.model.downloadFormRequested = false;
    }
  }

  aboutToDisappear(): void { this.filterRevision++; this.model.cancelDownloadAuthentication(); this.model.closeDownloadDetail(); }

  @Monitor('showingDetail')
  private detailVisibilityChanged(): void {
    if (!this.showingDetail) { this.showingFile = false; this.model.closeDownloadDetail(); }
  }

  @Monitor('model.selectedDownload')
  private selectionChanged(): void { if (this.model.selectedDownload === undefined) { this.showingDetail = false; } }

  @Monitor('model.downloadsLoaded')
  private firstPageLoaded(): void { if (this.visible && this.filter !== 'all') { this.supplement(); } }

  @Monitor('refreshRevision')
  private refreshRequested(): void { if (this.visible) { this.refresh(); } }

  private selectFilter(filter: string): void {
    this.filter = filter; this.filterRevision++; this.reachArmed = false;
    if (filter !== 'all') { this.supplement(); }
  }

  /** 一次筛选最多补两页；布局触底不能续用这次预算。 */
  private async supplement(force: boolean = false): Promise<void> {
    if (this.supplementing || !this.visible) { return; }
    const revision = this.filterRevision;
    this.supplementing = true; this.reachArmed = false;
    try {
      for (let pages = 0; pages < 2 && this.model.downloadHasMore && (this.tasks().length < 6 || force && pages === 0); pages++) {
        if (!this.visible || revision !== this.filterRevision || !await this.model.loadMoreDownloads()) { break; }
      }
    } finally {
      this.supplementing = false;
      if (this.visible && revision !== this.filterRevision && this.filter !== 'all') { this.supplement(); }
    }
  }

  private async refresh(): Promise<void> {
    this.reachArmed = false;
    this.refreshing = true;
    try { if (await this.model.refreshDownloads() && this.filter !== 'all') { await this.supplement(); } }
    finally { this.refreshing = false; }
  }

  private async loadMore(): Promise<void> {
    this.reachArmed = false;
    if (this.filter === 'all') { await this.model.loadMoreDownloads(); }
    else { await this.supplement(true); }
  }

  private async paste(): Promise<void> {
    try { this.model.downloadUri = (await pasteboard.getSystemPasteboard().getData()).getPrimaryText(); this.model.clearTorrent(); }
    catch { this.model.downloadError = this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.task_paste_failed').id); }
  }

  private tasks(): DownloadTask[] {
    return this.model.downloads.filter((task: DownloadTask): boolean => downloadMatchesFilter(task, this.filter));
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
  private taskEnded(task: DownloadTask): boolean {
    return task.status === 'finished' || task.status === 'error';
  }
  private hasProgress(task: DownloadTask): boolean {
    return !this.taskEnded(task) && task.totalBytes !== undefined && task.totalBytes > 0 && task.downloadedBytes !== undefined;
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
    this.model.selectedDownload = task; this.showingDetail = true;
    await this.model.showDownload(task.id);
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

  private taskIcon(task: DownloadTask): Resource {
    switch (task.status) {
      case 'finished':
      case 'seeding':
        return $r('sys.symbol.checkmark');
      case 'paused':
        return $r('sys.symbol.pause');
      case 'error':
        return $r('sys.symbol.exclamationmark_triangle');
      default:
        return $r('sys.symbol.arrow_down');
    }
  }
  private taskIconColor(task: DownloadTask): ResourceColor {
    switch (task.status) {
      case 'finished':
      case 'seeding':
        return $r('sys.color.icon_emphasize');
      case 'error':
        return $r('app.color.workbench_danger');
      case 'paused':
        return $r('sys.color.icon_secondary');
      default:
        return $r('sys.color.icon_emphasize');
    }
  }
  private taskTileColor(task: DownloadTask): ResourceColor {
    switch (task.status) {
      case 'error':
        return $r('app.color.workbench_warning_surface');
      case 'paused':
        return $r('app.color.workbench_subtle');
      default:
        return $r('app.color.workbench_accent_surface');
    }
  }
  private statusColor(task: DownloadTask): ResourceColor {
    switch (task.status) {
      case 'downloading':
      case 'seeding':
        return $r('sys.color.font_emphasize');
      case 'error':
        return $r('app.color.workbench_danger');
      case 'paused':
        return $r('app.color.workbench_warning');
      default:
        return $r('sys.color.font_secondary');
    }
  }

  @Builder
  taskMenu(task: DownloadTask) {
    Menu() {
      MenuItem({ content: '移除任务' }).enabled(this.model.canWrite('nasDownloads'))
        .onClick((): void => { this.confirmRemove(task); })
    }
  }

  @Builder
  taskRow(task: DownloadTask) {
    Row({ space: 8 }) {
      Button() {
        Row({ space: 12 }) {
          WorkbenchIconTile({
            icon: this.taskIcon(task),
            iconSize: 20, tileSize: 40, tileRadius: 12,
            iconColor: this.taskIconColor(task),
            tileColor: this.taskTileColor(task)
          })
          Column({ space: 4 }) {
            Text(task.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
              .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.hasProgress(task)) {
              Progress({ value: this.progress(task), total: 100, type: ProgressType.Linear }).width('100%').height(4)
            }
            Row({ space: 8 }) {
              Text(this.bytes(task)).fontSize(12).fontColor($r('sys.color.font_secondary')).layoutWeight(1)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              if ((task.status === 'downloading' || task.status === 'seeding') && task.downloadBytesPerSecond !== undefined) {
                Text(this.rate(task)).fontSize(12).fontColor($r('sys.color.font_emphasize')).maxLines(1)
              }
              Text(this.statusText(task)).fontSize(12).fontColor(this.statusColor(task)).maxLines(1)
            }.width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding({ top: 10, bottom: 10, right: 4 })
      }.layoutWeight(1).type(ButtonType.Normal).backgroundColor(Color.Transparent).padding(0)
        .constraintSize({ minHeight: this.hasProgress(task) ? 64 : 56 }).onClick((): void => { this.openDetail(task); })
        .accessibilityText(task.title + '，' + this.statusText(task) + '，查看详情')
      if (this.canPause(task) || task.status === 'paused' || task.status === 'error') {
        Button() {
          SymbolGlyph(this.canPause(task) ? $r('sys.symbol.pause') : $r('sys.symbol.play')).fontSize(18)
            .fontColor([this.canPause(task) ? $r('sys.color.icon_emphasize') : $r('sys.color.brand')])
        }.width(44).height(44).type(ButtonType.Circle)
          .backgroundColor($r('app.color.workbench_subtle')).padding(0)
          .enabled(this.model.canWrite('nasDownloads')).accessibilityText(task.title + (this.canPause(task) ? '，暂停' : task.status === 'error' ? '，尝试继续' : '，继续'))
          .onClick((): void => { this.model.controlDownload(task.id, this.canPause(task) ? 'pause' : 'resume'); })
      }
      Button() { SymbolGlyph($r('sys.symbol.dot_grid_1x2')).fontSize(20).fontColor([$r('sys.color.icon_secondary')]) }
        .width(44).height(44).type(ButtonType.Circle)
        .backgroundColor(Color.Transparent).padding(0)
        .enabled(!this.model.busy).bindMenu(this.taskMenu(task)).accessibilityText(task.title + '，更多操作')
    }.width('100%').constraintSize({ minHeight: this.hasProgress(task) ? 96 : 72 }).padding({ left: 14, right: 8 })
      .borderRadius(16).backgroundColor($r('app.color.workbench_surface'))
  }

  @Builder
  createForm() {
    Column({ space: 12 }) {
      Row() {
        Text($r('app.string.task_link')).fontSize(16).fontColor($r('sys.color.font_primary')).layoutWeight(1)
        PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE })
          .onClick((_event: ClickEvent, result: PasteButtonOnClickResult): void => { if (result === PasteButtonOnClickResult.SUCCESS) { this.paste(); } })
      }.width('100%')
      TextInput({ text: this.model.downloadUri, placeholder: $r('app.string.task_link_placeholder') }).enabled(!this.model.busy)
        .onChange((value: string): void => { this.model.clearTorrent(); this.model.downloadUri = value; })
      Button($r('app.string.torrent_pick')).buttonStyle(ButtonStyleMode.TEXTUAL).height(48).enabled(!this.model.busy)
        .onClick((): void => { this.model.chooseTorrent(); })
      if (this.model.torrentName.length > 0) {
        Text($r('app.string.torrent_selected', this.model.torrentName)).fontSize(14).fontColor($r('sys.color.font_secondary'))
      }
      WorkbenchInfoRow({ label: $r('app.string.task_remote_directory'), value: this.model.downloadDestination.length === 0 ? '尚未选择' : '/' + this.model.downloadDestination })
      if (this.model.downloadFreeBytes !== undefined) {
        WorkbenchInfoRow({ label: $r('app.string.download_free_space'), value: workbenchBytes(this.model.downloadFreeBytes) })
      }
      WorkbenchNotice({ text: this.model.downloadSpaceError, warning: true })
      Button($r('app.string.task_choose_directory')).buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 48 }).enabled(!this.model.busy)
        .onClick((): void => { this.creating = false; this.onChooseDirectory(); })
      ExtensionStatusPanel({ model: this.model, feature: 'nasDownloads' })
      if (this.model.downloadAuthenticationRequired) { this.authenticationForm() }
      if (!this.model.canCreateDownload) {
        WorkbenchNotice({ text: '当前无法在此 NAS 创建下载任务，可查看和管理已有任务。', warning: true })
      }
      Button($r('app.string.task_remote_create')).width('100%').constraintSize({ minHeight: 48 })
        .enabled(this.model.canCreateDownload && this.model.canWrite('nasDownloads') && (this.model.downloadUri.trim().length > 0 || this.model.torrentName.length > 0) &&
          this.model.downloadDestination.length > 0).onClick((): void => { this.confirmCreate(); })
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
  }

  @Builder
  authenticationForm() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        WorkbenchIconTile({
          icon: $r('sys.symbol.lock'),
          iconSize: 20, tileSize: 40, tileRadius: 12,
          iconColor: $r('app.color.workbench_warning'),
          tileColor: $r('app.color.workbench_warning_surface')
        })
        Column({ space: 2 }) {
          Text('需要验证 NAS 账号密码').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
          Text('执行此操作需要重新验证当前 DSM 账户凭据').fontSize(12).fontColor($r('sys.color.font_secondary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      TextInput({ text: this.model.downloadPassword, placeholder: $r('app.string.download_password') })
        .type(InputType.Password).height(48).borderRadius(12).enabled(!this.model.busy)
        .onChange((value: string): void => { this.model.downloadPassword = value; })
        .accessibilityText($r('app.string.download_password'))
      if (this.model.downloadNeedsOtp) {
        TextInput({ text: this.model.downloadOtp, placeholder: $r('app.string.download_otp') })
          .type(InputType.Number).height(48).borderRadius(12).enabled(!this.model.busy)
          .onChange((value: string): void => { this.model.downloadOtp = value; })
          .accessibilityText($r('app.string.download_otp'))
      }
      Row({ space: 12 }) {
        Button($r('app.string.action_cancel')).buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 44 }).layoutWeight(1)
          .onClick((): void => { this.model.cancelDownloadAuthentication(); })
        Button($r('app.string.download_authenticate')).constraintSize({ minHeight: 44 }).layoutWeight(1)
          .enabled(!this.model.busy && this.model.downloadPassword.length > 0)
          .onClick((): void => { this.onAuthenticate(); })
      }.width('100%')
    }.width('100%').padding(16).borderRadius(WorkbenchMetrics.cardRadius)
      .backgroundColor($r('app.color.workbench_surface'))
  }

  @Builder
  detail() {
    Scroll() {
      Column({ space: 8 }) {
        if (this.model.selectedDownload !== undefined) {
          WorkbenchInfoRow({ label: '任务', value: this.model.selectedDownload.title })
          WorkbenchInfoRow({ label: '状态', value: this.statusText(this.model.selectedDownload) })
          WorkbenchInfoRow({ label: '下载大小', value: this.bytes(this.model.selectedDownload) })
          WorkbenchInfoRow({ label: $r('app.string.task_download_rate'), value: this.rate(this.model.selectedDownload) })
          WorkbenchInfoRow({ label: $r('app.string.task_upload_rate'), value: this.model.selectedDownload.uploadBytesPerSecond === undefined ? '未提供' :
            workbenchBytes(this.model.selectedDownload.uploadBytesPerSecond) + '/s' })
          WorkbenchInfoRow({ label: 'NAS 目录', value: this.model.selectedDownload.destination ?? '未提供' })
          WorkbenchNotice({ text: this.model.selectedDownload.errorMessage ?? '', warning: true })
          if (this.model.downloadDetailLoading) { LoadingProgress().width(24).height(24) }
          WorkbenchNotice({ text: this.model.downloadDetailError, warning: true })
          Button($r('app.string.task_detail_refresh')).buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 44 })
            .enabled(!this.model.busy).onClick((): void => { this.model.showDownload(this.model.selectedDownload!.id); })
          ForEach(this.model.selectedDownload.files ?? [], (file: DownloadTaskFile): void => {
            Row({ space: 8 }) {
              Text(file.name).fontSize(16).fontColor($r('sys.color.font_primary')).layoutWeight(1).maxLines(1)
                .textOverflow({ overflow: TextOverflow.MARQUEE })
              Button() { SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(22).fontColor([$r('sys.color.icon_secondary')]) }
                .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText($r('app.string.task_file_details'))
                .onClick((): void => { this.fileDetail = file; this.showingFile = true; })
            }.width('100%')
          }, (file: DownloadTaskFile): string => file.name)
          Flex({ wrap: FlexWrap.Wrap }) {
            Button($r('app.string.task_remote_remove')).constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.NORMAL)
              .enabled(this.model.canWrite('nasDownloads')).onClick((): void => { this.confirmRemove(this.model.selectedDownload!); })
            if (this.canPause(this.model.selectedDownload) || ['paused', 'error'].includes(this.model.selectedDownload.status)) {
              Button(this.canPause(this.model.selectedDownload) ? $r('app.string.task_pause') : this.model.selectedDownload.status === 'error' ?
                $r('app.string.task_try_resume') : $r('app.string.task_resume')).constraintSize({ minHeight: 48 })
                .enabled(this.model.canWrite('nasDownloads')).onClick((): void => { const task = this.model.selectedDownload!;
                  this.model.controlDownload(task.id, this.canPause(task) ? 'pause' : 'resume'); })
            }
          }.width('100%')
        }
      }.width('100%').padding(16)
    }.width('100%').height('100%')
  }

  @Builder
  fileInformation() {
    Column({ space: 12 }) {
      if (this.fileDetail !== undefined) {
        WorkbenchInfoRow({ label: $r('app.string.task_name'), value: this.fileDetail.name })
        WorkbenchInfoRow({ label: $r('app.string.file_info_size'), value: workbenchBytes(this.fileDetail.totalBytes) })
        WorkbenchInfoRow({ label: $r('app.string.task_download_size'), value: workbenchBytes(this.fileDetail.downloadedBytes) })
        WorkbenchInfoRow({ label: $r('app.string.task_path'), value: (this.model.selectedDownload?.destination ?? '') + '/' + this.fileDetail.name })
      }
    }.width('100%').padding(24)
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        ForEach(['all', 'active', 'finished'], (filter: string): void => {
          WorkbenchChoice({ label: this.getUIContext().getHostContext()!.resourceManager.getStringSync((filter === 'all' ?
            $r('app.string.task_all') : filter === 'active' ? $r('app.string.task_active') : $r('app.string.task_downloaded')).id),
            selected: this.filter === filter, onSelect: (): void => { this.selectFilter(filter); } })
        }, (filter: string): string => filter)
      }.width('100%').padding({ top: 4, bottom: 8 })
        .bindSheet($$this.showingFile, this.fileInformation(), {
          height: SheetSize.FIT_CONTENT, showClose: true, title: { title: $r('app.string.task_file_details') },
          backgroundColor: $r('app.color.workbench_surface_elevated')
        })
      Refresh({ refreshing: $$this.refreshing }) {
        List({ space: 8, scroller: this.scroller }) {
          ListItem() {
            Column({ space: 12 }) {
              ExtensionStatusPanel({ model: this.model, feature: 'nasDownloads' })
              if (this.model.downloadAuthenticationRequired) { this.authenticationForm() }
            }.width('100%')
          }
          Repeat<DownloadTask>(this.tasks()).each((entry: RepeatItem<DownloadTask>): void => {
            ListItem() { this.taskRow(entry.item) }
          }).key((task: DownloadTask): string => task.id).virtualScroll()
          ListItem() {
            Column({ space: 12 }) {
              WorkbenchNotice({ text: this.model.downloadListError, warning: true })
              if (this.model.downloadsLoading || this.supplementing) {
                LoadingProgress().width(32).height(32).accessibilityText($r('app.string.task_remote_loading'))
              } else if (this.model.downloadListError.length > 0 || !this.model.downloadsLoaded) {
                Button($r('app.string.task_retry_loading')).buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 48 })
                  .enabled(!this.model.busy).onClick((): void => { if (this.model.downloadRetryAppend) { this.loadMore(); } else { this.refresh(); } })
              } else if (this.model.downloadsLoaded && this.model.downloadTotal === 0) {
                WorkbenchEmptyState({
                  icon: $r('sys.symbol.arrow_down_circle'),
                  title: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.task_remote_empty').id),
                  description: '点击右上角加号可向 NAS 提交 HTTP、FTP 或磁力链接下载任务。'
                })
              } else if (this.tasks().length === 0 && this.model.downloadsLoaded) {
                WorkbenchEmptyState({
                  icon: $r('sys.symbol.arrow_down_circle'),
                  title: this.model.downloadHasMore || this.model.downloadListChanged ?
                    this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.task_loaded').id, this.model.downloads.length) :
                    this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.task_remote_no_match').id)
                })
              }
              if (this.model.downloadHasMore && !this.model.downloadsLoading && !this.supplementing) {
                Button($r('app.string.task_continue_loading')).constraintSize({ minHeight: 48 }).enabled(!this.model.busy)
                  .onClick((): void => { this.loadMore(); })
              }
              if (this.filter !== 'all' && this.tasks().length === 0) {
                Button($r('app.string.task_view_all')).buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 48 })
                  .onClick((): void => { this.selectFilter('all'); })
              }
            }.width('100%').padding(24)
          }
        }.width('100%').height('100%').scrollBar(BarState.Auto).contentEndOffset(this.bottomInset)
          .onScrollStart((): void => { if (!this.model.downloadsLoading && !this.supplementing) { this.reachArmed = true; } })
          .onReachEnd((): void => { if (this.reachArmed && !this.model.busy && this.visible) { this.loadMore(); } })
      }.width('100%').layoutWeight(1).onRefreshing((): void => { this.refresh(); })
        .bindSheet($$this.showingDetail, this.detail(), {
          height: SheetSize.LARGE, showClose: true, title: { title: $r('app.string.task_details') },
          backgroundColor: $r('app.color.workbench_surface_elevated')
        })
    }.width('100%').height('100%').constraintSize({ maxWidth: 960 }).padding({ left: 16, right: 16 })
      .backgroundColor($r('app.color.workbench_background'))
      .bindSheet($$this.creating, this.createForm(), {
        height: SheetSize.FIT_CONTENT, showClose: true, title: { title: $r('app.string.task_remote_create') },
        keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL,
        backgroundColor: $r('app.color.workbench_surface_elevated')
      })
  }
}
