import { hilog } from '@kit.PerformanceAnalysisKit';
import { TextFileParams } from '../model/RouteParams';
import { TextContent, TextFileLoader } from '../service/TextFileLoader';

const DOMAIN = 0x0000;
const TAG = 'NasPlayer';

/** 文本文件只读查看页：SMB 读取 + 自动编码解码，滚动展示、可长按复制 */
@Component
export default struct TextFilePage {
  params: TextFileParams = { path: '', name: '', size: 0 };

  @State loading: boolean = true;
  @State errorText: string = '';
  @State content: string = '';
  @State truncated: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const p = this.params;
    if (p === undefined || p === null || p.path.length === 0) {
      this.loading = false;
      this.errorText = '文件参数无效';
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      const result: TextContent = await TextFileLoader.load(p.path, p.size);
      this.content = result.text;
      this.truncated = result.truncated;
    } catch (e) {
      const msg = e instanceof Error ? e.message : '文本加载失败';
      hilog.warn(DOMAIN, TAG, 'text page load failed path=%{public}s err=%{public}s', p.path, msg);
      this.errorText = msg;
    } finally {
      this.loading = false;
    }
  }

  @Builder
  contentView() {
    Scroll() {
      Column({ space: 10 }) {
        if (this.truncated) {
          Text('文件较大，仅显示前 1MB 内容')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(8)
        }
        Text(this.content.length > 0 ? this.content : '（空文件）')
          .fontSize(14)
          .fontFamily('monospace')
          .fontColor($r('app.color.text_main'))
          .copyOption(CopyOptions.LocalDevice)
          .textAlign(TextAlign.Start)
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 14, right: 14, top: 12, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Auto)
  }

  build() {
    NavDestination() {
      if (this.loading) {
        Column({ space: 10 }) {
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
      } else {
        this.contentView()
      }
    }
    .title(this.params.name.length > 0 ? this.params.name : '文本')
    .hideTitleBar(false)
    .backgroundColor($r('app.color.theme_bg'))
    .width('100%')
    .height('100%')
  }
}
