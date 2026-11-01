import { ComponentAppear } from '@kit.ArkUI';
import { NoteModel } from './NoteModel';
import { NoteAttachment } from './NoteProtocol';
import { NoteRowView } from './NotePresentation';
import { NoteListPane } from './NoteListPane';
import { NoteDetailPane } from './NoteDetailPane';

/**
 * Note Station 入口。
 * 手机（wide=false）：只显示列表；点选笔记后通过 onOpenDetail 由 Index 压入独立的 'note-detail' 页面。
 * 宽屏（wide=true）：保留既有的内层 Navigation(Auto, navBarWidth 40%) 列表＋详情，不做扩展。
 */
@ComponentV2
export struct NoteStationPage {
  @Require @Param model: NoteModel = new NoteModel();
  @Param scroller: Scroller = new Scroller();
  @Param bottomInset: number = 16;
  @Param wide: boolean = false;
  @Param detailScroller: Scroller = new Scroller();
  @Event onManagement: () => void = (): void => {};
  /** 手机单栏下请求 Index 压入 'note-detail'；Index 负责去重。 */
  @Event onOpenDetail: () => void = (): void => {};
  @Event onPreview: (item: NoteAttachment, uri: string) => void = (): void => {};
  private detailStack: NavPathStack = new NavPathStack();

  @ComponentAppear
  onNoteAppear(): void { this.selectionChanged(); }

  @Monitor('model.selected', 'wide')
  private selectionChanged(): void {
    if (this.model.selected === undefined) { this.detailStack.clear(); }
    else if (this.wide && this.detailStack.size() === 0) { this.detailStack.pushPathByName('detail', undefined); }
    else if (!this.wide) {
      this.detailStack.clear();
      // 手机单栏或宽屏缩为手机时，选中笔记交给独立详情页显示；Index 侧对重复压栈去重。
      this.onOpenDetail();
    }
  }

  private open(row: NoteRowView): void {
    if (this.model.selected?.id !== row.id || this.model.detail === undefined && !this.model.detailLoading) { this.model.select(row.item); }
    if (!this.wide) { this.onOpenDetail(); }
  }

  @Builder
  listPane() {
    NoteListPane({ model: this.model, scroller: this.scroller, bottomInset: this.bottomInset, highlightSelected: this.wide,
      onOpen: (row: NoteRowView): void => { this.open(row); }, onManagement: (): void => { this.onManagement(); } })
  }

  @Builder
  noteDetail(name: string) {
    if (name === 'detail') {
      NavDestination() {
        NoteDetailPane({ model: this.model, scroller: this.detailScroller, bottomInset: this.bottomInset, showInlineTitle: true,
          activeAttachmentKey: this.model.attachments.activeKey,
          onPreview: (item: NoteAttachment, uri: string): void => { this.onPreview(item, uri); },
          onManagement: (): void => { this.onManagement(); } })
      }.hideTitleBar(true).backgroundColor($r('app.color.workbench_background'))
        .onBackPressed((): boolean => this.model.back())
    }
  }

  build() {
    Column() {
      if (this.wide) {
        Navigation(this.detailStack) { this.listPane() }
          .mode(NavigationMode.Auto).navBarWidth('40%').hideTitleBar(true).hideToolBar(true).navDestination(this.noteDetail)
      } else {
        this.listPane()
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.workbench_background'))
  }
}
