import { common, abilityAccessCtrl, bundleManager } from '@kit.AbilityKit';
import { BusinessError, deviceInfo, batteryInfo } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { dataSharePredicates } from '@kit.ArkData';
import { connection } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasConnector } from '../../core/network/NasConnector';
import { NasErrorKind, NasFailure, normalizeNasOrigin } from '../../core/domain/DsmProtocol';
import { backupAssetKey, backupDirectory, decodePhotoBackup, LocalBackupAsset, PhotoBackupSettings,
  PhotoBackupSnapshot, PhotoBackupMode, PhotoBackupLayout } from '../../core/domain/PhotoBackupPolicy';
import { sha256 } from '../../platform/SdkDigest';
import { writePrivateSnapshot } from '../../platform/SdkFileIO';
import { TransferQueue } from '../transfers/TransferQueue';
import { ensureTransferDirectory, hashTransferFile } from '../transfers/TransferQueueFiles';

/** 进程存活期间扫描；系统接管上传后，重启通过队列及成功记录恢复。 */
@ObservedV2
export class AutomaticPhotoBackup {
  @Trace settings: PhotoBackupSettings = new PhotoBackupSettings();
  @Trace ready: boolean = false;
  @Trace busy: boolean = false;
  @Trace status: string = '';
  @Trace errorText: string = '';
  @Trace completedCount: number = 0;
  readonly phoneModel: string = deviceInfo.productModel;
  private context: common.UIAbilityContext | undefined = undefined;
  private connector: NasConnector | undefined = undefined;
  private queue: TransferQueue | undefined = undefined;
  private helper: photoAccessHelper.PhotoAccessHelper | undefined = undefined;
  private scope: string = '';
  private path: string = '';
  private completed: Set<string> = new Set();
  private generation: number = 0;
  private timer: number = -1;
  private scanning: boolean = false;
  private scanRevision: number = 0;
  private checkedRevision: number = -1;
  private saveTail: Promise<void> = Promise.resolve();
  private foreground = (active: boolean): void => { if (active) { this.scan(); } };
  private changed = (_change: photoAccessHelper.ChangeData): void => { this.scan(); };

  async attach(context: common.UIAbilityContext, connector: NasConnector, queue: TransferQueue, origin: string, account: string): Promise<void> {
    this.detach();
    const ticket = this.generation;
    const scope = await sha256(new util.TextEncoder().encodeInto(JSON.stringify([normalizeNasOrigin(origin), account])));
    const directory = context.filesDir + '/photo-backup/' + scope;
    await ensureTransferDirectory(directory);
    let snapshot: PhotoBackupSnapshot = { version: 1, scope, settings: new PhotoBackupSettings(), completed: [] };
    const path = directory + '/backup.json';
    try { snapshot = decodePhotoBackup(await fileIo.readText(path), scope); }
    catch (error) { if ((error as BusinessError).code !== 13900002) { throw error as Error; } }
    if (ticket !== this.generation) { return; }
    this.context = context; this.connector = connector; this.queue = queue;
    this.scope = scope; this.path = path; this.settings = snapshot.settings;
    this.completed = new Set(snapshot.completed); this.completedCount = this.completed.size; this.ready = true;
    queue.backupCompleted = async (key: string): Promise<void> => {
      this.ensureCurrent(ticket);
      this.completed.add(key); this.completedCount = this.completed.size;
      await this.save();
      setTimeout((): void => { if (ticket === this.generation) { this.scan(false); } }, 0);
    };
    context.eventHub.on('nas-foreground-change', this.foreground);
    this.timer = setInterval((): void => { this.scan(false); }, 10000);
    this.scan();
  }

  detach(): void {
    this.generation++;
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    this.context?.eventHub.off('nas-foreground-change', this.foreground);
    if (this.helper !== undefined) {
      this.helper.unRegisterChange(photoAccessHelper.DefaultChangeUri.DEFAULT_PHOTO_URI, this.changed);
      this.helper.release().catch((error: Error): void => this.report(error));
    }
    if (this.queue !== undefined) { this.queue.backupCompleted = undefined; }
    this.helper = undefined; this.context = undefined; this.connector = undefined; this.queue = undefined;
    this.ready = false; this.settings = new PhotoBackupSettings(); this.status = ''; this.errorText = '';
    this.completed = new Set(); this.completedCount = 0; this.scanning = false; this.busy = false;
    this.scanRevision = 0; this.checkedRevision = -1;
  }

  /** 开启时申请媒体授权，拒绝或未获受限权限审批时保持关闭。 */
  async setEnabled(enabled: boolean): Promise<void> {
    if (!this.ready || this.busy) { return; }
    this.busy = true; this.errorText = '';
    const ticket = this.generation;
    try {
      if (enabled) {
        const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.context!, ['ohos.permission.READ_IMAGEVIDEO']);
        this.ensureCurrent(ticket);
        if (result.authResults[0] !== 0) { throw new NasFailure(NasErrorKind.Permission, '未获得相册读取授权，无法开启备份。'); }
      }
      await this.updateSettings(enabled, this.settings.mode, this.settings.custom, this.settings.directory, this.settings.layout,
        this.settings.photosOnly, this.settings.wifiOnly, this.settings.chargingOnly);
      this.ensureCurrent(ticket);
      await this.queue!.setBackupAllowed(enabled && await this.conditions());
    } catch (error) { if (ticket === this.generation) { this.report(error as Error); } }
    finally { if (ticket === this.generation) { this.busy = false; this.scan(); } }
  }

  async configure(mode: PhotoBackupMode = this.settings.mode, custom: boolean = this.settings.custom,
    directory: string = this.settings.directory, layout: PhotoBackupLayout = this.settings.layout,
    photosOnly: boolean = this.settings.photosOnly, wifiOnly: boolean = this.settings.wifiOnly,
    chargingOnly: boolean = this.settings.chargingOnly): Promise<void> {
    if (!this.ready || this.busy) { return; }
    this.busy = true; this.errorText = '';
    const ticket = this.generation;
    try { await this.updateSettings(this.settings.enabled, mode, custom, directory, layout, photosOnly, wifiOnly, chargingOnly); }
    catch (error) { if (ticket === this.generation) { this.report(error as Error); } }
    finally { if (ticket === this.generation) { this.busy = false; this.scan(); } }
  }

  private async updateSettings(enabled: boolean, mode: PhotoBackupMode, custom: boolean, directory: string,
    layout: PhotoBackupLayout, photosOnly: boolean, wifiOnly: boolean, chargingOnly: boolean): Promise<void> {
    const ticket = this.generation;
    const next = new PhotoBackupSettings();
    next.enabled = enabled; next.mode = mode; next.custom = custom; next.directory = directory; next.layout = layout;
    next.photosOnly = photosOnly; next.wifiOnly = wifiOnly; next.chargingOnly = chargingOnly;
    next.since = mode !== this.settings.mode ? (mode === 'new' ? Math.floor(Date.now() / 1000) : mode === 'all' ? 0 : this.settings.since) : this.settings.since;
    const previous = this.settings;
    this.settings = next;
    try { await this.save(); }
    catch (error) { if (ticket === this.generation) { this.settings = previous; } throw error as Error; }
  }

  scan(changed: boolean = true): void {
    if (changed) { this.scanRevision++; }
    if (!this.ready || this.scanning || this.busy) { return; }
    this.scanning = true;
    const ticket = this.generation;
    this.runScan(ticket).catch((error: Error): void => { if (ticket === this.generation) { this.report(error); } })
      .finally((): void => { if (ticket === this.generation) { this.scanning = false; } });
  }

  private async runScan(ticket: number): Promise<void> {
    const revision = this.scanRevision;
    const queue = this.queue!;
    const allowed = this.settings.enabled && await this.conditions();
    this.ensureCurrent(ticket);
    await queue.setBackupAllowed(allowed);
    if (!allowed) { this.checkedRevision = -1; if (!this.settings.enabled) { this.status = '备份已关闭'; } return; }
    const bundle = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    if (abilityAccessCtrl.createAtManager().verifyAccessTokenSync(bundle.appInfo.accessTokenId, 'ohos.permission.READ_IMAGEVIDEO') !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      throw new NasFailure(NasErrorKind.Permission, '相册读取授权不可用，请重新授权后备份。');
    }
    if (this.helper === undefined) {
      this.helper = photoAccessHelper.getPhotoAccessHelper(this.context!);
      this.helper.registerChange(photoAccessHelper.DefaultChangeUri.DEFAULT_PHOTO_URI, true, this.changed);
    }
    // 先固化已完成任务，再释放私有副本，不受传输历史条数上限约束。
    for (const item of queue.items.slice()) {
      if (item.backupKey !== undefined && item.state === 'completed') {
        this.completed.add(item.backupKey); await this.save(); await queue.removeRecord(item.id);
      }
    }
    this.completedCount = this.completed.size;
    if (queue.items.some((item): boolean => item.direction === 'upload' && !['completed', 'failed', 'cancelled', 'closed', 'clearing'].includes(item.state))) {
      this.status = '正在备份，传输结果可在任务中查看'; return;
    }
    // 定时器只检查传输条件，已扫描的图库在媒体变化、前台恢复或设置变化后重新读取。
    if (this.checkedRevision === revision) { return; }
    const settings = this.settings;
    this.status = '正在检查相册'; this.errorText = '';
    const origins = new Map<number, string>();
    if (settings.layout === 'album') {
      // owner_album_id 对应唯一实际目录，相册成员关系不会造成收藏或智能相册的重复副本。
      for (const type of [photoAccessHelper.AlbumType.SOURCE, photoAccessHelper.AlbumType.USER]) {
        const result = await this.helper.getAlbums(type, photoAccessHelper.AlbumSubtype.ANY);
        try {
          const albums = await result.getAllObjects();
          for (const album of albums) {
            this.ensureCurrent(ticket);
            if (album.lpath === undefined || album.lpath.length === 0) { throw new NasFailure(NasErrorKind.Protocol, '相册缺少来源目录，无法按相册备份。'); }
            origins.set(await this.helper.getAlbumIdByLpath(album.lpath), album.albumName);
          }
        } finally { result.close(); }
      }
    }
    if (await this.scanAssets(ticket, settings, origins)) { return; }
    this.checkedRevision = revision;
    const unresolved = queue.items.filter((item): boolean => item.backupKey !== undefined && ['failed', 'unknown', 'cancelled', 'closed'].includes(item.state));
    this.status = unresolved.length > 0 ? `有 ${unresolved.length} 项未完成，请在传输任务中处理` : '备份已完成';
  }

  private async scanAssets(ticket: number, settings: PhotoBackupSettings, origins: Map<number, string>): Promise<boolean> {
    let offset = 0;
    while (true) {
      this.ensureCurrent(ticket);
      if (settings !== this.settings || !settings.enabled) { return true; }
      const predicates = new dataSharePredicates.DataSharePredicates();
      if (settings.photosOnly) { predicates.equalTo(photoAccessHelper.PhotoKeys.PHOTO_TYPE, photoAccessHelper.PhotoType.IMAGE); }
      if (settings.since > 0) { predicates.greaterThanOrEqualTo(photoAccessHelper.PhotoKeys.DATE_ADDED, settings.since); }
      predicates.orderByAsc(photoAccessHelper.PhotoKeys.DATE_ADDED).limit(50, offset);
      const options: photoAccessHelper.FetchOptions = { predicates, fetchColumns: [photoAccessHelper.PhotoKeys.SIZE,
        photoAccessHelper.PhotoKeys.DATE_TAKEN, photoAccessHelper.PhotoKeys.DATE_MODIFIED, photoAccessHelper.PhotoKeys.DATE_ADDED] };
      if (settings.layout === 'album') { options.fetchColumns.push(photoAccessHelper.PhotoKeys.OWNER_ALBUM_ID); }
      const result = await this.helper!.getAssets(options);
      let count = 0;
      try {
        const assets = await result.getAllObjects(); count = assets.length;
        for (const row of assets) {
          this.ensureCurrent(ticket);
          if (settings !== this.settings || !await this.conditions()) { return true; }
          const asset: LocalBackupAsset = { uri: row.uri, name: row.displayName, bytes: Number(row.get(photoAccessHelper.PhotoKeys.SIZE)),
            takenAt: Number(row.get(photoAccessHelper.PhotoKeys.DATE_TAKEN)), modifiedAt: Number(row.get(photoAccessHelper.PhotoKeys.DATE_MODIFIED)),
            addedAt: Number(row.get(photoAccessHelper.PhotoKeys.DATE_ADDED)),
            album: settings.layout === 'album' ? origins.get(Number(row.get(photoAccessHelper.PhotoKeys.OWNER_ALBUM_ID))) ?? '' : '' };
          const relative = backupDirectory(settings, this.phoneModel, asset);
          const digest = await hashTransferFile(asset.uri, asset.bytes, (): void => this.ensureCurrent(ticket));
          const key = backupAssetKey(asset, relative, digest);
          if (this.completed.has(key) || this.queue!.items.some((item): boolean => item.backupKey === key)) { continue; }
          const folderId = await this.connector!.ensurePhotoDirectory(relative.split('/'));
          this.ensureCurrent(ticket);
          if (settings !== this.settings) { return true; }
          const accepted = await this.queue!.uploadPhotos('/home/Photos/' + relative, [{ uri: asset.uri, name: asset.name,
            bytes: asset.bytes, folderId, modifiedAt: asset.modifiedAt, wifiOnly: settings.wifiOnly, backupKey: key }], true);
          if (accepted.issues.length > 0) { throw new NasFailure(NasErrorKind.Protocol, accepted.issues[0].errorText); }
          this.status = '正在备份，传输结果可在任务中查看';
          // 保持当前页的扫描位置，仅在队列确认成功后准备下一项，私有副本始终有界。
          while (true) {
            this.ensureCurrent(ticket);
            if (settings !== this.settings) { return true; }
            const allowed = settings.enabled && await this.conditions();
            await this.queue!.setBackupAllowed(allowed);
            if (!allowed) { return true; }
            const transfer = this.queue!.items.find((item): boolean => item.backupKey === key);
            if (transfer === undefined) {
              if (this.completed.has(key)) { break; }
              throw new NasFailure(NasErrorKind.Protocol, '备份任务记录已变化，请检查传输结果。');
            }
            if (transfer.state === 'completed') {
              this.completed.add(key); this.completedCount = this.completed.size; await this.save();
              await this.queue!.removeRecord(transfer.id); break;
            }
            if (['failed', 'unknown', 'cancelled', 'closed'].includes(transfer.state)) {
              throw new NasFailure(NasErrorKind.Protocol, transfer.errorText || '备份未完成，请在传输任务中处理。');
            }
            await new Promise<void>((resolve): void => { setTimeout(resolve, 1000); });
          }
        }
      } finally { result.close(); }
      if (count < 50) { return false; }
      offset += count;
    }
  }

  private async conditions(): Promise<boolean> {
    if (this.settings.chargingOnly && ![batteryInfo.BatteryChargeState.ENABLE, batteryInfo.BatteryChargeState.FULL].includes(batteryInfo.chargingStatus)) {
      this.status = '等待充电'; return false;
    }
    const network = await connection.getDefaultNet();
    if (network.netId <= 0) { this.status = '等待网络'; return false; }
    if (this.settings.wifiOnly) {
      const capabilities = await connection.getNetCapabilities(network);
      if (!capabilities.bearerTypes.includes(connection.NetBearType.BEARER_WIFI)) { this.status = '等待无线局域网'; return false; }
    }
    return true;
  }

  private save(): Promise<void> {
    const path = this.path;
    const snapshot: PhotoBackupSnapshot = { version: 1, scope: this.scope, settings: this.settings, completed: Array.from(this.completed) };
    const text = JSON.stringify(snapshot);
    decodePhotoBackup(text, this.scope);
    const next = this.saveTail.then((): Promise<void> => writePrivateSnapshot(path, new util.TextEncoder().encodeInto(text)));
    this.saveTail = next.catch((): void => {});
    return next;
  }
  private ensureCurrent(ticket: number): void {
    if (ticket !== this.generation) { throw new NasFailure(NasErrorKind.Cancelled, '备份账号已变化。'); }
  }
  private report(error: Error): void {
    this.errorText = error instanceof NasFailure ? error.message : '相册备份未完成，请检查授权、连接和本机存储。';
    hilog.error(0x0000, 'PhotoBackup', 'operation=backup result=failed code=%{public}d', (error as BusinessError).code ?? 0);
  }
}
