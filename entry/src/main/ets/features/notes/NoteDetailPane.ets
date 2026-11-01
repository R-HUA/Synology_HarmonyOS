import { common } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { NoteModel } from './NoteModel';
import { NoteBlock, NoteSpan, NoteAttachment, noteAttachmentKey, noteLink } from './NoteProtocol';
import { noteBlockKey } from './NotePresentation';
import { WorkbenchIconTile, WorkbenchMetrics, WorkbenchNotice, WorkbenchServiceError, WorkbenchSkeleton } from '../workbench/WorkbenchUi';
import { workbenchBytes } from '../workbench/WorkbenchPresentation';

/**
 * 笔记详情内容区：不含标题栏与返回入口。
 * 手机由 Index 的 'note-detail' HdsNavDestination 承载（标题栏显示笔记名）；宽屏由 NoteStationPage 的内层导航承载。
 */
@ComponentV2
export struct NoteDetailPane {
  @Require @Param model: NoteModel = new NoteModel();
  @Param scroller: Scroller = new Scroller();
  @Param bottomInset: number = 16;
  /** 宽屏右栏没有独立标题栏，需要在正文顶部显示笔记标题；手机标题在标题栏中，不重复。 */
  @Param showInlineTitle: boolean = false;
  @Param activeAttachmentKey: string = '';
  @Event onManagement: () => void = (): void => {};
  @Local private refreshing: boolean = false;
  @Local private linkFailed: boolean = false;

  @Monitor('model.selected')
  private selectionChanged(): void { this.linkFailed = false; }

  private async refresh(): Promise<void> {
    if (this.refreshing) { return; }
    this.refreshing = true;
    try { await this.model.refreshDetail(); } finally { this.refreshing = false; }
  }
  private async openLink(url: string): Promise<void> {
    if (noteLink(url).length === 0) { return; }
    const detail = this.model.detail; this.linkFailed = false;
    try { await (this.getUIContext().getHostContext() as common.UIAbilityContext).openLink(url); }
    catch { if (this.model.detail === detail) { this.linkFailed = true; } }
  }
  private attachment(id: string): NoteAttachment | undefined {
    return this.model.detail?.attachments.find((item: NoteAttachment): boolean => item.fileId === id);
  }
  private imagePath(id: string): string {
    const item = this.attachment(id), path = item === undefined ? '' : this.model.attachments.path(item);
    return path.length > 0 ? fileUri.getUriFromPath(path) : '';
  }
  private rowBusy(item: NoteAttachment): boolean {
    return this.model.attachments.busy && this.activeAttachmentKey.length > 0 && this.activeAttachmentKey === noteAttachmentKey(item);
  }
  private sizeText(item: NoteAttachment): string {
    return item.bytes === undefined ? this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.notes_size_unknown').id) :
      workbenchBytes(item.bytes);
  }

  @Builder
  imageBlock(block: NoteBlock) {
    if (this.imagePath(block.attachmentId).length > 0) {
      Image(this.imagePath(block.attachmentId)).width('100%').constraintSize({ maxHeight: 480 }).objectFit(ImageFit.Contain)
        .borderRadius(WorkbenchMetrics.innerRadius)
        .accessibilityText(this.attachment(block.attachmentId)?.name ?? '')
    } else {
      // 未下载的图片就地占位，提供加载入口；下载走现有附件缓存，完成后同一位置显示图片。
      Row({ space: 12 }) {
        WorkbenchIconTile({ icon: $r('sys.symbol.picture'), iconColor: $r('sys.color.icon_secondary') })
        Text(this.attachment(block.attachmentId)?.name || this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.notes_image').id))
          .fontSize(14).fontColor($r('sys.color.font_secondary')).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.attachment(block.attachmentId) !== undefined) {
          if (this.rowBusy(this.attachment(block.attachmentId)!)) {
            LoadingProgress().width(24).height(24)
          } else {
            Button($r('app.string.notes_load_image')).buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
            .constraintSize({ minHeight: 40 }).enabled(!this.model.attachments.busy)
            .onClick((): void => { const item = this.attachment(block.attachmentId); if (item !== undefined) { this.model.attachments.download(item); } })
          }
        }
      }.width('100%').padding(12).borderRadius(WorkbenchMetrics.innerRadius).backgroundColor($r('app.color.workbench_subtle'))
    }
  }

  @Builder
  textBlock(block: NoteBlock) {
    Text() {
      ForEach(block.spans, (span: NoteSpan): void => {
        Span(span.text).fontWeight(span.bold || block.kind === 'heading' ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
          .fontColor(span.href.length > 0 ? $r('sys.color.font_emphasize') : $r('sys.color.font_primary'))
          .decoration({ type: span.href.length > 0 ? TextDecorationType.Underline : TextDecorationType.None })
          .onClick((): void => { if (span.href.length > 0) { this.openLink(span.href); } })
      }, (_span: NoteSpan, index: number): string => index.toString())
    }.fontSize(block.kind === 'heading' && block.level <= 2 ? 20 : 16).width('100%').copyOption(CopyOptions.InApp)
  }

  @Builder
  attachmentRow(item: NoteAttachment) {
    Row({ space: 12 }) {
      WorkbenchIconTile({ icon: $r('sys.symbol.doc'), iconColor: $r('sys.color.icon_secondary') })
      Column({ space: 2 }) {
        Text(item.name).fontSize(16).fontColor($r('sys.color.font_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.sizeText(item)).fontSize(14).fontColor($r('sys.color.font_secondary'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.rowBusy(item)) {
        LoadingProgress().width(24).height(24)
      } else if (this.model.attachments.path(item).length === 0) {
        Button($r('app.string.notes_download')).buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .constraintSize({ minHeight: 40 }).enabled(!this.model.attachments.busy)
          .onClick((): void => { this.model.attachments.download(item); })
      } else {
        Button($r('app.string.notes_save_to_device')).buttonStyle(ButtonStyleMode.NORMAL).controlSize(ControlSize.SMALL)
          .constraintSize({ minHeight: 40 }).enabled(!this.model.attachments.busy)
          .onClick((): void => { this.model.attachments.save(item); })
      }
    }.width('100%').constraintSize({ minHeight: WorkbenchMetrics.rowMinHeight }).padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  @Builder
  body() {
    if (this.showInlineTitle && this.model.selected !== undefined) {
      Text(this.model.detail?.item.title || this.model.selected.title).fontSize(20).fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
    }
    if (this.model.detailError.length > 0) {
      WorkbenchServiceError({ message: this.model.detailError, title: $r('app.string.notes_unavailable'), available: !this.model.detailLoading,
        retainedContent: this.model.detail !== undefined, onRetry: (): void => { this.model.refreshDetail(); }, onManagement: this.onManagement })
    }
    if (this.model.detail === undefined) {
      if (this.model.detailLoading) { WorkbenchSkeleton() }
    } else {
      if (!this.model.detail.bodyProvided) {
        WorkbenchNotice({ text: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.notes_body_unavailable').id) })
      } else if (this.model.detail.body.blocks.length === 0) {
        Text($r('app.string.notes_body_empty')).fontSize(14).fontColor($r('sys.color.font_secondary'))
      }
      if (this.model.detail.body.complex) {
        WorkbenchNotice({ text: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.notes_body_simplified').id) })
      }
      if (this.linkFailed) {
        WorkbenchNotice({ text: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.notes_link_failed').id), warning: true })
      }
      ForEach(this.model.detail.body.blocks, (block: NoteBlock): void => {
        if (block.kind === 'image') { this.imageBlock(block) } else { this.textBlock(block) }
      }, (_block: NoteBlock, index: number): string => noteBlockKey(this.model.detail?.item.id ?? '', this.model.detail?.version ?? '', index))
      if (this.model.detail.attachments.length > 0) {
        Text($r('app.string.notes_attachments', this.model.detail.attachments.length)).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_secondary')).padding({ top: 8 })
        Column() {
          ForEach(this.model.detail.attachments, (item: NoteAttachment): void => { this.attachmentRow(item) },
            (item: NoteAttachment): string => item.fileId)
        }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).backgroundColor($r('app.color.workbench_surface'))
        if (this.model.attachments.errorText.length > 0) {
          WorkbenchServiceError({ message: this.model.attachments.errorText, title: $r('app.string.notes_attachment_unavailable'),
            retryable: false, onManagement: this.onManagement })
        }
        if (this.model.attachments.notice.length > 0) { WorkbenchNotice({ text: this.model.attachments.notice }) }
      }
    }
  }

  build() {
    Refresh({ refreshing: this.refreshing }) {
      Scroll(this.scroller) {
        Column({ space: 12 }) { this.body() }
          .width('100%').constraintSize({ maxWidth: 840 }).alignItems(HorizontalAlign.Start)
          .padding({ top: 12, left: 16, right: 16, bottom: this.bottomInset })
      }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Auto)
    }.width('100%').height('100%').onRefreshing((): void => { this.refresh(); })
  }
}
