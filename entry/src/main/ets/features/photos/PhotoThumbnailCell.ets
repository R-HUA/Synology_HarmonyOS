import { fileUri } from '@kit.CoreFileKit';
import { NasPhotoItem } from '../../core/domain/PhotosProtocol';
import { PhotoLibrary, PhotoThumbnailState } from './PhotoLibrary';
import { photoMediaLabel, photoTakenDate } from '../workbench/WorkbenchPresentation';

@ComponentV2
export struct PhotoThumbnailCell {
  @Require @Param item: NasPhotoItem;
  @Require @Param library: PhotoLibrary;
  @Require @Param state: PhotoThumbnailState;
  @Param available: boolean = true;
  @Local private decodedPath: string = '';
  @Event onOpen: (item: NasPhotoItem) => void = (_item: NasPhotoItem): void => {};

  @Builder
  thumbnail(path: string) {
    Image(fileUri.getUriFromPath(path)).width('100%').height('100%').objectFit(ImageFit.Cover)
      .sourceSize({ width: 320, height: 320 }).accessibilityLevel('no')
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
        .borderRadius(8).enabled(this.available).onClick((): void => { this.onOpen(this.item); })
        .accessibilityText(photoMediaLabel(this.item) + '，' + this.item.filename + '，' + photoTakenDate(this.item))
      if (this.item.mediaType !== 'photo') {
        Text(photoMediaLabel(this.item)).fontSize(12).fontColor(Color.White)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(Color.Black).opacity(0.8).borderRadius(8).margin(6).hitTestBehavior(HitTestMode.None)
      }
      if (this.state.errorText.length > 0) {
        Button('重试缩略图').fontSize(12).width('100%').constraintSize({ minHeight: 40 })
          .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(this.available && !this.state.loading)
          .onClick((): void => { this.library.retryThumbnail(this.item); })
          .accessibilityDescription(this.state.errorText)
      }
    }.width('100%').aspectRatio(1).borderRadius(8).clip(true)
  }
}
