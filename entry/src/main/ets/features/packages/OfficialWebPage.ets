import { webview } from '@kit.ArkWeb';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { OfficialWebModel } from './OfficialWebModel';
import { WorkbenchNotice } from '../workbench/WorkbenchUi';

/** 新窗口保留独立控制器，使官方页面的 opener 与关闭行为由内核维护。 */
class OfficialWebWindow {
  id: number;
  handler: ControllerHandler | undefined;
  controller: webview.WebviewController = new webview.WebviewController();
  constructor(id: number, handler?: ControllerHandler) { this.id = id; this.handler = handler; }
}

/** 导航标题由外层目的页持有，官方网页保留自身布局与缩放。 */
@ComponentV2
export struct OfficialWebPage {
  @Param model: OfficialWebModel = new OfficialWebModel();
  @Local private loading: boolean = true;
  @Local private windows: OfficialWebWindow[] = [new OfficialWebWindow(0)];
  private revision: number = 0;
  private nextId: number = 1;
  private ownerIdentity: number = -1;

  aboutToAppear(): void { this.ownerIdentity = this.model.pageIdentity; }

  aboutToDisappear(): void {
    this.revision++;
    if (this.ownerIdentity === this.model.pageIdentity) { this.model.close(); }
  }

  private current(): boolean { return this.model.active && this.ownerIdentity === this.model.pageIdentity; }

  private back(): boolean {
    const current = this.windows[this.windows.length - 1];
    if (current.controller.accessBackward()) { current.controller.backward(); return true; }
    if (this.windows.length > 1) { this.windows = this.windows.slice(0, -1); return true; }
    return false;
  }

  private async load(): Promise<void> {
    if (!this.current()) { return; }
    const revision = ++this.revision;
    this.loading = true;
    this.windows = this.windows.slice(0, 1);
    try {
      const address = await this.model.prepare();
      if (revision === this.revision && this.current()) { this.windows[0].controller.loadUrl(address); }
    } catch (error) {
      if (revision === this.revision && this.current() && !(error instanceof NasFailure && error.kind === NasErrorKind.Cancelled)) {
        this.model.errorText = this.model.errorText.length > 0 ? this.model.errorText : '网页暂时无法打开，请重试。';
      }
    } finally { if (revision === this.revision) { this.loading = false; } }
  }

  @Builder
  webPane(item: OfficialWebWindow) {
    Web({ src: 'about:blank', controller: item.controller, incognitoMode: true })
      .javaScriptAccess(true).domStorageAccess(true).zoomAccess(true).multiWindowAccess(true)
      .onControllerAttached((): void => {
        if (!this.current()) { item.handler?.setWebController(null); return; }
        if (item.handler !== undefined) { item.handler.setWebController(item.controller); }
        else {
          this.model.onBack = (): boolean => this.back();
          this.load();
        }
      })
      .onLoadIntercept((event): boolean => {
        if (!this.current()) { return true; }
        const address = event.data.getRequestUrl();
        if (address === 'about:blank' || this.model.accepts(address)) { return false; }
        this.model.errorText = '此链接需要通过其他地址访问，请在浏览器中打开。';
        return true;
      })
      .onWindowNew((event): void => {
        if (!this.current()) { event.handler.setWebController(null); return; }
        if (event.targetUrl.length > 0 && event.targetUrl !== 'about:blank' && !this.model.accepts(event.targetUrl)) {
          event.handler.setWebController(null);
          this.model.errorText = '此链接需要通过其他地址访问，请在浏览器中打开。';
          return;
        }
        this.windows = this.windows.concat([new OfficialWebWindow(this.nextId++, event.handler)]);
      })
      .onWindowExit((): void => { if (this.current()) { this.windows = this.windows.filter((window: OfficialWebWindow): boolean => window.id !== item.id || item.id === 0); } })
      .onSslErrorEvent((event): void => {
        if (!this.current()) { event.handler.handleCancel(); return; }
        if (this.model.allowsCertificateException(event.url)) { event.handler.handleConfirm(); }
        else { event.handler.handleCancel(); this.model.errorText = '网页证书校验失败，请检查当前连接的证书设置。'; }
      })
      .onErrorReceive((event): void => {
        if (this.current() && event?.request.isMainFrame()) { this.model.errorText = '网页加载失败，请检查连接后刷新。'; }
      })
      .onHttpErrorReceive((event): void => {
        if (this.current() && event?.request.isMainFrame()) { this.model.errorText = '服务器未能打开此页面，请稍后刷新。'; }
      })
      .visibility(item.id === this.windows[this.windows.length - 1].id ? Visibility.Visible : Visibility.Hidden)
      .width('100%').height('100%')
  }

  build() {
    Column() {
      Row() {
        Button($r('app.string.web_back')).buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => { this.back(); })
        Blank()
        Button($r('app.string.web_refresh')).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.loading)
          .onClick((): void => { this.load(); })
      }.width('100%')
      if (this.loading) { LoadingProgress().width(32).height(32) }
      if (this.model.errorText.length > 0) { WorkbenchNotice({ text: this.model.errorText, warning: true }) }
      Stack() {
        if (this.model.active) {
          ForEach(this.windows, (item: OfficialWebWindow): void => { this.webPane(item) }, (item: OfficialWebWindow): string => item.id.toString())
        }
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%')
  }
}
