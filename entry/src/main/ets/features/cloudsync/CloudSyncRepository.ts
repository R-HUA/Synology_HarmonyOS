import { NasConnector } from '../../core/network/NasConnector';
import { NasFailure, NasErrorKind } from '../../core/domain/DsmProtocol';
import { CloudConnection, CloudFolder, CloudHistoryPage, CloudQuota, decodeCloudConnections, decodeCloudFolders, decodeCloudHistory, decodeCloudQuota } from './CloudSyncProtocol';

export class CloudSyncRepository {
  constructor(private connector: NasConnector) {}
  list(): Promise<CloudConnection[]> { return this.connector.readCloudSync('connections', '', 0, 0, decodeCloudConnections); }
  async folders(id: string, check: () => void): Promise<CloudFolder[]> {
    const connections = await this.list(); check();
    if (!connections.some((item: CloudConnection): boolean => item.id === id)) {
      throw new NasFailure(NasErrorKind.InvalidInput, '此云同步连接已被移除，请返回刷新列表。');
    }
    return this.connector.readCloudSync('folders', id, 0, 0, (data: Object): CloudFolder[] => decodeCloudFolders(data, id));
  }
  quota(id: string): Promise<CloudQuota> { return this.connector.readCloudSync('quota', id, 0, 0, decodeCloudQuota); }
  history(id: string, offset: number, until: number): Promise<CloudHistoryPage> {
    return this.connector.readCloudSync('history', id, offset, until, (data: Object): CloudHistoryPage => decodeCloudHistory(data, offset, until));
  }
}
