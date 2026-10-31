import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { WorkbenchEmptyState, WorkbenchIconTile, WorkbenchInfoRow, WorkbenchMetrics } from '../workbench/WorkbenchUi';
import { filterPackages, InstalledPackage, packageNativeTarget, PackageNativeTarget, PackageState } from './PackageProtocol';
import { PackageCatalogModel } from './PackageCatalogModel';

function packageName(item: InstalledPackage): ResourceStr {
  return item.name.length > 0 ? item.name : $r('app.string.package_unnamed');
}

function packageVersion(item: InstalledPackage): ResourceStr {
  return item.version.length > 0 ? item.version : $r('app.string.package_version_unknown');
}

function packageState(state: PackageState): ResourceStr {
  switch (state) {
    case 'running': return $r('app.string.package_running');
    case 'stopped': return $r('app.string.package_stopped');
    default: return $r('app.string.package_state_unknown');
  }
}

function packageIcon(item: InstalledPackage): Resource {
  switch (packageNativeTarget(item.id)) {
    case 'files':
    case 'drive': return $r('sys.symbol.folder');
    case 'photos': return $r('sys.symbol.picture');
    case 'downloads': return $r('sys.symbol.arrow_down_circle');
    default: return $r('sys.symbol.square_grid_2x2');
  }
}

function packageReadFailure(error: Error | undefined): ResourceStr {
  if (error instanceof NasFailure) {
    switch (error.kind) {
      case NasErrorKind.Permission:
      case NasErrorKind.Credentials: return $r('app.string.package_unauthorized');
      case NasErrorKind.SessionExpired: return $r('app.string.package_session_expired');
      case NasErrorKind.Unsupported: return $r('app.string.package_unsupported');
      case NasErrorKind.Network:
      case NasErrorKind.Tls:
      case NasErrorKind.Http: return $r('app.string.package_unreachable');
      case NasErrorKind.Protocol: return $r('app.string.package_invalid_response');
      default:
        if (error.code > 0) { return $r('app.string.package_server_failure', error.code); }
    }
  }
  return $r('app.string.package_read_failed');
}

@ComponentV2
struct PackageCatalogRow {
  @Require @Param item: InstalledPackage = { id: '', name: '', version: '', state: 'unknown', checkedAt: 0 };
  @Event onDetail: (item: InstalledPackage) => void = (): void => {};

  build() {
    Button() {
      Row({ space: 12 }) {
        WorkbenchIconTile({ icon: packageIcon(this.item) })
        Column({ space: 4 }) {
          Text(packageName(this.item)).fontSize(16).fontColor($r('sys.color.font_primary'))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(packageVersion(this.item)).fontSize(14).fontColor($r('sys.color.font_secondary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (packageNativeTarget(this.item.id) !== undefined) {
            Text($r('app.string.package_native_support')).fontSize(12).fontColor($r('sys.color.font_emphasize'))
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(packageState(this.item.state)).fontSize(14).fontColor($r('sys.color.font_secondary')).flexShrink(0)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([$r('sys.color.icon_secondary')])
          .accessibilityLevel('no')
      }.width('100%').padding(16)
    }.type(ButtonType.Normal).width('100%').backgroundColor($r('app.color.workbench_surface'))
      .borderRadius(WorkbenchMetrics.cardRadius).onClick((): void => { this.onDetail(this.item); })
  }
}

@ComponentV2
export struct PackageCatalogPage {
  @Param model: PackageCatalogModel = new PackageCatalogModel();
  @Param scroller: Scroller = new Scroller();
  @Param bottomInset: number = 16;
  @Event onDetail: (item: InstalledPackage) => void = (): void => {};

  private items(): InstalledPackage[] { return filterPackages(this.model.items, this.model.query, this.model.supportedOnly); }

  build() {
    Row() {
      List({ scroller: this.scroller, space: 12 }) {
        ListItem() {
          Column({ space: 12 }) {
            Search({ value: this.model.query, placeholder: $r('app.string.package_search') })
              .defaultFocus(false)
              .onChange((value: string): void => { this.model.query = value; })
            Row({ space: 8 }) {
              Button($r('app.string.package_all')).buttonStyle(this.model.supportedOnly ? ButtonStyleMode.NORMAL : ButtonStyleMode.EMPHASIZED)
                .onClick((): void => { this.model.supportedOnly = false; })
              Button($r('app.string.package_native_support')).buttonStyle(this.model.supportedOnly ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
                .onClick((): void => { this.model.supportedOnly = true; })
              Blank()
              Button() { SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(20).fontColor([$r('sys.color.icon_secondary')]) }
                .width(48).height(48).backgroundColor(Color.Transparent).enabled(!this.model.loading)
                .accessibilityText($r('app.string.task_refresh')).onClick((): void => { this.model.refresh(); })
            }.width('100%')
            if (this.model.loading) {
              Row({ space: 8 }) {
                LoadingProgress().width(24).height(24)
                Text($r('app.string.package_loading')).fontSize(14).fontColor($r('sys.color.font_secondary'))
              }.width('100%')
            }
            if (this.model.loaded) {
              Text($r('app.string.package_checked_at', new Date(this.model.checkedAt).toLocaleString()))
                .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
            }
            if (this.model.loaded && this.model.error !== undefined) {
              Text(packageReadFailure(this.model.error)).fontSize(14).fontColor($r('app.color.workbench_danger')).width('100%')
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
        if (!this.model.loaded && this.model.error !== undefined) {
          ListItem() {
            WorkbenchEmptyState({ icon: $r('sys.symbol.exclamationmark_circle'), title: $r('app.string.package_read_failed'),
              description: packageReadFailure(this.model.error), actionLabel: $r('app.string.task_retry'), actionAvailable: !this.model.loading,
              onAction: (): void => { this.model.refresh(); } })
          }
        } else if (this.model.loaded && this.model.items.length === 0) {
          ListItem() { WorkbenchEmptyState({ title: $r('app.string.package_empty'), icon: $r('sys.symbol.square_grid_2x2') }) }
        } else if (this.model.loaded && this.items().length === 0) {
          ListItem() { WorkbenchEmptyState({ title: $r('app.string.package_no_matches'), icon: $r('sys.symbol.magnifyingglass') }) }
        } else {
          ForEach(this.items(), (item: InstalledPackage): void => {
            ListItem() { PackageCatalogRow({ item: this.model.items.find((entry: InstalledPackage): boolean => entry.id === item.id)!, onDetail: this.onDetail }) }
          }, (item: InstalledPackage): string => item.id)
        }
      }.width('100%').constraintSize({ maxWidth: 960 }).height('100%')
        .padding({ top: 12, left: 16, right: 16, bottom: this.bottomInset }).clip(true)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}

@ComponentV2
export struct PackageDetailPage {
  @Param model: PackageCatalogModel = new PackageCatalogModel();
  @Param scroller: Scroller = new Scroller();
  @Param bottomInset: number = 16;
  @Event onNative: (target: PackageNativeTarget) => void = (): void => {};
  @Event onManagement: () => void = (): void => {};

  private openNative(): void {
    const item = this.model.selected;
    const target = item === undefined ? undefined : packageNativeTarget(item.id);
    if (target !== undefined) { this.onNative(target); }
  }

  @Builder
  detail() {
    Column({ space: 16 }) {
      WorkbenchIconTile({ icon: packageIcon(this.model.selected!), tileSize: 64, iconSize: 32 })
      Text(packageName(this.model.selected!)).fontSize(24).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
        .textAlign(TextAlign.Center).width('100%')
      Column() {
        WorkbenchInfoRow({ label: $r('app.string.package_version'), value: packageVersion(this.model.selected!) })
        WorkbenchInfoRow({ label: $r('app.string.package_state'), value: packageState(this.model.selected!.state) })
        WorkbenchInfoRow({ label: $r('app.string.package_support'), value: packageNativeTarget(this.model.selected!.id) === undefined ?
          $r('app.string.package_browser_support') : $r('app.string.package_native_support') })
      }.width('100%').padding(16).borderRadius(16).backgroundColor($r('app.color.workbench_surface'))
      Text($r('app.string.package_checked_at', new Date(this.model.selected!.checkedAt).toLocaleString()))
        .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      if (this.model.detailError !== undefined) {
        Text(packageReadFailure(this.model.detailError)).fontSize(14).fontColor($r('app.color.workbench_danger')).width('100%')
      }
      if (this.model.detailLoading) { LoadingProgress().width(32).height(32) }
      Button($r('app.string.task_refresh')).buttonStyle(ButtonStyleMode.NORMAL).enabled(!this.model.detailLoading)
        .onClick((): void => { this.model.refreshDetail(); })
      if (packageNativeTarget(this.model.selected!.id) !== undefined) {
        Button($r('app.string.package_open_native')).width('100%').constraintSize({ minHeight: 48 })
          .onClick((): void => { this.openNative(); })
      }
      Button($r('app.string.package_open_management')).buttonStyle(ButtonStyleMode.NORMAL).width('100%')
        .constraintSize({ minHeight: 48 }).onClick(this.onManagement)
    }.width('100%').constraintSize({ maxWidth: 960 })
      .padding({ top: 24, left: 16, right: 16, bottom: this.bottomInset })
  }

  build() {
    Scroll(this.scroller) {
      if (this.model.selected !== undefined) { this.detail() }
    }.width('100%').height('100%').align(Alignment.Top)
  }
}
