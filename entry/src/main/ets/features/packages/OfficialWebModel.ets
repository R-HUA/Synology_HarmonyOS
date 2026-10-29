import { webview } from '@kit.ArkWeb';
import { NasErrorKind, NasFailure, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import { NasConnector } from '../../core/network/NasConnector';

/** 网页状态随当前账号销毁，凭证不会进入网页地址或磁盘 Cookie 库。 */
@ObservedV2
export class OfficialWebModel {
  @Trace active: boolean = false;
  @Trace errorText: string = '';
  private connector: NasConnector | undefined = undefined;
  private origin: string = '';
  private insecureTls: boolean = false;
  onBack: () => boolean = (): boolean => false;
  private generation: number = 0;
  private identity: number = 0;
  get pageIdentity(): number { return this.identity; }
  private expired: (error: NasFailure) => Promise<void> = async (): Promise<void> => {};

  attach(connector: NasConnector, origin: string, insecureTls: boolean, expired: (error: NasFailure) => Promise<void>): void {
    this.reset();
    this.connector = connector; this.origin = normalizeNasOrigin(origin); this.insecureTls = insecureTls; this.expired = expired;
  }

  open(): void { this.errorText = ''; this.active = this.connector !== undefined; }

  close(): void {
    this.generation++; this.identity++; this.active = false; this.onBack = (): boolean => false;
    // API 11：本应用仅此容器使用隐私 Cookie，不影响普通 Web 存储。
    webview.WebCookieManager.clearAllCookiesSync(true);
  }

  reset(): void {
    this.close(); this.connector = undefined; this.origin = ''; this.errorText = '';
    this.expired = async (): Promise<void> => {};
  }

  /** API 14 的 HttpOnly Cookie 重载在页面加载前同步配置，避免退出与注入交错。 */
  async prepare(): Promise<string> {
    const connector = this.connector, generation = ++this.generation;
    if (!this.active || connector === undefined) { throw new NasFailure(NasErrorKind.Cancelled, '网页已关闭。'); }
    this.errorText = '';
    try {
      await connector.validateSession();
      if (!this.active || generation !== this.generation) { throw new NasFailure(NasErrorKind.Cancelled, '连接已变化。'); }
      webview.WebCookieManager.clearAllCookiesSync(true);
      for (const cookie of connector.webSessionCookies()) {
        webview.WebCookieManager.configCookieSync(this.origin + '/', cookie, true, true);
      }
      return this.origin + '/';
    } catch (error) {
      if (generation === this.generation && this.active) {
        this.errorText = error instanceof NasFailure ? error.message : '网页登录准备失败，请重试。';
        if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) { await this.expired(error); }
      }
      if (error instanceof Error) { throw error; }
      throw new NasFailure(NasErrorKind.Protocol, '网页登录准备失败。');
    }
  }

  accepts(address: string): boolean {
    const match = /^(https?:\/\/[^/?#]+)/i.exec(address);
    if (match === null) { return false; }
    try { return normalizeNasOrigin(match[1]) === this.origin; }
    catch (error) {
      if (error instanceof NasFailure && error.kind === NasErrorKind.InvalidInput) { return false; }
      if (error instanceof Error) { throw error; }
      throw new NasFailure(NasErrorKind.Protocol, '网页地址无效。');
    }
  }

  allowsCertificateException(address: string): boolean { return this.active && this.insecureTls && this.accepts(address); }
}
