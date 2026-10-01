import { NasFileEntry } from '../core/domain/DsmProtocol';
import { ConnectionViewModel } from '../features/connection/ConnectionViewModel';
import { common } from '@kit.AbilityKit';

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
        Button('刷新').enabled(!this.model.busy).onClick((): void => { this.model.refresh(); })
        Button('登出').enabled(!this.model.busy).onClick((): void => { this.model.disconnect(); })
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
                primaryButton: { value: '取消', action: (): void => {} },
                secondaryButton: { value: '开始', action: (): void => { this.model.verifyTransfer(); } }
              });
            })
        }.width('100%')
      }
      if (this.model.transfer.available) {
        Row({ space: 12 }) {
          Text(this.model.transfer.status).fontSize(14).layoutWeight(1)
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

  build() {
    Column({ space: 12 }) {
      if (this.model.authenticated) { this.filesView() }
      else { Scroll() { this.connectionForm() }.align(Alignment.TopStart).layoutWeight(1).width('100%') }
      if (this.model.errorText.length > 0) {
        Text(this.model.errorText).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
      }
    }.width('100%').height('100%').padding(20)
      .backgroundColor($r('sys.color.background_primary'))
  }
}
