import { AutomaticPhotoBackup } from './AutomaticPhotoBackup';
import { PhotoBackupLayout, PhotoBackupMode } from '../../core/domain/PhotoBackupPolicy';
import { WorkbenchIconTile, WorkbenchMetrics, WorkbenchNotice } from '../workbench/WorkbenchUi';

interface BackupChoiceOptions {
  label: Resource; selected: boolean; action: () => void; detail?: ResourceStr; group?: string; showChevron?: boolean;
}
interface BackupToggleOptions {
  label: Resource; selected: boolean; action: (enabled: boolean) => void;
}

@ComponentV2
export struct PhotoBackupSettingsPage {
  @Require @Param backup: AutomaticPhotoBackup;
  @Event onChooseDirectory: () => void = (): void => {};

  @Builder
  rowDivider() {
    Divider().color($r('app.color.workbench_divider')).margin({ left: 16, right: 16 })
  }

  @Builder
  choice($$: BackupChoiceOptions) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text($$.label).fontSize(16).fontColor($r('sys.color.font_primary'))
        if ($$.detail !== undefined && $$.detail !== '') { Text($$.detail).fontSize(14).fontColor($r('sys.color.font_secondary')) }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Row({ space: 6 }) {
        Radio({ value: $$.label.id.toString(), group: $$.group ?? 'location' }).checked($$.selected).hitTestBehavior(HitTestMode.None)
        if ($$.showChevron) {
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(WorkbenchMetrics.rowArrowSize)
            .fontColor([$r('sys.color.font_secondary')]).opacity(WorkbenchMetrics.rowArrowOpacity)
            .accessibilityLevel('no')
        }
      }.alignItems(VerticalAlign.Center)
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .enabled(this.backup.ready && !this.backup.busy).onClick((): void => { $$.action(); })
      .accessibilityText($$.label).accessibilitySelected($$.selected)
      .accessibilityDescription($$.selected ? this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.photos_selected').id) : '')
  }

  @Builder
  toggle($$: BackupToggleOptions) {
    Row({ space: 12 }) {
      Text($$.label).fontSize(16).fontColor($r('sys.color.font_primary')).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: $$.selected }).onChange((enabled: boolean): void => { $$.action(enabled); })
        .enabled(this.backup.ready && !this.backup.busy).accessibilityText($$.label)
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }

  @Builder
  mode(mode: PhotoBackupMode, label: Resource) {
    this.choice({ label, selected: this.backup.settings.mode === mode, action: (): void => { this.backup.configure(mode); }, group: 'mode' })
  }

  @Builder
  layout(layout: PhotoBackupLayout, label: Resource, detail: ResourceStr = '') {
    this.choice({ label, selected: this.backup.settings.layout === layout, action: (): void => {
      this.backup.configure(this.backup.settings.mode, this.backup.settings.custom, this.backup.settings.directory, layout);
    }, detail, group: 'layout' })
  }

  @Builder
  heading(label: Resource) {
    Text(label).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary')).width('100%')
  }

  @Builder
  statusDashboardCard() {
    Column() {
      this.toggle({ label: $r('app.string.photos_album_backup'), selected: this.backup.settings.enabled,
        action: (enabled: boolean): void => { this.backup.setEnabled(enabled); } })
      this.rowDivider()
      Row({ space: 12 }) {
        WorkbenchIconTile({
          icon: this.backup.settings.enabled ? $r('sys.symbol.arrow_up_circle') : $r('sys.symbol.pause_circle'),
          iconSize: 20, tileSize: 36, tileRadius: 10,
          iconColor: this.backup.settings.enabled ? $r('sys.color.icon_emphasize') : $r('sys.color.icon_secondary'),
          tileColor: this.backup.settings.enabled ? $r('app.color.workbench_accent_surface') : $r('app.color.workbench_subtle')
        })
        Column({ space: 2 }) {
          Text(this.backup.status.length > 0 ? this.backup.status :
            this.backup.settings.enabled ? '自动备份已开启' : '自动备份未开启')
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
          Text(this.backup.settings.enabled ? $r('app.string.backup_pending', this.backup.pendingCount) :
            $r('app.string.backup_enable_hint'))
            .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
          if (this.backup.lastSuccessAt > 0) {
            Text($r('app.string.backup_last_success', new Date(this.backup.lastSuccessAt).toLocaleString()))
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 12 })
    }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
  }

  build() {
    Column({ space: WorkbenchMetrics.sectionGap }) {
      this.statusDashboardCard()
      WorkbenchNotice({ text: this.backup.errorText, warning: true })
      Column({ space: WorkbenchMetrics.sectionGap }) {
      this.heading($r('app.string.photos_backup_mode'))
      Column() {
        this.mode('continue', $r('app.string.photos_backup_continue'))
        this.rowDivider()
        this.mode('new', $r('app.string.photos_backup_new'))
        this.rowDivider()
        this.mode('all', $r('app.string.photos_backup_all'))
      }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
      this.heading($r('app.string.photos_backup_location'))
      Column() {
        this.choice({ label: $r('app.string.photos_backup_default'), selected: !this.backup.settings.custom, action: (): void => {
          this.backup.configure(this.backup.settings.mode, false);
        }, detail: 'MobileBackup/' + this.backup.phoneModel })
        this.rowDivider()
        this.choice({ label: $r('app.string.photos_backup_custom'), selected: this.backup.settings.custom,
          showChevron: true, action: (): void => { this.onChooseDirectory(); },
          detail: this.backup.settings.directory.length > 0 ? this.backup.settings.directory : '点击选择 NAS 相册文件夹' })
        if (this.backup.settings.custom && this.backup.settings.directory.length > 0) {
          Button($r('app.string.backup_change_directory')).height(48).buttonStyle(ButtonStyleMode.TEXTUAL)
            .onClick((): void => { this.onChooseDirectory(); })
        }
      }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
      this.heading($r('app.string.photos_backup_layout'))
      Column() {
        this.layout('date', $r('app.string.photos_backup_date'), $r('app.string.photos_backup_date_detail'))
        this.rowDivider()
        this.layout('album', $r('app.string.photos_backup_album'))
        this.rowDivider()
        this.layout('flat', $r('app.string.photos_backup_flat'))
      }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
      this.heading($r('app.string.photos_upload_settings'))
      Column() {
        this.toggle({ label: $r('app.string.photos_backup_images'), selected: this.backup.settings.photosOnly, action: (enabled: boolean): void => {
          this.backup.configure(this.backup.settings.mode, this.backup.settings.custom, this.backup.settings.directory, this.backup.settings.layout, enabled);
        } })
        this.rowDivider()
        this.toggle({ label: $r('app.string.photos_backup_wifi'), selected: this.backup.settings.wifiOnly, action: (enabled: boolean): void => {
          this.backup.configure(this.backup.settings.mode, this.backup.settings.custom, this.backup.settings.directory, this.backup.settings.layout,
            this.backup.settings.photosOnly, enabled);
        } })
        this.rowDivider()
        this.toggle({ label: $r('app.string.photos_backup_charging'), selected: this.backup.settings.chargingOnly, action: (enabled: boolean): void => {
          this.backup.configure(this.backup.settings.mode, this.backup.settings.custom, this.backup.settings.directory, this.backup.settings.layout,
            this.backup.settings.photosOnly, this.backup.settings.wifiOnly, enabled);
        } })
      }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
      }.width('100%').enabled(this.backup.settings.enabled).opacity(this.backup.settings.enabled ? 1 : 0.45)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
