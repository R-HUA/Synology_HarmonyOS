import { NoteModel } from './NoteModel';
import { NoteFolder, filterNotes } from './NoteProtocol';
import { NoteRowView, noteRows, folderTitle } from './NotePresentation';
import { WorkbenchChoice, WorkbenchEmptyState, WorkbenchIconTile, WorkbenchMetrics, WorkbenchNotice, WorkbenchServiceError,
  WorkbenchSkeleton } from '../workbench/WorkbenchUi';

/** 笔记列表：搜索与筛选固定在顶部，只有 List 滚动；加载更多、到底与空结果都在滚动流末尾。 */
@ComponentV2
export struct NoteListPane {
  @Require @Param model: NoteModel = new NoteModel();
  @Param scroller: Scroller = new Scroller();
  @Param bottomInset: number = 16;
  /** 宽屏左栏中高亮当前笔记；手机单栏不高亮（详情在独立页面）。 */
  @Param highlightSelected: boolean = false;
  @Event onOpen: (row: NoteRowView) => void = (_row: NoteRowView): void => {};
  @Event onManagement: () => void = (): void => {};
  @Local private refreshing: boolean = false;
  @Local private folderSheetVisible: boolean = false;
  /** 'notebooks' | 'tags'：当前打开的选择面板。 */
  @Local private folderKind: string = 'notebooks';
  private reachArmed: boolean = false;

  /** 过滤结果每次状态变化只算一次；build 内多处读取共用同一结果。 */
  @Computed
  private get rows(): NoteRowView[] {
    return noteRows(filterNotes(this.model.items, this.model.notebook, this.model.tag, this.model.query, this.model.tags),
      this.model.notebooks, this.model.tags);
  }

  private async refresh(): Promise<void> {
    if (this.refreshing) { return; }
    this.refreshing = true; this.reachArmed = false;
    try { await this.model.refresh(); } finally { this.refreshing = false; }
  }
  private loadMore(): void {
    this.reachArmed = false;
    if (this.model.more && !this.model.loading) { this.model.refresh(true); }
  }
  private openFolders(kind: string): void { this.folderKind = kind; this.folderSheetVisible = true; }
  private chooseFolder(id: string): void {
    if (this.folderKind === 'notebooks') { this.model.notebook = id; } else { this.model.tag = id; }
    this.folderSheetVisible = false;
  }
  private resourceText(value: Resource): string {
    return this.getUIContext().getHostContext()!.resourceManager.getStringSync(value.id);
  }
  private chipLabel(kind: string): string {
    const title = kind === 'notebooks' ? folderTitle(this.model.notebooks, this.model.notebook) : folderTitle(this.model.tags, this.model.tag);
    return title.length > 0 ? title : this.resourceText(kind === 'notebooks' ? $r('app.string.notes_all_notebooks') : $r('app.string.notes_all_tags'));
  }
  private folders(): NoteFolder[] { return this.folderKind === 'notebooks' ? this.model.notebooks : this.model.tags; }
  private folderSelected(): string { return this.folderKind === 'notebooks' ? this.model.notebook : this.model.tag; }
  private folderMore(): boolean { return this.folderKind === 'notebooks' ? this.model.moreNotebooks : this.model.moreTags; }
  private folderError(): string { return this.folderKind === 'notebooks' ? this.model.notebookError : this.model.tagError; }

  @Builder
  noteRow(row: NoteRowView) {
    Row({ space: 12 }) {
      WorkbenchIconTile({ icon: $r('sys.symbol.doc_text'), iconSize: 22, tileSize: 40 })
      Column({ space: 2 }) {
        Text(row.title).fontSize(16).fontColor($r('sys.color.font_primary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (row.subtitle.length > 0) {
          Text(row.subtitle).fontSize(14).fontColor($r('sys.color.font_secondary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(WorkbenchMetrics.rowArrowSize)
        .fontColor([$r('sys.color.font_secondary')]).opacity(WorkbenchMetrics.rowArrowOpacity).accessibilityLevel('no')
    }.width('100%').constraintSize({ minHeight: WorkbenchMetrics.rowMinHeight }).padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .borderRadius(WorkbenchMetrics.cardRadius)
      .backgroundColor(this.highlightSelected && this.model.selected?.id === row.id ? $r('app.color.workbench_accent_surface') : $r('app.color.workbench_surface'))
      .accessibilityGroup(true).accessibilityText(row.title + (row.subtitle.length > 0 ? '，' + row.subtitle : ''))
      .onClick((): void => { this.onOpen(row); })
  }

  @Builder
  footer() {
    Column({ space: 12 }) {
      if (this.model.loading) {
        LoadingProgress().width(32).height(32)
      } else if (this.model.more) {
        if (this.rows.length === 0) {
          Text($r('app.string.notes_search_loaded_only', this.model.items.length)).fontSize(14).fontColor($r('sys.color.font_secondary'))
            .textAlign(TextAlign.Center)
        }
        Button($r('app.string.notes_load_more')).buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
          .onClick((): void => { this.loadMore(); })
      } else if (this.rows.length > 0) {
        Text($r('app.string.notes_list_end', this.model.items.length)).fontSize(14).fontColor($r('sys.color.font_secondary'))
      }
      Button($r('app.string.package_open_management')).buttonStyle(ButtonStyleMode.TEXTUAL)
        .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).onClick(this.onManagement)
    }.width('100%').padding({ top: 12, bottom: 12 })
  }

  @Builder
  folderSheet() {
    List() {
      ListItem() { this.folderRow('', this.resourceText(this.folderKind === 'notebooks' ? $r('app.string.notes_all_notebooks') : $r('app.string.notes_all_tags'))) }
      Repeat<NoteFolder>(this.folders()).each((entry: RepeatItem<NoteFolder>): void => {
        ListItem() { this.folderRow(entry.item.id, entry.item.title) }
      }).key((folder: NoteFolder): string => this.folderKind + ':' + folder.id).virtualScroll()
      ListItem() {
        Column({ space: 8 }) {
          if (this.folderError().length > 0) {
            WorkbenchNotice({ text: this.folderError(), warning: true, retryable: !this.model.loading,
              onRetry: (): void => { this.model.refresh(); } })
          }
          if (this.model.loading) { LoadingProgress().width(32).height(32) }
          else if (this.folderMore()) {
            Button($r('app.string.notes_load_more_folders')).buttonStyle(ButtonStyleMode.TEXTUAL)
              .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).onClick((): void => { this.model.loadFolders(this.folderKind); })
          }
        }.width('100%').padding({ top: 8, bottom: 16 })
      }
    }.width('100%').height('100%').padding({ left: WorkbenchMetrics.sheetMargin, right: WorkbenchMetrics.sheetMargin })
      .divider({ strokeWidth: 0.5, color: $r('app.color.workbench_divider') })
  }

  @Builder
  folderRow(id: string, title: string) {
    Row({ space: 12 }) {
      Text(title).fontSize(16).fontColor($r('sys.color.font_primary')).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.folderSelected() === id) {
        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(20).fontColor([$r('sys.color.icon_emphasize')]).accessibilityLevel('no')
      }
    }.width('100%').constraintSize({ minHeight: 56 })
      .accessibilityGroup(true).accessibilityText(title + (this.folderSelected() === id ? '，已选择' : ''))
      .onClick((): void => { this.chooseFolder(id); })
  }

  build() {
    Column() {
      Search({ value: this.model.query, placeholder: $r('app.string.notes_search') }).defaultFocus(false)
        .onChange((value: string): void => { this.model.query = value; })
      Row() {
        WorkbenchChoice({ label: this.chipLabel('notebooks'), selected: this.model.notebook.length > 0,
          onSelect: (): void => { this.openFolders('notebooks'); } })
        WorkbenchChoice({ label: this.chipLabel('tags'), selected: this.model.tag.length > 0,
          onSelect: (): void => { this.openFolders('tags'); } })
      }.width('100%').padding({ top: 8 })
        .bindSheet($$this.folderSheetVisible, this.folderSheet(), {
          height: SheetSize.LARGE, showClose: true,
          title: { title: this.folderKind === 'notebooks' ? $r('app.string.notes_pick_notebook') : $r('app.string.notes_pick_tag') },
          backgroundColor: $r('app.color.workbench_surface_elevated')
        })
      Refresh({ refreshing: this.refreshing }) {
        List({ space: 8, scroller: this.scroller }) {
          if (this.model.items.length === 0) {
            ListItem() {
              Column() {
                if (this.model.loading) { WorkbenchSkeleton() }
                else if (this.model.errorText.length > 0) {
                  WorkbenchServiceError({ message: this.model.errorText, title: $r('app.string.notes_unavailable'), available: !this.model.loading,
                    onRetry: (): void => { this.model.refresh(); }, onManagement: this.onManagement })
                } else if (this.model.loaded) {
                  WorkbenchEmptyState({ icon: $r('sys.symbol.doc_text'), title: $r('app.string.notes_empty'),
                    secondaryLabel: $r('app.string.package_open_management'), onSecondaryAction: this.onManagement })
                }
              }.width('100%')
            }
          } else {
            if (this.model.errorText.length > 0 || this.model.notebookError.length > 0 || this.model.tagError.length > 0) {
              ListItem() {
                WorkbenchNotice({ text: this.model.errorText || this.model.notebookError || this.model.tagError, warning: true,
                  retryable: !this.model.loading, onRetry: (): void => { this.model.refresh(); } })
              }
            }
            if (this.rows.length === 0 && this.model.loaded) {
              ListItem() { WorkbenchEmptyState({ icon: $r('sys.symbol.magnifyingglass'), title: $r('app.string.notes_no_matches') }) }
            }
            Repeat<NoteRowView>(this.rows).each((entry: RepeatItem<NoteRowView>): void => {
              ListItem() { this.noteRow(entry.item) }
            }).key((row: NoteRowView): string => row.id).virtualScroll()
            ListItem() { this.footer() }
          }
        }.width('100%').height('100%').scrollBar(BarState.Auto).contentEndOffset(this.bottomInset).padding({ top: 12 })
          .onScrollStart((): void => { if (!this.model.loading) { this.reachArmed = true; } })
          .onReachEnd((): void => { if (this.reachArmed) { this.loadMore(); } })
      }.width('100%').layoutWeight(1).onRefreshing((): void => { this.refresh(); })
    }.width('100%').height('100%').padding({ top: 8, left: 16, right: 16 })
  }
}
