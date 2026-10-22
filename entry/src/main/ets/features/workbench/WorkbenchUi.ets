import { uiMaterial } from '@kit.ArkUI';

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
  /** 列表入口统一尾部箭头，避免各页面独立调整后产生差异。 */
  static readonly rowArrowSize: number = 18;
  static readonly rowArrowOpacity: number = 0.8;
  static readonly innerRadius: number = 12;
  static readonly touchSize: number = 48;
  static readonly rowMinHeight: number = 64;
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
  @Param label: ResourceStr = '';
  @Param value: ResourceStr = '';
  @Param labelWidth: number | undefined = undefined;
  @Param valueAlign: TextAlign = TextAlign.End;
  @Param minHeight: number = WorkbenchMetrics.infoRowHeight;
  /** 取值默认可长按复制；放进「整卡可点」的卡片时要关掉，否则这份文本会吞掉点击、卡片点不开。 */
  @Param copyable: boolean = true;

  build() {
    // 用 Row + layoutWeight 取代带换行的 Flex：FlexWrap.Wrap 下单行内容会贴行首（顶部），
    // 中文看起来“靠上”且行间留白不均；Row 的 VerticalAlign.Center 才能保证文字垂直居中。
    Row() {
      Text(this.label).fontSize(14).fontColor($r('sys.color.font_secondary'))
        .width(this.labelWidth).margin({ right: 16 }).flexShrink(0)
      Text(this.value).fontSize(16).fontColor($r('sys.color.font_primary')).textAlign(this.valueAlign)
        .wordBreak(this.labelWidth === undefined ? WordBreak.NORMAL : WordBreak.BREAK_ALL)
        .layoutWeight(1).copyOption(this.copyable ? CopyOptions.InApp : CopyOptions.None)
    }.width('100%').constraintSize({ minHeight: this.minHeight })
      .alignItems(VerticalAlign.Center)
  }
}

@ComponentV2
export struct WorkbenchNotice {
  @Param text: string = '';
  @Param warning: boolean = false;
  private shownError: string = '';

  aboutToAppear(): void { this.showError(); }

  /** 页面保留完整错误，系统提示只展示首句，避免遮挡当前操作。 */
  @Monitor('text', 'warning')
  private showError(): void {
    const text = this.text.trim();
    if (!this.warning || text.length === 0) { this.shownError = ''; return; }
    if (text === this.shownError) { return; }
    this.shownError = text;
    const sentence = text.split(/[。；\n]/)[0];
    this.getUIContext().getPromptAction().showToast({ message: sentence.length > 36 ? sentence.slice(0, 36) + '…' : sentence,
      duration: 2500, systemMaterial: new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.REGULAR }) });
  }

  build() {
    if (!this.warning && this.text.length > 0) {
      Text(this.text).fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%').padding(12).borderRadius(WorkbenchMetrics.innerRadius)
        .backgroundColor($r('app.color.workbench_subtle'))
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
  @Param showChevron: boolean = true;
  @Param compact: boolean = false;
  @Event onAction: () => void = (): void => {};

  build() {
    Button() {
      Row({ space: 12 }) {
        WorkbenchIconTile({ icon: this.icon, iconSize: this.compact ? 20 : 22, tileSize: this.compact ? 32 : 40,
          iconColor: this.destructive ? $r('app.color.workbench_danger') : $r('sys.color.icon_emphasize'),
          tileColor: $r('app.color.workbench_subtle') })
        Column({ space: 2 }) {
          Text(this.label).fontSize(16)
            .fontColor(this.destructive ? $r('app.color.workbench_danger') : $r('sys.color.font_primary'))
          if (this.description.length > 0) {
            Text(this.description).fontSize(14).fontColor($r('sys.color.font_secondary'))
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.showChevron) {
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(WorkbenchMetrics.rowArrowSize)
            .fontColor([$r('sys.color.font_secondary')]).opacity(WorkbenchMetrics.rowArrowOpacity)
            .accessibilityLevel('no')
        }
      }.width('100%').padding({ left: 16, right: 16, top: this.compact ? 6 : 10, bottom: this.compact ? 6 : 10 })
    }.type(ButtonType.Normal).width('100%').constraintSize({ minHeight: this.compact ? WorkbenchMetrics.touchSize : WorkbenchMetrics.rowMinHeight })
      .backgroundColor(Color.Transparent).enabled(this.available).onClick(this.onAction)
      .accessibilityText(this.label + (this.description.length > 0 ? '，' + this.description : ''))
  }
}

/**
 * 文件/条目列表行：图标底板 + 主标题 + 副标题。
 * 作为 @ComponentV2 + @Param 实现，数据后到时能正常刷新（@Builder 按值传参不会刷新）。
 */
@ComponentV2
export struct WorkbenchEntryRow {
  @Param title: string = '';
  @Param subtitle: string = '';
  @Param icon: Resource = $r('sys.symbol.doc');
  @Param iconColor: ResourceColor = $r('sys.color.font_secondary');
  @Param available: boolean = true;
  @Param thumbnail: string = '';
  @Param menu: MenuElement[] = [];
  @Param menuAvailable: boolean = true;
  @Param actionLabel: string = '';
  @Param actionAvailable: boolean = true;
  /** 多选行让出复选框后缩小内边距，使文字与分隔线保持同一基准。 */
  @Param contentInset: number = 16;
  @Param showDivider: boolean = true;
  @Event onOpen: () => void = (): void => {};
  @Event onAction: () => void = (): void => {};
  @Local private pressed: boolean = false;

  build() {
    Column() {
      Row() {
        Button() {
          Row({ space: 12 }) {
            if (this.thumbnail.length > 0) {
              Image(this.thumbnail).width(40).height(40).objectFit(ImageFit.Cover).borderRadius(8)
                .accessibilityLevel('no')
            } else {
              WorkbenchIconTile({ icon: this.icon, iconSize: 22, tileSize: 40, tileRadius: 12,
                iconColor: this.iconColor, tileColor: $r('app.color.workbench_subtle') })
            }
            Column({ space: 2 }) {
              Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('sys.color.font_primary')).width('100%')
              Text(this.subtitle).fontSize(14).fontColor($r('sys.color.font_secondary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%').padding({ left: this.contentInset, top: 10, bottom: 10, right: 16 })
        }.layoutWeight(1).constraintSize({ minHeight: WorkbenchMetrics.rowMinHeight })
          .type(ButtonType.Normal).padding(0).backgroundColor(Color.Transparent).stateEffect(false).enabled(this.available)
          .onClick(this.onOpen).accessibilityText(this.title)
        if (this.menu.length > 0) {
          Button() {
            SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(32)
              .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
              .fontColor([$r('sys.color.icon_primary'), Color.Transparent]).accessibilityLevel('no')
          }.width(48).constraintSize({ minHeight: WorkbenchMetrics.touchSize }).type(ButtonType.Normal).padding(0)
            .margin({ right: 8 }).backgroundColor(Color.Transparent).stateEffect(false).enabled(this.menuAvailable)
            .bindMenu(this.menu).accessibilityText(this.title + '，操作菜单')
        }
        if (this.actionLabel.length > 0) {
          Button(this.actionLabel).buttonStyle(ButtonStyleMode.TEXTUAL)
            .constraintSize({ minHeight: WorkbenchMetrics.touchSize }).margin({ right: 8 })
            .backgroundColor(Color.Transparent).stateEffect(false).enabled(this.actionAvailable)
            .onClick(this.onAction).accessibilityText(this.actionLabel + '“' + this.title + '”')
        }
      }.width('100%').backgroundColor(this.pressed ? $r('app.color.workbench_pressed') : Color.Transparent)
        // 点击仍由各按钮处理，按压底色由整行共享，避免图标与菜单区域被截断。
        .onTouch((event: TouchEvent): void => { this.pressed = event.type === TouchType.Down; })
      if (this.showDivider) {
        Divider().color($r('app.color.workbench_divider')).margin({ left: this.contentInset + 52, right: 16 })
      }
    }.width('100%').backgroundColor($r('app.color.workbench_surface'))
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
