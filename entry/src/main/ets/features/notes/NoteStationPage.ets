import { common } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { NoteModel } from './NoteModel';
import { NoteSummary, NoteFolder, NoteBlock, NoteSpan, NoteAttachment, filterNotes, noteLink } from './NoteProtocol';
import { WorkbenchEmptyState, WorkbenchInfoRow } from '../workbench/WorkbenchUi';
import { workbenchBytes } from '../workbench/WorkbenchPresentation';

@ComponentV2
export struct NoteStationPage {
  @Require @Param model: NoteModel = new NoteModel();
  @Param scroller: Scroller = new Scroller();
  @Param bottomInset: number = 16;
  @Local linkError: string = '';
  @Event onManagement: () => void = (): void => {};
  private async openLink(url: string): Promise<void> {
    if (noteLink(url).length === 0) { return; }
    const detail = this.model.detail; this.linkError = '';
    try { await (this.getUIContext().getHostContext() as common.UIAbilityContext).openLink(url); }
    catch { if (this.model.detail === detail) { this.linkError = '链接无法打开。'; } }
  }
  private options(items: NoteFolder[], title: string): SelectOption[] {
    const result: SelectOption[] = [{ value: title }]; return result.concat(items.map((item: NoteFolder): SelectOption => ({ value: item.title })));
  }
  private attachment(id: string): NoteAttachment | undefined { return this.model.detail?.attachments.find((item: NoteAttachment): boolean => item.fileId === id); }
  private imagePath(id: string): string {
    const item = this.attachment(id), path = item === undefined ? '' : this.model.attachments.path(item);
    return path.length > 0 ? fileUri.getUriFromPath(path) : '';
  }
  @Builder
  list() {
    Search({ value: this.model.query, placeholder: '搜索已加载笔记标题' }).onChange((value: string): void => { this.model.query = value; })
    Text('笔记本、标签筛选和标题搜索仅限已加载笔记').fontSize(14).fontColor($r('sys.color.font_secondary'))
    Flex({ wrap: FlexWrap.Wrap }) {
      Select(this.options(this.model.notebooks, '全部笔记本')).selected(this.model.notebooks.findIndex((item: NoteFolder): boolean => item.id === this.model.notebook) + 1)
        .onSelect((index: number): void => { this.model.notebook = index === 0 ? '' : this.model.notebooks[index - 1].id; })
      Select(this.options(this.model.tags, '全部标签')).selected(this.model.tags.findIndex((item: NoteFolder): boolean => item.id === this.model.tag) + 1)
        .onSelect((index: number): void => { this.model.tag = index === 0 ? '' : this.model.tags[index - 1].id; })
    }
    if (this.model.moreNotebooks) { Button('加载更多笔记本').enabled(!this.model.loading).onClick((): void => { this.model.loadFolders('notebooks'); }) }
    if (this.model.moreTags) { Button('加载更多标签').enabled(!this.model.loading).onClick((): void => { this.model.loadFolders('tags'); }) }
    if (this.model.notebookError.length > 0) { Text(this.model.notebookError).fontColor($r('app.color.workbench_danger')) }
    if (this.model.tagError.length > 0) { Text(this.model.tagError).fontColor($r('app.color.workbench_danger')) }
    Button('刷新').enabled(!this.model.loading).onClick((): void => { this.model.refresh(); })
    if (this.model.checkedAt > 0) { Text('读取时间：' + new Date(this.model.checkedAt).toLocaleString()).fontSize(14) }
    if (this.model.loaded && this.model.items.length === 0) { WorkbenchEmptyState({ title: '暂无笔记' }) }
    else if (this.model.loaded && filterNotes(this.model.items, this.model.notebook, this.model.tag, this.model.query).length === 0) {
      WorkbenchEmptyState({ title: '已加载笔记中没有符合条件的笔记' })
    }
    ForEach(filterNotes(this.model.items, this.model.notebook, this.model.tag, this.model.query), (item: NoteSummary): void => {
      Button(item.title).type(ButtonType.Normal).width('100%').constraintSize({ minHeight: 56 }).borderRadius(16)
        .backgroundColor($r('app.color.workbench_surface')).onClick((): void => { this.linkError = ''; this.model.select(item); })
    }, (item: NoteSummary): string => JSON.stringify(item))
    if (this.model.more) { Button('加载更多笔记').enabled(!this.model.loading).onClick((): void => { this.model.refresh(true); }) }
  }
  @Builder
  block(block: NoteBlock) {
    if (block.kind === 'image') {
      if (this.imagePath(block.attachmentId).length > 0) {
        Image(this.imagePath(block.attachmentId)).width('100%').constraintSize({ maxHeight: 480 }).objectFit(ImageFit.Contain)
      } else { Text(this.attachment(block.attachmentId)?.name || '附件图片').fontSize(14).fontColor($r('sys.color.font_secondary')) }
    } else {
      Text() {
        ForEach(block.spans, (span: NoteSpan): void => {
          Span(span.text).fontWeight(span.bold || block.kind === 'heading' ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
            .fontColor(span.href.length > 0 ? $r('sys.color.font_emphasize') : $r('sys.color.font_primary'))
            .onClick((): void => { if (span.href.length > 0) { this.openLink(span.href); } })
        })
      }.fontSize(block.kind === 'heading' ? Math.max(18, 28 - block.level * 2) : 16).width('100%').copyOption(CopyOptions.InApp)
    }
  }
  @Builder
  detail() {
    Row({ space: 12 }) {
      Button('返回列表').buttonStyle(ButtonStyleMode.NORMAL).onClick((): void => { this.model.back(); })
      Button('刷新正文').enabled(!this.model.detailLoading).onClick((): void => { this.model.refreshDetail(); })
    }
    Text(this.model.detail?.item.title || this.model.selected!.title).fontSize(24).fontWeight(FontWeight.Medium)
    if (this.model.detailLoading) { LoadingProgress().width(32).height(32) }
    if (this.model.detailError.length > 0) { Text(this.model.detailError).fontColor($r('app.color.workbench_danger')) }
    if (this.model.detail !== undefined) {
      if (!this.model.detail.bodyProvided) { Text('正文暂不可读取，请在浏览器中查看。') }
      else if (this.model.detail.body.blocks.length === 0) { Text('正文为空') }
      ForEach(this.model.detail.body.blocks, (block: NoteBlock): void => { this.block(block) })
      if (this.model.detail.body.complex) { Text('部分排版已简化，可在浏览器中查看完整内容。').fontSize(14) }
      if (this.linkError.length > 0) { Text(this.linkError).fontColor($r('app.color.workbench_danger')) }
      if (this.model.detail.attachments.length > 0) { Text('附件').fontSize(18).fontWeight(FontWeight.Medium) }
      ForEach(this.model.detail.attachments, (item: NoteAttachment): void => {
        Column({ space: 8 }) {
          WorkbenchInfoRow({ label: item.name, value: item.bytes === undefined ? '未提供大小' : workbenchBytes(item.bytes) })
          if (this.model.attachments.path(item).length === 0) {
            Button('下载附件').enabled(!this.model.attachments.busy).onClick((): void => { this.model.attachments.download(item); })
          } else { Button('另存到设备').enabled(!this.model.attachments.busy).onClick((): void => { this.model.attachments.save(item); }) }
        }.width('100%').padding(16).backgroundColor($r('app.color.workbench_surface')).borderRadius(16)
      }, (item: NoteAttachment): string => JSON.stringify(item))
      if (this.model.attachments.busy) { LoadingProgress().width(24).height(24) }
      if (this.model.attachments.errorText.length > 0) { Text(this.model.attachments.errorText).fontColor($r('app.color.workbench_danger')) }
      if (this.model.attachments.notice.length > 0) { Text(this.model.attachments.notice).fontSize(14) }
    }
  }
  build() {
    Row() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          if (this.model.selected === undefined) { this.list() } else { this.detail() }
          if (this.model.loading) { LoadingProgress().width(32).height(32) }
          if (this.model.errorText.length > 0) { Text(this.model.errorText).fontColor($r('app.color.workbench_danger')) }
          Button($r('app.string.package_open_management')).buttonStyle(ButtonStyleMode.NORMAL).onClick(this.onManagement)
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, left: 16, right: 16, bottom: this.bottomInset })
      }.width('100%').height('100%').constraintSize({ maxWidth: 960 }).align(Alignment.Top)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
