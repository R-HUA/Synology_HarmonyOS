import { decodeNasResponse, nasRecord, NasErrorKind, NasFailure } from './DsmProtocol';
import type { NasFormField } from './DsmProtocol';

/**
 * Synology Drive 接入的领域与协议层（走 DSM 内部 `SYNO.SynologyDrive.*` WebAPI）。
 *
 * 这是**未公开、无兼容承诺**的内部接口；Drive 语义收敛在协议与适配器两层，
 * 二进制传输对应 DriveTransferProtocol/DriveTransferAdapter，便于切到官方 Office Suite REST，
 * 或适配 DSM 的版本漂移。
 *
 * 实测依据：`work/drive-probe/drive-api-map.json`（三轮真机探测 + Web UI 抓包）。
 * 凡标注「实测」的结论都有该文件佐证；推断项单独标注。
 */

/** Files 命名空间承载目录浏览、单条详情、面包屑、最近、星标、共享、搜索与全部写操作。 */
export const DRIVE_FILES_API = 'SYNO.SynologyDrive.Files';

/**
 * 版本**按方法**登记，不是一个全局版本号 —— 实测 `Files.list` 用 v2，
 * `Files.get` 与 `list_backup_tasks` 用 v3。升级前先跑探测脚本回归。
 * P0 只用到 list；P1 起按方法各自登记（见 Drive_Access_Plan 的 §2 映射表）。
 */
export const DRIVE_LIST_VERSION = 2;
export const DRIVE_TEAM_FOLDERS_API = 'SYNO.SynologyDrive.TeamFolders';
export const DRIVE_TRASH_API = 'SYNO.SynologyDrive.Trash';
export const DRIVE_TEAM_FOLDERS_VERSION = 1;
export const DRIVE_TRASH_VERSION = 1;
export const DRIVE_SEARCH_VERSION = 2;
export const DRIVE_ANCESTORS_VERSION = 2;

export enum DriveView {
  MyDrive = 'mydrive', TeamFolders = 'teamFolders', Recent = 'recent', Starred = 'starred',
  SharedWithMe = 'sharedWithMe', SharedWithOthers = 'sharedWithOthers', Trash = 'trash', Search = 'search'
}

export function driveViewLabel(view: DriveView): string {
  switch (view) {
    case DriveView.MyDrive: return '我的文件';
    case DriveView.TeamFolders: return '团队文件夹';
    case DriveView.Recent: return '最近';
    case DriveView.Starred: return '星标';
    case DriveView.SharedWithMe: return '共享给我';
    case DriveView.SharedWithOthers: return '我共享出去的';
    case DriveView.Trash: return '回收站';
    case DriveView.Search: return '搜索结果';
  }
}

/**
 * 每页条目数。
 *
 * 实测**不传 limit 时服务端只给 10 条**（`total=11` 而 `items=10`），必须显式传。
 * Drive Web UI 传 1000；本应用取 200：手机端单页渲染与常驻内存更可控，同时让
 * `offset`/`limit` 分页在真实数据量下就能被验证，而不是永远只请求第一页。
 */
export const DRIVE_PAGE_SIZE = 200;

export enum DriveSortBy { Name = 'name', ModifiedTime = 'modified_time', AccessTime = 'atime' }
export enum DriveSortDirection { Ascending = 'asc', Descending = 'desc' }

/** 服务端的 `type` 取值；`folder` 是社区写法，一并接受，避免多一个值就整页失败。 */
export enum DriveEntryKind { File = 'file', Folder = 'folder' }

/** 一个 Drive 位置所属的空间。团队文件夹不能靠虚拟路径进入，只能用 fileId。 */
export enum DriveSpace { MyDrive = 'mydrive', TeamFolder = 'teamFolder' }

/**
 * 条目能力开关（实测 11 个布尔）。**按钮可见性只读这里，不用账号角色推断。**
 * 缺字段按 false 处理：宁可少显示一个按钮，也不能显示一个按不动的按钮。
 */
export interface DriveCapabilities {
  canRead: boolean;
  canDownload: boolean;
  canPreview: boolean;
  canWrite: boolean;
  canRename: boolean;
  canDelete: boolean;
  canShare: boolean;
  /** 整理类操作（移动/复制）。△ 推断，未实测确认。 */
  canOrganize: boolean;
  canComment: boolean;
  canSync: boolean;
  canEncrypt: boolean;
}

export interface DriveOwner {
  displayName?: string;
  name?: string;
  nickname?: string;
  uid?: string;
}

/**
 * 领域条目。
 *
 * 只有 `fileId` / `name` / `kind` 是必需的：这三个缺任何一个条目都不可用。
 * 其余字段一律可选 —— 面对无合同保障的内部接口，把可选字段当必需会让一次
 * 无关紧要的字段缺失炸掉整页；但**字段存在时类型必须正确**，否则视为协议漂移。
 */
export interface DriveEntry {
  /** 数字字符串，不经 Number 往返，保证超长 ID 不被舍入。 */
  fileId: string;
  name: string;
  kind: DriveEntryKind;
  sizeBytes?: number;
  createdAt?: number;
  modifiedAt?: number;
  accessedAt?: number;
  /** 服务端返回的路径文本，用于回传给接口，不作展示。 */
  pathText?: string;
  /** 展示用路径；实测存在，但缺失时由界面用面包屑兜底。 */
  displayPath?: string;
  parentId?: string;
  /** 缩略图沿用列表给出的修订号，不自行推断最新版本。 */
  versionId?: string;
  starred: boolean;
  shared: boolean;
  /** `revisions` 是版本数（数字），不是数组。 */
  revisionCount?: number;
  owner?: DriveOwner;
  capabilities: DriveCapabilities;
}

/** 元数据变化也要重建 ForEach 行及其回调；不能复用仅标识内容修订的缩略图缓存键。 */
export function driveEntryRenderKey(entry: DriveEntry): string {
  return JSON.stringify(entry);
}

export interface DrivePage {
  items: DriveEntry[];
  total: number;
  offset: number;
}

/** recent 实测可能只回 items；未知总数不能补成当前页长度。 */
export interface DriveViewPage {
  items: DriveEntry[];
  total?: number;
  offset: number;
  hasMore: boolean;
}

/** 浏览位置。`fileId` 缺省表示该空间的根。 */
export interface DriveFolderRef {
  space: DriveSpace;
  fileId?: string;
  /** 仅用于面包屑首项与错误文案，不参与请求。 */
  displayName?: string;
}

/** list_ancestor 只返回父级链，个人根允许空名称，不是普通文件条目。 */
export interface DriveAncestor {
  fileId: string;
  name: string;
  parentId?: string;
}

/**
 * 条目顶层 40 键白名单（实测）。此处记录完整名单是为了让"解码只取已知字段"
 * 这条规则可被审阅与测试，不代表模型里都有对应字段。
 */
export const DRIVE_ENTRY_KEYS: string[] = ['access_time', 'adv_shared', 'app_properties', 'capabilities',
  'change_id', 'change_time', 'content_snippet', 'content_type', 'created_time', 'disable_download',
  'display_path', 'dsm_path', 'enable_watermark', 'encrypted', 'file_id', 'force_watermark_download', 'hash',
  'image_metadata', 'labels', 'max_id', 'modified_time', 'name', 'owner', 'parent_id', 'path', 'permanent_link',
  'properties', 'removed', 'revisions', 'shared', 'shared_with', 'size', 'starred', 'support_remote', 'sync_id',
  'sync_to_device', 'transient', 'type', 'version_id', 'watermark_version'];

function driveProtocolError(detail: string): NasFailure {
  return new NasFailure(NasErrorKind.Protocol,
    'Synology Drive 返回了无法识别的数据（' + detail + '），请刷新重试；若仍失败，可通过 DSM 的 Drive 网页检查。');
}

/** 空间未安装 / 无权限时的统一文案；`selectNasApi` 的通用提示会让人以为是版本问题。 */
export function driveUnsupportedFailure(api: string): NasFailure {
  return new NasFailure(NasErrorKind.Unsupported,
    '此 NAS 不可通过 Drive 访问：' + api + ' 未安装、被停用或当前账号无权使用 Synology Drive。');
}

/**
 * Drive 的错误码语义与 File Station 不同，必须单独解释，否则会把
 * 「参数不对」误报成「接口不存在」、把「路径不存在」显示成裸错误码。
 * 依据：drive-api-map.json 的 errorCodeLessons。
 *
 * 只看错误码、不限定错误类别：实测 105 会落到 Permission、120 落到 Server，
 * 但两者的真实含义都是 Drive 特有的，不能按类别放行。传输层错误（HTTP/网络/证书）
 * 不作为业务码解释，否则 103/105 这类 HTTP 状态会被误认。
 */
export function relabelDriveFailure(error: Object): Object {
  if (!(error instanceof NasFailure)) { return error; }
  if ([NasErrorKind.Http, NasErrorKind.Network, NasErrorKind.Tls, NasErrorKind.Cancelled].includes(error.kind)) {
    return error;
  }
  switch (error.code) {
    case 103:
      return new NasFailure(NasErrorKind.Unsupported,
        '暂时无法读取 Drive 内容，请刷新重试。', 103);
    case 105:
    case 120:
      return new NasFailure(NasErrorKind.Server,
        '暂时无法读取 Drive 内容，请刷新重试。', error.code);
    case 1000:
      return new NasFailure(NasErrorKind.InvalidInput,
        '无法打开此 Drive 位置，请返回上级后重试。', 1000);
  }
  return error;
}

/**
 * 保精度的 JSON 预处理。
 *
 * Drive 的 ID 目前是**字符串**（实测 18 位数字，若为 number 早已超出
 * `Number.MAX_SAFE_INTEGER` 而被 `JSON.parse` 舍入），常规路径下扫描后保持原文。
 * 一旦某个 DSM 版本改发裸数字 ID，舍入后的
 * ID 会指向另一个对象 —— 这是不能容忍的静默错误，所以在解析入口先把已知
 * ID 字段的长整数补上引号。
 *
 * 先匹配完整字符串 token，再识别其后的整数，避免改写名称或正文中的同形文本。
 * 只处理合法整数字面量，不把小数、指数或带前导零的非法 JSON 修成合法 ID。
 */
export function precisionSafeDriveJson(text: string): string {
  return text.replace(/"(?:\\.|[^"\\])*"(?:\s*:\s*[1-9]\d{15,}(?=\s*[,}]))?/g,
    (token: string): string => token.replace(
      /^"(file_id|parent_id|max_id|change_id|version_id|sync_id|team_id|uid)"(\s*:\s*)([1-9]\d{15,})$/,
      '"$1"$2"$3"'));
}

/** HTTP 与信封校验沿用 File Station 的口径，只额外做保精度预处理与 Drive 错误码解释。 */
export function decodeDriveResponse(api: string, status: number, text: string): Record<string, Object> {
  try {
    return decodeNasResponse(api, status, precisionSafeDriveJson(text));
  } catch (error) {
    throw relabelDriveFailure(error as Object);
  }
}

/** 只接受纯数字 ID，避免把任意字符串拼进 `id:` 表达式发给服务器。 */
export function validateDriveFileId(fileId: string): string {
  if (!/^[0-9]{1,20}$/.test(fileId)) {
    throw new NasFailure(NasErrorKind.InvalidInput, 'Drive 文件标识不正确，请刷新目录后重试。');
  }
  return fileId;
}

/** 解码用：数字 ID 在安全整数范围内也可接受（15 位以内的 ID 不会被舍入）。 */
function decodeDriveId(value: Object | undefined, detail: string): string {
  if (typeof value === 'string' && /^[0-9]{1,20}$/.test(value)) { return value; }
  if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 0) { return value.toString(); }
  throw driveProtocolError(detail);
}

function optionalDriveId(value: Object | undefined): string | undefined {
  if (value === undefined) { return undefined; }
  return decodeDriveId(value, 'id 字段');
}

function optionalDriveText(value: Object | undefined, limit: number): string | undefined {
  // 可选文本的空字符串表示没有值；必需的 name 仍由条目解码明确拒绝。
  if (value === undefined || value === '') { return undefined; }
  if (typeof value !== 'string' || value.length > limit || /[\u0000-\u001f\u007f]/.test(value)) {
    throw driveProtocolError('文本字段');
  }
  return value;
}

/** 时间戳接受有限非负数；不强制整数，避免把小数秒当成协议漂移。 */
function optionalDriveTime(value: Object | undefined): number | undefined {
  if (value === undefined) { return undefined; }
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) { throw driveProtocolError('时间字段'); }
  return value;
}

/** 缺字段按 false；字段存在但不是布尔则是漂移。 */
function driveFlag(row: Record<string, Object>, key: string): boolean {
  const value = row[key];
  if (value === undefined) { return false; }
  if (typeof value !== 'boolean') { throw driveProtocolError(key); }
  return value === true;
}

function decodeDriveCapabilities(value: Object | undefined): DriveCapabilities {
  if (value === undefined) {
    // 保守：没有能力信息就不暴露任何操作入口。
    return { canRead: false, canDownload: false, canPreview: false, canWrite: false, canRename: false,
      canDelete: false, canShare: false, canOrganize: false, canComment: false, canSync: false, canEncrypt: false };
  }
  const row = nasRecord(value);
  return { canRead: driveFlag(row, 'can_read'), canDownload: driveFlag(row, 'can_download'),
    canPreview: driveFlag(row, 'can_preview'), canWrite: driveFlag(row, 'can_write'),
    canRename: driveFlag(row, 'can_rename'), canDelete: driveFlag(row, 'can_delete'),
    canShare: driveFlag(row, 'can_share'), canOrganize: driveFlag(row, 'can_organize'),
    canComment: driveFlag(row, 'can_comment'), canSync: driveFlag(row, 'can_sync'),
    canEncrypt: driveFlag(row, 'can_encrypt') };
}

function decodeDriveOwner(value: Object | undefined): DriveOwner | undefined {
  if (value === undefined) { return undefined; }
  const row = nasRecord(value);
  const owner: DriveOwner = {};
  const displayName = optionalDriveText(row['display_name'], 128);
  const name = optionalDriveText(row['name'], 128);
  const nickname = optionalDriveText(row['nickname'], 128);
  const uid = optionalDriveId(row['uid']);
  if (displayName !== undefined) { owner.displayName = displayName; }
  if (name !== undefined) { owner.name = name; }
  if (nickname !== undefined) { owner.nickname = nickname; }
  if (uid !== undefined) { owner.uid = uid; }
  return owner;
}

function decodeDriveKind(row: Record<string, Object>): DriveEntryKind {
  const value = row['type'];
  if (value === 'file') { return DriveEntryKind.File; }
  if (value === 'dir' || value === 'folder') { return DriveEntryKind.Folder; }
  throw driveProtocolError('type 字段');
}

export function decodeDriveEntry(raw: Object): DriveEntry {
  const row = nasRecord(raw);
  const fileId = decodeDriveId(row['file_id'], 'file_id 字段');
  const name = optionalDriveText(row['name'], 255);
  if (name === undefined) { throw driveProtocolError('name 字段'); }
  const size = row['size'];
  if (size !== undefined && (typeof size !== 'number' || !Number.isSafeInteger(size) || (size as number) < 0)) {
    throw driveProtocolError('size 字段');
  }
  const revisions = row['revisions'];
  if (revisions !== undefined && (typeof revisions !== 'number' || !Number.isSafeInteger(revisions) || (revisions as number) < 0)) {
    throw driveProtocolError('revisions 字段');
  }
  const entry: DriveEntry = { fileId: fileId, name: name, kind: decodeDriveKind(row),
    starred: driveFlag(row, 'starred'), shared: driveFlag(row, 'shared'),
    revisionCount: revisions as number | undefined,
    capabilities: decodeDriveCapabilities(row['capabilities']) };
  if (size !== undefined) { entry.sizeBytes = size as number; }
  const createdAt = optionalDriveTime(row['created_time']);
  const modifiedAt = optionalDriveTime(row['modified_time']);
  const accessedAt = optionalDriveTime(row['access_time']);
  const pathText = optionalDriveText(row['path'], 4096);
  const displayPath = optionalDriveText(row['display_path'], 4096);
  const parentId = optionalDriveId(row['parent_id']);
  const versionId = optionalDriveId(row['version_id']);
  const owner = decodeDriveOwner(row['owner']);
  if (createdAt !== undefined) { entry.createdAt = createdAt; }
  if (modifiedAt !== undefined) { entry.modifiedAt = modifiedAt; }
  if (accessedAt !== undefined) { entry.accessedAt = accessedAt; }
  if (pathText !== undefined) { entry.pathText = pathText; }
  if (displayPath !== undefined) { entry.displayPath = displayPath; }
  if (parentId !== undefined) { entry.parentId = parentId; }
  if (versionId !== undefined) { entry.versionId = versionId; }
  if (owner !== undefined) { entry.owner = owner; }
  return entry;
}

/** 普通文件列表；祖先链使用独立解码器。 */
export function decodeDriveEntryList(data: Record<string, Object>): DriveEntry[] {
  const raw = data['items'];
  if (!Array.isArray(raw)) { throw driveProtocolError('items 字段'); }
  return (raw as Object[]).map((item: Object): DriveEntry => decodeDriveEntry(item));
}

/** 校验根到父目录的链条，避免把乱序、循环或当前目录重复显示成可导航的祖先。 */
export function decodeDriveAncestors(data: Record<string, Object>, target: DriveEntry): DriveAncestor[] {
  const raw = data['items'];
  if (!Array.isArray(raw) || data['total'] !== raw.length) { throw driveProtocolError('祖先链'); }
  const seen = new Set<string>([target.fileId]);
  const ancestors: DriveAncestor[] = [];
  for (const item of raw as Object[]) {
    const row = nasRecord(item);
    const fileId = decodeDriveId(row['file_id'], '祖先 file_id');
    const name = optionalDriveText(row['name'], 255);
    const parentId = optionalDriveId(row['parent_id']);
    if (decodeDriveKind(row) !== DriveEntryKind.Folder || seen.has(fileId) ||
      name === undefined && (row['name'] !== '' || ancestors.length !== 0) ||
      ancestors.length > 0 && parentId !== ancestors[ancestors.length - 1].fileId) {
      throw driveProtocolError('祖先链顺序');
    }
    seen.add(fileId);
    ancestors.push({ fileId, name: name ?? '', parentId });
  }
  if (ancestors.length > 0 && target.parentId !== undefined &&
    target.parentId !== ancestors[ancestors.length - 1].fileId) { throw driveProtocolError('祖先链父目录'); }
  return ancestors;
}

/**
 * 分页校验与 File Station 同口径：条目数不能超过 limit、不能越过 total、
 * 也不能在 offset 未到末尾时返回空页。响应里没有 offset（实测只回 items/total），
 * 因此以请求参数为准。
 */
export function decodeDrivePage(data: Record<string, Object>, requestedOffset: number, limit: number): DrivePage {
  const total = data['total'];
  if (typeof total !== 'number' || !Number.isSafeInteger(total) || (total as number) < 0) {
    throw driveProtocolError('total 字段');
  }
  const items = decodeDriveEntryList(data);
  validateDrivePageItems(items, requestedOffset, limit, total as number);
  return { items: items, total: total as number, offset: requestedOffset };
}

function validateDrivePageItems(items: DriveEntry[], requestedOffset: number, limit: number, total?: number): void {
  if (!Number.isSafeInteger(requestedOffset) || requestedOffset < 0 ||
    !Number.isSafeInteger(limit) || limit <= 0) { throw driveProtocolError('分页请求'); }
  if (items.length > limit || total !== undefined && (requestedOffset + items.length > total ||
    items.length === 0 && requestedOffset < total)) {
    throw new NasFailure(NasErrorKind.Protocol, 'Drive 列表已变化，请刷新后重试。');
  }
  const seen = new Set<string>();
  for (const item of items) {
    if (seen.has(item.fileId)) { throw driveProtocolError('重复条目'); }
    seen.add(item.fileId);
  }
}

/** 团队入口实测没有 type，按该端点的目录契约解码，不能修改普通文件条目的必需字段。 */
export function decodeDriveTeamFolder(raw: Object): DriveEntry {
  const row = nasRecord(raw);
  const fileId = decodeDriveId(row['file_id'], 'file_id 字段');
  const name = optionalDriveText(row['name'], 255);
  if (name === undefined) { throw driveProtocolError('name 字段'); }
  return { fileId, name, kind: DriveEntryKind.Folder, starred: false, shared: false,
    capabilities: decodeDriveCapabilities(row['capabilities']) };
}

export function decodeDriveViewPage(data: Record<string, Object>, view: DriveView,
  requestedOffset: number, limit: number = DRIVE_PAGE_SIZE): DriveViewPage {
  const total = data['total'];
  if (total === undefined ? view !== DriveView.Recent :
    typeof total !== 'number' || !Number.isSafeInteger(total) || (total as number) < 0) {
    throw driveProtocolError('total 字段');
  }
  const raw = data['items'];
  if (!Array.isArray(raw)) { throw driveProtocolError('items 字段'); }
  const items = (raw as Object[]).map((item: Object): DriveEntry =>
    view === DriveView.TeamFolders ? decodeDriveTeamFolder(item) : decodeDriveEntry(item));
  validateDrivePageItems(items, requestedOffset, limit, total as number | undefined);
  return { items, total: total as number | undefined, offset: requestedOffset,
    hasMore: total === undefined ? items.length === limit : requestedOffset + items.length < (total as number) };
}

/**
 * 把浏览位置转成 Drive 的 `path` 表达式。
 *
 * 铁律：**团队文件夹没有虚拟根**。实测 `path=/team-folders` 返回 1000，
 * 必须先 `TeamFolders.list` 取到 `file_id` 再按 `id:<file_id>` 访问；
 * 也不能把 `/mydrive` 简单替换成 File Station 的 `/home`。
 */
export function drivePathExpression(folder: DriveFolderRef): string {
  if (folder.fileId === undefined) {
    if (folder.space !== DriveSpace.MyDrive) {
      throw new NasFailure(NasErrorKind.InvalidInput, '请先选择具体的团队文件夹。');
    }
    return '/mydrive';
  }
  return 'id:' + validateDriveFileId(folder.fileId);
}

function driveText(field: string, value: string, limit: number): NasFormField {
  if (value.length === 0 || value.length > limit || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new NasFailure(NasErrorKind.InvalidInput, 'Drive 请求参数不正确。');
  }
  return { name: field, content: JSON.stringify(value) };
}

function driveCount(field: string, value: number, allowZero: boolean): NasFormField {
  if (!Number.isSafeInteger(value) || value < (allowZero ? 0 : 1)) {
    throw new NasFailure(NasErrorKind.InvalidInput, 'Drive 请求参数不正确。');
  }
  return { name: field, content: value.toString() };
}

/**
 * 构造目录列表参数。
 *
 * 参数值**不是一律 JSON 编码**：实测 offset/limit 是裸数字，而 path / sort_by /
 * sort_direction 是带引号的 JSON 字符串（`path="/mydrive"`、`sort_by="modified_time"`）。
 * 混用这两类会让服务端返回 103。
 */
export function driveListFields(folder: DriveFolderRef, offset: number,
  sortBy: DriveSortBy = DriveSortBy.Name,
  sortDirection: DriveSortDirection = DriveSortDirection.Ascending,
  limit: number = DRIVE_PAGE_SIZE): NasFormField[] {
  return [
    driveText('path', drivePathExpression(folder), 4096),
    driveCount('offset', offset, true),
    driveCount('limit', limit, false),
    driveText('sort_by', sortBy, 32),
    driveText('sort_direction', sortDirection, 8)
  ];
}

/** P1 列表沿用成功探测的完整参数；recent 用 atime，不给跨目录视图硬塞 path。 */
export function driveViewFields(view: DriveView, offset: number): NasFormField[] {
  const fields: NasFormField[] = [driveCount('offset', offset, true), driveCount('limit', DRIVE_PAGE_SIZE, false),
    driveText('sort_by', view === DriveView.Recent ? DriveSortBy.AccessTime : DriveSortBy.ModifiedTime, 32),
    driveText('sort_direction', DriveSortDirection.Ascending, 8),
    { name: 'filter', content: '{"include_transient":true}' }];
  if (view === DriveView.MyDrive || view === DriveView.Trash) { fields.push(driveText('path', '/mydrive', 4096)); }
  return fields;
}

export function driveSearchFields(keyword: string, offset: number, folder?: DriveFolderRef): NasFormField[] {
  const query = keyword.trim();
  if (query.length === 0) { throw new NasFailure(NasErrorKind.InvalidInput, '请输入搜索内容。'); }
  if (folder !== undefined && folder.fileId === undefined) {
    throw new NasFailure(NasErrorKind.InvalidInput, '请先选择具体的 Drive 文件夹。');
  }
  // 只使用成功抓包的 mydrive/custom 范围；搜索排序与普通列表不同。
  const fields: NasFormField[] = [driveText('keyword', query, 256),
    driveText('location', folder === undefined ? 'mydrive' : 'custom', 32),
    driveText('sort_by', 'score', 32), driveText('sort_direction', DriveSortDirection.Ascending, 8),
    { name: 'enable_content_search', content: 'false' }, { name: 'content_snippet', content: 'false' },
    driveCount('offset', offset, true), driveCount('limit', DRIVE_PAGE_SIZE, false),
    { name: 'filter', content: '{"include_transient":true}' }];
  if (folder !== undefined) { fields.push(driveText('custom_location', drivePathExpression(folder), 4096)); }
  return fields;
}

export function driveAncestorFields(fileId: string): NasFormField[] {
  return [driveText('path', 'id:' + validateDriveFileId(fileId), 4096)];
}

/**
 * 诊断用：列出响应里不在白名单内的顶层键。
 *
 * 它是"解码只取已知字段"这条规则的**探针**：DSM 升级若新增或改名条目字段，
 * 白名单不变则功能不受影响，但调用方（含单测与以后的诊断页）能立刻看到漂移。
 */
export function unknownDriveEntryKeys(raw: Object): string[] {
  const row = nasRecord(raw);
  return Object.keys(row).filter((key: string): boolean => !DRIVE_ENTRY_KEYS.includes(key));
}
