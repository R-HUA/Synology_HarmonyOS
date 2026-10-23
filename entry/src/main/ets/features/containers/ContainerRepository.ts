import { NasConnector } from '../../core/network/NasConnector';
import { ContainerDetail, ContainerItem, ContainerResource, decodeContainerDetail, decodeContainerLogs, decodeContainerResource, decodeContainers } from './ContainerProtocol';
import { TextWindow } from '../../core/domain/ReadOnlyProtocol';

export class ContainerRepository {
  constructor(private connector: NasConnector) {}
  list(): Promise<ContainerItem[]> { return this.connector.readContainers('list', '', decodeContainers); }
  detail(item: ContainerItem): Promise<ContainerDetail> {
    return this.connector.readContainers('detail', item.name, (data: Object): ContainerDetail => decodeContainerDetail(data, item));
  }
  async resources(item: ContainerItem, check: () => void): Promise<ContainerResource> {
    // 批量资源只有名称；只在详情读取，并在采样前后核对原始容器身份。
    await this.detail(item); check();
    const resource = await this.connector.readContainers('resources', '', (data: Object): ContainerResource => decodeContainerResource(data, item));
    check(); await this.detail(item); check();
    return resource;
  }
  async logs(item: ContainerItem, check: () => void): Promise<TextWindow> {
    await this.detail(item); check();
    const logs = await this.connector.readContainers('logs', item.name, decodeContainerLogs);
    check(); await this.detail(item); check();
    return logs;
  }
}
