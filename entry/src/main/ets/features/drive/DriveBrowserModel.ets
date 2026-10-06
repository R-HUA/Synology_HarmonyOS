import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { DriveEntry, DriveEntryKind, DriveFolderRef, DriveSpace, DriveView, driveViewLabel } from '../../core/domain/DriveProtocol';
import type { DriveViewPage, DriveAncestor } from '../../core/domain/DriveProtocol';
import { DriveAdapter } from '../../core/network/DriveAdapter';
import { NasConnector } from '../../core/network/NasConnector';
import { hilog } from '@kit.PerformanceAnalysisKit';

export const DRIVE_ROOT_LABEL = '我的文件';
export const DRIVE_BROWSER_VIEWS: DriveView[] = [DriveView.MyDrive, DriveView.TeamFolders, DriveView.Recent,
  DriveView.Starred, DriveView.SharedWithMe, DriveView.SharedWithOthers, DriveView.Trash];

/** 面包屑一层。`fileId` 缺省表示个人空间根，与 `DriveFolderRef` 的约定一致。 */
export interface DriveTrailItem {
  name: string;
  fileId?: string;
  /** 保留服务器给出的目录能力，标题上传入口不为虚拟根或未知祖先伪造权限。 */
  entry?: DriveEntry;
}

interface DriveSearchQuery {
  keyword: string;
  folder?: DriveFolderRef;
  scopeName: string;
}

interface DrivePagePosition {
  offset: number;
  previousOffsets: number[];
}

interface DriveBrowseReturn {
  trail: DriveTrailItem[];
  view: DriveView;
  position: DrivePagePosition;
}

/**
 * Drive 只读浏览状态。
 *
 * 与 `PhotoLibrary` / `TelemetryMonitor` 一样是独立子模型：Drive 走的是一套
 * **无兼容承诺**的内部接口，状态与 File Station 完全分开，任何一侧出问题都不该
 * 影响另一侧；来源切换由界面决定，切换本身不改变这里的已加载内容。
 */
@ObservedV2
export class DriveBrowserModel {
  /** 服务器是否通告了可用的 Drive 接口；false 时来源切换应保持不可选并说明原因。 */
  @Trace available: boolean = false;
  @Trace busy: boolean = false;
  @Trace errorText: string = '';
  /** 只读阶段的一次性说明（例如点了暂不支持的文件），换目录或刷新时清空。 */
  @Trace notice: string = '';
  @Trace entries: DriveEntry[] = [];
  @Trace total: number | undefined = undefined;
  @Trace view: DriveView = DriveView.MyDrive;
  @Trace searchText: string = '';
  @Trace searchKeyword: string = '';
  @Trace searchScopeName: string = DRIVE_ROOT_LABEL;
  @Trace hasMore: boolean = false;
  @Trace pageOffset: number = 0;
  /** 面包屑与导航共用同一份栈，避免"显示的位置"和"请求的位置"各说各话。 */
  @Trace trail: DriveTrailItem[] = [{ name: DRIVE_ROOT_LABEL }];
  /** 根目录是否已成功列出；只用于避免每次切来源都重复请求，不作为"当前有数据"的判据。 */
  @Trace loaded: boolean = false;
  private adapter: DriveAdapter | undefined = undefined;
  private onSessionFailure: ((error: NasFailure) => Promise<void>) | undefined = undefined;
  private generation: number = 0;
  private previousOffsets: number[] = [];
  private searchQuery: DriveSearchQuery | undefined = undefined;
  private searchReturn: DriveBrowseReturn | undefined = undefined;
  private searchResultsPosition: DrivePagePosition | undefined = undefined;

  attach(connector: NasConnector, onSessionFailure: (error: NasFailure) => Promise<void>): void {
    this.detach();
    const adapter = new DriveAdapter(connector);
    this.adapter = adapter;
    this.onSessionFailure = onSessionFailure;
    this.available = adapter.available();
  }

  detach(): void {
    this.adapter = undefined;
    this.onSessionFailure = undefined;
    this.available = false;
    this.reset();
  }

  reset(): void {
    this.generation++;
    this.busy = false;
    this.errorText = '';
    this.notice = '';
    this.entries = [];
    this.total = undefined;
    this.view = DriveView.MyDrive;
    this.searchText = '';
    this.searchKeyword = '';
    this.searchScopeName = DRIVE_ROOT_LABEL;
    this.searchQuery = undefined;
    this.searchReturn = undefined;
    this.searchResultsPosition = undefined;
    this.hasMore = false;
    this.pageOffset = 0;
    this.trail = [{ name: DRIVE_ROOT_LABEL }];
    this.loaded = false;
    this.previousOffsets = [];
  }

  /** 切到 Drive 来源时调用。已成功加载过就复用现有内容，不重复打请求。 */
  async open(): Promise<void> {
    if (!this.available || this.loaded || this.busy) { return; }
    await this.load(this.trail, 0);
  }

  /** 手动刷新始终回到当前目录第一页。 */
  async reload(): Promise<void> {
    if (!this.supportsView(this.view)) { return; }
    await this.load(this.trail, 0);
  }

  supportsView(view: DriveView): boolean {
    return this.adapter !== undefined && this.adapter.available(view);
  }

  /** 成功读取之后才切换入口和导航，失败时保留当前内容供用户重试。 */
  async selectView(view: DriveView): Promise<void> {
    if (view === DriveView.Search) { return; }
    if (this.busy || !this.supportsView(view) || this.view === view && this.trail.length === 1 && this.loaded) { return; }
    await this.load([{ name: driveViewLabel(view) }], 0, view);
  }

  async search(value: string): Promise<void> {
    if (this.busy || !this.supportsView(DriveView.Search)) { return; }
    const folder = this.searchFolder();
    const query: DriveSearchQuery = { keyword: value.trim(), folder,
      scopeName: folder?.displayName ?? DRIVE_ROOT_LABEL };
    await this.load([{ name: driveViewLabel(DriveView.Search) }], 0, DriveView.Search, [], query);
  }

  searchPlaceholder(): string {
    return this.searchFolder() === undefined ? '搜索我的文件' : '搜索当前文件夹';
  }

  private searchFolder(): DriveFolderRef | undefined {
    const current = this.trail[this.trail.length - 1];
    if (current.fileId !== undefined) {
      return { space: this.view === DriveView.TeamFolders ? DriveSpace.TeamFolder : DriveSpace.MyDrive,
        fileId: current.fileId, displayName: current.name };
    }
    return this.view === DriveView.Search ? this.searchQuery?.folder : undefined;
  }

  async exitSearch(): Promise<void> {
    const origin = this.searchReturn;
    if (this.busy || this.view !== DriveView.Search || origin === undefined) { return; }
    await this.load(origin.trail, origin.position.offset, origin.view, origin.position.previousOffsets);
  }

  async openFolder(entry: DriveEntry): Promise<void> {
    if (entry.kind !== DriveEntryKind.Folder || !entry.capabilities.canRead || this.busy) { return; }
    if (this.view === DriveView.Trash) {
      this.notice = '暂不支持打开回收站内的文件夹。';
      return;
    }
    const target: DriveTrailItem = { name: entry.name, fileId: entry.fileId, entry: entry };
    const crossDirectory = this.trail.length === 1 &&
      this.view !== DriveView.MyDrive && this.view !== DriveView.TeamFolders;
    await this.load(this.trail.concat([target]), 0, this.view, [], this.searchQuery,
      crossDirectory ? entry : undefined);
  }

  /** 点面包屑或「返回上级」：目标层成功加载后才收缩面包屑，避免位置与内容不一致。 */
  async goToTrail(index: number): Promise<void> {
    if (this.busy || index < 0 || index >= this.trail.length - 1) { return; }
    const position = index === 0 && this.view === DriveView.Search ? this.searchResultsPosition : undefined;
    await this.load(this.trail.slice(0, index + 1), position?.offset ?? 0, this.view, position?.previousOffsets ?? []);
  }

  async goUp(): Promise<void> {
    if (this.trail.length === 1 && this.view === DriveView.Search) { await this.exitSearch(); }
    else { await this.goToTrail(this.trail.length - 2); }
  }

  uploadDestination(): DriveEntry | undefined {
    const entry = this.trail[this.trail.length - 1].entry;
    return this.loaded && !this.busy && this.view !== DriveView.Trash && entry?.capabilities.canRead && entry.capabilities.canWrite ? entry : undefined;
  }

  async previousPage(): Promise<void> {
    if (this.busy || this.previousOffsets.length === 0) { return; }
    const history = this.previousOffsets.slice(0, -1);
    await this.load(this.trail, this.previousOffsets[this.previousOffsets.length - 1], this.view, history);
  }

  async nextPage(): Promise<void> {
    if (this.busy || !this.hasMore || this.entries.length === 0) { return; }
    await this.load(this.trail, this.pageOffset + this.entries.length, this.view,
      this.previousOffsets.concat([this.pageOffset]));
  }

  /** 当前页是否还有下一页；供界面决定「下一页」是否可点。 */
  more(): boolean {
    return this.hasMore;
  }

  canGoUp(): boolean {
    return this.trail.length > 1 || this.view === DriveView.Search && this.searchReturn !== undefined;
  }

  /**
   * 列表入口与真实目录区分：团队入口没有虚拟路径，选中后只使用 fileId。
   */
  private folderOf(item: DriveTrailItem, view: DriveView): DriveFolderRef {
    return { space: view === DriveView.TeamFolders ? DriveSpace.TeamFolder : DriveSpace.MyDrive, fileId: item.fileId };
  }

  private async load(trail: DriveTrailItem[], offset: number, view: DriveView = this.view,
    previousOffsets: number[] = [], query: DriveSearchQuery | undefined = this.searchQuery,
    ancestorTarget?: DriveEntry): Promise<boolean> {
    const adapter = this.adapter;
    if (adapter === undefined || this.busy) { return false; }
    const ticket = this.generation;
    this.busy = true;
    this.errorText = '';
    this.notice = '';
    try {
      if (ancestorTarget !== undefined) {
        const ancestors = await adapter.ancestors(ancestorTarget);
        if (ticket !== this.generation) { return false; }
        trail = [trail[0]].concat(ancestors.map((item: DriveAncestor): DriveTrailItem =>
          ({ name: item.name || '根目录', fileId: item.fileId })), [trail[trail.length - 1]]);
      }
      const current = trail[trail.length - 1];
      let page: DriveViewPage;
      if (current.fileId === undefined) {
        if (view === DriveView.Search) {
          if (query === undefined) { throw new NasFailure(NasErrorKind.InvalidInput, '请输入搜索内容。'); }
          page = await adapter.search(query.keyword, offset, query.folder);
        } else { page = await adapter.readView(view, offset); }
      }
      else {
        const folderPage = await adapter.list(this.folderOf(current, view), offset);
        page = { items: folderPage.items, total: folderPage.total, offset: folderPage.offset,
          hasMore: folderPage.offset + folderPage.items.length < folderPage.total };
      }
      if (ticket !== this.generation) { return false; }
      // recent 没有 total 时需要多读一页确认末尾；确认后保留最后一页，不展示假空列表。
      if (page.total === undefined && page.items.length === 0 && offset > 0) {
        this.hasMore = false;
        this.notice = '已到列表末尾。';
        return false;
      }
      if (view === DriveView.Search && this.view !== DriveView.Search) {
        this.searchReturn = { trail: this.trail, view: this.view,
          position: { offset: this.pageOffset, previousOffsets: this.previousOffsets } };
      }
      if (view === DriveView.Search && trail.length === 1) {
        this.searchResultsPosition = { offset: page.offset, previousOffsets };
        this.searchText = query?.keyword ?? '';
      }
      this.entries = page.items;
      this.total = page.total;
      this.pageOffset = page.offset;
      this.hasMore = page.hasMore;
      this.view = view;
      this.searchKeyword = view === DriveView.Search ? query?.keyword ?? '' : '';
      this.searchScopeName = view === DriveView.Search ? query?.scopeName ?? DRIVE_ROOT_LABEL : DRIVE_ROOT_LABEL;
      this.searchQuery = view === DriveView.Search ? query : undefined;
      if (view !== DriveView.Search) {
        this.searchReturn = undefined;
        this.searchResultsPosition = undefined;
        this.searchText = '';
      }
      this.trail = trail;
      this.previousOffsets = previousOffsets;
      this.loaded = true;
      hilog.info(0x0000, 'NasDrive', 'operation=list result=success');
      return true;
    } catch (error) {
      if (ticket === this.generation) { await this.fail(error as Object); }
      return false;
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }

  /** 会话失效要交给连接层统一处理；其余错误只在本来源内提示，不污染 File Station 的文案。 */
  private async fail(error: Object): Promise<void> {
    hilog.error(0x0000, 'NasDrive', 'operation=list kind=%{public}d code=%{public}d',
      error instanceof NasFailure ? error.kind : -1, error instanceof NasFailure ? error.code : 0);
    this.errorText = error instanceof NasFailure ? error.message : 'Drive 请求未完成，请稍后重试。';
    if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired && this.onSessionFailure !== undefined) {
      await this.onSessionFailure(error);
    }
  }
}
