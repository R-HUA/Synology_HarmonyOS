import { NasConnector } from '../../core/network/NasConnector';
import { decodeSystemLogs, SystemLogPage } from './SystemLogProtocol';

export class SystemLogRepository {
  constructor(private connector: NasConnector) {}
  list(offset: number, until: number): Promise<SystemLogPage> {
    return this.connector.readSystemLogs(offset, until, (data: Object): SystemLogPage => decodeSystemLogs(data, offset));
  }
}
