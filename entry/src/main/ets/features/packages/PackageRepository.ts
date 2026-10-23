import type { NasFormField } from '../../core/domain/DsmProtocol';
import { decodePackageDetail, decodePackageList, validatePackageId } from './PackageProtocol';
import type { InstalledPackage } from './PackageProtocol';

/** 目录仅使用固定的两种读取操作，版本与会话由连接器统一处理。 */
export class PackageRepository {
  constructor(private call: (method: 'list' | 'get', fields: NasFormField[]) => Promise<Object>) {}

  async list(): Promise<InstalledPackage[]> {
    return decodePackageList(await this.call('list', [
      { name: 'additional', content: '["status"]' }, { name: 'ignore_hidden', content: 'false' }
    ]));
  }

  async get(id: string): Promise<InstalledPackage> {
    validatePackageId(id);
    return decodePackageDetail(await this.call('get', [
      { name: 'id', content: id }, { name: 'additional', content: '["status"]' }
    ]), id);
  }
}
