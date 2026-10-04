import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { DriveEntry, DriveEntryKind, DriveFolderRef, DriveSpace, DRIVE_PAGE_SIZE } from '../../core/domain/DriveProtocol';
import { DriveAdapter } from '../../core/network/DriveAdapter';
import { NasConnector } from '../../core/network/NasConnector';
import { hilog } from '@kit.PerformanceAnalysisKit';

export const DRIVE_ROOT_LABEL = '我的文件';

/** 面包屑一层。`fileId` 缺省表示个人空间根，与 `DriveFolderRef` 的约定一致。 */
export interface DriveTrailItem {
  name: string;
  fileId?: string;
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
  @Trace total: number = 0;
  @Trace pageOffset: number = 0;
  /** 面包屑与导航共用同一份栈，避免"显示的位置"和"请求的位置"各说各话。 */
  @Trace trail: DriveTrailItem[] = [{ name: DRIVE_ROOT_LABEL }];
  /** 根目录是否已成功列出；只用于避免每次切来源都重复请求，不作为"当前有数据"的判据。 */
  @Trace loaded: boolean = false;
  private adapter: DriveAdapter | undefined = undefined;
  private onSessionFailure: ((error: NasFailure) => Promise<void>) | undefined = undefined;
  private generation: number = 0;

  attach(connector: NasConnector, onSessionFailure: (error: NasFailure) => Promise<void>): void {
    this.detach();
    const adapter = new DriveAdapter(connector);
    this.adapter = adapter;
    this.onSessionFailure = onSessionFailure;
    this.available = adapter.available();
  }

  detach(): void {
    this.generation++;
    this.adapter = undefined;
    this.onSessionFailure = undefined;
    this.reset();
  }

  reset(): void {
    this.busy = false;
    this.errorText = '';
    this.notice = '';
    this.entries = [];
    this.total = 0;
    this.pageOffset = 0;
    this.trail = [{ name: DRIVE_ROOT_LABEL }];
    this.loaded = false;
  }

  /** 切到 Drive 来源时调用。已成功加载过就复用现有内容，不重复打请求。 */
  async open(): Promise<void> {
    if (!this.available || this.loaded || this.busy) { return; }
    await this.load(this.folderOf(this.trail[0]), 0);
  }

  /** 手动刷新始终回到当前目录第一页。 */
  async reload(): Promise<void> {
    if (!this.available) { return; }
    await this.load(this.currentFolder(), 0);
  }

  async openFolder(entry: DriveEntry): Promise<void> {
    if (entry.kind !== DriveEntryKind.Folder || this.busy) { return; }
    const target: DriveTrailItem = { name: entry.name, fileId: entry.fileId };
    if (await this.load(this.folderOf(target), 0)) { this.trail = this.trail.concat([target]); }
  }

  /** 点面包屑或「返回上级」：目标层成功加载后才收缩面包屑，避免位置与内容不一致。 */
  async goToTrail(index: number): Promise<void> {
    if (this.busy || index < 0 || index >= this.trail.length - 1) { return; }
    if (await this.load(this.folderOf(this.trail[index]), 0)) { this.trail = this.trail.slice(0, index + 1); }
  }

  async goUp(): Promise<void> {
    await this.goToTrail(this.trail.length - 2);
  }

  async previousPage(): Promise<void> {
    if (this.busy || this.pageOffset === 0) { return; }
    await this.load(this.currentFolder(), Math.max(0, this.pageOffset - DRIVE_PAGE_SIZE));
  }

  async nextPage(): Promise<void> {
    if (this.busy || this.pageOffset + this.entries.length >= this.total) { return; }
    await this.load(this.currentFolder(), this.pageOffset + DRIVE_PAGE_SIZE);
  }

  /** 当前页是否还有下一页；供界面决定「下一页」是否可点。 */
  more(): boolean {
    return this.pageOffset + this.entries.length < this.total;
  }

  canGoUp(): boolean {
    return this.trail.length > 1;
  }

  private currentFolder(): DriveFolderRef {
    return this.folderOf(this.trail[this.trail.length - 1]);
  }

  /**
   * 团队成员与共享条目今后会带各自的空间，这里按栈项还原请求位置。
   * P0 只有个人空间，`fileId` 缺省即根。
   */
  private folderOf(item: DriveTrailItem): DriveFolderRef {
    return item.fileId === undefined ? { space: DriveSpace.MyDrive } : { space: DriveSpace.MyDrive, fileId: item.fileId };
  }

  private async load(folder: DriveFolderRef, offset: number): Promise<boolean> {
    const adapter = this.adapter;
    if (adapter === undefined || this.busy) { return false; }
    const ticket = this.generation;
    this.busy = true;
    this.errorText = '';
    this.notice = '';
    try {
      const page = await adapter.list(folder, offset);
      if (ticket !== this.generation) { return false; }
      this.entries = page.items;
      this.total = page.total;
      this.pageOffset = page.offset;
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
