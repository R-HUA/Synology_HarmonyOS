import { NasErrorKind, NasFailure } from '../domain/DsmProtocol';
import type { NasFormField } from '../domain/DsmProtocol';
import { decodeDrivePage, DRIVE_FILES_API, DRIVE_LIST_VERSION, DRIVE_PAGE_SIZE, DriveSortBy,
  DriveSortDirection, driveListFields } from '../domain/DriveProtocol';
import type { DriveFolderRef, DrivePage } from '../domain/DriveProtocol';

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
 * Drive 只读适配器。P0 只暴露「是否可用」与「列目录」两项：
 * 计划里 §2 的其余方法（最近/星标/共享/回收站/上传下载/文件操作/分享）
 * 分别在 P1–P4 落地，避免先写出没有调用方的空壳。
 */
export class DriveAdapter {
  constructor(private kernel: DriveKernelPort) {}

  /** Drive 是否可用。界面据此决定来源切换能不能点、以及为什么不能点。 */
  available(): boolean {
    return this.kernel.supportsDriveApi(DRIVE_FILES_API, DRIVE_LIST_VERSION);
  }

  /** 列出目录。`offset` 必须是页大小的整数倍，防止界面上翻出重叠页。 */
  async list(folder: DriveFolderRef, offset: number = 0, sortBy: DriveSortBy = DriveSortBy.Name,
    sortDirection: DriveSortDirection = DriveSortDirection.Ascending): Promise<DrivePage> {
    if (!Number.isSafeInteger(offset) || offset < 0 || offset % DRIVE_PAGE_SIZE !== 0) {
      throw new NasFailure(NasErrorKind.InvalidInput, 'Drive 列表分页位置不正确，请刷新目录后重试。');
    }
    const fields = driveListFields(folder, offset, sortBy, sortDirection);
    const read = async (): Promise<DrivePage> => decodeDrivePage(
      await this.kernel.requestDrive(DRIVE_FILES_API, DRIVE_LIST_VERSION, 'list', fields), offset, DRIVE_PAGE_SIZE);
    // 只有第一页代表"这个来源能用"；后续页失败不该把已确认的能力打回未验证。
    return offset === 0 ? this.kernel.readDriveFeature('driveBrowse', read) : read();
  }
}
