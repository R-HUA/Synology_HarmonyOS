import { common } from '@kit.AbilityKit';
import { NasErrorKind, NasFailure, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import { NasConnectionAddress, NasConnectionDeviceBinding, NasConnectionRouteKind,
  validateConnectionAddress, decodeNasDeviceIdentity } from '../../core/domain/ConnectionRoutes';
import { NasConnector } from '../../core/network/NasConnector';
import { RcpNasTransport } from '../../core/network/RcpNasTransport';
import { NasAddressBookStore, nasDeviceFingerprint } from './NasAddressBookStore';

export interface NasAddressProbeResult {
  origin: string;
  passed: boolean;
  observedAt: number;
  message: string;
}

@ObservedV2
export class ConnectionAddressBook {
  @Trace addresses: NasConnectionAddress[] = [];
  @Trace ready: boolean = false;
  @Trace busy: boolean = false;
  @Trace probing: boolean = false;
  @Trace errorText: string = '';
  @Trace notice: string = '';
  @Trace draftOrigin: string = '';
  @Trace draftName: string = '';
  @Trace draftKind: NasConnectionRouteKind = 'lan';
  @Trace probeResult: NasAddressProbeResult | undefined = undefined;
  private store: NasAddressBookStore = new NasAddressBookStore();
  private generation: number = 0;
  private probeGeneration: number = 0;
  private probeConnector: NasConnector | undefined = undefined;

  async load(context: common.UIAbilityContext): Promise<boolean> {
    if (this.busy) { return false; }
    this.cancelProbe();
    const ticket = ++this.generation;
    this.busy = true;
    this.ready = false;
    this.errorText = '';
    try {
      const addresses = await this.store.load(context);
      if (ticket !== this.generation) { return false; }
      this.addresses = addresses;
      this.ready = true;
      return true;
    } catch (error) {
      if (ticket === this.generation) { this.errorText = this.failureText(error as Error, '读取连接地址失败，请重试。'); }
      return false;
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }

  setDraftOrigin(origin: string): void {
    this.cancelProbe();
    this.draftOrigin = origin;
    this.probeResult = undefined;
    this.notice = '';
  }

  edit(address: NasConnectionAddress): void {
    if (this.busy) { return; }
    this.setDraftOrigin(address.origin);
    this.draftName = address.name;
    this.draftKind = address.kind;
  }

  async probe(origin: string = this.draftOrigin): Promise<void> {
    if (this.busy || this.probing) { return; }
    const ticket = ++this.probeGeneration;
    this.probing = true;
    this.probeResult = undefined;
    const connector = new NasConnector(new RcpNasTransport());
    this.probeConnector = connector;
    let normalized = origin;
    try {
      normalized = normalizeNasOrigin(origin);
      await connector.discover(normalized);
      if (ticket !== this.probeGeneration) { return; }
      this.probeResult = { origin: normalized, passed: true, observedAt: Date.now(),
        message: 'HTTPS 与基础接口可用；未发送登录凭据，也未核验设备身份。' };
    } catch (error) {
      if (ticket === this.probeGeneration) {
        const failure = error instanceof NasFailure ? error : undefined;
        this.probeResult = { origin: normalized, passed: false, observedAt: Date.now(),
          message: failure?.kind === NasErrorKind.Unsupported ? '此地址未提供应用所需的基础接口。' :
            this.failureText(error as Error, '测试连接失败，请检查地址与网络。') };
      }
    } finally {
      connector.close();
      if (ticket === this.probeGeneration) { this.probeConnector = undefined; this.probing = false; }
    }
  }

  cancelProbe(): void {
    this.probeGeneration++;
    this.probeConnector?.close();
    this.probeConnector = undefined;
    this.probing = false;
  }

  async saveDraft(): Promise<boolean> {
    return this.saveAddress(this.draftOrigin, this.draftName, this.draftKind);
  }

  async saveCurrent(connector: NasConnector, origin: string, account: string): Promise<boolean> {
    if (!this.ready || this.busy || this.probing) { return false; }
    const ticket = this.generation;
    this.busy = true;
    this.errorText = '';
    this.notice = '';
    try {
      const normalized = normalizeNasOrigin(origin);
      const existing = this.addresses.find((address: NasConnectionAddress): boolean => address.origin === normalized);
      validateConnectionAddress({ origin: normalized, name: this.draftName, kind: this.draftKind, device: existing?.device });
      let device = existing?.device;
      let verified = false;
      try {
        const identity = decodeNasDeviceIdentity(await connector.telemetrySystem());
        const fingerprint = await nasDeviceFingerprint(identity);
        if (ticket !== this.generation) { return false; }
        if (device !== undefined && device.fingerprint !== fingerprint) {
          throw new NasFailure(NasErrorKind.InvalidInput, '设备标识与原登记不一致，不能覆盖登记。请先核对服务器地址。');
        }
        device = { account: account.trim(), fingerprint: fingerprint, model: identity.model };
        verified = true;
      } catch (error) {
        if (!(error instanceof NasFailure) || ![NasErrorKind.Permission, NasErrorKind.Unsupported].includes(error.kind)) { throw error as Error; }
      }
      if (ticket !== this.generation) { return false; }
      const address: NasConnectionAddress = { origin: normalized, name: this.draftName, kind: this.draftKind, device: device };
      const saved = await this.commit(address, ticket);
      if (saved) {
        this.notice = verified ? '地址与当前账号的设备身份已登记，后续登录会重新核验。' :
          device === undefined ? '地址已保存；当前账号无法读取设备标识，未登记设备身份。' :
            '地址已保存，原设备登记仍保留；本次未完成身份核验。';
      }
      return saved;
    } catch (error) {
      if (ticket === this.generation) { this.errorText = this.failureText(error as Error, '保存当前连接失败，请重试。'); }
      if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { throw error; }
      return false;
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }

  async verifyExpectedDevice(connector: NasConnector, origin: string, account: string): Promise<string | undefined> {
    if (!this.ready) { throw new NasFailure(NasErrorKind.Protocol, '连接地址配置尚未读取成功，不能安全恢复连接。'); }
    const normalized = normalizeNasOrigin(origin);
    const device = this.addresses.find((address: NasConnectionAddress): boolean => address.origin === normalized)?.device;
    if (device === undefined || device.account !== account.trim()) { return undefined; }
    const ticket = this.generation;
    let fingerprint: string;
    try {
      fingerprint = await nasDeviceFingerprint(decodeNasDeviceIdentity(await connector.telemetrySystem()));
    } catch (error) {
      if (error instanceof NasFailure && [NasErrorKind.Permission, NasErrorKind.Unsupported].includes(error.kind)) {
        throw new NasFailure(error.kind, '当前账号无法核验已登记的设备，已停止恢复。请在连接地址中核对登记或账号权限。', error.code);
      }
      throw error as Error;
    }
    if (ticket !== this.generation) { throw new NasFailure(NasErrorKind.Cancelled, '连接地址配置已变化，请重试。'); }
    if (fingerprint !== device.fingerprint) {
      throw new NasFailure(NasErrorKind.InvalidInput, '此地址的设备标识已变化，已停止连接，未恢复旧任务。请在连接地址中核对设备。');
    }
    return device.model;
  }

  private async saveAddress(origin: string, name: string, kind: NasConnectionRouteKind): Promise<boolean> {
    if (!this.ready || this.busy || this.probing) { return false; }
    const ticket = this.generation;
    this.busy = true;
    this.errorText = '';
    this.notice = '';
    try {
      const normalized = normalizeNasOrigin(origin);
      const previous = this.addresses.find((address: NasConnectionAddress): boolean => address.origin === normalized);
      const saved = await this.commit({ origin: normalized, name: name, kind: kind, device: previous?.device }, ticket);
      if (saved) { this.notice = '连接地址已保存；不会自动切换地址或复制登录信息。'; }
      return saved;
    } catch (error) {
      if (ticket === this.generation) { this.errorText = this.failureText(error as Error, '保存连接地址失败，请重试。'); }
      return false;
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }

  async remove(origin: string): Promise<void> {
    if (!this.ready || this.busy || this.probing) { return; }
    const ticket = this.generation;
    this.busy = true;
    this.errorText = '';
    this.notice = '';
    try {
      const normalized = normalizeNasOrigin(origin);
      const addresses = this.addresses.filter((address: NasConnectionAddress): boolean => address.origin !== normalized);
      await this.store.save(addresses);
      if (ticket === this.generation) { this.addresses = addresses; this.notice = '地址与身份登记已移除，文件和任务记录未删除。'; }
    } catch (error) {
      if (ticket === this.generation) { this.errorText = this.failureText(error as Error, '移除连接地址失败，请重试。'); }
    } finally { if (ticket === this.generation) { this.busy = false; } }
  }

  private async commit(input: NasConnectionAddress, ticket: number): Promise<boolean> {
    const address = validateConnectionAddress(input);
    const addresses = this.addresses.filter((candidate: NasConnectionAddress): boolean => candidate.origin !== address.origin);
    addresses.push(address);
    await this.store.save(addresses);
    if (ticket !== this.generation) { return false; }
    this.addresses = addresses;
    return true;
  }

  dispose(): void {
    this.generation++;
    this.cancelProbe();
    this.ready = false;
    this.busy = false;
    this.addresses = [];
  }

  private failureText(error: Error, fallback: string): string {
    return error instanceof NasFailure ? error.message : fallback;
  }
}
