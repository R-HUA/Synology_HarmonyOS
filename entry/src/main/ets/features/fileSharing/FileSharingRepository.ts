import type { NasFormField } from '../../core/domain/DsmProtocol';
import { decodeShareCreateResults, decodeShareIdResults, decodeShareInfo, decodeSharePage,
  sharingCreateFields, sharingEditFields, sharingInfoFields, sharingListFields, sharingRemoveFields } from './FileSharingProtocol';
import type { ShareCreateResult, ShareIdResult, ShareLink, ShareLinkOptions, ShareLinkPage } from './FileSharingProtocol';

export class FileSharingRepository {
  constructor(private call: (method: string, fields: NasFormField[]) => Promise<Object>) {}

  async list(offset: number = 0, limit: number = 50): Promise<ShareLinkPage> {
    const fields = sharingListFields(offset, limit);
    return decodeSharePage(await this.call('list', fields), offset, limit);
  }

  async getInfo(id: string): Promise<ShareLink> {
    const fields = sharingInfoFields(id);
    return decodeShareInfo(await this.call('getinfo', fields), id);
  }

  async create(paths: string[], options: ShareLinkOptions = {}): Promise<ShareCreateResult[]> {
    const fields = sharingCreateFields(paths, options);
    const requested = paths.slice();
    return decodeShareCreateResults(await this.call('create', fields), requested);
  }

  async edit(id: string, options: ShareLinkOptions): Promise<ShareIdResult> {
    const fields = sharingEditFields(id, options);
    return decodeShareIdResults(await this.call('edit', fields), [id])[0];
  }

  async remove(ids: string[]): Promise<ShareIdResult[]> {
    const fields = sharingRemoveFields(ids);
    const requested = ids.slice();
    return decodeShareIdResults(await this.call('delete', fields), requested);
  }
}
