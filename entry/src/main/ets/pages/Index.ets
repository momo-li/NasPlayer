import { common } from '@kit.AbilityKit';
import { SmbConfig } from '../model/SmbConfig';
import { BrowserParams, PlayerParams } from '../model/RouteParams';
import { ConfigStore } from '../service/ConfigStore';
import { SmbService } from '../service/SmbService';
import { ThumbnailService } from '../service/ThumbnailService';
import BrowserPage from './BrowserPage';
import PlayerPage from './PlayerPage';

@Entry
@Component
struct Index {
  private pathStack: NavPathStack = new NavPathStack();
  @State host: string = '';
  @State portText: string = '445';
  @State share: string = '';
  @State username: string = '';
  @State password: string = '';
  @State domain: string = 'WORKGROUP';
  @State connecting: boolean = false;
  @State statusText: string = '';

  aboutToAppear(): void {
    ThumbnailService.getInstance().init(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.loadConfig();
  }

  async loadConfig(): Promise<void> {
    try {
      const cfg = await ConfigStore.load(this.getUIContext().getHostContext() as common.UIAbilityContext);
      this.host = cfg.host;
      this.portText = String(cfg.port);
      this.share = cfg.share;
      this.username = cfg.username;
      this.password = cfg.password;
      this.domain = cfg.domain;
    } catch (e) {
      this.statusText = '配置读取失败';
    }
  }

  private showToast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private buildConfig(): SmbConfig {
    const cfg: SmbConfig = {
      host: this.host.trim(),
      port: Number(this.portText) > 0 ? Number(this.portText) : 445,
      share: this.share.trim(),
      username: this.username.trim(),
      password: this.password,
      domain: this.domain.trim().length > 0 ? this.domain.trim() : 'WORKGROUP'
    };
    return cfg;
  }

  async handleConnect(): Promise<void> {
    if (this.host.trim().length === 0 || this.share.trim().length === 0) {
      this.showToast('请填写主机地址与共享名');
      return;
    }
    if (this.connecting) {
      return;
    }
    this.connecting = true;
    this.statusText = '正在连接…';
    const cfg = this.buildConfig();
    try {
      await ConfigStore.save(this.getUIContext().getHostContext() as common.UIAbilityContext, cfg);
      await SmbService.getInstance().connect(cfg);
      this.statusText = '已连接（' + SmbService.getInstance().dialectText + '）';
      const p: BrowserParams = { sharePath: '' };
      this.pathStack.pushPathByName('Browser', p);
    } catch (e) {
      this.statusText = '';
      this.showToast('连接失败，请检查主机、账号与共享名');
    } finally {
      this.connecting = false;
    }
  }

  async handleSave(): Promise<void> {
    if (this.host.trim().length === 0 || this.share.trim().length === 0) {
      this.showToast('请填写主机地址与共享名');
      return;
    }
    try {
      await ConfigStore.save(this.getUIContext().getHostContext() as common.UIAbilityContext, this.buildConfig());
      this.showToast('配置已保存');
    } catch (e) {
      this.showToast('保存失败');
    }
  }

  build() {
    Navigation(this.pathStack) {
      Column() {
        Text('NasPlayer')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_main'))
          .margin({ top: 24, bottom: 4 })
        Text('播放 NAS 中的视频（SMB）')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .margin({ bottom: 8 })

        Scroll() {
          Column() {
            Text('主机地址')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            TextInput({ placeholder: '例如 192.168.1.100', text: this.host })
              .width('100%')
              .fontSize(16)
              .backgroundColor(Color.White)
              .onChange((value: string) => {
                this.host = value;
              })

            Text('端口')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ top: 12 })
            TextInput({ placeholder: '445', text: this.portText })
              .width('100%')
              .fontSize(16)
              .backgroundColor(Color.White)
              .type(InputType.Number)
              .onChange((value: string) => {
                this.portText = value;
              })

            Text('共享名')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ top: 12 })
            TextInput({ placeholder: '例如 video 或 public', text: this.share })
              .width('100%')
              .fontSize(16)
              .backgroundColor(Color.White)
              .onChange((value: string) => {
                this.share = value;
              })

            Text('用户名')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ top: 12 })
            TextInput({ placeholder: '共享账号', text: this.username })
              .width('100%')
              .fontSize(16)
              .backgroundColor(Color.White)
              .onChange((value: string) => {
                this.username = value;
              })

            Text('密码')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ top: 12 })
            TextInput({ placeholder: '共享密码', text: this.password })
              .width('100%')
              .fontSize(16)
              .backgroundColor(Color.White)
              .type(InputType.Password)
              .onChange((value: string) => {
                this.password = value;
              })

            Text('域 / 工作组')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ top: 12 })
            TextInput({ placeholder: 'WORKGROUP', text: this.domain })
              .width('100%')
              .fontSize(16)
              .backgroundColor(Color.White)
              .onChange((value: string) => {
                this.domain = value;
              })

            Button(this.connecting ? '正在连接…' : '连接并浏览')
              .width('100%')
              .height(46)
              .fontSize(16)
              .margin({ top: 24 })
              .backgroundColor($r('app.color.theme_primary'))
              .onClick(() => {
                this.handleConnect();
              })

            Button('保存配置')
              .width('100%')
              .height(44)
              .fontSize(15)
              .margin({ top: 12 })
              .backgroundColor(Color.White)
              .fontColor($r('app.color.theme_primary'))
              .onClick(() => {
                this.handleSave();
              })

            if (this.statusText.length > 0) {
              Text(this.statusText)
                .fontSize(13)
                .fontColor($r('app.color.theme_primary'))
                .margin({ top: 12 })
            }

            Text('支持 SMB 2.0.2 / 2.1 / 3.0 / 3.1.1，NTLMv2 认证')
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 24, bottom: 16 })
          }
          .width('100%')
          .padding({ left: 20, right: 20 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.theme_bg'))
    }
    .navDestination((name: string, param: Object) => {
      if (name === 'Browser') {
        BrowserPage({ params: param as BrowserParams })
      } else if (name === 'Player') {
        PlayerPage({ params: param as PlayerParams })
      }
    })
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .width('100%')
    .height('100%')
  }
}

