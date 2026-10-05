import { NasErrorKind, NasFailure } from '../domain/DsmProtocol';
import type { NasFormField } from '../domain/DsmProtocol';
import { decodeDrivePage, DRIVE_FILES_API, DRIVE_LIST_VERSION, DRIVE_PAGE_SIZE, DriveSortBy,
  DriveSortDirection, driveListFields, DriveView, DRIVE_TEAM_FOLDERS_API, DRIVE_TEAM_FOLDERS_VERSION,
  DRIVE_TRASH_API, DRIVE_TRASH_VERSION, driveViewFields, decodeDriveViewPage } from '../domain/DriveProtocol';
import type { DriveFolderRef, DrivePage, DriveViewPage } from '../domain/DriveProtocol';

interface DriveReadSpec { api: string; version: number; method: string; feature: string; }

/**
 * 内核需要向 Drive 适配器暴露的最小能力集合。由 `NasConnector` 实现。
 *
 * 刻意做成窄接口而不是把 `NasConnector` 直接递进来：Drive 是**无兼容承诺**的
 * 内部接口，将来整体切到官方 Office Suite REST 时，只需替换本适配器与这个端口，
 * 不必动内核；同时纯逻辑测试可以注入假端口，不需要真实套件。
 */
export interface DriveKernelPort {
  /** 该 api 是否已通告，且落在某个已核对的版本上。 */
  supportsDriveApi(api: string, version: number): boolean;
  /** 统一调用：Cookie 会话、代际校验、Drive 错误码解释都在内核完成。 */
  requestDrive(api: string, version: number, method: string, fields: NasFormField[]): Promise<Record<string, Object>>;
  /** 把一次真实读取登记到能力状态机（如 driveBrowse）。 */
  readDriveFeature<T>(feature: string, read: () => Promise<T>): Promise<T>;
}

/**
 * Drive 只读适配器：目录与视图入口分别使用已探测的方法和响应契约。
 */
export class DriveAdapter {
  constructor(private kernel: DriveKernelPort) {}

  /** Drive 是否可用。界面据此决定来源切换能不能点、以及为什么不能点。 */
  available(view: DriveView = DriveView.MyDrive): boolean {
    const spec = this.viewSpec(view);
    return this.kernel.supportsDriveApi(spec.api, spec.version);
  }

  /** 短页之后按实际返回数量继续请求，因此合法 offset 不必是页大小的倍数。 */
  async list(folder: DriveFolderRef, offset: number = 0, sortBy: DriveSortBy = DriveSortBy.Name,
    sortDirection: DriveSortDirection = DriveSortDirection.Ascending): Promise<DrivePage> {
    if (!Number.isSafeInteger(offset) || offset < 0) {
      throw new NasFailure(NasErrorKind.InvalidInput, 'Drive 列表分页位置不正确，请刷新目录后重试。');
    }
    const fields = driveListFields(folder, offset, sortBy, sortDirection);
    const read = async (): Promise<DrivePage> => decodeDrivePage(
      await this.kernel.requestDrive(DRIVE_FILES_API, DRIVE_LIST_VERSION, 'list', fields), offset, DRIVE_PAGE_SIZE);
    // 只有第一页代表"这个来源能用"；后续页失败不该把已确认的能力打回未验证。
    return offset === 0 ? this.kernel.readDriveFeature('driveBrowse', read) : read();
  }

  async readView(view: DriveView, offset: number = 0): Promise<DriveViewPage> {
    const spec = this.viewSpec(view);
    const fields = driveViewFields(view, offset);
    const read = async (): Promise<DriveViewPage> => decodeDriveViewPage(
      await this.kernel.requestDrive(spec.api, spec.version, spec.method, fields), view, offset);
    return offset === 0 ? this.kernel.readDriveFeature(spec.feature, read) : read();
  }

  private viewSpec(view: DriveView): DriveReadSpec {
    switch (view) {
      case DriveView.MyDrive:
        return { api: DRIVE_FILES_API, version: DRIVE_LIST_VERSION, method: 'list', feature: 'driveBrowse' };
      case DriveView.TeamFolders:
        return { api: DRIVE_TEAM_FOLDERS_API, version: DRIVE_TEAM_FOLDERS_VERSION, method: 'list', feature: 'driveTeamFolders' };
      case DriveView.Trash:
        return { api: DRIVE_TRASH_API, version: DRIVE_TRASH_VERSION, method: 'list', feature: 'driveTrash' };
      case DriveView.Recent:
        return { api: DRIVE_FILES_API, version: 2, method: 'recent', feature: 'driveRecent' };
      case DriveView.Starred:
        return { api: DRIVE_FILES_API, version: 2, method: 'list_starred', feature: 'driveStarred' };
      case DriveView.SharedWithMe:
        return { api: DRIVE_FILES_API, version: 2, method: 'shared_with_me', feature: 'driveSharedWithMe' };
      case DriveView.SharedWithOthers:
        return { api: DRIVE_FILES_API, version: 2, method: 'shared_with_others', feature: 'driveSharedWithOthers' };
    }
  }
}
