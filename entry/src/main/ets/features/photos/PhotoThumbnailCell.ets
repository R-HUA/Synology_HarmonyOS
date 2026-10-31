import { fileUri } from '@kit.CoreFileKit';
import { NasPhotoItem } from '../../core/domain/PhotosProtocol';
import { PhotoLibrary, PhotoThumbnailState } from './PhotoLibrary';
import { photoMediaLabel, photoTakenDate } from '../workbench/WorkbenchPresentation';
import { interactionFeedback } from '../../platform/InteractionFeedback';

@ComponentV2
export struct PhotoThumbnailCell {
  @Require @Param item: NasPhotoItem;
  @Require @Param library: PhotoLibrary;
  @Require @Param state: PhotoThumbnailState;
  @Param available: boolean = true;
  @Param selecting: boolean = false;
  @Param selected: boolean = false;
  @Local private decodedPath: string = '';
  @Event onOpen: (item: NasPhotoItem) => void = (_item: NasPhotoItem): void => {};

  @Builder
  thumbnail(path: string) {
    Image(fileUri.getUriFromPath(path)).width('100%').height('100%').objectFit(ImageFit.Cover)
      .accessibilityLevel('no')
      .opacity(this.decodedPath === path ? 1 : 0)
      .onComplete((): void => { this.decodedPath = path; })
      .onError((): void => { this.library.thumbnailImageError(this.item, path); })
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Button() {
        Stack() {
          if (this.state.path.length > 0) { this.thumbnail(this.state.path) }
          if (this.state.loading || this.item.thumbnail !== undefined && this.state.errorText.length === 0 &&
            (this.state.path.length === 0 || this.decodedPath !== this.state.path)) {
            LoadingProgress().width(24).height(24).color($r('sys.color.font_secondary')).accessibilityLevel('no')
          } else if (this.state.path.length === 0 && this.state.errorText.length === 0) {
            Text($r('app.string.preview_unavailable')).fontSize(12).fontColor($r('sys.color.font_tertiary'))
          }
        }.width('100%').height('100%').backgroundColor($r('app.color.workbench_subtle'))
      }.width('100%').height('100%').type(ButtonType.Normal).backgroundColor(Color.Transparent)
        .borderRadius(0).enabled(this.available).onClick((): void => { this.onOpen(this.item); })
        .gesture(LongPressGesture().onAction((): void => {
          if (!this.selecting) { interactionFeedback(); this.library.beginSelection(); this.library.toggleSelection(this.item); }
        }))
        .accessibilityText(photoMediaLabel(this.item) + '，' + this.item.filename + '，' + photoTakenDate(this.item))
      if (this.item.favorite === true || this.item.mediaType !== 'photo') {
        Row({ space: 6 }) {
          if (this.item.favorite === true) {
            Stack() {
              SymbolGlyph($r('sys.symbol.heart_fill')).fontSize(12).fontColor([$r('app.color.workbench_danger')])
            }.width(22).height(22).borderRadius(11).backgroundColor($r('app.color.workbench_media_overlay'))
          }
          Blank()
          if (this.item.mediaType === 'live') {
            SymbolGlyph($r('sys.symbol.livephoto')).fontSize(16).fontColor([Color.White])
              .padding(4).backgroundColor($r('app.color.workbench_media_overlay')).borderRadius(6).accessibilityLevel('no')
          } else if (this.item.mediaType === 'video') {
            Text(this.item.mediaType === 'video' && this.item.durationMs !== undefined ?
              Math.floor(this.item.durationMs / 60000).toString().padStart(2, '0') + ':' +
                Math.floor(this.item.durationMs / 1000 % 60).toString().padStart(2, '0') : photoMediaLabel(this.item)).fontSize(11).fontColor(Color.White)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor($r('app.color.workbench_media_overlay')).borderRadius(6)
          }
        }.width('100%').padding(6).alignItems(VerticalAlign.Center).hitTestBehavior(HitTestMode.None)
      }
      if (this.state.errorText.length > 0) {
        Button('重试缩略图').fontSize(12).width('100%').constraintSize({ minHeight: 40 })
          .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(this.available && !this.state.loading)
          .onClick((): void => { this.library.retryThumbnail(this.item); })
          .accessibilityDescription(this.state.errorText)
      }
      if (this.selecting) {
        Checkbox().select(this.selected).hitTestBehavior(HitTestMode.None)
          .position({ right: 4, top: 4 }).accessibilityLevel('no')
      }
    }.width('100%').aspectRatio(1).borderRadius(0).clip(true)
      .geometryTransition('photo-' + this.item.space.toString() + ':' + this.item.id.toString())
  }
}
