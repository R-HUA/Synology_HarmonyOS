import { decodeCapabilities, decodeNasFileInfo, decodeNasFilePage, decodeNasResponse, decodeNasSession, encodeNasForm,
  nasString, NasErrorKind, NasFailure,
  normalizeNasOrigin, selectNasApi, validateLogicalPath } from '../domain/DsmProtocol';
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

export interface NasHttpReply { status: number; text: string; }
export interface NasEnvironment { model: string; dsmVersion: string; fileStationVersion: string; photosVersion: string; administrator: boolean; }
export interface NasTransferPlan { address: string; fields: NasFormField[]; session: NasLoginSession; }
export interface NasTransport {
  post(address: string, body: string, session?: NasLoginSession): Promise<NasHttpReply>;
  close(): void;
}

export const NAS_DISCOVERY_QUERY = 'SYNO.API.Auth,SYNO.FileStation.List,SYNO.FileStation.Info,' +
  'SYNO.FileStation.Upload,SYNO.FileStation.Download,SYNO.Foto.Browse.Item,SYNO.FotoTeam.Browse.Item,' +
  'SYNO.DSM.Info,SYNO.Core.Package,SYNO.Foto.Sharing.Misc,' +
  'SYNO.Foto.Browse.Album,SYNO.FotoTeam.Browse.Album,SYNO.Foto.Thumbnail,SYNO.FotoTeam.Thumbnail,SYNO.Foto.Download,SYNO.FotoTeam.Download,' +
  'SYNO.FileStation.CreateFolder,SYNO.FileStation.Rename,SYNO.FileStation.Delete,SYNO.FileStation.CopyMove,SYNO.FileStation.MD5,' +
  'SYNO.Core.System,SYNO.Core.System.Utilization,SYNO.Storage.CGI.Storage';

export class NasConnector {
  private origin: string = '';
  private capabilities: NasApiDescriptor[] = [];
  private session: NasLoginSession | undefined = undefined;
  private generation: number = 0;
  private disposed: boolean = false;
  private authenticating: boolean = false;
  constructor(private transport: NasTransport, private sessionName: 'FileStation' | 'NasControl' = 'FileStation') {}

  async discover(address: string): Promise<NasApiDescriptor[]> {
    this.ensureOpen();
    if (this.origin.length > 0) { throw new NasFailure(NasErrorKind.InvalidInput, '请先断开当前连接。'); }
    this.origin = normalizeNasOrigin(address);
    const ticket = this.generation;
    const reply = await this.transport.post(this.origin + '/webapi/query.cgi', encodeNasForm([
      { name: 'api', content: 'SYNO.API.Info' }, { name: 'version', content: '1' },
      { name: 'method', content: 'query' }, { name: 'query', content: NAS_DISCOVERY_QUERY }
    ]));
    this.ensureCurrent(ticket);
    this.capabilities = decodeCapabilities(decodeNasResponse('SYNO.API.Info', reply.status, reply.text));
    selectNasApi(this.capabilities, 'SYNO.API.Auth', [6]);
    selectNasApi(this.capabilities, 'SYNO.FileStation.List', [2]);
    return this.capabilities.slice();
  }

  async login(account: string, password: string, otp: string): Promise<void> {
    this.ensureOpen();
    if (account.trim().length === 0 || password.length === 0) { throw new NasFailure(NasErrorKind.InvalidInput, '请输入账号和密码。'); }
    if (otp.length > 0 && !/^[0-9]{6}$/.test(otp)) { throw new NasFailure(NasErrorKind.InvalidInput, '动态码应为 6 位数字。'); }
    if (this.authenticating || this.session !== undefined) { throw new NasFailure(NasErrorKind.InvalidInput, '当前正在登录或已经登录。'); }
    const fields: NasFormField[] = [
      { name: 'account', content: account.trim() }, { name: 'passwd', content: password },
      { name: 'session', content: this.sessionName }, { name: 'format', content: 'sid' },
      { name: 'enable_syno_token', content: 'yes' }
    ];
    if (otp.length > 0) { fields.push({ name: 'otp_code', content: otp }); }
    this.authenticating = true;
    try { this.session = decodeNasSession(await this.call('SYNO.API.Auth', 6, 'login', fields)); }
    finally { this.authenticating = false; }
  }

  async list(path: string, offset: number = 0, sortBy: NasFileSortBy = NasFileSortBy.Name,
    sortDirection: NasFileSortDirection = NasFileSortDirection.Ascending): Promise<NasFilePage> {
    this.ensureOpen();
    if (this.session === undefined) { throw new NasFailure(NasErrorKind.SessionExpired, '请先登录 NAS。'); }
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
    const data = await this.call('SYNO.FileStation.List', 2, path.length === 0 ? 'list_share' : 'list', fields);
    return decodeNasFilePage(data, path.length === 0, offset, 100);
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

  async environment(): Promise<NasEnvironment> {
    this.requireSession();
    const administrator = await this.isFileManager();
    const info = await this.call('SYNO.DSM.Info', 2, 'getinfo', []);
    const model = this.metadataText(info['model']);
    const dsmVersion = this.metadataText(info['version_string']);
    const fileStationVersion = await this.packageVersion('FileStation');
    const photosVersion = await this.packageVersion('SynologyPhotos');
    return { model: model, dsmVersion: dsmVersion, fileStationVersion: fileStationVersion,
      photosVersion: photosVersion, administrator: administrator };
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
    return decodePhotosPage(await this.photosCall(api, 'list', this.photoListFields(offset)), space, offset, 20);
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

  restoreSession(session: NasLoginSession): void {
    this.ensureOpen();
    selectNasApi(this.capabilities, 'SYNO.API.Auth', [6]);
    if (this.authenticating || this.session !== undefined) { throw new NasFailure(NasErrorKind.InvalidInput, '当前正在登录或已经登录。'); }
    const data: Record<string, Object> = { sid: session.sid };
    if (session.synoToken.length > 0) { data['synotoken'] = session.synoToken; }
    this.session = decodeNasSession(data);
  }

  sessionSnapshot(): NasLoginSession | undefined {
    this.ensureOpen();
    return this.session === undefined ? undefined : { sid: this.session.sid, synoToken: this.session.synoToken };
  }

  async logout(): Promise<void> {
    const oldSession = this.session;
    this.session = undefined;
    this.generation++;
    if (this.disposed || oldSession === undefined) { this.close(); return; }
    try {
      const api = selectNasApi(this.capabilities, 'SYNO.API.Auth', [6]);
      const fields: NasFormField[] = [
        { name: 'api', content: api.name }, { name: 'version', content: '6' },
        { name: 'method', content: 'logout' }, { name: 'session', content: this.sessionName }
      ];
      const reply = await this.transport.post(this.origin + '/webapi/' + api.path, encodeNasForm(fields), oldSession);
      decodeNasResponse(api.name, reply.status, reply.text);
    } finally { this.close(); }
  }

  close(): void {
    if (this.disposed) { return; }
    this.disposed = true;
    this.generation++;
    this.session = undefined;
    this.capabilities = [];
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
    const fields: NasFormField[] = [
      { name: 'api', content: api.name }, { name: 'version', content: '1' }, { name: 'method', content: method }
    ];
    if (method === 'shutdown') { fields.push({ name: 'local', content: 'true' }); }
    const reply = await this.transport.post(this.origin + '/webapi/' + api.path, encodeNasForm(fields), this.session);
    this.ensureCurrent(ticket);
    assertNasControlAccepted(reply.status, reply.text);
  }

  private async call(name: string, version: number, method: string, parameters: NasFormField[], invalidateExpired: boolean = true): Promise<Record<string, Object>> {
    this.ensureOpen();
    const ticket = this.generation;
    const api = selectNasApi(this.capabilities, name, [version]);
    const fields: NasFormField[] = [
      { name: 'api', content: name }, { name: 'version', content: version.toString() },
      { name: 'method', content: method }
    ];
    for (const parameter of parameters) { fields.push(parameter); }
    // 认证参数交由传输层发送 Cookie 和 CSRF 请求头，不进入 URL 或业务表单。
    const reply = await this.transport.post(this.origin + '/webapi/' + api.path, encodeNasForm(fields), this.session);
    this.ensureCurrent(ticket);
    try { return decodeNasResponse(name, reply.status, reply.text); }
    catch (error) {
      if (invalidateExpired && error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) {
        this.session = undefined;
        this.generation++;
      }
      throw error;
    }
  }

  private ensureOpen(): void {
    if (this.disposed) { throw new NasFailure(NasErrorKind.Cancelled, '连接已关闭。'); }
  }
  private requireSession(): NasLoginSession {
    this.ensureOpen();
    if (this.session === undefined) { throw new NasFailure(NasErrorKind.SessionExpired, '请先登录 NAS。'); }
    return { sid: this.session.sid, synoToken: this.session.synoToken };
  }
  private ensureCurrent(ticket: number): void {
    this.ensureOpen();
    if (ticket !== this.generation) { throw new NasFailure(NasErrorKind.Cancelled, '连接已切换。'); }
  }
}
