import { image } from '@kit.ImageKit';
import { uiMaterial } from '@kit.ArkUI';
import { HdsTabs, hdsMaterial, ActionBarButton } from '@kit.UIDesignKit';
import { WorkbenchInfoRow, WorkbenchNotice } from './WorkbenchUi';

export interface PreviewInformation { label: ResourceStr; value: ResourceStr; }

/** 页签自定义内容只挂载一次，按钮组件独立观察原生操作模型的变化。 */
@ComponentV2
struct PreviewToolbarButton {
  @Param action: ActionBarButton = new ActionBarButton({});
  @Event onAction: () => void = (): void => {};

  build() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(this.action.baseIcon as Resource).fontSize(24).fontColor([$r('sys.color.font_primary')])
    }.width(48).height(48).backgroundColor(Color.Transparent)
      .systemMaterial(uiMaterial.Material.empty)
      .enabled(this.action.enabled !== false).opacity(this.action.enabled === false ? 0.4 : 1)
      .accessibilityText(this.action.accessibilityText as Resource)
      .onClick((): void => { this.onAction(); })
  }
}

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
  private materialAvailable: boolean = uiMaterial.isImmersiveMaterialSupported();
  @Local private shareAction: ActionBarButton = new ActionBarButton({ baseIcon: $r('sys.symbol.share'),
    accessibilityText: $r('app.string.preview_share') });
  @Local private favoriteAction: ActionBarButton = new ActionBarButton({ baseIcon: $r('sys.symbol.heart'),
    accessibilityText: $r('app.string.preview_favorite'), enabled: true });
  @Local private informationAction: ActionBarButton = new ActionBarButton({ baseIcon: $r('sys.symbol.info_circle'),
    accessibilityText: $r('app.string.preview_information') });
  @Local private deleteAction: ActionBarButton = new ActionBarButton({ baseIcon: $r('sys.symbol.trash'),
    accessibilityText: $r('app.string.preview_delete') });
  @Local private downloadAction: ActionBarButton = new ActionBarButton({ baseIcon: $r('sys.symbol.arrow_down_circle'),
    accessibilityText: $r('app.string.preview_download') });

  aboutToAppear(): void { this.updateActions(); }

  @Monitor('canShare', 'canDelete', 'canDownload', 'favorite')
  private updateActions(): void {
    this.shareAction.enabled = this.canShare;
    this.deleteAction.enabled = this.canDelete;
    this.downloadAction.enabled = this.canDownload;
    this.favoriteAction.baseIcon = this.favorite ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart');
    this.favoriteAction.accessibilityText = this.favorite ? $r('app.string.preview_unfavorite') : $r('app.string.preview_favorite');
  }

  @Monitor('itemKey')
  private resetPhotoView(): void {
    this.resetView();
    this.infoVisible = false;
  }

  private resetView(): void { this.scaleValue = 1; this.offsetX = 0; this.offsetY = 0; }

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
    }.width('100%').height('100%')
  }

  @Builder
  actionBar() {
    Row({ space: 8 }) {
      if (this.photos) {
        PreviewToolbarButton({ action: this.shareAction, onAction: (): void => { this.onShare(); } })
        PreviewToolbarButton({ action: this.favoriteAction, onAction: (): void => { this.onFavorite(); } })
        PreviewToolbarButton({ action: this.informationAction, onAction: (): void => { this.infoVisible = true; } })
        PreviewToolbarButton({ action: this.deleteAction, onAction: (): void => { this.onDelete(); } })
      } else {
        PreviewToolbarButton({ action: this.downloadAction, onAction: (): void => { this.onDownload(); } })
        PreviewToolbarButton({ action: this.deleteAction, onAction: (): void => { this.onDelete(); } })
        PreviewToolbarButton({ action: this.shareAction, onAction: (): void => { this.onShare(); } })
        PreviewToolbarButton({ action: this.informationAction, onAction: (): void => { this.infoVisible = true; } })
      }
    }.padding({ left: 4, right: 4 }).width(224).height(48).justifyContent(FlexAlign.Center)
  }

  build() {
    // 预览内容直接复用主页面的悬浮底栏，按钮仅执行操作，不切换内容。
    HdsTabs({ index: 0 }) {
      TabContent() { this.content() }.tabBar(this.actionBar())
    }.width('100%').height('100%').barPosition(BarPosition.End).scrollable(false)
      .barOverlap(true).vertical(false).barHeight(56)
      .barFloatingStyle({ barWidth: { smallWidth: 224, mediumWidth: 224, largeWidth: 224 }, barBottomMargin: 12,
        gradientMask: { maskColor: Color.Transparent, maskHeight: 0 },
        systemMaterialEffect: { materialType: hdsMaterial.MaterialType.ADAPTIVE, materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE },
        thermoCtrl: true })
      .backgroundColor($r('app.color.workbench_background'))
      .bindSheet($$this.infoVisible, this.details(), { height: SheetSize.FIT_CONTENT,
        title: { title: $r('app.string.preview_information') }, showClose: true,
        backgroundColor: this.materialAvailable ? Color.Transparent : $r('app.color.workbench_surface'), systemMaterial: this.material })
  }
}
