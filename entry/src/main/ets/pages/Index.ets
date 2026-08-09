import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NeighborHost } from '../model/NeighborHost';
import { BrowserParams, PlayerParams, SharesParams } from '../model/RouteParams';
import { ConfigStore } from '../service/ConfigStore';
import { NeighborScanner } from '../service/NeighborScanner';
import { SmbService } from '../service/SmbService';
import { SmbError } from '../smb/SmbClient';
import BrowserPage from './BrowserPage';
import PlayerPage from './PlayerPage';
import ShareListPage from './ShareListPage';

@Entry
@Component
struct Index {
  private pathStack: NavPathStack = new NavPathStack();
  @State hosts: NeighborHost[] = [];
  @State scanning: boolean = false;
  @State progressText: string = '';
  @State errorText: string = '';
  @State connecting: boolean = false;
  @State username: string = '';
  @State password: string = '';

  @State dialogVisible: boolean = false;
  @State dialogHost: string = '';
  @State dialogManual: boolean = false;
  @State dialogUsername: string = '';
  @State dialogPassword: string = '';

  aboutToAppear(): void {
    this.loadCredentials();
    this.loadCachedHosts();
  }

  async loadCachedHosts(): Promise<void> {
    try {
      const cached = await ConfigStore.loadHosts(this.getUIContext().getHostContext() as common.UIAbilityContext);
      this.hosts = cached;
      if (cached.length > 0) {
        this.progressText = '上次扫描到 ' + cached.length + ' 台主机（点击扫描可更新）';
      } else {
        this.startScan();
      }
    } catch (e) {
      this.startScan();
    }
  }

  async loadCredentials(): Promise<void> {
    try {
      const cred = await ConfigStore.loadCredentials(this.getUIContext().getHostContext() as common.UIAbilityContext);
      this.username = cred.username;
      this.password = cred.password;
    } catch (e) {
      this.errorText = '配置读取失败';
    }
  }

  private showToast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  async startScan(): Promise<void> {
    if (this.scanning) {
      return;
    }
    this.scanning = true;
    this.errorText = '';
    this.progressText = '正在扫描局域网…';
    try {
      const found = await NeighborScanner.scan((done: number, total: number) => {
        this.progressText = '扫描中 ' + done + '/' + total;
      });
      this.hosts = found;
      this.progressText = found.length > 0 ? '发现 ' + found.length + ' 台 SMB 主机' : '未发现 SMB 主机';
      await ConfigStore.saveHosts(this.getUIContext().getHostContext() as common.UIAbilityContext, found);
    } catch (e) {
      this.errorText = '扫描失败';
      this.progressText = '';
    } finally {
      this.scanning = false;
    }
  }

  async doConnect(host: string, username: string, password: string): Promise<void> {
    if (host.length === 0) {
      this.showToast('请输入主机地址');
      return;
    }
    if (this.connecting) {
      return;
    }
    this.connecting = true;
    try {
      await ConfigStore.saveCredentials(this.getUIContext().getHostContext() as common.UIAbilityContext,
        username, password);
      await SmbService.getInstance().connectHost(host, username, password, '', 445);
      const p: SharesParams = { host: host };
      this.pathStack.pushPathByName('Shares', p);
    } catch (e) {
      const errMsg = e instanceof Error ? e.message : String(e);
      const errStack = e instanceof Error && e.stack !== undefined ? e.stack : '';
      hilog.error(0x0000, 'NasPlayer', 'connect failed, host=%{public}s, err=%{public}s, stack=%{public}s',
        host, errMsg, errStack);
      if (e instanceof SmbError) {
        this.showToast('连接失败：' + e.message);
      } else {
        const msg = errMsg;
        if (msg.indexOf('超时') >= 0) {
          this.showToast('连接超时：主机无响应，请检查网络');
        } else if (msg.indexOf('断开') >= 0 || msg.indexOf('closed') >= 0) {
          this.showToast('连接被中断：服务器拒绝了连接');
        } else if (msg.indexOf('connect') >= 0 || msg.indexOf('socket') >= 0) {
          this.showToast('无法连接主机（' + msg + '），请确认手机与主机在同一网络');
        } else if (msg.length > 0) {
          this.showToast('连接失败：' + msg);
        } else {
          this.showToast('连接失败，请检查网络或账号密码');
        }
      }
    } finally {
      this.connecting = false;
    }
  }

  private showConnectDialog(host: string): void {
    this.dialogHost = host;
    this.dialogManual = false;
    this.dialogUsername = this.username;
    this.dialogPassword = this.password;
    this.dialogVisible = true;
  }

  private showManualDialog(): void {
    this.dialogHost = '';
    this.dialogManual = true;
    this.dialogUsername = this.username;
    this.dialogPassword = this.password;
    this.dialogVisible = true;
  }

  private confirmDialog(): void {
    const h = this.dialogManual ? this.dialogHost.trim() : this.dialogHost;
    this.dialogVisible = false;
    this.doConnect(h, this.dialogUsername.trim(), this.dialogPassword);
  }

  @Builder
  HostCell(host: NeighborHost) {
    Row({ space: 12 }) {
      Text('🖥️')
        .fontSize(26)
      Column({ space: 4 }) {
        Text(host.ip)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_main'))
          .width('100%')
        Text(host.dialectText.length > 0 ? host.dialectText + ' 服务器' : '端口 445 已开放')
          .fontSize(12)
          .fontColor(host.dialectText.length > 0 ? $r('app.color.theme_primary') : $r('app.color.text_secondary'))
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('>')
        .fontSize(16)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(10)
  }

  @Builder
  PageMap(name: string, param: Object) {
    if (name === 'Shares') {
      ShareListPage({ params: param as SharesParams })
    } else if (name === 'Browser') {
      BrowserPage({ params: param as BrowserParams })
    } else if (name === 'Player') {
      PlayerPage({ params: param as PlayerParams })
    }
  }

  build() {
    Stack() {
      Navigation(this.pathStack) {
        Column() {
          Text('网络邻居')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_main'))
            .margin({ top: 24, bottom: 4 })
          Text('自动搜索局域网中的 Windows 共享主机')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .margin({ bottom: 10 })

          Row({ space: 10 }) {
            Button(this.scanning ? '扫描中…' : '重新扫描')
              .height(38)
              .fontSize(14)
              .backgroundColor($r('app.color.theme_primary'))
              .onClick(() => {
                this.startScan();
              })
            if (this.progressText.length > 0) {
              Text(this.progressText)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 8 })

          if (this.errorText.length > 0) {
            Text(this.errorText)
              .fontSize(14)
              .fontColor($r('app.color.text_error'))
              .padding({ left: 14, right: 14, bottom: 8 })
          }

          if (this.scanning && this.hosts.length === 0) {
            Column({ space: 10 }) {
              LoadingProgress()
                .width(40)
                .height(40)
                .color($r('app.color.theme_primary'))
              Text('正在搜索网络邻居…')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            List({ space: 8 }) {
              ForEach(this.hosts, (host: NeighborHost) => {
                ListItem() {
                  this.HostCell(host)
                }
                .onClick(() => {
                  this.showConnectDialog(host.ip);
                })
              }, (host: NeighborHost) => host.ip)
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ left: 14, right: 14 })
            .scrollBar(BarState.Off)
          }

          Button('手动输入主机 IP')
            .width('calc(100% - 28vp)')
            .height(44)
            .fontSize(15)
            .margin({ top: 6, bottom: 10 })
            .backgroundColor($r('app.color.card_bg'))
            .fontColor($r('app.color.theme_primary'))
            .onClick(() => {
              this.showManualDialog();
            })
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.theme_bg'))
      }
      .navDestination(this.PageMap)
      .mode(NavigationMode.Stack)
      .hideTitleBar(true)
      .width('100%')
      .height('100%')

      if (this.dialogVisible) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#80000000')
            .onClick(() => {
              this.dialogVisible = false;
            })

          Column({ space: 12 }) {
            Text(this.dialogManual ? '手动输入主机' : '连接 ' + this.dialogHost)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_main'))
              .width('100%')

            if (this.dialogManual) {
              TextInput({ placeholder: '主机 IP 地址', text: this.dialogHost })
                .width('100%')
                .height(44)
                .fontSize(15)
                .onChange((value: string) => {
                  this.dialogHost = value;
                })
            }

            TextInput({ placeholder: '用户名', text: this.dialogUsername })
              .width('100%')
              .height(44)
              .fontSize(15)
              .onChange((value: string) => {
                this.dialogUsername = value;
              })

            TextInput({ placeholder: '密码', text: this.dialogPassword })
              .width('100%')
              .height(44)
              .fontSize(15)
              .type(InputType.Password)
              .onChange((value: string) => {
                this.dialogPassword = value;
              })

            Row({ space: 12 }) {
              Button('取消')
                .layoutWeight(1)
                .height(42)
                .fontSize(15)
                .backgroundColor($r('app.color.button_cancel_bg'))
                .fontColor($r('app.color.text_main'))
                .onClick(() => {
                  this.dialogVisible = false;
                })
              Button('连接')
                .layoutWeight(1)
                .height(42)
                .fontSize(15)
                .backgroundColor($r('app.color.theme_primary'))
                .onClick(() => {
                  this.confirmDialog();
                })
            }
            .width('100%')
          }
          .width(320)
          .padding(20)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(16)
          .offset({ y: -60 })
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}

