import { NasFileEntry } from '../core/domain/DsmProtocol';
import { ConnectionViewModel } from '../features/connection/ConnectionViewModel';
import { common } from '@kit.AbilityKit';
import { NasPhotoItem, NasSharedAlbum, PhotosSpace } from '../core/domain/PhotosProtocol';

@Entry
@ComponentV2
struct Index {
  @Local private model: ConnectionViewModel = new ConnectionViewModel();

  aboutToAppear(): void { this.model.restore(this.getUIContext().getHostContext() as common.UIAbilityContext); }

  aboutToDisappear(): void { this.model.dispose(); }

  @Builder
  connectionForm() {
    Column({ space: 16 }) {
      Text(this.model.connected ? '登录 NAS' : '连接 NAS').fontSize(28).fontWeight(FontWeight.Bold)
      TextInput({ text: this.model.address, placeholder: 'https://nas.example.com:5001' })
        .enabled(!this.model.connected && !this.model.busy && !this.model.savedSession)
        .onChange((text: string): void => { this.model.address = text; })
        .accessibilityText('NAS HTTPS 地址')
      if (this.model.savedSession) {
        Button(this.model.busy ? '正在连接…' : '重试连接')
          .width('100%').enabled(!this.model.busy)
          .onClick((): void => { this.model.restore(); })
        Button('重新登录').enabled(!this.model.busy)
          .backgroundColor(Color.Transparent).fontColor($r('sys.color.font_secondary'))
          .onClick((): void => { this.model.disconnect(); })
      } else if (!this.model.connected) {
        Button(this.model.busy ? '正在连接…' : '连接 NAS')
          .width('100%').enabled(!this.model.busy)
          .onClick((): void => { this.model.connect(); })
      } else {
        TextInput({ text: this.model.account, placeholder: 'NAS 账号' })
          .enabled(!this.model.busy)
          .onChange((text: string): void => { this.model.account = text; })
          .accessibilityText('NAS 账号')
        TextInput({ text: this.model.password, placeholder: '密码' })
          .type(InputType.Password).enabled(!this.model.busy)
          .onChange((text: string): void => { this.model.password = text; })
          .accessibilityText('NAS 密码')
        if (this.model.needsOtp) {
          TextInput({ text: this.model.otp, placeholder: '6 位动态码' })
            .type(InputType.Number).maxLength(6).enabled(!this.model.busy)
            .onChange((text: string): void => { this.model.otp = text; })
            .accessibilityText('双重验证动态码')
        }
        Button(this.model.busy ? '正在登录…' : '登录')
          .width('100%').enabled(!this.model.busy)
          .onClick((): void => { this.model.login(); })
        Button('更换服务器').enabled(!this.model.busy)
          .backgroundColor(Color.Transparent).fontColor($r('sys.color.font_secondary'))
          .onClick((): void => { this.model.disconnect(); })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 32 })
  }

  @Builder
  filesView() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text('文件').fontSize(26).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('照片').enabled(!this.model.busy).onClick((): void => { this.model.openPhotos(); })
        Button('刷新').enabled(!this.model.busy).onClick((): void => { this.model.refresh(); })
        Button('更多').enabled(!this.model.busy).onClick((): void => {
          this.getUIContext().showAlertDialog({ title: '连接', message: '', buttons: [
            { value: '设备信息', action: (): void => {
              this.model.serverInfo().then((info: string): void => {
                if (info.length > 0) { this.getUIContext().showAlertDialog({ title: '设备信息', message: info,
                  confirm: { value: '确定', action: (): void => {} } }); }
              });
            } },
            { value: '登出', action: (): void => { this.model.disconnect(); } },
            { value: '取消', action: (): void => {} }
          ] });
        })
      }.width('100%')
      Text(this.model.directory.length === 0 ? '共享文件夹' : this.model.directory)
        .fontSize(14).width('100%').fontColor($r('sys.color.font_secondary'))
      if (this.model.directory.length > 0) {
        Row({ space: 12 }) {
          Button('返回上级').enabled(!this.model.busy).onClick((): void => { this.model.goBack(); })
          Button('验证上传下载').enabled(!this.model.busy)
            .onClick((): void => {
              this.getUIContext().showAlertDialog({
                title: '验证上传下载',
                message: '将在 ' + this.model.directory + ' 新增一个测试文件，完成后保留。',
                buttons: [
                  { value: '小文件', action: (): void => { this.model.verifyTransfer(); } },
                  { value: '64 MB 文件', action: (): void => { this.model.verifyTransfer(false, true); } },
                  { value: '取消', action: (): void => {} }
                ]
              });
            })
        }.width('100%')
      }
      if (this.model.transfer.available) {
        Row({ space: 12 }) {
          Text(this.model.transfer.status).fontSize(14).layoutWeight(1)
          if (this.model.transfer.stoppable) {
            Button('停止').onClick((): void => { this.model.stopTransfer(); })
          }
          Button('重新检查').enabled(!this.model.busy)
            .backgroundColor(Color.Transparent).fontColor($r('sys.color.font_secondary'))
            .onClick((): void => { this.model.verifyTransfer(true); })
          if (this.model.transfer.status !== '上传下载已校验' && this.model.transfer.status !== '上次上传下载已校验') {
            Button('取消检查').enabled(!this.model.busy)
              .backgroundColor(Color.Transparent).fontColor($r('sys.color.font_secondary'))
              .onClick((): void => {
                this.getUIContext().showAlertDialog({
                  title: '取消传输检查', message: '将停止本机任务并清除检查记录。NAS 上已产生的文件会保留。',
                  primaryButton: { value: '返回', action: (): void => {} },
                  secondaryButton: { value: '确认', action: (): void => { this.model.discardTransfer(); } }
                });
              })
          }
        }.width('100%')
      }
      if (this.model.busy && !this.model.transfer.running) {
        Text('正在读取文件…').fontSize(14)
      } else if (this.model.entries.length === 0 && this.model.errorText.length === 0) {
        Text('此位置没有可显示的文件。').fontColor($r('sys.color.font_secondary'))
      }
      List({ space: 8 }) {
        ForEach(this.model.entries, (entry: NasFileEntry): void => {
          ListItem() {
            Row({ space: 12 }) {
              Text(entry.isDirectory ? '目录' : '文件').fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
              Text(entry.name).fontSize(16).layoutWeight(1)
              if (entry.isDirectory) { Text('›').fontSize(24) }
              else if (entry.bytes !== undefined) { Text(entry.bytes.toString() + ' B').fontSize(12) }
            }.width('100%').padding(16).borderRadius(16)
              .backgroundColor($r('sys.color.comp_background_secondary'))
          }.enabled(!this.model.busy && entry.isDirectory)
            .onClick((): void => { this.model.openDirectory(entry); })
            .accessibilityText((entry.isDirectory ? '文件夹，' : '文件，') + entry.name)
        }, (entry: NasFileEntry): string => this.model.account + ':' + entry.path)
      }.layoutWeight(1).width('100%')
      Row({ space: 12 }) {
        Button('上一页').enabled(!this.model.busy && this.model.pageOffset > 0)
          .onClick((): void => { this.model.previousPage(); })
        Text(this.model.total === 0 ? '0 项' :
          (this.model.pageOffset + 1).toString() + '–' +
          (this.model.pageOffset + this.model.entries.length).toString() + ' / ' + this.model.total.toString())
          .layoutWeight(1).textAlign(TextAlign.Center).fontSize(12)
        Button('下一页').enabled(!this.model.busy &&
          this.model.pageOffset + this.model.entries.length < this.model.total)
          .onClick((): void => { this.model.nextPage(); })
      }.width('100%')
    }.layoutWeight(1).width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  photosView() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text('照片').fontSize(26).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('文件').enabled(!this.model.busy).onClick((): void => { this.model.closePhotos(); })
        Button('刷新').enabled(!this.model.busy)
          .onClick((): void => { this.model.openPhotos(this.model.photosSpace, 0); })
      }.width('100%')
      Row({ space: 12 }) {
        Button('个人空间').enabled(!this.model.busy && this.model.photosSpace !== PhotosSpace.Personal)
          .onClick((): void => { this.model.openPhotos(PhotosSpace.Personal); })
        Button('与我共享').enabled(!this.model.busy && this.model.photosSpace !== PhotosSpace.WithMe)
          .onClick((): void => { this.model.openPhotos(PhotosSpace.WithMe); })
      }.width('100%')
      if (this.model.selectedAlbum !== undefined) {
        Row({ space: 12 }) {
          Button('相册列表').enabled(!this.model.busy).onClick((): void => { this.model.backToAlbums(); })
          Text(this.model.selectedAlbum.name).fontSize(16).layoutWeight(1)
        }.width('100%')
      }
      if (this.model.busy && !this.model.media.running) { Text('正在读取…').fontSize(14) }
      else if (this.model.photosPageCount() === 0 && this.model.errorText.length === 0) {
        Text('当前账号没有可见的项目。').fontColor($r('sys.color.font_secondary'))
      }
      List({ space: 8 }) {
        ForEach(this.model.sharedAlbums, (album: NasSharedAlbum): void => {
          ListItem() {
            Row({ space: 12 }) {
              Text(album.name).fontSize(16).layoutWeight(1)
              Text(album.itemCount.toString() + ' 项').fontSize(12)
              Text('›').fontSize(24)
            }.width('100%').padding(16).borderRadius(16)
              .backgroundColor($r('sys.color.comp_background_secondary'))
          }.enabled(!this.model.busy).onClick((): void => { this.model.openSharedAlbum(album); })
        }, (album: NasSharedAlbum): string => this.model.address + ':' + this.model.account + ':' + album.id.toString())
        ForEach(this.model.photoItems, (item: NasPhotoItem): void => {
          ListItem() {
            Row({ space: 12 }) {
              Text(item.mediaType === 'video' ? '视频' : item.mediaType === 'live' ? '动态照片' : '照片').fontSize(12)
              Text(item.filename).fontSize(16).layoutWeight(1)
              Text(item.bytes.toString() + ' B').fontSize(12)
            }.width('100%').padding(16).borderRadius(16)
              .backgroundColor($r('sys.color.comp_background_secondary'))
          }
        }, (item: NasPhotoItem): string => this.model.address + ':' + this.model.account + ':' + item.space.toString() + ':' + item.id.toString())
      }.layoutWeight(1).width('100%')
      Row({ space: 12 }) {
        Button('上一页').enabled(!this.model.busy && this.model.photosOffset > 0)
          .onClick((): void => { this.model.previousPhotos(); })
        Text(this.model.errorText.length > 0 ? '未读取' : this.model.photosPageCount().toString() + ' 项')
          .layoutWeight(1).textAlign(TextAlign.Center).fontSize(12)
        Button('下一页').enabled(!this.model.busy && this.model.photosMore)
          .onClick((): void => { this.model.openPhotos(this.model.photosSpace, this.model.photosOffset + this.model.photosPageCount()); })
      }.width('100%')
      Button('选择照片').enabled(!this.model.busy).onClick((): void => { this.model.selectMedia(); })
      if (this.model.media.status.length > 0) { Text(this.model.media.status).fontSize(14) }
    }.layoutWeight(1).width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 12 }) {
      if (this.model.authenticated) {
        if (this.model.photosOpened) { this.photosView() }
        else { this.filesView() }
      }
      else { Scroll() { this.connectionForm() }.align(Alignment.TopStart).layoutWeight(1).width('100%') }
      if (this.model.errorText.length > 0) {
        Text(this.model.errorText).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
      }
    }.width('100%').height('100%').padding(20)
      .backgroundColor($r('sys.color.background_primary'))
  }
}
