import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasFailure, NasErrorKind } from '../../core/domain/DsmProtocol';
import { NasConnector } from '../../core/network/NasConnector';
import { NoteSummary, NoteDetail, NoteFolder } from './NoteProtocol';
import { NoteRepository } from './NoteRepository';
import { NoteAttachmentStore } from './NoteAttachmentStore';

@ObservedV2
export class NoteModel {
  @Trace items: NoteSummary[] = [];
  @Trace notebooks: NoteFolder[] = [];
  @Trace tags: NoteFolder[] = [];
  @Trace notebookOffset: number = 0;
  @Trace tagOffset: number = 0;
  @Trace moreNotebooks: boolean = false;
  @Trace moreTags: boolean = false;
  @Trace notebookError: string = '';
  @Trace tagError: string = '';
  @Trace loaded: boolean = false;
  @Trace loading: boolean = false;
  @Trace checkedAt: number = 0;
  @Trace errorText: string = '';
  @Trace more: boolean = false;
  @Trace query: string = '';
  @Trace notebook: string = '';
  @Trace tag: string = '';
  @Trace selected: NoteSummary | undefined = undefined;
  @Trace detail: NoteDetail | undefined = undefined;
  @Trace detailLoading: boolean = false;
  @Trace detailError: string = '';
  readonly attachments: NoteAttachmentStore = new NoteAttachmentStore();
  private repository: NoteRepository | undefined = undefined;
  private visible: boolean = false;
  private generation: number = 0;
  private revision: number = 0;
  private detailRevision: number = 0;
  private offset: number = 0;
  private onExpired: (error: NasFailure) => Promise<void> = async (): Promise<void> => {};
  attach(connector: NasConnector, context: common.UIAbilityContext | undefined, expired: (error: NasFailure) => Promise<void>): void {
    this.reset(); this.repository = new NoteRepository(connector); this.onExpired = expired;
    const generation = this.generation;
    this.attachments.attach(context, this.repository, async (error: Error): Promise<void> => {
      if (generation === this.generation) { await this.failure(error, 'attachment'); }
    });
  }
  reset(): void {
    this.generation++; this.setVisible(false); this.revision++; this.back(); this.attachments.reset();
    this.repository = undefined; this.items = []; this.notebooks = []; this.tags = [];
    this.notebookOffset = 0; this.tagOffset = 0; this.moreNotebooks = false; this.moreTags = false; this.notebookError = ''; this.tagError = '';
    this.loaded = false; this.loading = false; this.checkedAt = 0; this.errorText = ''; this.more = false; this.offset = 0;
    this.query = ''; this.notebook = ''; this.tag = ''; this.onExpired = async (): Promise<void> => {};
  }
  setVisible(value: boolean): void {
    if (this.visible === value) { return; } this.visible = value;
    if (!value) { this.revision++; this.detailRevision++; this.loading = false; this.detailLoading = false; this.attachments.cancel(); }
    else if (this.selected !== undefined && this.detail === undefined) { this.refreshDetail(); }
    else if (!this.loaded && this.errorText.length === 0) { this.refresh(); }
  }
  async refresh(append: boolean = false): Promise<void> {
    const repository = this.repository;
    if (!this.visible || this.loading || repository === undefined || append && !this.more) { return; }
    const revision = ++this.revision, offset = append ? this.offset : 0; this.loading = true; this.errorText = '';
    try {
      const page = await repository.list(offset);
      if (revision !== this.revision) { return; }
      const combined = (append ? this.items : []).concat(page.items), ids: Set<string> = new Set<string>();
      this.items = combined.filter((item: NoteSummary): boolean => { if (ids.has(item.id)) { return false; } ids.add(item.id); return true; });
      this.loaded = true; this.checkedAt = Date.now(); this.offset = offset + page.received; this.more = page.more;
      if (!append) { await this.readFolders('notebooks', false, revision); if (revision === this.revision) { await this.readFolders('tags', false, revision); } }
    } catch (error) { if (revision === this.revision) { const text = await this.failure(error as Error, 'list'); if (revision === this.revision) { this.errorText = text; } } }
    finally { if (revision === this.revision) { this.loading = false; } }
  }
  async loadFolders(kind: string): Promise<void> {
    if (!this.visible || this.loading || (kind === 'notebooks' ? !this.moreNotebooks : !this.moreTags)) { return; }
    const revision = this.revision; this.loading = true;
    try { await this.readFolders(kind, true, revision); } finally { if (revision === this.revision) { this.loading = false; } }
  }
  private async readFolders(kind: string, append: boolean, revision: number): Promise<void> {
    const repository = this.repository!;
    try {
      const offset = append ? kind === 'notebooks' ? this.notebookOffset : this.tagOffset : 0;
      const rows = kind === 'notebooks' ? await repository.notebooks(offset) : await repository.tags(offset);
      if (revision !== this.revision) { return; }
      const all = (append ? kind === 'notebooks' ? this.notebooks : this.tags : []).concat(rows), ids: Set<string> = new Set<string>();
      const folders = all.filter((item: NoteFolder): boolean => { if (ids.has(item.id)) { return false; } ids.add(item.id); return true; });
      if (kind === 'notebooks') { this.notebooks = folders; this.notebookOffset = offset + rows.length; this.moreNotebooks = rows.length === 100; this.notebookError = ''; }
      else { this.tags = folders; this.tagOffset = offset + rows.length; this.moreTags = rows.length === 100; this.tagError = ''; }
    } catch (error) {
      if (revision === this.revision) { const text = await this.failure(error as Error, kind); if (revision === this.revision) { if (kind === 'notebooks') { this.notebookError = text; } else { this.tagError = text; } } }
    }
  }
  select(item: NoteSummary): void { this.back(); this.selected = item; this.refreshDetail(); }
  back(): boolean {
    const selected = this.selected !== undefined; this.detailRevision++; this.attachments.cancel(); this.selected = undefined; this.detail = undefined;
    this.detailLoading = false; this.detailError = ''; return selected;
  }
  async refreshDetail(): Promise<void> {
    const repository = this.repository, item = this.selected;
    if (!this.visible || repository === undefined || item === undefined || this.detailLoading) { return; }
    const revision = ++this.detailRevision; this.detailLoading = true; this.detailError = '';
    try { const detail = await repository.detail(item.id); if (revision === this.detailRevision) { this.detail = detail; } }
    catch (error) { if (revision === this.detailRevision) { const text = await this.failure(error as Error, 'detail'); if (revision === this.detailRevision) { this.detailError = text; } } }
    finally { if (revision === this.detailRevision) { this.detailLoading = false; } }
  }
  private async failure(error: Error, operation: string): Promise<string> {
    hilog.error(0, 'NasNotes', 'operation=%{public}s kind=%{public}d code=%{public}d', operation,
      error instanceof NasFailure ? error.kind : -1, error instanceof NasFailure ? error.code : -1);
    if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { await this.onExpired(error); }
    return error instanceof NasFailure ? error.message : '笔记读取失败，请重试。';
  }
}
