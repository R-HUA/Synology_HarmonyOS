import { decodeCapabilities, decodeNasFileInfo, decodeNasFilePage, decodeNasResponse, decodeNasSession,
  nasString, NasErrorKind, NasFailure,
  normalizeNasOrigin, selectNasApi, validateApiPath, validateLogicalPath } from '../domain/DsmProtocol';
import type { NasApiDescriptor, NasFileEntry, NasFileInfo, NasFilePage, NasFormField, NasLoginSession } from '../domain/DsmProtocol';
import { assertNasControlAccepted, validateNasControlAction } from '../domain/SystemControl';
import type { NasControlAction } from '../domain/SystemControl';
import { decodePhotosPage, decodeSharedAlbumPage, decodePhotoAlbumPage, decodePhotoDetail, validatePhotoIdentity,
  photoMediaSource, PhotosSpace } from '../domain/PhotosProtocol';
import type { NasPhotoMediaAccess, NasPhotoItem, NasPhotoAlbum, NasPhotoAlbumPage, NasPhotoPage,
  NasSharedAlbum, NasSharedAlbumPage } from '../domain/PhotosProtocol';
import { assertFileOperationSuccess, decodeFileOperationEntry, decodeFileTask, decodeFileTaskStatus,
  NasFileSortBy, NasFileSortDirection, NasFileTaskKind,
  validateFileName, validateFileOperationPath, validateFileOperationPaths, validateFileTask } from '../domain/FileOperations';
import type { NasFileOperationCapabilities, NasFileTask, NasFileTaskStatus } from '../domain/FileOperations';
import { decodeTransferChecksumStatus, decodeTransferChecksumTask,
  validateChecksumTaskId } from '../domain/TransferQueueState';
import type { TransferChecksumStatus } from '../domain/TransferQueueState';
import { DsmRpcClient } from './DsmRpcClient';
import { decodeExtensionResponse } from '../domain/ExtensionProtocol';
import { decodeDriveResponse, DRIVE_FILES_API, DRIVE_LIST_VERSION, DRIVE_TEAM_FOLDERS_API, DRIVE_TEAM_FOLDERS_VERSION,
  DRIVE_TRASH_API, DRIVE_TRASH_VERSION, DRIVE_SEARCH_VERSION, DRIVE_ANCESTORS_VERSION,
  driveUnsupportedFailure } from '../domain/DriveProtocol';
import { selectVerifiedApi } from './ApiVersionPolicy';
import { CapabilityRegistry } from '../capabilities/CapabilityRegistry';
import type { CapabilitySnapshot } from '../capabilities/CapabilityRegistry';
import { SessionRegistry } from './SessionRegistry';
import type { BusinessSessionName, BusinessSessionRecord } from './SessionRegistry';
import type { NasHttpReply, NasTransport } from './DsmRpcClient';
import type { DriveKernelPort } from './DriveAdapter';
import type { DriveTransferKernelPort } from './DriveTransferAdapter';
import { decodeDriveUpload, DRIVE_TRANSFER_VERSION, driveUploadFields, driveDownloadFields,
  validateDriveDownload } from '../domain/DriveTransferProtocol';
import type { DriveUploadRequest, DriveDownloadRequest, DriveUploadResult } from '../domain/DriveTransferProtocol';
import { NasTransferCancellation, validateNasDownloadTarget, validateNasUploadSource } from './NasTransferTransport';
import type { NasBinaryReply, NasDownloadReceipt, NasDownloadResult, NasDownloadTarget, NasTransferControl,
  NasTransferProgress, NasTransferRequest, NasTransferTransport, NasUploadSource } from './NasTransferTransport';
export type { NasHttpReply, NasTransport } from './DsmRpcClient';

export interface NasEnvironment { model: string; dsmVersion: string; fileStationVersion: string; photosVersion: string; administrator: boolean; }
/** 首页设备卡所需的身份信息；读不到的字段一律留空串，由界面兜底。 */
export interface NasDeviceIdentity { model: string; serverName: string; }
export interface NasTransferPlan { address: string; fields: NasFormField[]; session: NasLoginSession; }

export const NAS_DISCOVERY_QUERY = 'SYNO.API.Auth,SYNO.FileStation.List,SYNO.FileStation.Info,' +
  'SYNO.FileStation.Upload,SYNO.FileStation.Download,SYNO.Foto.Browse.Item,SYNO.FotoTeam.Browse.Item,' +
  'SYNO.DSM.Info,SYNO.Core.Package,SYNO.Foto.Sharing.Misc,SYNO.Core.Network,' +
  'SYNO.Foto.Browse.Album,SYNO.FotoTeam.Browse.Album,SYNO.Foto.Thumbnail,SYNO.FotoTeam.Thumbnail,SYNO.Foto.Download,SYNO.FotoTeam.Download,' +
  'SYNO.FileStation.CreateFolder,SYNO.FileStation.Rename,SYNO.FileStation.Delete,SYNO.FileStation.CopyMove,SYNO.FileStation.MD5,' +
  'SYNO.FileStation.Sharing,SYNO.DownloadStation.Task,' +
  // Drive 是独立套件，必须单独问；SYNO.API.Info 只回答被问到的名字。
  'SYNO.SynologyDrive.Files,SYNO.SynologyDrive.TeamFolders,SYNO.SynologyDrive.Trash,' +
  'SYNO.Core.System,SYNO.Core.System.Utilization,SYNO.Storage.CGI.Storage';

interface DriveTransferScope {
  ticket: number;
  sessionRevision: number;
  control: NasTransferControl;
  transport: NasTransferTransport;
  dispose: () => void;
}

export class NasConnector implements DriveKernelPort, DriveTransferKernelPort {
  private driveTransfers: Set<NasTransferCancellation> = new Set<NasTransferCancellation>();
  private origin: string = '';
  private capabilities: NasApiDescriptor[] = [];
  private sessions: SessionRegistry = new SessionRegistry();
  private generation: number = 0;
  private disposed: boolean = false;
  private loggingOut: boolean = false;
  private authenticating: boolean = false;
  private rpc: DsmRpcClient;
  private featureRegistry: CapabilityRegistry = new CapabilityRegistry([
    { feature: 'fileBrowse', api: 'SYNO.FileStation.List', verifiedVersions: [2] },
    { feature: 'personalPhotos', api: 'SYNO.Foto.Browse.Item', verifiedVersions: [1] },
    { feature: 'sharedPhotos', api: 'SYNO.FotoTeam.Browse.Item', verifiedVersions: [1] },
    { feature: 'fileSharing', api: 'SYNO.FileStation.Sharing', verifiedVersions: [3] },
    { feature: 'nasDownloads', api: 'SYNO.DownloadStation.Task', verifiedVersions: [1, 3] },
    { feature: 'driveBrowse', api: DRIVE_FILES_API, verifiedVersions: [DRIVE_LIST_VERSION] },
    { feature: 'driveRecent', api: DRIVE_FILES_API, verifiedVersions: [2] },
    { feature: 'driveStarred', api: DRIVE_FILES_API, verifiedVersions: [2] },
    { feature: 'driveSharedWithMe', api: DRIVE_FILES_API, verifiedVersions: [2] },
    { feature: 'driveSharedWithOthers', api: DRIVE_FILES_API, verifiedVersions: [2] },
    { feature: 'driveSearch', api: DRIVE_FILES_API, verifiedVersions: [DRIVE_SEARCH_VERSION] },
    { feature: 'driveAncestors', api: DRIVE_FILES_API, verifiedVersions: [DRIVE_ANCESTORS_VERSION] },
    { feature: 'driveTeamFolders', api: DRIVE_TEAM_FOLDERS_API, verifiedVersions: [DRIVE_TEAM_FOLDERS_VERSION] },
    { feature: 'driveTrash', api: DRIVE_TRASH_API, verifiedVersions: [DRIVE_TRASH_VERSION] }
  ]);
  constructor(private transport: NasTransport, private sessionName: 'FileStation' | 'NasControl' = 'FileStation') {
    this.rpc = new DsmRpcClient(transport);
  }

  async discover(address: string): Promise<NasApiDescriptor[]> {
    this.ensureOpen();
    if (this.origin.length > 0) { throw new NasFailure(NasErrorKind.InvalidInput, '请先断开当前连接。'); }
    this.origin = normalizeNasOrigin(address);
    const ticket = this.generation;
    const reply = await this.rpc.discover(this.origin, NAS_DISCOVERY_QUERY);
    this.ensureCurrent(ticket);
    this.capabilities = decodeCapabilities(decodeNasResponse('SYNO.API.Info', reply.status, reply.text));
    this.featureRegistry.discover(this.capabilities);
    // 连接只依赖认证接口；File Station 未发现或无权限不阻止登录，文件能力保持未验证并按套件降级。
    selectNasApi(this.capabilities, 'SYNO.API.Auth', [6]);
    return this.capabilities.slice();
  }

  async login(account: string, password: string, otp: string): Promise<void> {
    this.ensureOpen();
    if (account.trim().length === 0 || password.length === 0) { throw new NasFailure(NasErrorKind.InvalidInput, '请输入账号和密码。'); }
    if (otp.length > 0 && !/^[0-9]{6}$/.test(otp)) { throw new NasFailure(NasErrorKind.InvalidInput, '动态码应为 6 位数字。'); }
    if (this.authenticating || this.sessions.has(this.sessionName)) { throw new NasFailure(NasErrorKind.InvalidInput, '当前正在登录或已经登录。'); }
    // 重新登录可能更换账号；不能把上一账号仍有效的附属套件会话带到新账号中。
    this.sessions.clear();
    this.generation++;
    this.featureRegistry.discover(this.capabilities);
    const ticket = this.generation;
    this.authenticating = true;
    try {
      const authorization = decodeNasSession(await this.call('SYNO.API.Auth', 6, 'login',
        this.loginFields(this.sessionName, account, password, otp)));
      this.ensureCurrent(ticket);
      this.sessions.register(this.sessionName, authorization);
      const revision = this.sessions.revision(this.sessionName);
      await this.loginDownloadStation(account, password, otp);
      this.ensureSessionCurrent(ticket, this.sessionName, revision);
    }
    finally { this.authenticating = false; }
  }

  private loginFields(session: BusinessSessionName, account: string, password: string, otp: string): NasFormField[] {
    const fields: NasFormField[] = [
      { name: 'account', content: account.trim() }, { name: 'passwd', content: password },
      { name: 'session', content: session }, { name: 'format', content: 'sid' },
      { name: 'enable_syno_token', content: 'yes' }
    ];
    if (otp.length > 0) { fields.push({ name: 'otp_code', content: otp }); }
    return fields;
  }

  /**
   * Download Station 按 DSM 规范使用独立套件会话；主会话登录成功后凭同一凭据尽力建立。
   * 失败不阻止主登录（含动态码一次性导致二次登录被拒的场景），NAS 下载入口在使用时提示重新登录。
   */
  private async loginDownloadStation(account: string, password: string, otp: string): Promise<void> {
    if (this.sessionName !== 'FileStation' ||
      !this.capabilities.some((api: NasApiDescriptor): boolean => api.name === 'SYNO.DownloadStation.Task')) { return; }
    const ticket = this.generation;
    const revision = this.sessions.revision(this.sessionName);
    try {
      const authorization = decodeNasSession(await this.call('SYNO.API.Auth', 6, 'login',
        this.loginFields('DownloadStation', account, password, otp)));
      this.ensureSessionCurrent(ticket, this.sessionName, revision);
      this.sessions.register('DownloadStation', authorization);
    } catch (error) {
      this.ensureOpen();
      if (error instanceof NasFailure && error.kind === NasErrorKind.Cancelled) { throw error; }
      // 独立套件登录失败时主会话仍可使用；连接取消不能被降级为登录成功。
    }
  }

  async list(path: string, offset: number = 0, sortBy: NasFileSortBy = NasFileSortBy.Name,
    sortDirection: NasFileSortDirection = NasFileSortDirection.Ascending): Promise<NasFilePage> {
    this.ensureOpen();
    if (!this.sessions.has(this.sessionName)) { throw new NasFailure(NasErrorKind.SessionExpired, '请先登录 NAS。'); }
    if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(offset + 100)) {
      throw new NasFailure(NasErrorKind.InvalidInput, '分页位置不正确。');
    }
    if (![NasFileSortBy.Name, NasFileSortBy.Size, NasFileSortBy.ModifiedTime, NasFileSortBy.Type].includes(sortBy) ||
      ![NasFileSortDirection.Ascending, NasFileSortDirection.Descending].includes(sortDirection) ||
      path.length === 0 && (sortBy === NasFileSortBy.Size || sortBy === NasFileSortBy.Type)) {
      throw new NasFailure(NasErrorKind.InvalidInput, '当前目录不支持此排序方式。');
    }
    const api = selectNasApi(this.capabilities, 'SYNO.FileStation.List', [2]);
    const fields: NasFormField[] = [
      { name: 'offset', content: offset.toString() }, { name: 'limit', content: '100' },
      { name: 'sort_by', content: api.jsonParameters ? JSON.stringify(sortBy) : sortBy },
      { name: 'sort_direction', content: api.jsonParameters ? JSON.stringify(sortDirection) : sortDirection },
      { name: 'additional', content: JSON.stringify(['size']) }
    ];
    if (path.length > 0) {
      validateLogicalPath(path);
      fields.push({ name: 'folder_path', content: api.jsonParameters ? JSON.stringify(path) : path });
    }
    const read = async (): Promise<NasFilePage> => {
      const data = await this.call('SYNO.FileStation.List', 2, path.length === 0 ? 'list_share' : 'list', fields);
      return decodeNasFilePage(data, path.length === 0, offset, 100);
    };
    return path.length === 0 && offset === 0 ? this.featureRegistry.read('fileBrowse', read) : read();
  }

  capabilitySnapshots(): CapabilitySnapshot[] {
    this.ensureOpen();
    return this.featureRegistry.snapshots();
  }

  fileOperationCapabilities(): NasFileOperationCapabilities {
    this.ensureOpen();
    const supports = (name: string, version: number): boolean => this.capabilities.some((api: NasApiDescriptor): boolean =>
      api.name === name && api.minVersion <= version && api.maxVersion >= version);
    const copyMove = supports('SYNO.FileStation.CopyMove', 3);
    return { createFolder: supports('SYNO.FileStation.CreateFolder', 2), renameFile: supports('SYNO.FileStation.Rename', 2),
      deleteFiles: supports('SYNO.FileStation.Delete', 2), copyFiles: copyMove, moveFiles: copyMove };
  }

  async createFolder(directory: string, name: string): Promise<NasFileEntry> {
    this.requireSession();
    validateFileOperationPath(directory);
    validateFileName(name);
    const api = 'SYNO.FileStation.CreateFolder';
    const data = await this.call(api, 2, 'create', [
      { name: 'folder_path', content: JSON.stringify([directory]) }, { name: 'name', content: JSON.stringify([name]) },
      { name: 'force_parent', content: 'false' }
    ]);
    return decodeFileOperationEntry(data, api, 'folders', directory + '/' + name, name, true);
  }

  async renameFile(path: string, name: string): Promise<NasFileEntry> {
    this.requireSession();
    validateFileOperationPath(path, true);
    validateFileName(name);
    const api = 'SYNO.FileStation.Rename';
    const data = await this.call(api, 2, 'rename', [
      { name: 'path', content: JSON.stringify([path]) }, { name: 'name', content: JSON.stringify([name]) }
    ]);
    return decodeFileOperationEntry(data, api, 'files', path.slice(0, path.lastIndexOf('/') + 1) + name, name, false);
  }

  /** 递归删除所选条目；返回值只确认启动，调用者继续查询 fileTaskStatus。 */
  async deleteFiles(paths: string[]): Promise<NasFileTask> {
    this.requireSession();
    validateFileOperationPaths(paths);
    const api = 'SYNO.FileStation.Delete';
    return decodeFileTask(await this.call(api, 2, 'start', [
      { name: 'path', content: JSON.stringify(paths) }, { name: 'recursive', content: 'true' },
      { name: 'accurate_progress', content: 'true' }
    ]), api, NasFileTaskKind.Delete);
  }

  async copyFiles(paths: string[], directory: string): Promise<NasFileTask> {
    return this.copyMoveFiles(paths, directory, false);
  }

  async moveFiles(paths: string[], directory: string): Promise<NasFileTask> {
    return this.copyMoveFiles(paths, directory, true);
  }

  private async copyMoveFiles(paths: string[], directory: string, removeSource: boolean): Promise<NasFileTask> {
    this.requireSession();
    validateFileOperationPaths(paths);
    validateFileOperationPath(directory);
    if (paths.some((path: string): boolean => directory === path || directory.startsWith(path + '/'))) {
      throw new NasFailure(NasErrorKind.InvalidInput, '目标目录不能是所选文件夹或其内部目录。');
    }
    const api = selectNasApi(this.capabilities, 'SYNO.FileStation.CopyMove', [3]);
    // 不传 overwrite：重名由 DSM 明确报错，不能静默跳过或覆盖。
    return decodeFileTask(await this.call(api.name, 3, 'start', [
      { name: 'path', content: JSON.stringify(paths) },
      { name: 'dest_folder_path', content: api.jsonParameters ? JSON.stringify(directory) : directory },
      { name: 'remove_src', content: removeSource ? 'true' : 'false' }, { name: 'accurate_progress', content: 'true' }
    ]), api.name, removeSource ? NasFileTaskKind.Move : NasFileTaskKind.Copy);
  }

  async fileTaskStatus(task: NasFileTask): Promise<NasFileTaskStatus> {
    this.requireSession();
    validateFileTask(task);
    const requestedTask: NasFileTask = { taskId: task.taskId, kind: task.kind };
    const api = selectNasApi(this.capabilities,
      requestedTask.kind === NasFileTaskKind.Delete ? 'SYNO.FileStation.Delete' : 'SYNO.FileStation.CopyMove',
      [requestedTask.kind === NasFileTaskKind.Delete ? 2 : 3]);
    const data = await this.call(api.name, requestedTask.kind === NasFileTaskKind.Delete ? 2 : 3, 'status', [
      { name: 'taskid', content: api.jsonParameters ? JSON.stringify(requestedTask.taskId) : requestedTask.taskId }
    ]);
    return decodeFileTaskStatus(data, api.name, requestedTask);
  }

  /** 停止任务不会回滚已经完成的文件修改。 */
  async stopFileTask(task: NasFileTask): Promise<void> {
    this.requireSession();
    validateFileTask(task);
    const api = selectNasApi(this.capabilities,
      task.kind === NasFileTaskKind.Delete ? 'SYNO.FileStation.Delete' : 'SYNO.FileStation.CopyMove',
      [task.kind === NasFileTaskKind.Delete ? 2 : 3]);
    assertFileOperationSuccess(await this.call(api.name, task.kind === NasFileTaskKind.Delete ? 2 : 3, 'stop', [
      { name: 'taskid', content: api.jsonParameters ? JSON.stringify(task.taskId) : task.taskId }
    ]), api.name);
  }

  async getFileInfo(path: string): Promise<NasFileInfo> {
    this.requireSession();
    validateLogicalPath(path);
    const data = await this.call('SYNO.FileStation.List', 2, 'getinfo', [
      { name: 'path', content: JSON.stringify([path]) },
      { name: 'additional', content: JSON.stringify(['size']) }
    ]);
    return decodeNasFileInfo(data, path);
  }

  async startFileChecksum(path: string): Promise<string> {
    this.requireSession();
    validateLogicalPath(path);
    const api = selectNasApi(this.capabilities, 'SYNO.FileStation.MD5', [2]);
    return decodeTransferChecksumTask(await this.call(api.name, 2, 'start', [
      { name: 'file_path', content: api.jsonParameters ? JSON.stringify(path) : path }
    ]));
  }

  async fileChecksumStatus(taskId: string): Promise<TransferChecksumStatus> {
    this.requireSession();
    validateChecksumTaskId(taskId);
    const api = selectNasApi(this.capabilities, 'SYNO.FileStation.MD5', [2]);
    return decodeTransferChecksumStatus(await this.call(api.name, 2, 'status', [
      { name: 'taskid', content: api.jsonParameters ? JSON.stringify(taskId) : taskId }
    ]));
  }

  async stopFileChecksum(taskId: string): Promise<void> {
    this.requireSession();
    validateChecksumTaskId(taskId);
    const api = selectNasApi(this.capabilities, 'SYNO.FileStation.MD5', [2]);
    await this.call(api.name, 2, 'stop', [{ name: 'taskid', content: api.jsonParameters ? JSON.stringify(taskId) : taskId }]);
  }

  async isFileManager(): Promise<boolean> {
    this.requireSession();
    const data = await this.call('SYNO.FileStation.Info', 2, 'get', []);
    if (typeof data['is_manager'] !== 'boolean') {
      throw new NasFailure(NasErrorKind.Protocol, '文件权限响应格式不符合预期。');
    }
    return data['is_manager'] === true;
  }

  async telemetrySystem(): Promise<Record<string, Object>> {
    this.requireSession();
    return this.call('SYNO.Core.System', 1, 'info', []);
  }

  async telemetryUtilization(): Promise<Record<string, Object>> {
    this.requireSession();
    return this.call('SYNO.Core.System.Utilization', 1, 'get', []);
  }

  async telemetryStorage(): Promise<Record<string, Object>> {
    this.requireSession();
    return this.call('SYNO.Storage.CGI.Storage', 1, 'load_info', []);
  }

  /**
   * 首页设备卡需要的型号与服务器名称（控制面板 → 网络 → 常规 → 服务器名称）。
   * 服务器名称来自 SYNO.Core.Network v1 get 的 server_name；旧固件没有该接口或字段时留空。
   * 两个字段各自独立兜底，任一失败都不影响另一个。
   */
  async deviceIdentity(): Promise<NasDeviceIdentity> {
    this.requireSession();
    let model = '';
    let serverName = '';
    try {
      const info = await this.call('SYNO.Core.System', 1, 'info', []);
      model = this.identityText(info['model'], 128);
    } catch { model = ''; }
    try {
      const network = await this.call('SYNO.Core.Network', 1, 'get', []);
      serverName = this.identityText(network['server_name'], 64);
    } catch { serverName = ''; }
    return { model: model, serverName: serverName };
  }

  private identityText(value: Object | undefined, limit: number): string {
    if (typeof value !== 'string') { return ''; }
    const text = (value as string).trim();
    if (text.length === 0 || text.length > limit || /[\u0000-\u001f\u007f-\u009f]/.test(text)) { return ''; }
    return text;
  }

  async environment(): Promise<NasEnvironment> {
    this.requireSession();
    const info = await this.call('SYNO.DSM.Info', 2, 'getinfo', []);
    const model = this.metadataText(info['model']);
    const dsmVersion = this.metadataText(info['version_string']);
    // 套件版本与管理标记按权限降级：无权限或接口缺失时留空，由界面明确提示；
    // 响应格式不符、网络与会话错误仍然原样上抛，不用空值掩盖。
    let administrator = false;
    let fileStationVersion = '';
    let photosVersion = '';
    try { administrator = await this.isFileManager(); }
    catch (error) { this.assertCapabilityUnavailable(error as Object); }
    try { fileStationVersion = await this.packageVersion('FileStation'); }
    catch (error) { this.assertCapabilityUnavailable(error as Object); }
    try { photosVersion = await this.packageVersion('SynologyPhotos'); }
    catch (error) { this.assertCapabilityUnavailable(error as Object); }
    return { model: model, dsmVersion: dsmVersion, fileStationVersion: fileStationVersion,
      photosVersion: photosVersion, administrator: administrator };
  }

  /** 套件无权限或未发现时静默降级；其余错误继续抛出，不用空值掩盖。 */
  private assertCapabilityUnavailable(error: Object): void {
    if (error instanceof NasFailure && [NasErrorKind.Permission, NasErrorKind.Unsupported].includes(error.kind)) { return; }
    throw error;
  }

  private async packageVersion(id: string): Promise<string> {
    const api = selectNasApi(this.capabilities, 'SYNO.Core.Package', [1]);
    const data = await this.call(api.name, 1, 'get', [
      { name: 'id', content: api.jsonParameters ? JSON.stringify(id) : id },
      { name: 'additional', content: '[]' }
    ]);
    if (data['id'] !== id) { throw new NasFailure(NasErrorKind.Protocol, '套件信息与请求不匹配。'); }
    return this.metadataText(data['version']);
  }

  private metadataText(value: Object | undefined): string {
    const text = nasString(value);
    if (!/^[A-Za-z0-9. +_-]{1,96}$/.test(text)) { throw new NasFailure(NasErrorKind.Protocol, '设备版本信息格式不符合预期。'); }
    return text;
  }

  async photos(space: PhotosSpace, offset: number = 0): Promise<NasPhotoPage> {
    this.validatePhotosOffset(offset);
    if (space !== PhotosSpace.Personal && space !== PhotosSpace.Shared) {
      throw new NasFailure(NasErrorKind.InvalidInput, '照片空间不正确。');
    }
    const api = this.photoApi(space, 'Browse.Item');
    const read = async (): Promise<NasPhotoPage> =>
      decodePhotosPage(await this.photosCall(api, 'list', this.photoListFields(offset)), space, offset, 20);
    return offset === 0 ? this.featureRegistry.read(space === PhotosSpace.Personal ? 'personalPhotos' : 'sharedPhotos', read) : read();
  }

  async photoAlbums(space: PhotosSpace, offset: number = 0): Promise<NasPhotoAlbumPage> {
    this.validatePhotosOffset(offset);
    if (space === PhotosSpace.WithMe) {
      const page = await this.sharedAlbums(offset);
      return { items: page.items.map((album: NasSharedAlbum): NasPhotoAlbum => ({ id: album.id, name: album.name,
        itemCount: album.itemCount, space: space, passphrase: album.passphrase })), offset: page.offset, hasMore: page.hasMore };
    }
    const data = await this.photosCall(this.photoApi(space, 'Browse.Album'), 'list', [
      { name: 'offset', content: offset.toString() }, { name: 'limit', content: '20' }
    ]);
    return decodePhotoAlbumPage(data, space, offset, 20);
  }

  async albumPhotos(album: NasPhotoAlbum, offset: number = 0): Promise<NasPhotoPage> {
    this.validatePhotosOffset(offset);
    if (!Number.isSafeInteger(album.id) || album.id < 0) { throw new NasFailure(NasErrorKind.InvalidInput, '相册标识不正确。'); }
    if (album.space === PhotosSpace.WithMe) { return this.sharedAlbumPhotos(album, offset); }
    const fields = this.photoListFields(offset);
    fields.push({ name: 'id', content: album.id.toString() });
    return decodePhotosPage(await this.photosCall(this.photoApi(album.space, 'Browse.Item'), 'list', fields), album.space, offset, 20);
  }

  async photoDetail(item: NasPhotoItem): Promise<NasPhotoItem> {
    this.requireSession();
    validatePhotoIdentity(item);
    return decodePhotoDetail(await this.photosCall(this.photoApi(item.space, 'Browse.Item'), 'get', [
      { name: 'id', content: JSON.stringify([item.id]) },
      { name: 'additional', content: JSON.stringify(['thumbnail', 'resolution', 'orientation']) }
    ]), item);
  }

  photoThumbnailPlan(item: NasPhotoItem, size: 'm' | 'xl' = 'm', access?: NasPhotoMediaAccess): NasTransferPlan {
    const source = photoMediaSource(item, access);
    const thumbnail = item.thumbnail;
    const id = item.space === PhotosSpace.WithMe ? item.id : thumbnail?.unitId;
    const cacheKey = thumbnail?.cacheKey;
    if (id === undefined || !Number.isSafeInteger(id) || id < 0 || !['m', 'xl'].includes(size) ||
      item.space === PhotosSpace.WithMe && (cacheKey === undefined || cacheKey.length === 0)) {
      throw new NasFailure(NasErrorKind.Unsupported, '此照片尚未提供可用缩略图信息。');
    }
    const fields: NasFormField[] = [ { name: 'id', content: id.toString() },
      { name: 'type', content: 'unit' }, { name: 'size', content: size } ];
    if (cacheKey !== undefined) { fields.push({ name: 'cache_key', content: cacheKey }); }
    return this.photoMediaPlan(this.photoApi(source, 'Thumbnail'), 'get', fields, access);
  }

  photoOriginalPlan(item: NasPhotoItem, access?: NasPhotoMediaAccess): NasTransferPlan {
    const source = photoMediaSource(item, access);
    const cacheKey = item.thumbnail?.cacheKey;
    if (item.space === PhotosSpace.WithMe && (cacheKey === undefined || cacheKey.length === 0)) {
      throw new NasFailure(NasErrorKind.Unsupported, '共享照片未提供媒体缓存标识，请刷新相册后重试。');
    }
    const fields: NasFormField[] = [{ name: 'unit_id', content: JSON.stringify([item.id]) }];
    if (cacheKey !== undefined) { fields.push({ name: 'cache_key', content: cacheKey }); }
    return this.photoMediaPlan(this.photoApi(source, 'Download'), 'download', fields, access);
  }

  /** 套件认证失败先核对基础会话；媒体权限拒绝不能清除正常的基础登录。 */
  async photoMediaFailure(error: NasFailure): Promise<void> {
    if (error.kind === NasErrorKind.SessionExpired ||
      [NasErrorKind.Http, NasErrorKind.Server].includes(error.kind) && error.code === 401) {
      await this.list('', 0);
      throw new NasFailure(error.kind === NasErrorKind.SessionExpired ? NasErrorKind.Unsupported : NasErrorKind.Permission,
        '照片媒体认证未通过，基础文件登录仍可使用；请重新打开相册或检查分享权限。', error.code);
    }
    if (error.kind === NasErrorKind.Http && error.code === 403) {
      throw new NasFailure(NasErrorKind.Permission, '当前账号没有读取此照片媒体的权限。', error.code);
    }
    throw error;
  }

  private photoMediaPlan(name: string, method: string, fields: NasFormField[], access?: NasPhotoMediaAccess): NasTransferPlan {
    const session = this.requireSession();
    const api = this.selectPhotoApi(name);
    const parameters = fields.slice();
    if (access?.passphrase !== undefined && access.passphrase.length > 0) {
      parameters.push({ name: 'passphrase', content: access.passphrase });
    }
    const encoded = parameters.map((field: NasFormField): NasFormField => ({ name: field.name,
      content: api.jsonParameters && ['type', 'size', 'cache_key', 'passphrase'].includes(field.name) ? JSON.stringify(field.content) : field.content }));
    return { address: this.origin + '/webapi/' + api.path, session: session, fields: [
      { name: 'api', content: name }, { name: 'version', content: '1' }, { name: 'method', content: method }, ...encoded
    ] };
  }

  private photoApi(space: PhotosSpace, suffix: string): string {
    if (space !== PhotosSpace.Personal && space !== PhotosSpace.Shared) {
      throw new NasFailure(NasErrorKind.InvalidInput, '照片空间不正确。');
    }
    return (space === PhotosSpace.Personal ? 'SYNO.Foto.' : 'SYNO.FotoTeam.') + suffix;
  }

  private selectPhotoApi(name: string): NasApiDescriptor {
    try { return selectNasApi(this.capabilities, name, [1]); }
    catch (error) {
      if (error instanceof NasFailure && error.kind === NasErrorKind.Unsupported) {
        throw this.photoUnsupportedFailure(name, error.code);
      }
      throw error;
    }
  }

  private photoUnsupportedFailure(name: string, code: number): NasFailure {
    const space = name.startsWith('SYNO.FotoTeam.') ? '共享空间' : '个人空间';
    let operation = '浏览' + space + '照片';
    if (name.endsWith('Browse.Album')) { operation = '浏览' + space + '相册'; }
    else if (name === 'SYNO.Foto.Sharing.Misc') { operation = '浏览分享给我的相册'; }
    else if (name.endsWith('Thumbnail')) { operation = '读取' + space + '照片缩略图'; }
    else if (name.endsWith('Download')) { operation = '下载' + space + '照片或视频原文件'; }
    return new NasFailure(NasErrorKind.Unsupported,
      '当前服务器不支持' + operation + '，请检查 Synology Photos 套件版本及空间设置。', code);
  }

  private photoListFields(offset: number): NasFormField[] {
    return [ { name: 'offset', content: offset.toString() }, { name: 'limit', content: '20' },
      { name: 'sort_by', content: 'takentime' }, { name: 'sort_direction', content: 'desc' },
      { name: 'additional', content: JSON.stringify(['thumbnail', 'resolution', 'orientation']) } ];
  }

  async sharedAlbums(offset: number = 0): Promise<NasSharedAlbumPage> {
    this.validatePhotosOffset(offset);
    const data = await this.photosCall('SYNO.Foto.Sharing.Misc', 'list_shared_with_me_album', [
      { name: 'offset', content: offset.toString() }, { name: 'limit', content: '20' },
      { name: 'additional', content: JSON.stringify(['sharing_info']) }
    ]);
    return decodeSharedAlbumPage(data, offset, 20);
  }

  async sharedAlbumPhotos(album: NasSharedAlbum, offset: number = 0): Promise<NasPhotoPage> {
    this.validatePhotosOffset(offset);
    if (!Number.isSafeInteger(album.id) || album.id < 0) { throw new NasFailure(NasErrorKind.InvalidInput, '相册标识不正确。'); }
    const api = this.selectPhotoApi('SYNO.Foto.Browse.Item');
    const fields = this.photoListFields(offset);
    if (album.passphrase !== undefined && album.passphrase.length > 0) {
      fields.push({ name: 'passphrase', content: api.jsonParameters ? JSON.stringify(album.passphrase) : album.passphrase });
    } else { fields.push({ name: 'album_id', content: album.id.toString() }); }
    return decodePhotosPage(await this.photosCall(api.name, 'list', fields), PhotosSpace.WithMe, offset, 20);
  }

  private validatePhotosOffset(offset: number): void {
    this.requireSession();
    if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(offset + 20)) {
      throw new NasFailure(NasErrorKind.InvalidInput, '照片分页位置不正确。');
    }
  }

  private async photosCall(api: string, method: string, fields: NasFormField[]): Promise<Record<string, Object>> {
    this.requireSession();
    try { return await this.call(api, 1, method, fields, false); }
    catch (error) {
      if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) {
        await this.list('', 0);
        throw new NasFailure(NasErrorKind.Unsupported, '当前 Photos 不接受此会话，文件浏览仍可使用。', error.code);
      }
      if (error instanceof NasFailure && error.kind === NasErrorKind.Unsupported) {
        throw this.photoUnsupportedFailure(api, error.code);
      }
      throw error;
    }
  }

  /** 文件字段由传输层追加在末尾；不提供覆盖参数，重名交由 DSM 明确拒绝。 */
  transferUploadPlan(directory: string): NasTransferPlan {
    const session = this.requireSession();
    validateLogicalPath(directory);
    const api = selectNasApi(this.capabilities, 'SYNO.FileStation.Upload', [2]);
    return { address: this.origin + '/webapi/' + api.path, session: session, fields: [
      { name: 'api', content: api.name }, { name: 'version', content: '2' },
      { name: 'method', content: 'upload' },
      // 上传 multipart 的 path 是原始标量，不能沿用普通表单的 JSON 引号。
      { name: 'path', content: directory },
      { name: 'create_parents', content: 'false' }
    ] };
  }

  transferDownloadPlan(filePath: string): NasTransferPlan {
    const session = this.requireSession();
    validateLogicalPath(filePath);
    const api = selectNasApi(this.capabilities, 'SYNO.FileStation.Download', [2]);
    return { address: this.origin + '/webapi/' + api.path, session: session, fields: [
      { name: 'api', content: api.name }, { name: 'version', content: '2' },
      { name: 'method', content: 'download' },
      { name: 'path', content: JSON.stringify([filePath]) },
      { name: 'mode', content: api.jsonParameters ? JSON.stringify('download') : 'download' }
    ] };
  }

  restoreSession(sessions: BusinessSessionRecord[]): void {
    this.ensureOpen();
    selectNasApi(this.capabilities, 'SYNO.API.Auth', [6]);
    if (this.authenticating || this.sessions.has(this.sessionName)) { throw new NasFailure(NasErrorKind.InvalidInput, '当前正在登录或已经登录。'); }
    this.sessions.restore(sessions);
    this.generation++;
    this.cancelDriveTransfers();
    this.featureRegistry.discover(this.capabilities);
  }

  sessionSnapshot(): BusinessSessionRecord[] {
    this.ensureOpen();
    return this.sessions.snapshot();
  }

  /** 是否已建立某个业务会话；供界面区分“未登录套件会话”与“套件拒绝会话”。 */
  hasBusinessSession(name: BusinessSessionName): boolean {
    this.ensureOpen();
    return this.sessions.has(name);
  }

  async logout(): Promise<void> {
    if (this.disposed) { return; }
    if (this.loggingOut) { throw new NasFailure(NasErrorKind.Cancelled, '连接正在退出。'); }
    const records = this.sessions.snapshot();
    this.loggingOut = true;
    this.sessions.clear();
    this.generation++;
    this.cancelDriveTransfers();
    this.featureRegistry.clear();
    if (this.disposed || records.length === 0) { this.close(); return; }
    // 逐个业务登出：单个失败不阻止其余业务登出，最终把第一个失败交给调用方。
    let firstFailure: unknown = undefined;
    try {
      const api = selectNasApi(this.capabilities, 'SYNO.API.Auth', [6]);
      for (const record of records) {
        try {
          const reply = await this.rpc.request(this.origin, api, 6, 'logout',
            [{ name: 'session', content: record.name }], { sid: record.sid, synoToken: record.synoToken });
          decodeNasResponse(api.name, reply.status, reply.text);
        } catch (error) {
          if (firstFailure === undefined) { firstFailure = error; }
        }
      }
    } finally { this.close(); }
    if (firstFailure !== undefined) { throw firstFailure; }
  }

  close(): void {
    if (this.disposed) { return; }
    this.disposed = true;
    this.generation++;
    this.cancelDriveTransfers();
    this.sessions.clear();
    this.capabilities = [];
    this.featureRegistry.clear();
    this.transport.close();
  }

  async systemControl(action: NasControlAction): Promise<void> {
    this.requireSession();
    if (this.sessionName !== 'NasControl') {
      throw new NasFailure(NasErrorKind.Permission, '系统控制需要单独登录授权，不能使用文件会话。');
    }
    const method = validateNasControlAction(action);
    const api = selectNasApi(this.capabilities, 'SYNO.Core.System', [1]);
    const ticket = this.generation;
    const revision = this.sessions.revision('NasControl');
    const fields: NasFormField[] = [];
    if (method === 'shutdown') { fields.push({ name: 'local', content: 'true' }); }
    const reply = await this.rpc.request(this.origin, api, 1, method, fields, this.requireSession())
      .catch((error: Error): NasHttpReply => { this.ensureSessionCurrent(ticket, 'NasControl', revision); throw error; });
    this.ensureSessionCurrent(ticket, 'NasControl', revision);
    try { assertNasControlAccepted(reply.status, reply.text); }
    catch (error) {
      if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { this.invalidateSession('NasControl'); }
      throw error;
    }
  }

  private async call(name: string, version: number, method: string, parameters: NasFormField[],
    invalidateExpired: boolean = true): Promise<Record<string, Object>> {
    return this.callWith(name, version, method, parameters, decodeNasResponse, invalidateExpired);
  }

  /**
   * 传输、会话失效与代际校验只保留一份实现，解码器可替换：
   * Drive 需要在解析入口做保精度预处理，并使用自己的错误码语义。
   */
  private async callWith(name: string, version: number, method: string, parameters: NasFormField[],
    decode: (api: string, status: number, text: string) => Record<string, Object>,
    invalidateExpired: boolean = true): Promise<Record<string, Object>> {
    this.ensureOpen();
    const ticket = this.generation;
    const sessionName: BusinessSessionName = name.startsWith('SYNO.SynologyDrive.') ? 'FileStation' : this.sessionName;
    const revision = this.sessions.revision(sessionName);
    const api = selectNasApi(this.capabilities, name, [version]);
    // 认证参数交由传输层发送 Cookie 和 CSRF 请求头，不进入 URL 或业务表单。
    const authorization = name === 'SYNO.API.Auth' && method === 'login' ? undefined : this.requireSession(sessionName);
    const reply = await this.rpc.request(this.origin, api, version, method, parameters, authorization)
      .catch((error: Error): NasHttpReply => { this.ensureSessionCurrent(ticket, sessionName, revision); throw error; });
    this.ensureSessionCurrent(ticket, sessionName, revision);
    try { return decode(name, reply.status, reply.text); }
    catch (error) {
      if (invalidateExpired && error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) {
        this.invalidateSession(sessionName);
      }
      throw error;
    }
  }

  async extensionRequest(feature: 'fileSharing' | 'nasDownloads', method: string, fields: NasFormField[]): Promise<Object> {
    this.ensureOpen();
    const name = feature === 'fileSharing' ? 'SYNO.FileStation.Sharing' : 'SYNO.DownloadStation.Task';
    const methods = feature === 'fileSharing' ? ['list', 'getinfo', 'create', 'edit', 'delete'] :
      ['list', 'getinfo', 'create', 'pause', 'resume', 'delete'];
    if (!methods.includes(method)) { throw new NasFailure(NasErrorKind.InvalidInput, '不支持此套件操作。'); }
    const versions = feature === 'fileSharing' || method === 'create' ? [3] : [1, 3];
    const selected = selectVerifiedApi(this.capabilities, name, versions);
    // NAS 下载使用独立套件会话；未建立时先给出明确的重新登录提示，不发起注定被拒的请求。
    const sessionName: BusinessSessionName = feature === 'nasDownloads' ? 'DownloadStation' : 'FileStation';
    const authorization = this.requireSession(sessionName);
    const ticket = this.generation;
    const revision = this.sessions.revision(sessionName);
    const reply = await this.rpc.request(this.origin, selected.api, selected.version, method, fields, authorization)
      .catch((error: Error): NasHttpReply => { this.ensureSessionCurrent(ticket, sessionName, revision); throw error; });
    this.ensureSessionCurrent(ticket, sessionName, revision);
    try { return decodeExtensionResponse(name, method, reply.status, reply.text); }
    catch (error) {
      // 套件会话被服务器拒绝只失效该业务，不影响其他业务的已建立会话。
      if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { this.invalidateSession(sessionName); }
      throw error;
    }
  }

  supportsExtensionAction(feature: 'fileSharing' | 'nasDownloads', method: string): boolean {
    this.ensureOpen();
    const name = feature === 'fileSharing' ? 'SYNO.FileStation.Sharing' : 'SYNO.DownloadStation.Task';
    try {
      selectVerifiedApi(this.capabilities, name, feature === 'fileSharing' || method === 'create' ? [3] : [1, 3]);
      return true;
    } catch (error) {
      if (error instanceof NasFailure && error.kind === NasErrorKind.Unsupported) { return false; }
      throw error;
    }
  }

  async readExtension<T>(feature: 'fileSharing' | 'nasDownloads', readAndValidate: () => Promise<T>): Promise<T> {
    this.requireSession(feature === 'nasDownloads' ? 'DownloadStation' : 'FileStation');
    return this.featureRegistry.read(feature, readAndValidate);
  }

  /**
   * Drive 适配器需要的窄端口。Drive 走 DSM 内部 WebAPI（无兼容承诺），
   * 因此刻意不让适配器直接持有本类：将来整体切到官方 Office Suite REST 时，
   * 只需替换 `DriveAdapter` 与这一组方法。
   */
  supportsDriveApi(api: string, version: number): boolean {
    this.ensureOpen();
    return this.capabilities.some((row: NasApiDescriptor): boolean =>
      row.name === api && row.minVersion <= version && row.maxVersion >= version);
  }

  /**
   * 先自行判断可用性，再用 Drive 自己的解码器与错误码解释：
   * `selectNasApi` 的通用提示会把「套件没装」说成「版本不支持」，而 Drive 的
   * 103/105/120/1000 也与 File Station 语义不同。会话失效与代际校验仍复用 callWith。
   */
  async requestDrive(api: string, version: number, method: string,
    fields: NasFormField[]): Promise<Record<string, Object>> {
    if (!this.supportsDriveApi(api, version)) { throw driveUnsupportedFailure(api); }
    return this.callWith(api, version, method, fields, decodeDriveResponse);
  }

  async uploadDrive(input: DriveUploadRequest, source: NasUploadSource,
    control: NasTransferControl): Promise<DriveUploadResult> {
    validateNasUploadSource(source);
    const request = this.driveTransferRequest('upload', driveUploadFields(input));
    const uploadSource: NasUploadSource = { path: source.path, bytes: source.bytes };
    const filename = input.filename;
    const scope = this.beginDriveTransfer(control);
    try {
      const reply = await scope.transport.upload(request, uploadSource, filename, scope.control);
      this.checkDriveTransfer(scope);
      return decodeDriveUpload(reply.status, reply.text, uploadSource.bytes);
    } catch (error) {
      this.driveTransferFailed(scope, error);
      throw error;
    } finally { scope.dispose(); }
  }

  async downloadDrive(input: DriveDownloadRequest, target: NasDownloadTarget,
    control: NasTransferControl): Promise<NasDownloadResult> {
    validateNasDownloadTarget(target);
    const fields = driveDownloadFields(input);
    const suffix = (input.preview ? '/' : '/SYNO.SynologyDrive.Files/') + encodeURIComponent(input.filename);
    const request = this.driveTransferRequest('download', fields, suffix);
    const output: NasDownloadTarget = { directory: target.directory, maximumBytes: target.maximumBytes,
      expectedBytes: target.expectedBytes };
    const scope = this.beginDriveTransfer(control);
    let receipt: NasDownloadReceipt | undefined = undefined;
    try {
      receipt = await scope.transport.download(request, output, scope.control, (reply: NasBinaryReply): void => {
        this.checkDriveTransfer(scope);
        validateDriveDownload(reply, output);
      });
      this.checkDriveTransfer(scope);
      return { path: receipt.path, bytes: receipt.bytes };
    } catch (error) {
      // 临时文件属于本次调用，先释放再解释失败；清理异常不得覆盖真正的失败原因。
      try { if (receipt !== undefined) { receipt.discard(); } } catch (_) {}
      this.driveTransferFailed(scope, error);
      throw error;
    } finally { scope.dispose(); }
  }

  private driveTransferRequest(method: 'upload' | 'download', fields: NasFormField[], suffix: string = ''): NasTransferRequest {
    const session = this.requireSession('FileStation');
    if (!this.supportsDriveApi(DRIVE_FILES_API, DRIVE_TRANSFER_VERSION)) { throw driveUnsupportedFailure(DRIVE_FILES_API); }
    const api = selectNasApi(this.capabilities, DRIVE_FILES_API, [DRIVE_TRANSFER_VERSION]);
    const parameters: NasFormField[] = [
      { name: 'api', content: DRIVE_FILES_API }, { name: 'version', content: DRIVE_TRANSFER_VERSION.toString() },
      { name: 'method', content: method }
    ].concat(fields);
    if (method === 'download') {
      // 原始 GET 抓包携带 SynoToken。只在内核中注入，不进入资源引用或任务记录。
      // 服务器没签发令牌时提示重新登录，但不失效当前会话：服务器状态未知，
      // 直接清除会让仍然可用的文件浏览一起失效。
      if (session.synoToken.length === 0) { throw new NasFailure(NasErrorKind.SessionExpired, '请重新登录后下载文件。'); }
      parameters.push({ name: 'SynoToken', content: session.synoToken });
    }
    return { address: this.origin + '/webapi/' + validateApiPath(api.path) + suffix,
      method: method === 'upload' ? 'POST' : 'GET', fields: parameters,
      session: { sid: session.sid, synoToken: session.synoToken } };
  }

  private beginDriveTransfer(control: NasTransferControl): DriveTransferScope {
    this.ensureOpen();
    control.cancellation.check();
    const transport = this.transport.transfers;
    if (transport === undefined) { throw new NasFailure(NasErrorKind.Unsupported, '当前连接不支持文件传输。'); }
    const ticket = this.generation;
    const sessionRevision = this.sessions.revision('FileStation');
    const cancellation = new NasTransferCancellation();
    this.driveTransfers.add(cancellation);
    const unsubscribe = control.cancellation.subscribe((): void => { cancellation.cancel(); });
    const onProgress = control.onProgress;
    return { ticket, sessionRevision, transport, control: { cancellation,
      onProgress: (progress: NasTransferProgress): void => {
        this.ensureSessionCurrent(ticket, 'FileStation', sessionRevision);
        cancellation.check();
        if (onProgress !== undefined) { onProgress(progress); }
      } }, dispose: (): void => { unsubscribe(); this.driveTransfers.delete(cancellation); } };
  }

  private checkDriveTransfer(scope: DriveTransferScope): void {
    this.ensureSessionCurrent(scope.ticket, 'FileStation', scope.sessionRevision);
    scope.control.cancellation.check();
  }

  /**
   * 失败收尾：代际已切换时只报告连接已切换，不让旧会话的错误冒充新会话的失败。
   * 调用方主动取消不改变代际，因此保留传输层给出的具体说明（例如上传结果未确认）。
   */
  private driveTransferFailed(scope: DriveTransferScope, error: unknown): void {
    this.ensureSessionCurrent(scope.ticket, 'FileStation', scope.sessionRevision);
    if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) {
      this.invalidateSession('FileStation');
    }
  }

  private cancelDriveTransfers(): void {
    for (const cancellation of this.driveTransfers) { cancellation.cancel(); }
    this.driveTransfers.clear();
  }

  /** 供 Drive 适配器把一次真实读取登记到能力状态机。 */
  async readDriveFeature<T>(feature: string, readAndValidate: () => Promise<T>): Promise<T> {
    this.requireSession();
    return this.featureRegistry.read(feature, readAndValidate);
  }

  private ensureOpen(): void {
    if (this.disposed || this.loggingOut) { throw new NasFailure(NasErrorKind.Cancelled, '连接已关闭。'); }
  }
  private requireSession(name: BusinessSessionName = this.sessionName): NasLoginSession {
    this.ensureOpen();
    const session = this.sessions.get(name);
    if (session === undefined) {
      throw new NasFailure(NasErrorKind.SessionExpired,
        name === this.sessionName ? '请先登录 NAS。' : '该功能的套件会话未建立，请退出后重新登录。');
    }
    return session;
  }
  private ensureCurrent(ticket: number): void {
    this.ensureOpen();
    if (ticket !== this.generation) { throw new NasFailure(NasErrorKind.Cancelled, '连接已切换。'); }
  }

  private ensureSessionCurrent(ticket: number, name: BusinessSessionName, revision: number): void {
    this.ensureCurrent(ticket);
    if (revision !== this.sessions.revision(name)) { throw new NasFailure(NasErrorKind.Cancelled, '连接已切换。'); }
  }

  private invalidateSession(name: BusinessSessionName): void {
    if (!this.sessions.invalidate(name)) { return; }
    if (name === 'NasControl') { return; }
    if (name === 'FileStation') { this.cancelDriveTransfers(); }
    for (const snapshot of this.featureRegistry.snapshots()) {
      if ((snapshot.feature === 'nasDownloads') === (name === 'DownloadStation')) {
        this.featureRegistry.invalidate(snapshot.feature);
      }
    }
  }
}
