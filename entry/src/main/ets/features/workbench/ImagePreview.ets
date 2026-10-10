import { image } from '@kit.ImageKit';
import { uiMaterial } from '@kit.ArkUI';
import { HdsActionBar, ActionBarButton } from '@kit.UIDesignKit';
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
  @Local exifSelected: boolean = false;
  private material: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THICK });
  private materialAvailable: boolean = uiMaterial.isImmersiveMaterialSupported();

  private resetView(): void { this.scaleValue = 1; this.offsetX = 0; this.offsetY = 0; }

  private action(icon: Resource, label: Resource, enabled: boolean, callback: () => void): ActionBarButton {
    return new ActionBarButton({ baseIcon: icon, enabled, accessibilityText: label, onClick: callback });
  }

  private startActions(): ActionBarButton[] {
    if (this.photos) {
      return [this.action($r('sys.symbol.share'), $r('app.string.preview_share'), this.canShare, this.onShare),
        this.action(this.favorite ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
          this.favorite ? $r('app.string.preview_unfavorite') : $r('app.string.preview_favorite'), this.canFavorite, this.onFavorite)];
    }
    return [this.action($r('sys.symbol.arrow_down_circle'), $r('app.string.preview_download'), this.canDownload, this.onDownload),
      this.action($r('sys.symbol.trash'), $r('app.string.preview_delete'), this.canDelete, this.onDelete)];
  }

  private endActions(): ActionBarButton[] {
    const information = this.action($r('sys.symbol.info_circle'), $r('app.string.preview_information'), true,
      (): void => { this.infoVisible = true; });
    if (this.photos) { return [information, this.action($r('sys.symbol.trash'), $r('app.string.preview_delete'), this.canDelete, this.onDelete)]; }
    return [this.action($r('sys.symbol.share'), $r('app.string.preview_share'), this.canShare, this.onShare), information];
  }

  @Builder
  details() {
    Column() {
      if (this.photos) {
        Row({ space: 16 }) {
          Button($r('app.string.preview_details')).buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontColor(this.exifSelected ? $r('sys.color.font_secondary') : $r('sys.color.font_emphasize'))
            .onClick((): void => { this.exifSelected = false; })
          Button($r('app.string.preview_exif')).buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontColor(this.exifSelected ? $r('sys.color.font_emphasize') : $r('sys.color.font_secondary'))
            .onClick((): void => { this.exifSelected = true; })
        }.width('100%').padding({ left: 8, right: 8 })
      }
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.photos && this.exifSelected ? this.exif : this.information, (row: PreviewInformation): void => {
            WorkbenchInfoRow({ label: row.label, value: row.value, labelWidth: 88, valueAlign: TextAlign.Start })
          })
          if (this.photos && this.exifSelected && this.exif.length === 0) {
            Text($r('app.string.preview_no_exif')).fontColor($r('sys.color.font_secondary')).width('100%')
          }
        }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    }.width('100%').height('100%')
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        if (this.source !== '') {
          if (this.video && this.original && typeof this.source === 'string') {
            Video({ src: this.source }).width('100%').height('100%').autoPlay(false).controls(true)
              .onError((): void => { this.onDecodeError(); })
          } else {
            Image(this.source).width('100%').height('100%').objectFit(ImageFit.Contain)
              .sourceSize({ width: Math.max(640, Math.min(2880, this.viewWidth * this.scaleValue * 2)),
                height: Math.max(640, Math.min(2880, this.viewHeight * this.scaleValue * 2)) })
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
            }),
          TapGesture({ count: 2 }).onAction((): void => { this.resetView(); this.onRefine(1); })
        ))
      WorkbenchNotice({ text: this.errorText, warning: true })
      HdsActionBar({ startButtons: this.startActions(), endButtons: this.endActions() })
        .margin({ left: 16, right: 16, bottom: 12 })
    }.width('100%').height('100%').backgroundColor($r('app.color.workbench_background'))
      .bindSheet($$this.infoVisible, this.details(), { height: SheetSize.MEDIUM, detents: [SheetSize.MEDIUM, SheetSize.LARGE],
        title: { title: $r('app.string.preview_information') }, showClose: true,
        backgroundColor: this.materialAvailable ? Color.Transparent : $r('app.color.workbench_surface'), systemMaterial: this.material })
  }
}
