import type { NasFormField } from '../../core/domain/DsmProtocol';
import { decodeDownloadActionResults, decodeDownloadCreateResult, decodeDownloadTaskInfo, decodeDownloadTaskPage,
  validateDownloadDestination, validateDownloadPagination, validateDownloadTaskIds, validateDownloadUri } from './DownloadStationProtocol';
import type { DownloadCreateResult, DownloadTask, DownloadTaskActionResult, DownloadTaskPage } from './DownloadStationProtocol';

export class DownloadStationRepository {
  constructor(private call: (method: string, fields: NasFormField[]) => Promise<Object>) {}

  async list(offset: number = 0, limit: number = 50): Promise<DownloadTaskPage> {
    validateDownloadPagination(offset, limit);
    return decodeDownloadTaskPage(await this.call('list', [
      { name: 'offset', content: offset.toString() }, { name: 'limit', content: limit.toString() },
      { name: 'additional', content: 'detail,transfer' }
    ]), offset, limit);
  }

  async getInfo(id: string): Promise<DownloadTask> {
    validateDownloadTaskIds([id]);
    return decodeDownloadTaskInfo(await this.call('getinfo', [
      { name: 'id', content: id }, { name: 'additional', content: 'detail,transfer,file' }
    ]), id);
  }

  async create(uri: string, destination: string): Promise<DownloadCreateResult> {
    validateDownloadUri(uri);
    validateDownloadDestination(destination);
    return decodeDownloadCreateResult(await this.call('create', [
      { name: 'uri', content: uri }, { name: 'destination', content: destination }
    ]));
  }

  async pause(ids: string[]): Promise<DownloadTaskActionResult[]> {
    return this.control('pause', ids);
  }

  async resume(ids: string[]): Promise<DownloadTaskActionResult[]> {
    return this.control('resume', ids);
  }

  async remove(ids: string[]): Promise<DownloadTaskActionResult[]> {
    return this.control('delete', ids);
  }

  private async control(method: string, ids: string[]): Promise<DownloadTaskActionResult[]> {
    validateDownloadTaskIds(ids);
    const requestedIds = ids.slice();
    const fields: NasFormField[] = [{ name: 'id', content: requestedIds.join(',') }];
    if (method === 'delete') { fields.push({ name: 'force_complete', content: 'false' }); }
    return decodeDownloadActionResults(await this.call(method, fields), requestedIds);
  }
}
