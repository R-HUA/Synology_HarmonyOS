import { DriveEntryKind, DriveView } from '../../core/domain/DriveProtocol';
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

  build() {
    List({ scroller: this.scroller }) {
      ListItem() {
        Column({ space: 12 }) {
          if (this.model.draft !== undefined) {
            Text(driveActionText(this.model.draft.action) + '“' + this.model.draft.entry.name + '”')
              .fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
            if (this.model.draft.action === 'rename') {
              TextInput({ text: this.model.newName, placeholder: '新名称' }).maxLength(255)
                .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).enabled(!this.model.busy)
                .onChange((value: string): void => { this.model.newName = value; }).accessibilityText('新名称')
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
              Text(this.model.destinations.trail.map((item): string => item.name).join(' / '))
                .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
              Button('返回上级').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
                .enabled(!this.model.busy && !this.model.destinations.busy && this.model.destinations.canGoUp())
                .onClick((): void => { this.model.destinations.goUp(); })
              Button('刷新文件夹').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
                .enabled(!this.model.busy && !this.model.destinations.busy).onClick((): void => { this.model.destinations.reload(); })
              WorkbenchNotice({ text: this.model.destinations.errorText, warning: true })
            }
            Flex({ wrap: FlexWrap.Wrap }) {
              Button('确认' + driveActionText(this.model.draft.action)).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
                .enabled(this.model.ready && !this.model.busy && !this.model.hasPending &&
                  (this.model.draft.action === 'rename' || this.model.draft.action === 'delete' || this.model.draft.target !== undefined))
                .fontColor(this.model.draft.action === 'delete' ? $r('app.color.workbench_danger') : $r('sys.color.font_primary'))
                .onClick(this.onSubmit)
              Button('取消').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
                .enabled(!this.model.busy).onClick(this.onCancel)
            }.width('100%')
          }
          WorkbenchNotice({ text: this.model.errorText, warning: true })
          if (this.model.busy || this.model.destinations.busy) { LoadingProgress().width(24).height(24) }
        }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      }
      if (this.model.draft?.action === 'move' || this.model.draft?.action === 'copy') {
        if (!this.model.destinations.busy && !this.model.destinations.entries.some((entry: DriveEntry): boolean => entry.kind === DriveEntryKind.Folder)) {
          ListItem() {
            Text('本页没有文件夹，可查看其他页或返回上级。').fontSize(14).fontColor($r('sys.color.font_secondary')).padding(16)
          }
        }
        ForEach(this.model.destinations.entries, (entry: DriveEntry): void => {
          if (entry.kind === DriveEntryKind.Folder) {
            ListItem() {
              Row() {
                WorkbenchEntryRow({ title: entry.name, subtitle: entry.capabilities.canWrite ? '可选为目标文件夹' : '只读文件夹',
                  icon: $r('sys.symbol.folder'), iconColor: $r('sys.color.icon_emphasize'),
                  available: entry.capabilities.canRead && !this.model.busy && !this.model.destinations.busy,
                  onOpen: (): void => { this.model.destinations.openFolder(entry); } }).layoutWeight(1)
                Button('选择').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
                  .enabled(entry.capabilities.canRead && entry.capabilities.canWrite && !this.model.busy && !this.model.destinations.busy)
                  .onClick((): void => { this.model.selectDestination(entry); }).accessibilityText('选择“' + entry.name + '”')
              }.width('100%')
            }
          }
        }, (entry: DriveEntry): string => entry.fileId)
        ListItem() {
          Row({ space: 8 }) {
            Button('上一页').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .enabled(!this.model.busy && !this.model.destinations.busy && this.model.destinations.pageOffset > 0)
              .onClick((): void => { this.model.destinations.previousPage(); })
            Button('下一页').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
              .enabled(!this.model.busy && !this.model.destinations.busy && this.model.destinations.more())
              .onClick((): void => { this.model.destinations.nextPage(); })
          }.width('100%').padding(16)
        }
      }
    }.width('100%').height('100%').scrollBar(BarState.Auto)
  }
}

@ComponentV2
export struct DriveActionSummary {
  @Param model: DriveActionModel = new DriveActionModel();
  build() {
    Column({ space: 8 }) {
      Text('Drive 文件操作').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
      Text('结果待确认时，请先在 NAS 核对，再关闭记录。')
        .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      if (!this.model.ready) {
        Button('重新加载记录').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
          .enabled(!this.model.busy).onClick((): void => { this.model.reload(); })
      } else if (this.model.items.length === 0) {
        Text('暂无 Drive 文件操作。').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      }
      WorkbenchNotice({ text: this.model.errorText, warning: true })
      WorkbenchNotice({ text: this.model.notice })
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
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
    Column({ space: 8 }) {
      Text(this.item.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
      Text(driveActionText(this.item.action) + ' · ' + driveActionStateText(this.item.state))
        .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      if (this.item.destination.length > 0) {
        Text(this.item.destination).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
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
        Button('返回文件').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).onClick(this.onFiles)
      }.width('100%')
    }.width('100%').padding(16).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_surface'))
      .alignItems(HorizontalAlign.Start)
  }
}
