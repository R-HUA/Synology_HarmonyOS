import { image } from '@kit.ImageKit';
import { ColorMetrics, LengthMetrics, uiMaterial } from '@kit.ArkUI';
import { HdsActionBar, ActionBarButton, ActionBarStyle } from '@kit.UIDesignKit';
import { WorkbenchInfoRow, WorkbenchNotice } from './WorkbenchUi';

export interface PreviewInformation { label: ResourceStr; value: ResourceStr; }

/** 三个套件共用手势与工具栏，操作回调仍由各套件处理。 */
@ComponentV2
export struct ImagePreview {
  @Param source: string | image.PixelMap = '';
  @Param name: string = '';
  @Param busy: boolean = false;
  @Param original: boolean = false;
  @Param canDownload: boolean = true;
  @Param video: boolean = false;
  @Param photos: boolean = false;
  @Param itemKey: string = '';
  @Param canNavigate: boolean = true;
  @Param favorite: boolean = false;
  @Param canFavorite: boolean = false;
  @Param canDelete: boolean = false;
  @Param canShare: boolean = false;
  @Param information: PreviewInformation[] = [];
  @Param exif: PreviewInformation[] = [];
  @Param errorText: string = '';
  @Event onDownload: () => void = (): void => {};
  @Event onDelete: () => void = (): void => {};
  @Event onShare: () => void = (): void => {};
  @Event onFavorite: () => void = (): void => {};
  @Event onNavigate: (direction: number) => void = (_direction: number): void => {};
  @Event onDecodeError: () => void = (): void => {};
  @Event onViewport: (width: number, height: number) => void = (): void => {};
  @Event onRefine: (scale: number) => void = (): void => {};
  @Local scaleValue: number = 1;
  @Local initialScale: number = 1;
  @Local offsetX: number = 0;
  @Local offsetY: number = 0;
  @Local initialX: number = 0;
  @Local initialY: number = 0;
  @Local viewWidth: number = 0;
  @Local viewHeight: number = 0;
  @Local infoVisible: boolean = false;
  private material: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THICK });
  private toolbarMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN, colorInvert: true, interactive: true });
  private materialAvailable: boolean = uiMaterial.isImmersiveMaterialSupported();
  @Local private shareButton: ActionBarButton = this.photoButton($r('sys.symbol.share'), $r('app.string.preview_share'),
    (): void => { this.onShare(); });
  @Local private favoriteButton: ActionBarButton = this.photoButton($r('sys.symbol.heart'), $r('app.string.preview_favorite'),
    (): void => { this.onFavorite(); });
  @Local private informationButton: ActionBarButton = this.photoButton($r('sys.symbol.info_circle'), $r('app.string.preview_information'),
    (): void => { this.infoVisible = true; });
  @Local private deleteButton: ActionBarButton = this.photoButton($r('sys.symbol.trash'), $r('app.string.preview_delete'),
    (): void => { this.onDelete(); });

  aboutToAppear(): void { this.updatePhotoButtons(); }

  @Monitor('canShare', 'canFavorite', 'canDelete', 'favorite')
  private updatePhotoButtons(): void {
    // 原生操作栏持续观察同一按钮对象，异步读取状态后才能同步启用和图标。
    this.shareButton.enabled = this.canShare;
    this.favoriteButton.enabled = this.canFavorite;
    this.favoriteButton.baseIcon = this.favorite ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart');
    this.favoriteButton.accessibilityText = this.favorite ? $r('app.string.preview_unfavorite') : $r('app.string.preview_favorite');
    this.favoriteButton.hoverTips = this.favoriteButton.accessibilityText;
    this.deleteButton.enabled = this.canDelete;
  }

  private photoButton(icon: Resource, label: Resource, callback: () => void): ActionBarButton {
    return new ActionBarButton({ baseIcon: icon, accessibilityText: label, hoverTips: label, onClick: callback,
      width: LengthMetrics.vp(40), iconSize: LengthMetrics.vp(24),
      backgroundColor: ColorMetrics.rgba(0, 0, 0, 0), shadowStyle: { radius: 0, color: Color.Transparent } });
  }

  @Monitor('itemKey')
  private resetPhotoView(): void {
    this.resetView();
    this.infoVisible = false;
  }

  private resetView(): void { this.scaleValue = 1; this.offsetX = 0; this.offsetY = 0; }

  private action(icon: Resource, label: Resource, enabled: boolean, callback: () => void): ActionBarButton {
    return new ActionBarButton({ baseIcon: icon, enabled, accessibilityText: label, hoverTips: label, onClick: callback });
  }

  private startActions(): ActionBarButton[] {
    return [this.action($r('sys.symbol.arrow_down_circle'), $r('app.string.preview_download'), this.canDownload, this.onDownload),
      this.action($r('sys.symbol.trash'), $r('app.string.preview_delete'), this.canDelete, this.onDelete)];
  }

  private endActions(): ActionBarButton[] {
    const information = this.action($r('sys.symbol.info_circle'), $r('app.string.preview_information'), true,
      (): void => { this.infoVisible = true; });
    return [this.action($r('sys.symbol.share'), $r('app.string.preview_share'), this.canShare, this.onShare), information];
  }

  @Builder
  details() {
    Scroll() {
      Column({ space: 16 }) {
        ForEach(this.information, (row: PreviewInformation): void => {
          WorkbenchInfoRow({ label: row.label, value: row.value, labelWidth: 72, valueAlign: TextAlign.Start })
        })
        if (this.photos && this.exif.length > 0) {
          Divider().color($r('sys.color.comp_divider'))
          Text($r('app.string.preview_exif')).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary')).width('100%')
          ForEach(this.exif, (row: PreviewInformation): void => {
            WorkbenchInfoRow({ label: row.label, value: row.value, labelWidth: 72, valueAlign: TextAlign.Start })
          })
        }
      }.width('100%').padding({ left: 24, right: 24, top: 12, bottom: 24 }).alignItems(HorizontalAlign.Start)
    }.width('100%').constraintSize({ maxHeight: this.viewHeight * 0.8 }).scrollBar(BarState.Auto)
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
  }

  @Builder
  content() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        if (this.source !== '') {
          if (this.video && this.original && typeof this.source === 'string') {
            Video({ src: this.source }).width('100%').height('100%').autoPlay(false).controls(true)
              .onError((): void => { this.onDecodeError(); })
          } else {
            Image(this.source).width('100%').height('100%').objectFit(ImageFit.Contain)
              .syncLoad(!this.original)
              .scale({ x: this.scaleValue, y: this.scaleValue }).translate({ x: this.offsetX, y: this.offsetY })
              .accessibilityText(this.name).onError((): void => { this.onDecodeError(); })
          }
        }
        if (this.busy) { LoadingProgress().width(32).height(32).align(Alignment.Center).hitTestBehavior(HitTestMode.None) }
        else if (this.source === '' && this.errorText.length === 0) {
          Text($r('app.string.preview_unavailable')).fontColor($r('sys.color.font_secondary'))
        }
      }.width('100%').layoutWeight(1).clip(true)
        .onAreaChange((_oldArea: Area, area: Area): void => {
          this.viewWidth = Number(area.width); this.viewHeight = Number(area.height);
          this.onViewport(this.viewWidth, this.viewHeight);
        })
        .gesture(GestureGroup(GestureMode.Parallel,
          PinchGesture().onActionStart((): void => { this.initialScale = this.scaleValue; })
            .onActionUpdate((event: GestureEvent): void => { this.scaleValue = Math.min(4, Math.max(1, this.initialScale * event.scale)); })
            .onActionEnd((): void => { this.onRefine(this.scaleValue); if (this.scaleValue === 1) { this.resetView(); } }),
          PanGesture().onActionStart((): void => { this.initialX = this.offsetX; this.initialY = this.offsetY; })
            .onActionUpdate((event: GestureEvent): void => {
              if (this.scaleValue > 1) {
                const limitX = this.viewWidth * (this.scaleValue - 1) / 2, limitY = this.viewHeight * (this.scaleValue - 1) / 2;
                this.offsetX = Math.min(limitX, Math.max(-limitX, this.initialX + event.offsetX));
                this.offsetY = Math.min(limitY, Math.max(-limitY, this.initialY + event.offsetY));
              }
            })
            .onActionEnd((event: GestureEvent): void => {
              // 缩放后的拖动只移动图片，原始比例下的横向滑动才切换照片。
              if (this.photos && this.canNavigate && this.scaleValue === 1 &&
                Math.abs(event.offsetX) >= 48 && Math.abs(event.offsetX) > Math.abs(event.offsetY) * 1.5) {
                this.onNavigate(event.offsetX < 0 ? 1 : -1);
              }
            }),
          TapGesture({ count: 2 }).onAction((): void => { this.resetView(); this.onRefine(1); })
        ))
      WorkbenchNotice({ text: this.errorText, warning: true })
      if (!this.photos) { this.actionBar() }
    }.width('100%').height('100%')
  }

  @Builder
  actionBar() {
    HdsActionBar({ startButtons: this.startActions(), endButtons: this.endActions() })
      .margin({ left: 16, right: 16, bottom: 12 })
  }

  @Builder
  photoActionBar() {
    Row() {
      HdsActionBar({ startButtons: [this.shareButton, this.favoriteButton, this.informationButton, this.deleteButton],
        actionBarStyle: new ActionBarStyle({ height: LengthMetrics.vp(56), margin: LengthMetrics.vp(0) }) })
    }.borderRadius(28)
      .systemMaterial(this.toolbarMaterial)
      .margin({ bottom: 16 })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.content()
      if (this.photos) { this.photoActionBar() }
    }.width('100%').height('100%').backgroundColor($r('app.color.workbench_background'))
      .bindSheet($$this.infoVisible, this.details(), { height: SheetSize.FIT_CONTENT,
        title: { title: $r('app.string.preview_information') }, showClose: true,
        backgroundColor: this.materialAvailable ? Color.Transparent : $r('app.color.workbench_surface'), systemMaterial: this.material })
  }
}
