import { pasteboard } from '@kit.BasicServicesKit';
import { SystemLogModel } from './SystemLogModel';
import { SystemLogRecord, filterSystemLogs, systemLogCopy } from './SystemLogProtocol';
import { WorkbenchInfoRow, WorkbenchEmptyState, WorkbenchServiceError } from '../workbench/WorkbenchUi';

@ComponentV2
export struct SystemLogPage {
  @Require @Param model: SystemLogModel = new SystemLogModel();
  @Param scroller: Scroller = new Scroller();
  @Param bottomInset: number = 16;
  @Local copyText: string = '';
  @Event onManagement: () => void = (): void => {};
  private async copy(): Promise<void> {
    const item = this.model.selected; this.copyText = '';
    if (item === undefined) { return; }
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, systemLogCopy(item)));
      if (this.model.selected === item) { this.copyText = '已复制'; }
    } catch { if (this.model.selected === item) { this.copyText = '复制失败，请重试。'; } }
  }
  @Builder
  list() {
    Search({ value: this.model.query, placeholder: '搜索日志' }).defaultFocus(false).onChange((value: string): void => { this.model.query = value; })
    Row({ space: 8 }) {
      Select([{ value: '全部级别' }, { value: '信息' }, { value: '警告' }, { value: '错误' }, { value: '未知级别' }])
        .value(this.model.level === '全部' ? '全部级别' : this.model.level).controlSize(ControlSize.SMALL).layoutWeight(1)
        .selected(['全部', '信息', '警告', '错误', '未知级别'].indexOf(this.model.level)).onSelect((index: number): void => { this.model.level = ['全部', '信息', '警告', '错误', '未知级别'][index]; })
      Select([{ value: '全部来源' }, { value: '系统' }, { value: '连接' }, { value: '文件传输' }, { value: '其他来源' }])
        .value(this.model.source === '全部' ? '全部来源' : this.model.source).controlSize(ControlSize.SMALL).layoutWeight(1)
        .selected(['全部', '系统', '连接', '文件传输', '其他来源'].indexOf(this.model.source)).onSelect((index: number): void => { this.model.source = ['全部', '系统', '连接', '文件传输', '其他来源'][index]; })
      Select([{ value: '全部时间' }, { value: '最近一小时' }, { value: '最近一天' }])
        .value(this.model.hours === 1 ? '最近一小时' : this.model.hours === 24 ? '最近一天' : '全部时间').controlSize(ControlSize.SMALL).layoutWeight(1)
        .selected([0, 1, 24].indexOf(this.model.hours)).onSelect((index: number): void => { this.model.hours = [0, 1, 24][index]; })
    }.width('100%')
    if (this.model.hours > 0) { Text('未提供时区的记录不参与时间筛选。').fontSize(14) }
    if (this.model.loaded && this.model.items.length === 0) { WorkbenchEmptyState({ title: '暂无系统日志' }) }
    else if (this.model.loaded && filterSystemLogs(this.model.items, this.model.query, this.model.level, this.model.source, this.model.hours, this.model.checkedAt).length === 0) {
      WorkbenchEmptyState({ title: '已加载记录中没有符合条件的日志' })
    }
    ForEach(filterSystemLogs(this.model.items, this.model.query, this.model.level, this.model.source, this.model.hours, this.model.checkedAt), (item: SystemLogRecord): void => {
      Button() {
        Column({ space: 6 }) {
          Text(item.source + '，' + item.level).fontWeight(FontWeight.Medium)
          Text(item.message || '未提供日志内容').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(item.time || '未提供时间').fontSize(14)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
      }.type(ButtonType.Normal).width('100%').borderRadius(16).backgroundColor($r('app.color.workbench_surface'))
        .onClick((): void => { this.copyText = ''; this.model.selected = item; })
    }, (item: SystemLogRecord): string => JSON.stringify(item))
    if (this.model.more) { Button('加载更多').enabled(!this.model.loading).onClick((): void => { this.model.refresh(true); }) }
    if (this.model.truncated) { Text('已达到 500 条或 512 KiB 的读取上限，请刷新查看最新记录。').fontSize(14) }
  }
  @Builder
  detail() {
    Button('返回列表').onClick((): void => { this.model.back(); })
    WorkbenchInfoRow({ label: '时间', value: this.model.selected!.time || '未提供' })
    WorkbenchInfoRow({ label: '来源', value: this.model.selected!.source })
    WorkbenchInfoRow({ label: '级别', value: this.model.selected!.level })
    WorkbenchInfoRow({ label: '用户', value: this.model.selected!.who || '未提供' })
    WorkbenchInfoRow({ label: '地址', value: this.model.selected!.address || '未提供' })
    Text(this.model.selected!.message || '未提供日志内容').width('100%').copyOption(CopyOptions.InApp)
    Button('复制记录').onClick((): void => { this.copy(); })
    if (this.copyText.length > 0) { Text(this.copyText).fontSize(14) }
  }
  build() {
    Row() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          if (this.model.selected === undefined) { this.list() } else { this.detail() }
          if (this.model.loading) { LoadingProgress().width(32).height(32) }
          if (this.model.errorText.length > 0) { WorkbenchServiceError({ message: this.model.errorText,
            title: $r('app.string.system_logs_unavailable'), retainedContent: this.model.items.length > 0,
            available: !this.model.loading, onRetry: (): void => { this.model.refresh(); }, onManagement: this.onManagement }) }
          Button($r('app.string.package_open_management')).buttonStyle(ButtonStyleMode.NORMAL).onClick(this.onManagement)
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, left: 16, right: 16, bottom: this.bottomInset })
      }.width('100%').height('100%').constraintSize({ maxWidth: 960 }).align(Alignment.Top)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
