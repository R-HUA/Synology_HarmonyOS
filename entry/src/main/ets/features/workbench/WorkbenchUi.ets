export class WorkbenchMetrics {
  static readonly pageMargin: number = 16;
  static readonly sectionGap: number = 20;
  static readonly itemGap: number = 12;
  static readonly cardRadius: number = 24;
  static readonly innerRadius: number = 16;
  static readonly touchSize: number = 48;
}

@ComponentV2
export struct WorkbenchSectionTitle {
  @Param title: string = '';
  @Param subtitle: string = '';

  build() {
    Column({ space: 4 }) {
      Text(this.title).fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary'))
      if (this.subtitle.length > 0) {
        Text(this.subtitle).fontSize(13).fontColor($r('sys.color.font_secondary'))
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
export struct WorkbenchInfoRow {
  @Param label: string = '';
  @Param value: string = '';

  build() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
      Text(this.label).fontSize(14).fontColor($r('sys.color.font_secondary')).margin({ right: 16, top: 6, bottom: 6 })
      Text(this.value).fontSize(16).fontColor($r('sys.color.font_primary')).textAlign(TextAlign.End)
        .constraintSize({ maxWidth: '100%' }).margin({ top: 6, bottom: 6 }).copyOption(CopyOptions.InApp)
    }.width('100%').constraintSize({ minHeight: WorkbenchMetrics.touchSize })
  }
}

@ComponentV2
export struct WorkbenchNotice {
  @Param text: string = '';
  @Param warning: boolean = false;

  build() {
    if (this.text.length > 0) {
      Text(this.text).fontSize(14)
        .fontColor(this.warning ? $r('app.color.workbench_warning') : $r('sys.color.font_secondary'))
        .width('100%').padding(16).borderRadius(WorkbenchMetrics.innerRadius)
        .backgroundColor(this.warning ? $r('app.color.workbench_warning_surface') : $r('app.color.workbench_subtle'))
        .accessibilityText(this.text)
    }
  }
}

@ComponentV2
export struct WorkbenchChoice {
  @Param label: string = '';
  @Param selected: boolean = false;
  @Param available: boolean = true;
  @Event onSelect: () => void = (): void => {};

  build() {
    Button(this.label).type(ButtonType.Capsule).constraintSize({ minHeight: WorkbenchMetrics.touchSize })
      .fontSize(14).fontWeight(this.selected ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.selected ? $r('sys.color.font_emphasize') : $r('sys.color.font_secondary'))
      .backgroundColor(this.selected ? $r('app.color.workbench_accent_surface') : $r('app.color.workbench_subtle'))
      .padding({ left: 16, right: 16, top: 10, bottom: 10 }).margin({ right: 8, bottom: 8 }).enabled(this.available).onClick(this.onSelect)
      .accessibilityText(this.label + (this.selected ? '，已选择' : ''))
  }
}

@ComponentV2
export struct WorkbenchActionRow {
  @Param label: string = '';
  @Param description: string = '';
  @Param icon: Resource = $r('sys.symbol.folder');
  @Param available: boolean = true;
  @Param destructive: boolean = false;
  @Event onAction: () => void = (): void => {};

  build() {
    Button() {
      Row({ space: 12 }) {
        SymbolGlyph(this.icon).fontSize(22)
          .fontColor([this.destructive ? $r('app.color.workbench_danger') : $r('sys.color.icon_emphasize')])
          .width(40).height(40).borderRadius(12).backgroundColor($r('app.color.workbench_subtle'))
        Column({ space: 4 }) {
          Text(this.label).fontSize(16)
            .fontColor(this.destructive ? $r('app.color.workbench_danger') : $r('sys.color.font_primary'))
          if (this.description.length > 0) {
            Text(this.description).fontSize(13).fontColor($r('sys.color.font_secondary'))
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.arrow_right')).fontSize(12).fontColor([$r('sys.color.font_tertiary')])
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
    }.type(ButtonType.Normal).width('100%').constraintSize({ minHeight: 64 })
      .backgroundColor(Color.Transparent).enabled(this.available).onClick(this.onAction)
      .accessibilityText(this.label + (this.description.length > 0 ? '，' + this.description : ''))
  }
}

@ComponentV2
export struct WorkbenchMetric {
  @Param label: string = '';
  @Param value: string = '';
  @Param percentage: number | undefined = undefined;

  build() {
    Column({ space: 10 }) {
      Text(this.label).fontSize(14).fontColor($r('sys.color.font_secondary'))
      Text(this.value).fontSize(26).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
      if (this.percentage !== undefined) {
        Progress({ value: this.percentage, total: 100, type: ProgressType.Linear }).width('100%')
          .color($r('sys.color.icon_emphasize')).backgroundColor($r('app.color.workbench_divider'))
          .accessibilityText(this.label + '，' + this.value)
      }
    }.width('100%').padding(16).borderRadius(WorkbenchMetrics.innerRadius)
      .backgroundColor($r('app.color.workbench_subtle')).alignItems(HorizontalAlign.Start)
  }
}
