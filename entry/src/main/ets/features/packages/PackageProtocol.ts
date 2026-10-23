import { nasRecord, NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';

export type PackageState = 'running' | 'stopped' | 'unknown';
export type PackageNativeTarget = 'files' | 'drive' | 'photos' | 'downloads' | 'containers';

/** 仅保留目录展示所需信息，附加配置不进入页面状态。 */
export interface InstalledPackage {
  id: string;
  name: string;
  version: string;
  state: PackageState;
  checkedAt: number;
}

/** 原生入口按套件身份匹配，显示名称及服务端链接均不能决定路由。 */
export function packageNativeTarget(id: string): PackageNativeTarget | undefined {
  switch (id) {
    case 'FileStation': return 'files';
    case 'SynologyDrive': return 'drive';
    case 'SynologyPhotos': return 'photos';
    case 'DownloadStation': return 'downloads';
    case 'Docker': case 'ContainerManager': return 'containers';
    default: return undefined;
  }
}

export function validatePackageId(id: string): void {
  if (id.trim().length === 0 || /[\u0000-\u001f\u007f]/.test(id)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '套件标识无效。');
  }
}

function optionalText(data: Record<string, Object>, key: string): string {
  if (data[key] === undefined) { return ''; }
  if (typeof data[key] !== 'string') { throw new NasFailure(NasErrorKind.Protocol, '套件信息格式不正确。'); }
  return (data[key] as string).trim();
}

function decodePackage(input: Object, checkedAt: number): InstalledPackage {
  const data = nasRecord(input);
  const id = data['id'];
  if (typeof id !== 'string' || id.trim().length === 0 || /[\u0000-\u001f\u007f]/.test(id)) {
    throw new NasFailure(NasErrorKind.Protocol, '套件响应缺少有效标识。');
  }
  let state: PackageState = 'unknown';
  if (data['additional'] !== undefined) {
    const additional = nasRecord(data['additional']);
    const status = optionalText(additional, 'status');
    if (status === 'running' || status === 'stopped') { state = status; }
  }
  return { id: id, name: optionalText(data, 'name'), version: optionalText(data, 'version'), state: state, checkedAt: checkedAt };
}

/** 缺少目录结构或重复身份必须整体报错，不能把不完整响应展示成成功。 */
export function decodePackageList(input: Object, checkedAt: number = Date.now()): InstalledPackage[] {
  const data = nasRecord(input);
  if (!Array.isArray(data['packages'])) { throw new NasFailure(NasErrorKind.Protocol, '套件目录格式不正确。'); }
  const ids: Set<string> = new Set<string>();
  return (data['packages'] as Object[]).map((raw: Object): InstalledPackage => {
    const item = decodePackage(raw, checkedAt);
    if (ids.has(item.id)) { throw new NasFailure(NasErrorKind.Protocol, '套件目录包含重复标识。'); }
    ids.add(item.id);
    return item;
  }).sort((left: InstalledPackage, right: InstalledPackage): number =>
    left.name.localeCompare(right.name) || left.id.localeCompare(right.id));
}

export function decodePackageDetail(input: Object, id: string, checkedAt: number = Date.now()): InstalledPackage {
  const item = decodePackage(input, checkedAt);
  if (item.id !== id) { throw new NasFailure(NasErrorKind.Protocol, '返回的套件与请求不一致。'); }
  return item;
}

export function filterPackages(items: InstalledPackage[], query: string, supportedOnly: boolean): InstalledPackage[] {
  const text = query.trim().toLocaleLowerCase();
  return items.filter((item: InstalledPackage): boolean => (!supportedOnly || packageNativeTarget(item.id) !== undefined) &&
    (text.length === 0 || item.name.toLocaleLowerCase().includes(text) || item.id.toLocaleLowerCase().includes(text)));
}
