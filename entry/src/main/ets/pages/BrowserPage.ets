import { hilog } from '@kit.PerformanceAnalysisKit';
import { VideoEntry } from '../model/VideoEntry';
import { BrowserParams, ImageViewerParams, PlayerParams } from '../model/RouteParams';
import { SmbService } from '../service/SmbService';
import { MediaUtil } from '../service/MediaUtil';

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
struct VideoCell {
  @Prop path: string = '';
  @Prop name: string = '';
  @Prop fileSize: number = 0;
  @Prop isDir: boolean = false;
  @Prop modifiedTime: number = 0;

  build() {
    Row({ space: 10 }) {
      if (this.isDir) {
        Stack({ alignContent: Alignment.Center }) {
          Text('📁')
            .fontSize(20)
        }
        .width(44)
        .height(36)
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(6)
      } else {
        Stack({ alignContent: Alignment.Center }) {
          Text(this.extText())
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
        }
        .width(44)
        .height(36)
        .backgroundColor($r('app.color.poster_bg'))
        .borderRadius(6)
        .clip(true)
      }
      Column({ space: 4 }) {
        Text(this.name)
          .fontSize(13)
          .fontColor($r('app.color.text_main'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.metaText())
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(10)
  }

  private extText(): string {
    const idx = this.name.lastIndexOf('.');
    if (idx < 0 || idx === this.name.length - 1) {
      return '视频';
    }
    return this.name.substring(idx + 1).toUpperCase();
  }

  private metaText(): string {
    if (this.isDir) {
      return '文件夹';
    }
    const parts: string[] = [];
    parts.push(MediaUtil.formatSize(this.fileSize));
    parts.push(MediaUtil.formatTime(this.modifiedTime));
    return parts.join('  ·  ');
  }
}

@Component
export default struct BrowserPage {
  params: BrowserParams = { sharePath: '' };
  private navCtx: NavDestinationContext | undefined = undefined;
  private source: VideoDataSource = new VideoDataSource();
  @State currentPath: string = '';
  @State loading: boolean = false;
  @State errorText: string = '';
  @State emptyText: string = '';
  @State refreshing: boolean = false;
  @State deleteTarget: VideoEntry | undefined = undefined;
  @State deleting: boolean = false;

  aboutToAppear(): void {
    this.load(this.params.sharePath);
  }

  private showToast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  async load(path: string, force: boolean = false): Promise<void> {
    this.loading = true;
    this.errorText = '';
    this.emptyText = '';
    try {
      const list = await SmbService.getInstance().readdir(path, force);
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

  /** 返回上级目录；无上级目录（共享根）时返回 false 让系统退出页面 */
  private goBack(): boolean {
    const cur = this.currentPath;
    if (cur.length === 0) {
      return false;
    }
    const idx = cur.lastIndexOf('\\');
    // 单级目录（无 \）返回根目录；多级目录返回上一级
    const parent = idx < 0 ? '' : (idx === 0 ? '' : cur.substring(0, idx));
    this.load(parent);
    return true;
  }

  private openEntry(entry: VideoEntry): void {
    if (entry.isDirectory) {
      this.load(entry.path);
      return;
    }
    if (MediaUtil.isImage(entry.name)) {
      this.openImages(entry);
      return;
    }
    if (!MediaUtil.isVideo(entry.name)) {
      this.showToast('暂不支持该文件类型');
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

  private openImages(entry: VideoEntry): void {
    const images: VideoEntry[] = [];
    for (let i = 0; i < this.source.totalCount(); i++) {
      const item = this.source.getData(i);
      if (!item.isDirectory && MediaUtil.isImage(item.name)) {
        images.push(item);
      }
    }
    if (images.length === 0) {
      return;
    }
    let index = 0;
    for (let i = 0; i < images.length; i++) {
      if (images[i].path === entry.path) {
        index = i;
        break;
      }
    }
    const p: ImageViewerParams = { files: images, index: index };
    if (this.navCtx !== undefined) {
      this.navCtx.pathStack.pushPathByName('ImageViewer', p);
    }
  }

  private deleteName(): string {
    const t = this.deleteTarget;
    return t !== undefined ? t.name : '';
  }

  private deleteHint(): string {
    const t = this.deleteTarget;
    if (t !== undefined && t.isDirectory) {
      return '删除后无法恢复，文件夹必须为空';
    }
    return '删除后无法恢复，请谨慎操作';
  }

  /** 删除前二次确认（后续新增操作按钮时，各自入口保持独立） */
  private confirmDelete(): void {
    const target = this.deleteTarget;
    if (target === undefined || this.deleting) {
      return;
    }
    const kind = target.isDirectory ? '文件夹' : '文件';
    const cancelBtn: AlertDialogButtonOptions = {
      value: '取消',
      action: () => {
      }
    };
    const deleteBtn: AlertDialogButtonOptions = {
      value: '删除',
      fontColor: '#E53935',
      action: () => {
        this.doDelete(target);
      }
    };
    const options: AlertDialogParamWithButtons = {
      title: '确认删除',
      message: '确定要删除' + kind + '“' + target.name + '”吗？此操作不可恢复。',
      autoCancel: true,
      primaryButton: cancelBtn,
      secondaryButton: deleteBtn
    };
    this.getUIContext().showAlertDialog(options);
  }

  private async doDelete(target: VideoEntry): Promise<void> {
    if (this.deleting) {
      return;
    }
    this.deleting = true;
    this.showToast('正在删除…');
    try {
      await SmbService.getInstance().deleteEntry(target.path, target.isDirectory);
      hilog.info(0x0000, 'NasPlayer', 'delete ok path=%{public}s', target.path);
      this.deleteTarget = undefined;
      this.showToast('已删除：' + target.name);
      await this.load(this.currentPath, true);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      hilog.error(0x0000, 'NasPlayer', 'delete failed path=%{public}s err=%{public}s', target.path, msg);
      this.showToast('删除失败：' + msg);
    } finally {
      this.deleting = false;
    }
  }

  build() {
    NavDestination() {
      Stack() {
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
          } else {
            Refresh({ refreshing: $$this.refreshing }) {
              List({ space: 8 }) {
                LazyForEach(this.source, (item: VideoEntry) => {
                  ListItem() {
                    VideoCell({
                      path: item.path,
                      name: item.name,
                      fileSize: item.size,
                      isDir: item.isDirectory,
                      modifiedTime: item.modifiedTime
                    })
                  }
                  .onClick(() => {
                    this.openEntry(item);
                  })
                  .gesture(
                    LongPressGesture({ repeat: false, duration: 500 })
                      .onAction(() => {
                        if (!this.deleting) {
                          this.deleteTarget = item;
                        }
                      })
                  )
                }, (item: VideoEntry) => item.path)
              }
              .padding({ left: 14, right: 14, bottom: 14 })
              .width('100%')
              .layoutWeight(1)
              .scrollBar(BarState.Off)
            }
            .onRefreshing(() => {
              this.refreshing = true;
              this.load(this.currentPath, true).finally(() => {
                this.refreshing = false;
              });
            })
            .layoutWeight(1)
            .width('100%')
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.theme_bg'))

        if (this.deleteTarget !== undefined) {
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor('#80000000')
              .onClick(() => {
                if (!this.deleting) {
                  this.deleteTarget = undefined;
                }
              })

            Column({ space: 14 }) {
              Text(this.deleteName())
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_main'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.deleteHint())
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              // 操作按钮区：后续新增操作（重命名/移动等）在此追加按钮
              Column({ space: 10 }) {
                Button(this.deleting ? '删除中…' : '删除')
                  .width('100%')
                  .height(42)
                  .fontSize(15)
                  .backgroundColor($r('app.color.text_error'))
                  .enabled(!this.deleting)
                  .onClick(() => {
                    this.confirmDelete();
                  })
              }
              .width('100%')
              Button('取消')
                .width('100%')
                .height(42)
                .fontSize(15)
                .backgroundColor($r('app.color.button_cancel_bg'))
                .fontColor($r('app.color.text_main'))
                .onClick(() => {
                  this.deleteTarget = undefined;
                })
            }
            .width(300)
            .padding(20)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(16)
            .offset({ y: -40 })
          }
          .width('100%')
          .height('100%')
        }
      }
      .width('100%')
      .height('100%')
    }
    .title(this.currentPath.length > 0 ? this.currentPath.split('\\').pop() ?? '文件浏览' : '文件浏览')
    .hideTitleBar(false)
    .onBackPressed(() => {
      return this.goBack();
    })
    .onReady((ctx: NavDestinationContext) => {
      this.navCtx = ctx;
    })
  }
}
