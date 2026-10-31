import { DriveEntryKind, DriveView, driveEntryRenderKey } from '../../core/domain/DriveProtocol';
import type { DriveEntry } from '../../core/domain/DriveProtocol';
import { driveActionText, driveActionStateText } from '../../core/domain/DriveActionState';
import type { DriveActionRecord } from '../../core/domain/DriveActionState';
import { DriveActionModel } from './DriveActionModel';
import { WorkbenchChoice, WorkbenchMetrics, WorkbenchNotice, WorkbenchEntryRow } from '../workbench/WorkbenchUi';

@ComponentV2
export struct DriveActionPage {
  @Param model: DriveActionModel = new DriveActionModel();
  @Param scroller: Scroller = new Scroller();
  @Event onSubmit: () => void = (): void => {};
  @Event onCancel: () => void = (): void => {};

  @Computed
  private get folders(): DriveEntry[] {
    return this.model.destinations.entries.filter((entry: DriveEntry): boolean => entry.kind === DriveEntryKind.Folder);
  }

  build() {
    List({ scroller: this.scroller }) {
      ListItem() {
        Column({ space: 8 }) {
          if (this.model.draft !== undefined) {
            if (this.model.draft.action === 'create') {
              Text($r('app.string.drive_create_folder')).fontSize(16).fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary')).width('100%')
            } else {
              Text(this.model.draft.entries !== undefined ? $r('app.string.drive_batch_action', driveActionText(this.model.draft.action), this.model.draft.entries.length) :
                driveActionText(this.model.draft.action) + '“' + this.model.draft.entry.name + '”')
                .fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
            }
            if (this.model.draft.action === 'rename' || this.model.draft.action === 'create') {
              TextInput({ text: this.model.newName, placeholder: this.model.draft.action === 'create' ?
                $r('app.string.drive_folder_name') : $r('app.string.drive_new_name') }).maxLength(255)
                .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).enabled(!this.model.busy)
                .onChange((value: string): void => { this.model.newName = value; })
                .accessibilityText(this.model.draft.action === 'create' ? $r('app.string.drive_folder_name') : $r('app.string.drive_new_name'))
            } else if (this.model.draft.action === 'delete') {
              Text('请确认删除此项目。能否恢复取决于 NAS 的回收站与版本设置；文件夹内的内容也会受影响。')
                .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
            } else {
              Text(this.model.draft.target === undefined ? '请选择可写的目标文件夹。' :
                '目标：' + (this.model.draft.target.displayPath || this.model.draft.target.name))
                .fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
              Text(this.model.draft.conflicts !== undefined && this.model.draft.conflicts > 0 ?
                '目标存在同名项目，操作时自动改名。' : '遇到同名项目时自动改名。')
                .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
              Flex({ wrap: FlexWrap.Wrap }) {
                WorkbenchChoice({ label: '我的文件', selected: this.model.destinations.view === DriveView.MyDrive,
                  available: !this.model.busy && !this.model.destinations.busy,
                  onSelect: (): void => { this.model.destinations.selectView(DriveView.MyDrive); } })
                WorkbenchChoice({ label: '团队文件夹', selected: this.model.destinations.view === DriveView.TeamFolders,
                  available: !this.model.busy && !this.model.destinations.busy && this.model.destinations.supportsView(DriveView.TeamFolders),
                  onSelect: (): void => { this.model.destinations.selectView(DriveView.TeamFolders); } })
              }.width('100%')
              Row({ space: 8 }) {
                Text(this.model.destinations.trail.map((item): string => item.name).join(' / '))
                  .fontSize(12).fontColor($r('sys.color.font_secondary')).layoutWeight(1)
                Button('上级').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
                  .enabled(!this.model.busy && !this.model.destinations.busy && this.model.destinations.canGoUp())
                  .onClick((): void => { this.model.destinations.goUp(); }).accessibilityText('返回上级文件夹')
                Button() {
                  SymbolGlyph($r('sys.symbol.arrow_2_circlepath')).fontSize(20).fontColor([$r('sys.color.icon_primary')])
                }.width(WorkbenchMetrics.touchSize).height(WorkbenchMetrics.touchSize).backgroundColor(Color.Transparent)
                  .enabled(!this.model.busy && !this.model.destinations.busy)
                  .onClick((): void => { this.model.destinations.reload(); }).accessibilityText('刷新目标文件夹')
              }.width('100%')
              WorkbenchNotice({ text: this.model.destinations.errorText, warning: true })
            }
            Flex({ wrap: FlexWrap.Wrap }) {
              Button('确认' + driveActionText(this.model.draft.action)).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
                .enabled(this.model.ready && !this.model.busy && !this.model.hasPending &&
                  (this.model.draft.action === 'create' ? this.model.newName.trim().length > 0 :
                    this.model.draft.action === 'rename' || this.model.draft.action === 'delete' || this.model.draft.target !== undefined))
                .fontColor(this.model.draft.action === 'delete' ? $r('app.color.workbench_danger') : $r('sys.color.font_primary'))
                .onClick(this.onSubmit)
              Button('取消').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
                .enabled(!this.model.busy).onClick(this.onCancel)
            }.width('100%')
          }
          WorkbenchNotice({ text: this.model.errorText, warning: true })
          if (this.model.busy || this.model.destinations.busy) { LoadingProgress().width(24).height(24) }
        }.width('100%').padding({ top: 8, bottom: 8 }).alignItems(HorizontalAlign.Start)
      }
      if (this.model.draft?.action === 'move' || this.model.draft?.action === 'copy') {
        if (!this.model.destinations.busy && this.folders.length === 0) {
          ListItem() {
            Text('本页没有文件夹，可查看其他页或返回上级。').fontSize(14).fontColor($r('sys.color.font_secondary')).padding(16)
          }
        }
        ForEach(this.folders, (entry: DriveEntry, index: number): void => {
          ListItem() {
            WorkbenchEntryRow({ title: entry.name, subtitle: entry.capabilities.canWrite ? '可选为目标文件夹' : '只读文件夹',
                icon: $r('sys.symbol.folder'), iconColor: $r('sys.color.icon_emphasize'),
                available: entry.capabilities.canRead && !this.model.busy && !this.model.destinations.busy,
                actionLabel: '选择', actionAvailable: entry.capabilities.canRead && entry.capabilities.canWrite &&
                  !this.model.busy && !this.model.destinations.busy,
                showDivider: index < this.folders.length - 1,
                onOpen: (): void => { this.model.destinations.openFolder(entry); },
                onAction: (): void => { this.model.selectDestination(entry); } })
          }.backgroundColor($r('app.color.workbench_surface')).borderRadius({ topLeft: index === 0 ? WorkbenchMetrics.cardRadius : 0,
            topRight: index === 0 ? WorkbenchMetrics.cardRadius : 0,
            bottomLeft: index === this.folders.length - 1 ? WorkbenchMetrics.cardRadius : 0,
            bottomRight: index === this.folders.length - 1 ? WorkbenchMetrics.cardRadius : 0 }).clip(true)
        }, (entry: DriveEntry): string => driveEntryRenderKey(entry))
        ListItem() {
          Row({ space: 8 }) {
            Button('上一页').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .enabled(!this.model.busy && !this.model.destinations.busy && this.model.destinations.pageOffset > 0)
              .onClick((): void => { this.model.destinations.previousPage(); })
            Button('下一页').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .enabled(!this.model.busy && !this.model.destinations.busy && this.model.destinations.more())
              .onClick((): void => { this.model.destinations.nextPage(); })
          }.width('100%').padding({ top: 4, bottom: 4 })
        }
      }
    }.width('100%').height('100%').scrollBar(BarState.Auto)
      .padding({ left: WorkbenchMetrics.pageMargin, right: WorkbenchMetrics.pageMargin })
      .backgroundColor($r('app.color.workbench_background'))
  }
}

@ComponentV2
export struct DriveActionSummary {
  @Param model: DriveActionModel = new DriveActionModel();
  build() {
    Column({ space: 8 }) {
      Text('文件操作').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
      if (this.model.items.some((item: DriveActionRecord): boolean => item.state === 'unknown' || item.state === 'accepted' && item.errorText.length > 0)) {
        Text('请先在 NAS 核对待确认的操作，再关闭记录。')
          .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
      }
      if (!this.model.ready) {
        Button('重新加载记录').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
          .enabled(!this.model.busy).onClick((): void => { this.model.reload(); })
      } else if (this.model.items.length === 0) {
        Text('暂无 Drive 文件操作。').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      }
      WorkbenchNotice({ text: this.model.errorText, warning: true })
      WorkbenchNotice({ text: this.model.notice })
    }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 }).alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
export struct DriveActionCard {
  @Param model: DriveActionModel = new DriveActionModel();
  @Param item: DriveActionRecord = { id: '', action: 'rename', resource: { nasOrigin: '', account: '', fileId: '' },
    name: '', destination: '', state: 'unknown', errorText: '' };
  @Event onFiles: () => void = (): void => {};

  private confirmClose(): void {
    this.getUIContext().showAlertDialog({ title: '已在 NAS 核对操作？',
      message: '请先确认操作已结束并核对结果。关闭只更新本机记录，不取消 NAS 任务，也不会重发操作。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '已核对，关闭', action: (): void => { this.model.closeUnknown(this.item.id); } } });
  }
  build() {
    Column({ space: 4 }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.doc_text')).fontSize(20).fontColor([$r('sys.color.icon_emphasize')])
        Column({ space: 4 }) {
          Text(this.item.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
            .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(driveActionText(this.item.action) + '，' + driveActionStateText(this.item.state))
            .fontSize(12).fontColor(this.item.state === 'unknown' || this.item.state === 'failed' ?
              $r('app.color.workbench_danger') : $r('sys.color.font_secondary')).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      if (this.item.destination.length > 0) {
        Text(this.item.destination).fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
      }
      if (this.item.state === 'accepted' && this.item.progress !== undefined) {
        Progress({ value: this.item.progress, total: 100, type: ProgressType.Linear }).width('100%').height(4)
          .accessibilityText('操作进度 ' + this.item.progress.toFixed(0) + '%')
      }
      WorkbenchNotice({ text: this.item.errorText, warning: true })
      Flex({ wrap: FlexWrap.Wrap }) {
        if (this.item.state === 'accepted') {
          Button('查询状态').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.model.refresh(this.item.id); })
        }
        if (this.item.state === 'unknown' || this.item.state === 'accepted' && this.item.errorText.length > 0) {
          Button('已核对，关闭记录').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.confirmClose(); })
        } else if (this.item.state !== 'accepted') {
          Button('移除记录').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
            .enabled(this.model.ready && !this.model.busy).onClick((): void => { this.model.remove(this.item.id); })
        }
        Button('查看文件').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).onClick(this.onFiles)
      }.width('100%')
    }.width('100%').padding(12).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
      .alignItems(HorizontalAlign.Start)
  }
}
