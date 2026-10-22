import { common } from '@kit.AbilityKit';
import { mdns } from '@kit.NetworkKit';
import { NasConnectionAddress } from '../../core/domain/ConnectionRoutes';
import { NasConnector } from '../../core/network/NasConnector';
import { RcpNasTransport } from '../../core/network/RcpNasTransport';

/** 仅检查局域网公布的网页服务，确认认证接口后才显示为群晖设备。 */
@ObservedV2
export class NasLanDiscovery {
  @Trace searching: boolean = false;
  @Trace results: NasConnectionAddress[] = [];
  @Trace errorText: string = '';
  @Trace finished: boolean = false;
  private services: mdns.DiscoveryService[] = [];
  private connectors: Set<NasConnector> = new Set();
  private checked: Set<string> = new Set();
  private generation: number = 0;
  private timer: number = -1;

  start(context: common.UIAbilityContext): void {
    this.stop();
    const ticket = this.generation;
    this.results = []; this.checked.clear(); this.errorText = ''; this.finished = false; this.searching = true;
    try {
      for (const type of ['_http._tcp', '_https._tcp']) {
        const service = mdns.createDiscoveryService(context, type);
        this.services.push(service);
        service.on('discoveryStart', (event: mdns.DiscoveryEventInfo): void => {
          if (ticket === this.generation && event.errorCode !== undefined) { this.errorText = '无法搜索局域网设备，请检查网络后重试。'; this.stop(); }
        });
        service.on('serviceFound', (info: mdns.LocalServiceInfo): void => { this.resolve(context, info, ticket); });
        service.startSearchingMDNS();
      }
      this.timer = setTimeout((): void => { this.stop(); this.finished = true; }, 15000);
    } catch (error) { this.errorText = (error as Error).message; this.stop(); }
  }

  private async resolve(context: common.UIAbilityContext, info: mdns.LocalServiceInfo, ticket: number): Promise<void> {
    let connector: NasConnector | undefined = undefined;
    try {
      const service = await mdns.resolveLocalService(context, info);
      if (ticket !== this.generation) { return; }
      const host = service.host?.address;
      if (!host || !service.port) { throw new Error('局域网服务未提供有效地址。'); }
      const origin = (service.serviceType === '_https._tcp' ? 'https://' : 'http://') +
        (host.includes(':') ? '[' + host + ']' : host) + ':' + service.port.toString();
      if (this.checked.has(origin)) { return; }
      this.checked.add(origin);
      connector = new NasConnector(new RcpNasTransport(false));
      this.connectors.add(connector);
      await connector.discover(origin);
      if (ticket === this.generation) {
        this.results = this.results.concat([{ origin, name: service.serviceName.slice(0, 40), kind: 'lan', insecureTls: false }]);
      }
    } catch (error) {
      if (ticket === this.generation) { this.errorText = '部分局域网服务无法验证：' + (error as Error).message; }
    } finally { if (connector !== undefined) { connector.close(); this.connectors.delete(connector); } }
  }

  stop(): void {
    this.generation++;
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    for (const service of this.services) { service.stopSearchingMDNS(); service.off('serviceFound'); service.off('discoveryStart'); }
    this.services = [];
    for (const connector of this.connectors) { connector.close(); }
    this.connectors.clear(); this.searching = false;
  }
}
