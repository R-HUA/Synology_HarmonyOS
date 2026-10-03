export class WorkbenchMetrics {
  static readonly pageMargin: number = 16;
  /** 半模态内容与标题栏共用的水平边距，保证标题左边缘与卡片左边缘对齐。 */
  static readonly sheetMargin: number = 24;
  /** 系统为半模态自定义标题栏（title 传 CustomBuilder）预留的左右内衬。实测 16vp。 */
  static readonly sheetTitleInset: number = 16;
  /** HDS 半模态标题栏高度（实测 63.7vp），内容区按它再加常规上边距让位。 */
  static readonly sheetTitleBarHeight: number = 64;
  static readonly sectionGap: number = 12;
  static readonly itemGap: number = 12;
  static readonly cardRadius: number = 16;
  static readonly innerRadius: number = 12;
  static readonly touchSize: number = 48;
  static readonly rowMinHeight: number = 56;
  static readonly chipHeight: number = 40;
  /** 信息行行高（左标签 + 右取值），与官方设置列表的单行条目一致。 */
  static readonly infoRowHeight: number = 48;
  /** 信息卡片的上下内边距，避免首末行紧贴卡片边缘。 */
  static readonly infoCardPadding: number = 8;
}

/** 统一图标容器：固定尺寸 + 居中，避免图标在底板中偏移。 */
@ComponentV2
export struct WorkbenchIconTile {
  @Param icon: Resource = $r('sys.symbol.folder');
  @Param iconSize: number = 22;
  @Param tileSize: number = 40;
  @Param iconColor: ResourceColor = $r('sys.color.icon_emphasize');
  @Param tileRadius: number = 12;
  @Param tileColor: ResourceColor = $r('app.color.workbench_subtle');

  build() {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(this.icon).fontSize(this.iconSize).fontColor([this.iconColor])
    }
    .width(this.tileSize).height(this.tileSize)
    .borderRadius(this.tileRadius).backgroundColor(this.tileColor)
  }
}

@ComponentV2
export struct WorkbenchSectionTitle {
  @Param title: string = '';
  @Param subtitle: string = '';

  build() {
    Column({ space: 2 }) {
      Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
      if (this.subtitle.length > 0) {
        Text(this.subtitle).fontSize(12).fontColor($r('sys.color.font_secondary'))
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
export struct WorkbenchInfoRow {
  @Param label: string = '';
  @Param value: string = '';
  @Param minHeight: number = WorkbenchMetrics.infoRowHeight;
  /** 取值默认可长按复制；放进「整卡可点」的卡片时要关掉，否则这份文本会吞掉点击、卡片点不开。 */
  @Param copyable: boolean = true;

  build() {
    // 用 Row + layoutWeight 取代带换行的 Flex：FlexWrap.Wrap 下单行内容会贴行首（顶部），
    // 中文看起来“靠上”且行间留白不均；Row 的 VerticalAlign.Center 才能保证文字垂直居中。
    Row() {
      Text(this.label).fontSize(14).fontColor($r('sys.color.font_secondary'))
        .margin({ right: 16 }).flexShrink(0)
      Text(this.value).fontSize(16).fontColor($r('sys.color.font_primary')).textAlign(TextAlign.End)
        .layoutWeight(1).copyOption(this.copyable ? CopyOptions.InApp : CopyOptions.None)
    }.width('100%').constraintSize({ minHeight: this.minHeight })
      .alignItems(VerticalAlign.Center)
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
        .width('100%').padding(12).borderRadius(WorkbenchMetrics.innerRadius)
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
    Button(this.label).type(ButtonType.Capsule).constraintSize({ minHeight: WorkbenchMetrics.chipHeight })
      .fontSize(14).fontWeight(this.selected ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.selected ? $r('sys.color.font_emphasize') : $r('sys.color.font_secondary'))
      .backgroundColor(this.selected ? $r('app.color.workbench_accent_surface') : $r('app.color.workbench_subtle'))
      .padding({ left: 14, right: 14, top: 6, bottom: 6 }).margin({ right: 8, bottom: 8 }).enabled(this.available).onClick(this.onSelect)
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
        WorkbenchIconTile({ icon: this.icon, iconSize: 22, tileSize: 40,
          iconColor: this.destructive ? $r('app.color.workbench_danger') : $r('sys.color.icon_emphasize'),
          tileColor: $r('app.color.workbench_subtle') })
        Column({ space: 2 }) {
          Text(this.label).fontSize(16)
            .fontColor(this.destructive ? $r('app.color.workbench_danger') : $r('sys.color.font_primary'))
          if (this.description.length > 0) {
            Text(this.description).fontSize(14).fontColor($r('sys.color.font_secondary'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.arrow_right')).fontSize(12).fontColor([$r('sys.color.font_tertiary')])
      }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 })
    }.type(ButtonType.Normal).width('100%').constraintSize({ minHeight: WorkbenchMetrics.rowMinHeight })
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
    Column({ space: 6 }) {
      Text(this.label).fontSize(14).fontColor($r('sys.color.font_secondary'))
      Text(this.value).fontSize(24).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
      if (this.percentage !== undefined) {
        Progress({ value: this.percentage, total: 100, type: ProgressType.Linear }).width('100%').height(4)
          .color($r('sys.color.icon_emphasize')).backgroundColor($r('app.color.workbench_divider'))
          .accessibilityText(this.label + '，' + this.value)
      }
    }.width('100%').padding(12).borderRadius(WorkbenchMetrics.innerRadius)
      .backgroundColor($r('app.color.workbench_subtle')).alignItems(HorizontalAlign.Start)
  }
}
