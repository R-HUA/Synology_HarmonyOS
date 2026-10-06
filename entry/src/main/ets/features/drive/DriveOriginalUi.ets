import { DriveOriginalModel } from './DriveOriginalModel';
import { WorkbenchMetrics, WorkbenchNotice } from '../workbench/WorkbenchUi';

@ComponentV2
export struct DriveOriginalPage {
  @Param model: DriveOriginalModel = new DriveOriginalModel();
  @Local scaleValue: number = 1;
  @Local initialScale: number = 1;
  @Local offsetX: number = 0;
  @Local offsetY: number = 0;
  @Local initialX: number = 0;
  @Local initialY: number = 0;
  @Local viewWidth: number = 0;
  @Local viewHeight: number = 0;

  private resetView(): void { this.scaleValue = 1; this.offsetX = 0; this.offsetY = 0; }

  build() {
    Column({ space: 8 }) {
      if (this.model.pixels !== undefined) {
        Stack() {
          Image(this.model.pixels).width('100%').height('100%').objectFit(ImageFit.Contain)
            .scale({ x: this.scaleValue, y: this.scaleValue }).translate({ x: this.offsetX, y: this.offsetY })
            .accessibilityText(this.model.entry?.name || '原图')
        }.width('100%').layoutWeight(1).clip(true)
          .onAreaChange((oldArea: Area, area: Area): void => {
            this.viewWidth = Number(area.width); this.viewHeight = Number(area.height);
            this.model.setViewport(this.viewWidth, this.viewHeight);
          })
          .gesture(GestureGroup(GestureMode.Parallel,
            PinchGesture().onActionStart((): void => { this.initialScale = this.scaleValue; })
              .onActionUpdate((event: GestureEvent): void => { this.scaleValue = Math.min(4, Math.max(1, this.initialScale * event.scale)); })
              .onActionEnd((): void => { this.model.refine(this.scaleValue); if (this.scaleValue === 1) { this.resetView(); } }),
            PanGesture().onActionStart((): void => { this.initialX = this.offsetX; this.initialY = this.offsetY; })
              .onActionUpdate((event: GestureEvent): void => {
                if (this.scaleValue > 1) {
                  const limitX = this.viewWidth * (this.scaleValue - 1) / 2, limitY = this.viewHeight * (this.scaleValue - 1) / 2;
                  this.offsetX = Math.min(limitX, Math.max(-limitX, this.initialX + event.offsetX));
                  this.offsetY = Math.min(limitY, Math.max(-limitY, this.initialY + event.offsetY));
                }
              }),
            TapGesture({ count: 2 }).onAction((): void => { this.resetView(); this.model.refine(1); })
          ))
        Button('还原显示').buttonStyle(ButtonStyleMode.TEXTUAL).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
          .onClick((): void => { this.resetView(); this.model.refine(1); })
        if (this.model.staticFrame) {
          Text('动态图像以静态画面显示。').fontSize(14).fontColor($r('sys.color.font_secondary'))
        }
      } else if (this.model.busy) {
        Column({ space: 8 }) {
          LoadingProgress().width(36).height(36)
          Text('正在加载原图…').fontColor($r('sys.color.font_secondary'))
          if (this.model.progress !== undefined) { Progress({ value: this.model.progress, total: 100 }).width('70%') }
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Column({ space: 8 }) {
          if (this.model.entry !== undefined) {
            Button('重新加载').onClick((): void => { const entry = this.model.entry; if (entry !== undefined) { this.resetView(); this.model.open(entry); } })
          }
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      }
      WorkbenchNotice({ text: this.model.errorText, warning: true })
    }.width('100%').height('100%').padding(12).backgroundColor($r('app.color.workbench_surface'))
  }
}
