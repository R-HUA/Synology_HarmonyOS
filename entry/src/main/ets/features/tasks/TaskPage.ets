import { ConnectionViewModel, FileTaskItem } from '../connection/ConnectionViewModel';
import { TaskFilter, TaskGroup, TaskRecordView, taskRecords, taskMatchesFilter, taskEnded } from '../../core/domain/TaskPresentation';
import { TransferQueueItem } from '../../core/domain/TransferQueueState';
import { DriveTransferRecord } from '../../core/domain/DriveTransferState';
import { DriveActionRecord } from '../../core/domain/DriveActionState';
import { NasFailure } from '../../core/domain/DsmProtocol';
import { TaskPageState } from './TaskPageState';
import { TaskRecordRow } from './TaskRecordRow';
import { DriveTransferCard } from '../drive/DriveTransferUi';
import { DriveActionCard } from '../drive/DriveActionUi';
import { WorkbenchChoice, WorkbenchEmptyState, WorkbenchInfoRow, WorkbenchNotice, WorkbenchActionRow, WorkbenchMetrics } from '../workbench/WorkbenchUi';
import { workbenchBytes } from '../workbench/WorkbenchPresentation';
import { supportsPhotoBackup } from '../workbench/ModuleNavigation';
import { HdsTabs } from '@kit.UIDesignKit';

type TaskCategory = TaskGroup | 'other';
interface TaskListEntry { key: string; group: TaskGroup; filter?: TaskFilter; record?: TaskRecordView; groupEnd?: boolean; }

@ComponentV2
export struct TaskPage {
  @Require @Param model: ConnectionViewModel;
  @Require @Param state: TaskPageState;
  @Param scroller: Scroller = new Scroller();
  @Param rootScrollers: Scroller[] = [];
  @Param topInset: number = 0;
  @Param bottomInset: number = 16;
  @Param wide: boolean = false;
  @Event onAllTasks: () => void = (): void => {};
  @Event onRemoteDownloads: () => void = (): void => {};
  @Event onPhotoBackup: () => void = (): void => {};
  @Event onDriveFiles: () => void = (): void => {};
  @Event onOverlay: (visible: boolean) => void = (): void => {};
  @Local private detailVisible: boolean = false;
  @Local private selectedKey: string = '';
  @Local private clearVisible: boolean = false;
  @Local private clearRecords: TaskRecordView[] = [];
  @Local private deleteLocalFiles: boolean = false;
  @Local private clearing: boolean = false;
  @Local private feedback: string = '';
  @Local private clearScope: string = '';
  @Local private refreshing: boolean = false;
  private categories: TaskCategory[] = ['download', 'upload', 'processing', 'other'];

  @Computed
  get records(): TaskRecordView[] {
    return taskRecords(this.state.scope, this.model.queue.items, this.model.driveTransfers.items, this.model.fileTasks, this.model.driveActions.items);
  }
  @Computed
  get entries(): TaskListEntry[] {
    if (this.state.scope === 'root') {
      const category = this.categories[this.state.categoryIndex];
      return category === 'other' ? [] : this.rootEntries(category);
    }
    const entries: TaskListEntry[] = [];
    for (const group of ['download', 'upload', 'processing'] as TaskGroup[]) {
      const records = this.records.filter((item: TaskRecordView): boolean => item.group === group && taskMatchesFilter(item, this.state.filter));
      if (records.length === 0 && this.groupReady(group) && this.groupError(group).length === 0) { continue; }
      entries.push({ key: 'header:' + group, group });
      records.forEach((record: TaskRecordView): void => { entries.push({ key: record.key, group, record }); });
    }
    return entries;
  }

  /** 类型页内按业务结束状态分区，数量和清理范围共用同一组记录。 */
  private rootEntries(group: TaskGroup): TaskListEntry[] {
    const entries: TaskListEntry[] = [];
    const filters: TaskFilter[] = group === 'processing' ? ['all'] : ['active', 'finished'];
    for (const filter of filters) {
      const records = this.groupRecords(group, filter);
      if (records.length === 0 && this.groupReady(group) && this.groupError(group).length === 0) { continue; }
      entries.push({ key: 'header:' + group + ':' + filter, group, filter, groupEnd: records.length === 0 });
      records.forEach((record: TaskRecordView, index: number): void => {
        entries.push({ key: record.key, group, record, groupEnd: index === records.length - 1 });
      });
    }
    return entries;
  }
  private groupRecords(group: TaskGroup, filter: TaskFilter): TaskRecordView[] {
    return this.records.filter((record: TaskRecordView): boolean => record.group === group && taskMatchesFilter(record, filter));
  }

  @Computed
  get loadError(): string { return this.groupError('download') || this.groupError('processing'); }

  aboutToAppear(): void { this.locate(); }
  aboutToDisappear(): void { this.onOverlay(false); }
  @Monitor('detailVisible', 'clearVisible')
  private overlayChanged(): void { this.onOverlay(this.detailVisible || this.clearVisible); }
  @Monitor('state.focusRevision')
  private locate(): void {
    if (this.state.focusKey.length === 0) { return; }
    const key = this.state.focusKey;
    setTimeout((): void => {
      const index = this.entries.findIndex((entry: TaskListEntry): boolean => entry.key === key);
      if (index >= 0) { this.scroller.scrollToIndex(index, true, ScrollAlign.CENTER); }
    }, 0);
  }
  private toast(text: string): void { this.getUIContext().getPromptAction().showToast({ message: text }); }
  private text(resource: Resource): string { return this.getUIContext().getHostContext()!.resourceManager.getStringSync(resource.id); }
  private groupTitle(group: TaskGroup): Resource {
    return group === 'download' ? $r('app.string.task_downloads') : group === 'upload' ? $r('app.string.task_uploads') : $r('app.string.task_processing');
  }
  private groupReady(group: TaskGroup): boolean {
    const scope = this.state.scope;
    if (group === 'processing') {
      return (scope === 'drive' || scope === 'photos' || this.model.fileTasksReady) &&
        (scope === 'files' || scope === 'photos' || this.model.driveActions.ready);
    }
    return (scope === 'drive' || this.model.queue.ready) &&
      (scope === 'files' || scope === 'photos' || this.model.driveTransfers.ready);
  }
  private groupError(group: TaskGroup): string {
    const scope = this.state.scope;
    if (group === 'processing') {
      return (scope === 'root' || scope === 'files' ? this.model.fileTasksErrorText : '') ||
        (scope === 'root' || scope === 'drive' ? this.model.driveActions.errorText : '');
    }
    return (scope !== 'drive' ? this.model.queue.errorText : '') ||
      (scope === 'root' || scope === 'drive' ? this.model.driveTransfers.errorText : '');
  }
  private countsReady(): boolean { return this.groupReady('download') && this.groupReady('upload') && this.groupReady('processing'); }
  private filterLabel(filter: TaskFilter): string {
    const title = this.text(filter === 'all' ? $r('app.string.task_all') : filter === 'active' ? $r('app.string.task_active') : $r('app.string.task_finished'));
    return title + (this.countsReady() && (['download', 'upload', 'processing'] as TaskGroup[]).every((group: TaskGroup): boolean => this.groupError(group).length === 0) ?
      ' ' + this.records.filter((record: TaskRecordView): boolean => taskMatchesFilter(record, filter)).length.toString() : '');
  }
  private selected(): TaskRecordView | undefined { return this.records.find((record: TaskRecordView): boolean => record.key === this.selectedKey); }
  private transfer(record: TaskRecordView): TransferQueueItem { return this.model.queue.items.find((item: TransferQueueItem): boolean => item.id === record.id)!; }
  private driveTransfer(record: TaskRecordView): DriveTransferRecord { return this.model.driveTransfers.items.find((item: DriveTransferRecord): boolean => item.id === record.id)!; }
  private file(record: TaskRecordView): FileTaskItem { return this.model.fileTasks.find((item: FileTaskItem): boolean => item.id === record.id)!; }
  private driveAction(record: TaskRecordView): DriveActionRecord { return this.model.driveActions.items.find((item: DriveActionRecord): boolean => item.id === record.id)!; }
  private canCancel(record: TaskRecordView): boolean {
    if (record.model === 'transfer') { return this.transfer(record).canCancel; }
    if (record.model !== 'driveTransfer') { return false; }
    const item = this.driveTransfer(record);
    return this.model.driveTransfers.activeId === item.id || (item.background !== undefined || item.state === 'paused') &&
      ['preparing', 'creating', 'running', 'waiting', 'paused'].includes(item.state);
  }
  private canPause(record: TaskRecordView): boolean {
    if (record.model === 'transfer') { return this.transfer(record).canPause === true; }
    if (record.model !== 'driveTransfer') { return false; }
    const item = this.driveTransfer(record);
    return item.direction === 'upload' && item.state === 'running' && item.uploadSession !== undefined;
  }
  private canResume(record: TaskRecordView): boolean {
    if (record.model === 'transfer') { return this.transfer(record).canResume === true; }
    if (record.model !== 'driveTransfer') { return false; }
    const item = this.driveTransfer(record);
    return item.direction === 'upload' && item.state === 'paused' && (item.uploadSession !== undefined || item.background?.startAttempted === false);
  }
  private actionsAvailable(record: TaskRecordView): boolean {
    if (this.clearing || this.model.busy) { return false; }
    return record.model === 'transfer' ? !this.model.queue.busy : record.model === 'driveTransfer' ?
      !this.model.driveTransfers.busy || this.model.driveTransfers.activeId === record.id : !this.model.driveActions.busy;
  }
  private async runQueue(work: () => Promise<void>): Promise<void> {
    this.feedback = '';
    try { await work(); }
    catch (error) { this.feedback = error instanceof NasFailure ? error.message : this.text($r('app.string.task_operation_failed')); }
  }
  private cancel(record: TaskRecordView): void {
    this.getUIContext().showAlertDialog({ title: $r('app.string.task_cancel'), message: record.name,
      primaryButton: { value: $r('app.string.action_cancel'), action: (): void => {} },
      secondaryButton: { value: $r('app.string.task_confirm_cancel'), action: (): void => {
        if (record.model === 'transfer') { this.runQueue(async (): Promise<void> => { await this.model.queue.cancel(record.id); }); }
        else { this.model.driveTransfers.cancelTask(record.id); }
      } } });
  }
  private pause(record: TaskRecordView): void {
    if (record.model === 'transfer' && (this.canPause(record) || this.canResume(record))) {
      this.runQueue(async (): Promise<void> => { await this.model.queue.setPaused(record.id, this.canPause(record)); });
    } else if (this.canPause(record)) { this.model.driveTransfers.pause(record.id); }
    else if (this.canResume(record)) { this.model.driveTransfers.resume(record.id); }
    else { this.selectedKey = record.key; this.detailVisible = true; }
  }

  private async controlGroup(group: TaskGroup, paused: boolean): Promise<void> {
    this.feedback = '';
    for (const record of this.records.filter((item: TaskRecordView): boolean => item.group === group && (paused ? this.canPause(item) : this.canResume(item)))) {
      if (record.model === 'transfer') {
        try { await this.model.queue.setPaused(record.id, paused); }
        catch (error) { this.feedback = (error as Error).message; return; }
      }
      else if (paused) { await this.model.driveTransfers.pause(record.id); }
      else { await this.model.driveTransfers.resume(record.id); }
      if (record.model === 'driveTransfer' && this.model.driveTransfers.errorText.length > 0) {
        this.feedback = this.model.driveTransfers.errorText; return;
      }
    }
  }
  private prepareClear(records: TaskRecordView[], selectedFilter: TaskFilter = this.state.filter): void {
    const scope = this.state.scope === 'files' ? $r('app.string.task_file_title') : this.state.scope === 'photos' ?
      $r('app.string.task_photo_title') : this.state.scope === 'drive' ? $r('app.string.task_drive_title') : $r('app.string.task_all_tasks');
    const filter = selectedFilter === 'all' ? $r('app.string.task_all') : selectedFilter === 'active' ?
      $r('app.string.task_active') : $r('app.string.task_finished');
    this.clearScope = this.text(scope) + ' · ' + this.text(filter) + ' · ' + this.text(this.groupTitle(records[0].group));
    this.clearRecords = records.slice(); this.deleteLocalFiles = false; this.clearVisible = true;
  }
  /** 确认框中的标识集合冻结；每一项仍由业务模型重新检查可移除条件。 */
  private async clear(): Promise<void> {
    const records = this.clearRecords.slice();
    const generation = this.model.sessionGeneration;
    this.clearing = true;
    let count = 0;
    try {
      for (const record of records) {
        if (generation !== this.model.sessionGeneration || !this.model.authenticated) { throw new Error(this.text($r('app.string.task_account_changed'))); }
        const current = this.records.find((item: TaskRecordView): boolean => item.key === record.key);
        if (current === undefined || !current.canRemove) { throw new Error(this.text($r('app.string.task_no_longer_removable'))); }
        let removed = true;
        if (record.model === 'transfer') { await this.model.queue.removeRecord(record.id, this.deleteLocalFiles); }
        else if (record.model === 'driveTransfer') { removed = await this.model.driveTransfers.remove(record.id, this.deleteLocalFiles); }
        else if (record.model === 'file') { removed = await this.model.removeFileTask(record.id); }
        else { removed = await this.model.driveActions.remove(record.id); }
        if (!removed) { throw new Error(this.groupError(record.group) || this.text($r('app.string.task_operation_failed'))); }
        count++;
      }
      this.feedback = this.text($r('app.string.task_cleared')) + ' ' + count.toString();
    } catch (error) {
      this.feedback = this.text($r('app.string.task_cleared')) + ' ' + count.toString() + '，' + (error as Error).message;
    } finally { this.clearing = false; this.clearVisible = false; this.toast(this.feedback); }
  }
  private async refresh(): Promise<void> {
    const generation = this.model.sessionGeneration;
    if (this.state.scope !== 'drive') { await this.runQueue(async (): Promise<void> => { await this.model.queue.reconcile(); }); }
    if (generation !== this.model.sessionGeneration) { return; }
    if (this.state.scope === 'root' || this.state.scope === 'files') {
      if (!this.model.fileTasksReady) { await this.model.reloadFileTasks(); }
      if (generation !== this.model.sessionGeneration) { return; }
      for (const item of this.model.fileTasks.filter((item: FileTaskItem): boolean => item.state === 'pending' || item.state === 'unknown')) {
        await this.model.checkFileTask(item.id);
        if (generation !== this.model.sessionGeneration) { return; }
      }
    }
    if (this.state.scope === 'root' || this.state.scope === 'drive') {
      if (!this.model.driveTransfers.ready) { await this.model.driveTransfers.reload(); }
      else { await this.model.driveTransfers.refresh(); }
      if (generation !== this.model.sessionGeneration) { return; }
      if (!this.model.driveActions.ready) { await this.model.driveActions.reload(); }
      if (generation !== this.model.sessionGeneration) { return; }
      for (const item of this.model.driveActions.items.filter((item: DriveActionRecord): boolean => item.state === 'accepted')) {
        await this.model.driveActions.refresh(item.id);
        if (generation !== this.model.sessionGeneration) { return; }
      }
    }
  }
  private async refreshRoot(): Promise<void> {
    try { await this.refresh(); }
    finally { this.refreshing = false; }
  }

  @Builder
  groupHeader(group: TaskGroup, filter: TaskFilter = this.state.filter) {
    Column({ space: 8 }) {
      Row() {
        Text((this.state.scope === 'root' && filter !== 'all' ? this.text(filter === 'active' ? $r('app.string.task_active') : $r('app.string.task_finished')) : this.text(this.groupTitle(group))) +
          (this.state.scope === 'root' && this.groupReady(group) && this.groupError(group).length === 0 ? ' ' + this.groupRecords(group, filter).length.toString() : ''))
          .fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).layoutWeight(1)
        if (filter !== 'active' && this.records.some((item: TaskRecordView): boolean => item.group === group && taskEnded(item.state) && item.canRemove && taskMatchesFilter(item, filter))) {
          Button($r('app.string.task_clear_records')).fontSize(13).buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 44 })
            .enabled(!this.clearing).onClick((): void => { this.prepareClear(this.records.filter((item: TaskRecordView): boolean =>
              item.group === group && taskEnded(item.state) && item.canRemove && taskMatchesFilter(item, filter)), filter); })
        }
      }.width('100%')
      if (filter !== 'finished' && this.records.some((item: TaskRecordView): boolean => item.group === group && (this.canPause(item) || this.canResume(item)))) {
        Row({ space: 8 }) {
          Button($r('app.string.task_pause_all')).buttonStyle(ButtonStyleMode.TEXTUAL).height(48)
            .enabled(!this.model.queue.busy).onClick((): void => { this.controlGroup(group, true); })
          Button($r('app.string.task_resume_all')).buttonStyle(ButtonStyleMode.TEXTUAL).height(48)
            .enabled(!this.model.queue.busy).onClick((): void => { this.controlGroup(group, false); })
        }.width('100%')
      }
      if (!this.groupReady(group) && this.groupError(group).length === 0) {
        WorkbenchNotice({ text: this.text($r('app.string.task_records_loading')) })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .padding(this.state.scope === 'root' ? { left: 16, right: 16, top: 12, bottom: 8 } : 0)
  }
  @Builder
  taskRow(entry: TaskListEntry) {
    Column() {
      TaskRecordRow({ record: entry.record!, focused: this.state.focusKey === entry.key,
        canCancel: this.canCancel(entry.record!), canPause: this.canPause(entry.record!), canResume: this.canResume(entry.record!),
        actionsEnabled: this.actionsAvailable(entry.record!),
        canRetry: entry.record!.model === 'transfer' && this.transfer(entry.record!).canRetry,
        onRetry: (): void => { this.runQueue(async (): Promise<void> => { await this.model.queue.retry(entry.record!.id); }); },
        onDetail: (): void => { this.selectedKey = entry.key; this.detailVisible = true; },
        onCancel: (): void => { this.cancel(entry.record!); }, onPause: (): void => { this.pause(entry.record!); } })
      if (this.state.scope === 'root' && !entry.groupEnd) {
        Divider().color($r('app.color.workbench_divider')).margin({ left: 68, right: 16 })
      }
    }.width('100%')
  }
  @Builder
  otherCategoryCard() {
    Column() {
      WorkbenchActionRow({
        label: this.text($r('app.string.task_remote_download')),
        description: this.model.extensions.downloadsLoaded ?
          this.text($r('app.string.home_loaded_downloads', this.model.extensions.downloads.filter((task): boolean =>
            !['finished', 'error', 'paused'].includes(task.status)).length)) :
          '查看或创建 NAS Download Station 离线下载任务',
        icon: $r('sys.symbol.arrow_down_circle'),
        onAction: this.onRemoteDownloads
      })
      if (supportsPhotoBackup((api: string): boolean => this.model.supports(api))) {
        Divider().color($r('app.color.workbench_divider')).margin({ left: 68, right: 16 })
        WorkbenchActionRow({
          label: this.text($r('app.string.photos_album_backup')),
          description: this.model.photoBackup.settings.enabled ?
            (this.model.photoBackup.status.length > 0 ? this.model.photoBackup.status : '已开启自动相册备份') :
            '管理本机照片与视频的自动备份策略',
          icon: $r('sys.symbol.arrow_up_circle'),
          onAction: this.onPhotoBackup
        })
      }
    }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true)
      .backgroundColor($r('app.color.workbench_surface'))
  }
  @Builder
  wideTaskColumn(group: TaskGroup, filter: TaskFilter) {
    List() {
      ListItem() { this.groupHeader(group, filter) }
      if (this.groupError(group).length > 0) {
        ListItem() { WorkbenchNotice({ text: this.groupError(group), warning: true }) }
      } else if (this.groupReady(group) && this.groupRecords(group, filter).length === 0) {
        ListItem() {
          WorkbenchEmptyState({ icon: $r('sys.symbol.clock'), title: this.text($r('app.string.task_empty')),
            description: this.text(filter === 'active' ? $r('app.string.task_empty_active') : $r('app.string.task_empty_finished')) })
        }
      }
      ForEach(this.groupRecords(group, filter), (record: TaskRecordView): void => {
        ListItem() { this.taskRow({ key: record.key, group, record }) }
      }, (record: TaskRecordView): string => record.key)
    }.layoutWeight(1).height('100%').contentEndOffset(this.bottomInset)
      .backgroundColor($r('app.color.workbench_surface')).borderRadius(16).clip(true)
  }
  @Builder
  rootList(category: TaskCategory, index: number) {
    if (this.wide && category !== 'other') {
      Refresh({ refreshing: $$this.refreshing }) {
      Row({ space: 16 }) {
        this.wideTaskColumn(category, 'active')
        this.wideTaskColumn(category, 'finished')
      }.width('100%').height('100%').padding({ left: 24, right: 24, top: 12 })
      }.width('100%').height('100%').onRefreshing((): void => { this.refreshRoot(); })
    } else {
    Refresh({ refreshing: $$this.refreshing }) {
      List({ scroller: this.rootScrollers[index] }) {
        if (category === 'other') {
          ListItem() {
            this.otherCategoryCard()
          }.margin({ top: 12 })
        } else {
          if (this.groupError(category).length > 0) {
            ListItem() { WorkbenchNotice({ text: this.groupError(category), warning: true }) }
          }
          Repeat<TaskListEntry>(this.rootEntries(category)).each((entry: RepeatItem<TaskListEntry>): void => {
            ListItem() {
              if (entry.item.record === undefined) { this.groupHeader(entry.item.group, entry.item.filter!) }
              else { this.taskRow(entry.item) }
            }.margin({ top: entry.item.record === undefined ? 12 : 0 })
              .borderRadius({ topLeft: entry.item.record === undefined ? WorkbenchMetrics.cardRadius : 0,
                topRight: entry.item.record === undefined ? WorkbenchMetrics.cardRadius : 0,
                bottomLeft: entry.item.groupEnd ? WorkbenchMetrics.cardRadius : 0,
                bottomRight: entry.item.groupEnd ? WorkbenchMetrics.cardRadius : 0 })
              .backgroundColor($r('app.color.workbench_surface')).clip(true)
          }).key((entry: TaskListEntry): string => entry.key).virtualScroll()
          if (this.rootEntries(category).length === 0) {
            ListItem() {
              WorkbenchEmptyState({
                icon: category === 'download' ? $r('sys.symbol.arrow_down_circle') :
                  category === 'upload' ? $r('sys.symbol.arrow_up_circle') : $r('sys.symbol.clock'),
                title: this.text($r('app.string.task_empty')),
                description: '当前分类下没有正在进行或已结束的任务记录。'
              })
            }
          }
        }
      }.width('100%').height('100%').scrollBar(BarState.Auto).contentEndOffset(this.bottomInset)
        .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin })
    }.width('100%').height('100%').backgroundColor($r('app.color.workbench_background'))
      .onRefreshing((): void => { this.refreshRoot(); })
    }
  }
  @Builder
  rootPage() {
    HdsTabs({ index: this.state.categoryIndex }) {
      ForEach(this.categories, (category: TaskCategory, index: number): void => {
        TabContent() { this.rootList(category, index) }
          .tabBar(SubTabBarStyle.of(category === 'other' ? $r('app.string.task_other') : this.groupTitle(category))
            .indicator({ color: $r('sys.color.icon_emphasize'), width: 20, height: 3, borderRadius: 2 })
            .labelStyle({ font: { size: 16 }, selectedColor: $r('sys.color.font_emphasize'), unselectedColor: $r('sys.color.font_primary') }))
      }, (category: TaskCategory): string => category)
    }.width('100%').layoutWeight(1).barPosition(BarPosition.Start).barHeight(52)
      .barMode(BarMode.Scrollable, { nonScrollableLayoutStyle: LayoutStyle.ALWAYS_AVERAGE_SPLIT }).scrollable(true)
      .onContentWillChange((): boolean => !this.model.sessionTransition && !this.detailVisible && !this.clearVisible)
      .animationDuration(300).onChange((index: number): void => { this.state.categoryIndex = index; })
  }
  @Builder
  queueActions(record: TaskRecordView) {
    Flex({ wrap: FlexWrap.Wrap }) {
      if (this.transfer(record).canRetry) {
        Button($r('app.string.task_retry')).constraintSize({ minHeight: 44 }).onClick((): void => { this.runQueue(async (): Promise<void> => { await this.model.queue.retry(record.id); }); })
      }
      if (record.state === 'unknown') {
        Button($r('app.string.task_check')).constraintSize({ minHeight: 44 }).onClick((): void => { this.runQueue(async (): Promise<void> => { await this.model.queue.reconcile(); }); })
      }
      if (this.transfer(record).canExport) {
        Button($r('app.string.task_save')).constraintSize({ minHeight: 44 }).onClick((): void => { this.runQueue(async (): Promise<void> => {
          if (await this.model.queue.exportDownload(record.id)) { this.toast(this.text($r('app.string.task_saved'))); }
        }); })
      }
      if (this.transfer(record).canClose) {
        Button($r('app.string.task_close_checked')).constraintSize({ minHeight: 44 }).onClick((): void => {
          this.getUIContext().showAlertDialog({ title: $r('app.string.task_close_checked'), message: $r('app.string.task_check_upload'),
            primaryButton: { value: $r('app.string.action_cancel'), action: (): void => {} },
            secondaryButton: { value: $r('app.string.task_close_checked'), action: (): void => { this.runQueue(async (): Promise<void> => { await this.model.queue.closeUnknownUpload(record.id); }); } } });
        })
      }
    }.width('100%').enabled(this.actionsAvailable(record))
  }
  @Builder
  detail(record: TaskRecordView) {
    if (record.model === 'driveTransfer') { DriveTransferCard({ model: this.model.driveTransfers, item: this.driveTransfer(record), detailsOnly: true }) }
    else if (record.model === 'driveAction') { DriveActionCard({ model: this.model.driveActions, item: this.driveAction(record),
      onFiles: (): void => { this.detailVisible = false; this.onDriveFiles(); } }) }
    else {
      Scroll() {
        Column({ space: 12 }) {
          WorkbenchInfoRow({ label: $r('app.string.task_name'), value: record.name })
          WorkbenchInfoRow({ label: $r('app.string.task_status'), value: record.stateText })
          WorkbenchInfoRow({ label: $r('app.string.task_path'), value: record.model === 'transfer' && record.group === 'download' ? this.model.queue.downloadLocalPath(record.id) : record.path })
          if (record.model === 'transfer') {
            WorkbenchInfoRow({ label: $r('app.string.file_info_size'), value: workbenchBytes(record.bytes) })
            this.queueActions(record)
          } else {
            WorkbenchInfoRow({ label: $r('app.string.task_source_path'), value: this.file(record).sources.join('、') })
            if (this.file(record).task !== undefined && ['pending', 'unknown'].includes(record.state)) {
              Button($r('app.string.task_check')).constraintSize({ minHeight: 44 }).enabled(!this.model.busy).onClick((): void => { this.model.checkFileTask(record.id); })
            }
            if (record.state === 'unknown') {
              Button($r('app.string.task_close_checked')).constraintSize({ minHeight: 44 }).enabled(!this.model.busy).onClick((): void => {
                this.getUIContext().showAlertDialog({ title: $r('app.string.task_close_checked'), message: $r('app.string.task_check_file'),
                  primaryButton: { value: $r('app.string.action_cancel'), action: (): void => {} },
                  secondaryButton: { value: $r('app.string.task_close_checked'), action: (): void => { this.model.closeFileTask(record.id); } } });
              })
            }
          }
          WorkbenchNotice({ text: record.errorText, warning: true })
          if (record.canRemove) {
            Button($r('app.string.task_remove')).constraintSize({ minHeight: 44 }).enabled(this.actionsAvailable(record)).onClick((): void => { this.detailVisible = false; this.prepareClear([record]); })
          }
        }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      }.width('100%').height('100%')
    }
  }
  @Builder
  detailsSheet() {
    if (this.selected() !== undefined) { this.detail(this.selected()!) }
  }
  @Builder
  clearSheet() {
    Column({ space: 16 }) {
      Text(this.text($r('app.string.task_clear_scope')) + this.clearScope + '，' + this.clearRecords.length.toString() + ' 项')
        .fontSize(16).fontColor($r('sys.color.font_primary')).width('100%')
      if (this.clearRecords.some((record: TaskRecordView): boolean => record.group === 'download')) {
        Row({ space: 8 }) {
          Checkbox().select(this.deleteLocalFiles).onChange((checked: boolean): void => { this.deleteLocalFiles = checked; })
          Text($r('app.string.task_delete_local')).fontSize(16).fontColor($r('sys.color.font_primary'))
        }.width('100%').enabled(!this.clearing)
      }
      Button($r('app.string.task_clear_records')).width('100%').constraintSize({ minHeight: 48 }).enabled(!this.clearing)
        .onClick((): void => { this.clear(); })
    }.width('100%').padding(24)
  }

  build() {
    Column() {
      Column() {
        if (this.state.scope === 'root') {
          this.rootPage()
        } else {
          Row({ space: 8 }) {
            ForEach(['all', 'active', 'finished'] as TaskFilter[], (filter: TaskFilter): void => {
              WorkbenchChoice({ label: this.filterLabel(filter), selected: this.state.filter === filter,
                onSelect: (): void => { this.state.filter = filter; } })
            }, (filter: TaskFilter): string => filter)
            Blank()
            Button() { SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(20).fontColor([$r('sys.color.icon_secondary')]) }
              .width(44).height(44).backgroundColor(Color.Transparent).enabled(!this.clearing).accessibilityText($r('app.string.task_refresh'))
              .onClick((): void => { this.refresh(); })
          }.width('100%').padding({ top: this.topInset + 4, bottom: 4 })
          Button($r('app.string.task_all_tasks')).buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: 44 }).onClick(this.onAllTasks)
          WorkbenchNotice({ text: this.loadError, warning: true })
          List({ space: 8, scroller: this.scroller }) {
            Repeat<TaskListEntry>(this.entries).each((entry: RepeatItem<TaskListEntry>): void => {
              ListItem() {
                if (entry.item.record === undefined) { this.groupHeader(entry.item.group) }
                else { this.taskRow(entry.item) }
              }
            }).key((entry: TaskListEntry): string => entry.key).virtualScroll()
            if (this.entries.length === 0 && this.countsReady()) {
              ListItem() {
                WorkbenchEmptyState({
                  icon: $r('sys.symbol.clock'),
                  title: this.text($r('app.string.task_empty')),
                  description: '当前筛选条件下没有任务记录。'
                })
              }
            }
          }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).contentEndOffset(this.bottomInset)
        }
      }.width('100%').height('100%')
        .bindSheet($$this.clearVisible, this.clearSheet(), {
          height: SheetSize.FIT_CONTENT, showClose: true, title: { title: $r('app.string.task_clear_records') },
          backgroundColor: $r('app.color.workbench_surface_elevated')
        })
    }.width('100%').height('100%').constraintSize({ maxWidth: 960 })
      .padding({ left: this.state.scope === 'root' ? 0 : 16, right: this.state.scope === 'root' ? 0 : 16,
        top: this.state.scope === 'root' ? this.topInset : 0 })
      .bindSheet($$this.detailVisible, this.detailsSheet(), {
        height: SheetSize.LARGE, showClose: true, title: { title: $r('app.string.task_details') },
        backgroundColor: $r('app.color.workbench_surface_elevated')
      })
  }
}
