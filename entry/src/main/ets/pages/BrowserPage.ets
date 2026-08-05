import { image } from '@kit.ImageKit';
import { VideoEntry } from '../model/VideoEntry';
import { BrowserParams, PlayerParams } from '../model/RouteParams';
import { SmbService } from '../service/SmbService';
import { MediaUtil } from '../service/MediaUtil';
import { ThumbnailService } from '../service/ThumbnailService';

class VideoDataSource implements IDataSource {
  private data: VideoEntry[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.data.length;
  }

  getData(index: number): VideoEntry {
    return this.data[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  setData(entries: VideoEntry[]): void {
    this.data = entries;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}

@Component
struct ThumbCell {
  @Prop path: string = '';
  @Prop name: string = '';
  @Prop fileSize: number = 0;
  @State pm: image.PixelMap | undefined = undefined;

  aboutToAppear(): void {
    this.loadThumb();
  }

  async loadThumb(): Promise<void> {
    const pm = await ThumbnailService.getInstance().request(this.path, this.fileSize);
    if (pm !== undefined) {
      this.pm = pm;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.pm !== undefined) {
        Image(this.pm)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Column({ space: 4 }) {
          Text('▶')
            .fontSize(28)
            .fontColor(Color.White)
          Text(this.name)
            .fontSize(11)
            .fontColor(Color.White)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 6, right: 6 })
            .textAlign(TextAlign.Center)
          Text(MediaUtil.formatSize(this.fileSize))
            .fontSize(10)
            .fontColor('#AABBDD')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height(140)
    .backgroundColor($r('app.color.poster_bg'))
    .borderRadius(8)
    .clip(true)
  }
}

@Component
export default struct BrowserPage {
  params: BrowserParams = { sharePath: '' };
  private navCtx: NavDestinationContext | undefined = undefined;
  private source: VideoDataSource = new VideoDataSource();
  @State currentPath: string = '';
  @State loading: boolean = false;
  @State gridMode: boolean = false;
  @State errorText: string = '';
  @State emptyText: string = '';

  aboutToAppear(): void {
    this.load(this.params.sharePath);
  }

  private showToast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  async load(path: string): Promise<void> {
    this.loading = true;
    this.errorText = '';
    this.emptyText = '';
    try {
      const list = await SmbService.getInstance().readdir(path);
      this.currentPath = path;
      this.source.setData(list);
      if (list.length === 0) {
        this.emptyText = '目录为空';
      }
    } catch (e) {
      this.errorText = '加载失败，请确认连接是否正常';
    } finally {
      this.loading = false;
    }
  }

  private openEntry(entry: VideoEntry): void {
    if (entry.isDirectory) {
      this.load(entry.path);
      return;
    }
    if (!MediaUtil.isVideo(entry.name)) {
      this.showToast('不是可播放的视频文件');
      return;
    }
    const videos: VideoEntry[] = [];
    for (let i = 0; i < this.source.totalCount(); i++) {
      const item = this.source.getData(i);
      if (!item.isDirectory && MediaUtil.isVideo(item.name)) {
        videos.push(item);
      }
    }
    if (videos.length === 0) {
      this.showToast('当前目录没有可播放的视频');
      return;
    }
    let index = 0;
    for (let i = 0; i < videos.length; i++) {
      if (videos[i].path === entry.path) {
        index = i;
        break;
      }
    }
    const p: PlayerParams = { files: videos, index: index };
    if (this.navCtx !== undefined) {
      this.navCtx.pathStack.pushPathByName('Player', p);
    }
  }

  @Builder
  VideoCell(entry: VideoEntry) {
    Row({ space: 12 }) {
      if (entry.isDirectory) {
        Text('📁')
          .fontSize(26)
      } else {
        Text('🎬')
          .fontSize(26)
      }
      Column({ space: 4 }) {
        Text(entry.name)
          .fontSize(15)
          .fontColor($r('app.color.text_main'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(entry.isDirectory ? '文件夹' : MediaUtil.formatSize(entry.size))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(Color.White)
    .borderRadius(10)
  }

  build() {
    NavDestination() {
      Column() {
        Row({ space: 10 }) {
          Text(this.currentPath.length > 0 ? this.currentPath.split('\\').pop() ?? this.currentPath : '共享根目录')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Button(this.gridMode ? '列表' : '海报墙')
            .fontSize(12)
            .height(30)
            .backgroundColor($r('app.color.theme_primary'))
            .onClick(() => {
              this.gridMode = !this.gridMode;
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, bottom: 8 })

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
                this.load(this.currentPath);
              })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.emptyText.length > 0) {
          Column() {
            Text(this.emptyText)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.gridMode) {
          Grid() {
            LazyForEach(this.source, (item: VideoEntry) => {
              GridItem() {
                Column({ space: 4 }) {
                  ThumbCell({ path: item.path, name: item.name, fileSize: item.size })
                  Text(item.name)
                    .fontSize(12)
                    .fontColor($r('app.color.text_main'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
                .width('100%')
              }
              .onClick(() => {
                this.openEntry(item);
              })
            }, (item: VideoEntry) => item.path)
          }
          .columnsTemplate('1fr 1fr 1fr')
          .columnsGap(8)
          .rowsGap(10)
          .padding({ left: 14, right: 14, bottom: 14 })
          .width('100%')
          .layoutWeight(1)
        } else {
          List({ space: 8 }) {
            LazyForEach(this.source, (item: VideoEntry) => {
              ListItem() {
                this.VideoCell(item)
              }
              .onClick(() => {
                this.openEntry(item);
              })
            }, (item: VideoEntry) => item.path)
          }
          .padding({ left: 14, right: 14, bottom: 14 })
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.theme_bg'))
    }
    .title(this.currentPath.length > 0 ? this.currentPath.split('\\').pop() ?? '文件浏览' : '文件浏览')
    .hideTitleBar(false)
    .onReady((ctx: NavDestinationContext) => {
      this.navCtx = ctx;
    })
  }
}
