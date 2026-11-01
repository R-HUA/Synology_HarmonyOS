import { common } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { ComponentAppear } from '@kit.ArkUI';
import { NoteModel } from './NoteModel';
import { NoteSummary, NoteFolder, NoteBlock, NoteSpan, NoteAttachment, filterNotes, noteLink } from './NoteProtocol';
import { WorkbenchEmptyState, WorkbenchInfoRow, WorkbenchServiceError, WorkbenchSkeleton } from '../workbench/WorkbenchUi';
import { workbenchBytes } from '../workbench/WorkbenchPresentation';

@ComponentV2
export struct NoteStationPage {
  @Require @Param model: NoteModel = new NoteModel();
  @Param scroller: Scroller = new Scroller();
  @Param bottomInset: number = 16;
  @Param wide: boolean = false;
  @Param detailScroller: Scroller = new Scroller();
  private detailStack: NavPathStack = new NavPathStack();
  @Local linkError: string = '';
  @Local private listRefreshing: boolean = false;
  @Local private detailRefreshing: boolean = false;
  @Event onManagement: () => void = (): void => {};

  @ComponentAppear
  onNoteAppear(): void { this.selectionChanged(); }

  @Monitor('model.selected', 'wide')
  private selectionChanged(): void {
    if (this.model.selected === undefined) { this.detailStack.clear(); }
    else if (this.wide && this.detailStack.size() === 0) { this.detailStack.pushPathByName('detail', undefined); }
  }
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
  /** 点击笔记的详情加载不应触发下拉刷新，更不能重读列表。 */
  private async refreshContent(detail: boolean): Promise<void> {
    if (detail ? this.detailRefreshing : this.listRefreshing) { return; }
    if (detail) { this.detailRefreshing = true; } else { this.listRefreshing = true; }
    try {
      if (detail) { await this.model.refreshDetail(); } else { await this.model.refresh(); }
    } finally {
      if (detail) { this.detailRefreshing = false; } else { this.listRefreshing = false; }
    }
  }
  @Builder
  list() {
    Search({ value: this.model.query, placeholder: $r('app.string.notes_search') }).defaultFocus(false)
      .onChange((value: string): void => { this.model.query = value; })
    Row({ space: 8 }) {
      Select(this.options(this.model.notebooks, '全部笔记本')).selected(this.model.notebooks.findIndex((item: NoteFolder): boolean => item.id === this.model.notebook) + 1)
        .value(this.model.notebooks.find((item: NoteFolder): boolean => item.id === this.model.notebook)?.title ?? $r('app.string.notes_all_notebooks'))
        .layoutWeight(1).constraintSize({ minHeight: 48 }).controlSize(ControlSize.SMALL)
        .onSelect((index: number): void => { this.model.notebook = index === 0 ? '' : this.model.notebooks[index - 1].id; })
      Divider().vertical(true).height(20).color($r('app.color.workbench_divider'))
      Select(this.options(this.model.tags, '全部标签')).selected(this.model.tags.findIndex((item: NoteFolder): boolean => item.id === this.model.tag) + 1)
        .value(this.model.tags.find((item: NoteFolder): boolean => item.id === this.model.tag)?.title ?? $r('app.string.notes_all_tags'))
        .layoutWeight(1).constraintSize({ minHeight: 48 }).controlSize(ControlSize.SMALL)
        .onSelect((index: number): void => { this.model.tag = index === 0 ? '' : this.model.tags[index - 1].id; })
    }.width('100%')
    if (this.model.moreNotebooks) { Button('加载更多笔记本').enabled(!this.model.loading).onClick((): void => { this.model.loadFolders('notebooks'); }) }
    if (this.model.moreTags) { Button('加载更多标签').enabled(!this.model.loading).onClick((): void => { this.model.loadFolders('tags'); }) }
    if (this.model.notebookError.length > 0 || this.model.tagError.length > 0) {
      WorkbenchServiceError({ message: this.model.notebookError || this.model.tagError,
        title: this.model.notebookError.length > 0 ? $r('app.string.notes_notebooks_unavailable') : $r('app.string.notes_tags_unavailable'),
        retainedContent: this.model.items.length > 0, available: !this.model.loading,
        onRetry: (): void => { this.model.refresh(); }, onManagement: this.onManagement })
    }
    if (this.model.loading && this.model.items.length === 0) { WorkbenchSkeleton() }
    else if (this.model.errorText.length > 0) {
      WorkbenchServiceError({ message: this.model.errorText, title: $r('app.string.notes_unavailable'), available: !this.model.loading, retainedContent: this.model.items.length > 0,
        onRetry: (): void => { this.model.refresh(); }, onManagement: this.onManagement })
    } else if (this.model.loaded && this.model.items.length === 0) {
      WorkbenchEmptyState({ title: $r('app.string.notes_empty'), secondaryLabel: $r('app.string.package_open_management'), onSecondaryAction: this.onManagement })
    }
    if (this.model.loaded && this.model.items.length > 0 && filterNotes(this.model.items, this.model.notebook, this.model.tag, this.model.query, this.model.tags).length === 0) {
      WorkbenchEmptyState({ title: $r('app.string.notes_no_matches') })
    }
    ForEach(filterNotes(this.model.items, this.model.notebook, this.model.tag, this.model.query, this.model.tags), (item: NoteSummary): void => {
      Button(item.title).type(ButtonType.Normal).width('100%').constraintSize({ minHeight: 56 }).borderRadius(16)
        .buttonStyle(ButtonStyleMode.NORMAL).fontColor($r('sys.color.font_primary'))
        .backgroundColor($r('app.color.workbench_surface')).onClick((): void => {
          this.linkError = ''; this.model.select(item);
        })
    }, (item: NoteSummary): string => item.id)
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
        }, (span: NoteSpan, index: number): string => index.toString() + ':' + JSON.stringify(span))
      }.fontSize(block.kind === 'heading' ? Math.max(18, 28 - block.level * 2) : 16).width('100%').copyOption(CopyOptions.InApp)
    }
  }
  @Builder
  detail() {
    if (!this.wide) { Button('返回列表').buttonStyle(ButtonStyleMode.NORMAL).onClick((): void => { this.model.back(); }) }
    Text(this.model.detail?.item.title || this.model.selected!.title).fontSize(24).fontWeight(FontWeight.Medium)
    if (this.model.detailLoading) { LoadingProgress().width(32).height(32) }
    if (this.model.detailError.length > 0) { WorkbenchServiceError({ message: this.model.detailError,
      title: $r('app.string.notes_unavailable'), available: !this.model.detailLoading,
      onRetry: (): void => { this.model.refreshDetail(); }, onManagement: this.onManagement }) }
    if (this.model.detail !== undefined) {
      if (!this.model.detail.bodyProvided) { Text('正文暂不可读取，请在浏览器中查看。') }
      else if (this.model.detail.body.blocks.length === 0) { Text('正文为空') }
      ForEach(this.model.detail.body.blocks, (block: NoteBlock): void => { this.block(block) },
        (block: NoteBlock, index: number): string => index.toString() + ':' + JSON.stringify(block))
      if (this.model.detail.body.complex) { Text('部分排版已简化，可在浏览器中查看完整内容。').fontSize(14) }
      if (this.linkError.length > 0) { Text(this.linkError).fontColor($r('sys.color.font_secondary')) }
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
      if (this.model.attachments.errorText.length > 0) {
        WorkbenchServiceError({ message: this.model.attachments.errorText, title: $r('app.string.notes_attachment_unavailable'),
          retryable: false, onManagement: this.onManagement })
      }
      if (this.model.attachments.notice.length > 0) { Text(this.model.attachments.notice).fontSize(14) }
    }
  }
  @Builder
  content(showDetail: boolean) {
    Row() {
      Refresh({ refreshing: showDetail ? this.detailRefreshing : this.listRefreshing }) {
      Scroll(showDetail ? this.detailScroller : this.scroller) {
        Column({ space: 12 }) {
          if (showDetail && this.model.selected !== undefined) { this.detail() } else { this.list() }
          if (this.model.items.length > 0 || this.model.selected !== undefined) {
            Button($r('app.string.package_open_management')).buttonStyle(ButtonStyleMode.NORMAL).onClick(this.onManagement)
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, left: 16, right: 16, bottom: this.bottomInset })
      }.width('100%').height('100%').constraintSize({ maxWidth: 960 }).align(Alignment.TopStart)
      }.width('100%').height('100%').onRefreshing((): void => {
        this.refreshContent(showDetail);
      })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }

  @Builder
  noteDetail(_name: string) {
    NavDestination() { this.content(true) }.hideTitleBar(true)
      .onBackPressed((): boolean => { this.model.back(); return true; })
  }

  build() {
    if (this.wide) {
      Navigation(this.detailStack) { this.content(false) }.mode(NavigationMode.Auto).navBarWidth('40%')
        .hideTitleBar(true).hideToolBar(true).navDestination(this.noteDetail).width('100%').height('100%')
    } else if (this.model.selected !== undefined) { this.content(true) }
    else { this.content(false) }
  }
}
