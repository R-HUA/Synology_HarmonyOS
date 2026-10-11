import { AutomaticPhotoBackup } from './AutomaticPhotoBackup';
import { PhotoBackupLayout, PhotoBackupMode } from '../../core/domain/PhotoBackupPolicy';
import { WorkbenchMetrics, WorkbenchNotice } from '../workbench/WorkbenchUi';

interface BackupChoiceOptions {
  label: Resource; selected: boolean; action: () => void; detail?: ResourceStr; group?: string;
}
interface BackupToggleOptions {
  label: Resource; selected: boolean; action: (enabled: boolean) => void;
}

@ComponentV2
export struct PhotoBackupSettingsPage {
  @Require @Param backup: AutomaticPhotoBackup;
  @Event onChooseDirectory: () => void = (): void => {};

  @Builder
  choice($$: BackupChoiceOptions) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text($$.label).fontSize(16).fontColor($r('sys.color.font_primary'))
        if ($$.detail !== undefined && $$.detail !== '') { Text($$.detail).fontSize(14).fontColor($r('sys.color.font_secondary')) }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Radio({ value: $$.label.id.toString(), group: $$.group ?? 'location' }).checked($$.selected).hitTestBehavior(HitTestMode.None)
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .enabled(this.backup.ready && !this.backup.busy).onClick((): void => { $$.action(); })
      .accessibilityText($$.label).accessibilityDescription($$.selected ? this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.photos_selected').id) : '')
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

  build() {
    Column({ space: WorkbenchMetrics.sectionGap }) {
      Column() {
        this.toggle({ label: $r('app.string.photos_album_backup'), selected: this.backup.settings.enabled,
          action: (enabled: boolean): void => { this.backup.setEnabled(enabled); } })
      }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
      WorkbenchNotice({ text: this.backup.errorText, warning: true })
      WorkbenchNotice({ text: this.backup.status })
      this.heading($r('app.string.photos_backup_mode'))
      Column() {
        this.mode('continue', $r('app.string.photos_backup_continue'))
        this.mode('new', $r('app.string.photos_backup_new'))
        this.mode('all', $r('app.string.photos_backup_all'))
      }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
      this.heading($r('app.string.photos_backup_location'))
      Column() {
        this.choice({ label: $r('app.string.photos_backup_default'), selected: !this.backup.settings.custom, action: (): void => {
          this.backup.configure(this.backup.settings.mode, false);
        }, detail: 'MobileBackup/' + this.backup.phoneModel })
        this.choice({ label: $r('app.string.photos_backup_custom'), selected: this.backup.settings.custom,
          action: (): void => { this.onChooseDirectory(); }, detail: this.backup.settings.directory })
      }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
      this.heading($r('app.string.photos_backup_layout'))
      Column() {
        this.layout('date', $r('app.string.photos_backup_date'), $r('app.string.photos_backup_date_detail'))
        this.layout('album', $r('app.string.photos_backup_album'))
        this.layout('flat', $r('app.string.photos_backup_flat'))
      }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
      this.heading($r('app.string.photos_upload_settings'))
      Column() {
        this.toggle({ label: $r('app.string.photos_backup_images'), selected: this.backup.settings.photosOnly, action: (enabled: boolean): void => {
          this.backup.configure(this.backup.settings.mode, this.backup.settings.custom, this.backup.settings.directory, this.backup.settings.layout, enabled);
        } })
        this.toggle({ label: $r('app.string.photos_backup_wifi'), selected: this.backup.settings.wifiOnly, action: (enabled: boolean): void => {
          this.backup.configure(this.backup.settings.mode, this.backup.settings.custom, this.backup.settings.directory, this.backup.settings.layout,
            this.backup.settings.photosOnly, enabled);
        } })
        this.toggle({ label: $r('app.string.photos_backup_charging'), selected: this.backup.settings.chargingOnly, action: (enabled: boolean): void => {
          this.backup.configure(this.backup.settings.mode, this.backup.settings.custom, this.backup.settings.directory, this.backup.settings.layout,
            this.backup.settings.photosOnly, this.backup.settings.wifiOnly, enabled);
        } })
      }.width('100%').borderRadius(WorkbenchMetrics.cardRadius).clip(true).backgroundColor($r('app.color.workbench_surface'))
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
