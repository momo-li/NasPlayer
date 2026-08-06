import { ShareEntry } from '../model/ShareEntry';
import { BrowserParams, SharesParams } from '../model/RouteParams';
import { SmbService } from '../service/SmbService';
import { hilog } from '@kit.PerformanceAnalysisKit';

@Component
export default struct ShareListPage {
  params: SharesParams = { host: '' };
  private navCtx: NavDestinationContext | undefined = undefined;
  @State shares: ShareEntry[] = [];
  @State loading: boolean = false;
  @State errorText: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private showToast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  async load(): Promise<void> {
    this.loading = true;
    this.errorText = '';
    try {
      const list = await SmbService.getInstance().enumerateShares();
      this.shares = list;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      const stack = e instanceof Error && e.stack !== undefined ? e.stack : '';
      hilog.error(0x0000, 'NasPlayer', 'enumerateShares failed: %{public}s stack=%{public}s', msg, stack);
      this.errorText = '无法获取共享列表：' + msg;
    } finally {
      this.loading = false;
    }
  }

  async openShare(entry: ShareEntry): Promise<void> {
    if (entry.isIpc) {
      this.showToast('IPC 共享不可浏览');
      return;
    }
    try {
      await SmbService.getInstance().enterShare(entry.name);
      const p: BrowserParams = { sharePath: '' };
      if (this.navCtx !== undefined) {
        this.navCtx.pathStack.pushPathByName('Browser', p);
      }
    } catch (e) {
      this.showToast('无法访问该共享');
    }
  }

  @Builder
  ShareCell(entry: ShareEntry) {
    Row({ space: 12 }) {
      Text(entry.isIpc ? '🔧' : '📁')
        .fontSize(26)
      Column({ space: 4 }) {
        Text(entry.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_main'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(entry.remark.length > 0 ? entry.remark : (entry.isIpc ? 'IPC 通道' : '磁盘共享'))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (!entry.isIpc) {
        Text('>')
          .fontSize(16)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(10)
  }

  build() {
    NavDestination() {
      Column() {
        if (this.loading) {
          Column({ space: 8 }) {
            LoadingProgress()
              .width(40)
              .height(40)
              .color($r('app.color.theme_primary'))
            Text('加载中…')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.errorText.length > 0) {
          Column({ space: 10 }) {
            Text(this.errorText)
              .fontSize(14)
              .fontColor($r('app.color.text_main'))
            Button('重试')
              .fontSize(14)
              .height(36)
              .backgroundColor($r('app.color.theme_primary'))
              .onClick(() => {
                this.load();
              })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.shares.length === 0) {
          Column() {
            Text('该主机没有可用的共享')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 8 }) {
            ForEach(this.shares, (entry: ShareEntry) => {
              ListItem() {
                this.ShareCell(entry)
              }
              .onClick(() => {
                this.openShare(entry);
              })
            }, (entry: ShareEntry) => entry.name)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 14, right: 14, bottom: 14 })
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.theme_bg'))
    }
    .title(this.params.host + ' 的共享')
    .hideTitleBar(false)
    .onReady((ctx: NavDestinationContext) => {
      this.navCtx = ctx;
    })
  }
}
