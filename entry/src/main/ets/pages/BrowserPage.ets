import { hilog } from '@kit.PerformanceAnalysisKit';
import { VideoEntry } from '../model/VideoEntry';
import { BrowserParams, ImageViewerParams, PlayerParams, AudioPlayerParams } from '../model/RouteParams';
import { SmbService } from '../service/SmbService';
import { MediaUtil } from '../service/MediaUtil';

/** 列表排序字段 */
enum SortKey {
  Name = 0,
  Time = 1,
  Size = 2
}

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
    const parts: string[] = [];
    if (this.isDir) {
      parts.push('文件夹');
    } else {
      parts.push(MediaUtil.formatSize(this.fileSize));
    }
    if (this.modifiedTime > 0) {
      parts.push(MediaUtil.formatTime(this.modifiedTime));
    }
    return parts.join('  ·  ');
  }
}

@Component
export default struct BrowserPage {
  params: BrowserParams = { sharePath: '' };
  private navCtx: NavDestinationContext | undefined = undefined;
  private source: VideoDataSource = new VideoDataSource();
  /** 列表滚动控制器：用于恢复各目录上次浏览位置 */
  private listScroller: Scroller = new Scroller();
  /** 目录路径 → 上次离开时列表首项索引 */
  private topIndexMap: Map<string, number> = new Map<string, number>();
  /** 当前列表显示的首项索引（随滚动更新） */
  private curTopIndex: number = 0;
  /** 待恢复的目标索引，< 0 表示无需恢复 */
  private pendingRestoreIndex: number = -1;
  private scrollAttempts: number = 0;
  /** 当前排序字段与方向；默认 名称·升序，文件夹始终优先 */
  @State sortKey: number = SortKey.Name;
  @State sortAsc: boolean = true;
  /** 当前目录的原始（未排序）列表：切换排序时复用，避免重新走 SMB */
  private rawList: VideoEntry[] = [];
  @State currentPath: string = '';
  @State loading: boolean = false;
  @State errorText: string = '';
  @State emptyText: string = '';
  @State refreshing: boolean = false;
  /** 长按选中的条目：操作面板（重命名/删除等）的目标 */
  @State actionTarget: VideoEntry | undefined = undefined;
  @State deleting: boolean = false;
  @State renameTarget: VideoEntry | undefined = undefined;
  @State renameText: string = '';
  @State renaming: boolean = false;

  aboutToAppear(): void {
    this.load(this.params.sharePath);
  }

  private showToast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  /** silent=true 用于下拉刷新/删除后刷新：不切到全屏“加载中”，保持列表与 Refresh 组件在场，
   *  否则 Refresh 会在刷新过程中被销毁，既看不到刷新动画、也拿不到刷新手势的完整状态 */
  async load(path: string, force: boolean = false, silent: boolean = false): Promise<void> {
    if (!silent) {
      this.loading = true;
    }
    // 先记下目标路径：这样失败后的重试/刷新仍指向同一个目录，而不是停留在上一次成功的路径
    this.currentPath = path;
    this.errorText = '';
    this.emptyText = '';
    if (!silent) {
      // 进入目录（含返回上级）时恢复该目录上次浏览到的位置
      const saved = this.topIndexMap.get(path);
      this.pendingRestoreIndex = saved !== undefined && saved > 0 ? saved : -1;
      this.curTopIndex = 0;
    }
    try {
      const list = await SmbService.getInstance().readdir(path, force);
      this.rawList = list;
      this.source.setData(BrowserPage.sortEntries(list, this.sortKey, this.sortAsc));
      if (list.length === 0) {
        this.emptyText = '目录为空';
        this.pendingRestoreIndex = -1;
      } else if (this.pendingRestoreIndex >= list.length) {
        this.pendingRestoreIndex = list.length - 1;
      }
    } catch (e) {
      this.errorText = '加载失败，请确认连接是否正常';
      this.pendingRestoreIndex = -1;
    } finally {
      this.loading = false;
    }
    if (this.pendingRestoreIndex >= 0) {
      this.restorePosition();
    }
  }

  /** 记录当前目录的滚动位置，供下次进入（返回上级）时恢复 */
  private rememberPosition(): void {
    this.topIndexMap.set(this.currentPath, this.curTopIndex);
  }

  /** 排序副本：readdir 返回的是 SMB 目录缓存的数组本体，绝不能原地排序，否则会污染其他调用方 */
  private static sortEntries(src: VideoEntry[], key: number, asc: boolean): VideoEntry[] {
    const out: VideoEntry[] = src.slice();
    out.sort((a: VideoEntry, b: VideoEntry): number => {
      if (a.isDirectory !== b.isDirectory) {
        // 文件夹始终优先，与排序字段无关
        return a.isDirectory ? -1 : 1;
      }
      let d = 0;
      if (key === SortKey.Time) {
        d = a.modifiedTime - b.modifiedTime;
      } else if (key === SortKey.Size) {
        d = a.size - b.size;
      } else {
        d = a.name.localeCompare(b.name);
      }
      return asc ? d : -d;
    });
    return out;
  }

  /** 点击排序栏：同一字段切换升降序；换字段则用该字段的默认方向 */
  private setSort(key: number): void {
    if (this.sortKey === key) {
      this.sortAsc = !this.sortAsc;
    } else {
      this.sortKey = key;
      // 名称默认升序；时间/大小默认降序（新的在前、大的在前）
      this.sortAsc = key === SortKey.Name;
    }
    this.applySort();
  }

  /** 重排当前目录：位置索引已被打乱，先清空“返回上级恢复位置”的缓存，再回到列表顶部 */
  private applySort(): void {
    this.topIndexMap.clear();
    this.curTopIndex = 0;
    this.pendingRestoreIndex = -1;
    this.source.setData(BrowserPage.sortEntries(this.rawList, this.sortKey, this.sortAsc));
    try {
      this.listScroller.scrollToIndex(0);
    } catch (e) {
      hilog.warn(0x0000, 'NasPlayer', 'sort scroll to top failed: %{public}s', String(e));
    }
  }

  /** 列表重建后恢复滚动位置；列表首帧可能尚未完成布局，失败则重试几次 */
  private restorePosition(): void {
    this.scrollAttempts = 0;
    this.tryScrollToIndex(this.pendingRestoreIndex);
  }

  private tryScrollToIndex(target: number): void {
    if (target < 0 || this.pendingRestoreIndex !== target) {
      return;
    }
    try {
      this.listScroller.scrollToIndex(target);
    } catch (e) {
      hilog.warn(0x0000, 'NasPlayer', 'restore scroll failed: %{public}s', String(e));
    }
    this.scrollAttempts++;
    if (this.scrollAttempts >= 3) {
      this.pendingRestoreIndex = -1;
      return;
    }
    setTimeout(() => {
      this.tryScrollToIndex(target);
    }, 80);
  }

  /** 返回上级目录；无上级目录（共享根）时返回 false 让系统退出页面 */
  private goBack(): boolean {
    const cur = this.currentPath;
    if (cur.length === 0) {
      return false;
    }
    this.rememberPosition();
    const idx = cur.lastIndexOf('\\');
    // 单级目录（无 \）返回根目录；多级目录返回上一级
    const parent = idx < 0 ? '' : (idx === 0 ? '' : cur.substring(0, idx));
    this.load(parent);
    return true;
  }

  private openEntry(entry: VideoEntry): void {
    if (entry.isDirectory) {
      this.rememberPosition();
      this.load(entry.path);
      return;
    }
    if (MediaUtil.isImage(entry.name)) {
      this.openImages(entry);
      return;
    }
    if (MediaUtil.isAudio(entry.name)) {
      this.openAudios(entry);
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

  private openAudios(entry: VideoEntry): void {
    const audios: VideoEntry[] = [];
    for (let i = 0; i < this.source.totalCount(); i++) {
      const item = this.source.getData(i);
      if (!item.isDirectory && MediaUtil.isAudio(item.name)) {
        audios.push(item);
      }
    }
    if (audios.length === 0) {
      return;
    }
    let index = 0;
    for (let i = 0; i < audios.length; i++) {
      if (audios[i].path === entry.path) {
        index = i;
        break;
      }
    }
    const p: AudioPlayerParams = { files: audios, index: index };
    if (this.navCtx !== undefined) {
      this.navCtx.pathStack.pushPathByName('AudioPlayer', p);
    }
  }

  private actionName(): string {
    const t = this.actionTarget;
    return t !== undefined ? t.name : '';
  }

  private actionHint(): string {
    const t = this.actionTarget;
    if (t === undefined) {
      return '';
    }
    if (t.isDirectory) {
      return '文件夹';
    }
    return MediaUtil.formatSize(t.size) + '  ·  ' + MediaUtil.formatTime(t.modifiedTime);
  }

  /** 删除前二次确认 */
  private confirmDelete(): void {
    const target = this.actionTarget;
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
      this.actionTarget = undefined;
      this.showToast('已删除：' + target.name);
      await this.load(this.currentPath, true, true);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      hilog.error(0x0000, 'NasPlayer', 'delete failed path=%{public}s err=%{public}s', target.path, msg);
      this.showToast('删除失败：' + msg);
    } finally {
      this.deleting = false;
    }
  }

  /** 打开重命名弹窗（关闭操作面板） */
  private startRename(): void {
    const target = this.actionTarget;
    if (target === undefined || this.deleting) {
      return;
    }
    this.actionTarget = undefined;
    this.renameText = target.name;
    this.renameTarget = target;
  }

  private static validateName(name: string): string {
    if (name.length === 0) {
      return '名称不能为空';
    }
    if (name === '.' || name === '..') {
      return '名称无效';
    }
    const invalid = '\\/:*?"<>|';
    for (let i = 0; i < name.length; i++) {
      if (invalid.indexOf(name.charAt(i)) >= 0) {
        return '名称不能包含 \\ / : * ? " < > | 字符';
      }
    }
    return '';
  }

  private async doRename(): Promise<void> {
    const target = this.renameTarget;
    if (target === undefined || this.renaming) {
      return;
    }
    const name = this.renameText.trim();
    const err = BrowserPage.validateName(name);
    if (err.length > 0) {
      this.showToast(err);
      return;
    }
    if (name === target.name) {
      this.renameTarget = undefined;
      return;
    }
    this.renaming = true;
    try {
      await SmbService.getInstance().renameEntry(target.path, name, target.isDirectory);
      hilog.info(0x0000, 'NasPlayer', 'rename ok path=%{public}s newName=%{public}s', target.path, name);
      this.renameTarget = undefined;
      this.showToast('已重命名为：' + name);
      await this.load(this.currentPath, true, true);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      hilog.error(0x0000, 'NasPlayer', 'rename failed path=%{public}s err=%{public}s', target.path, msg);
      this.showToast('重命名失败：' + msg);
    } finally {
      this.renaming = false;
    }
  }

  /** 排序栏：名称/时间/大小，当前项高亮并显示升降序箭头 */
  @Builder
  SortBar() {
    Row({ space: 8 }) {
      this.SortChip('名称', SortKey.Name)
      this.SortChip('时间', SortKey.Time)
      this.SortChip('大小', SortKey.Size)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 4, bottom: 8 })
  }

  @Builder
  SortChip(label: string, key: number) {
    Row({ space: 2 }) {
      Text(label)
        .fontSize(13)
        .fontColor(this.sortKey === key ? $r('app.color.theme_primary') : $r('app.color.text_secondary'))
      if (this.sortKey === key) {
        Text(this.sortAsc ? '↑' : '↓')
          .fontSize(12)
          .fontColor($r('app.color.theme_primary'))
      }
    }
    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
    .backgroundColor(this.sortKey === key ? '#141E88E5' : $r('app.color.card_bg'))
    .borderRadius(14)
    .onClick(() => {
      this.setSort(key);
    })
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
                  this.load(this.currentPath, true, true);
                })
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          } else if (this.emptyText.length > 0) {
            Column({ space: 10 }) {
              Text(this.emptyText)
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
              Button('刷新')
                .fontSize(14)
                .height(36)
                .backgroundColor($r('app.color.theme_primary'))
                .onClick(() => {
                  this.load(this.currentPath, true, true);
                })
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          } else {
            Column() {
              this.SortBar()
              Refresh({ refreshing: $$this.refreshing }) {
                List({ space: 8, scroller: this.listScroller }) {
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
                          if (!this.deleting && !this.renaming) {
                            this.actionTarget = item;
                          }
                        })
                    )
                  }, (item: VideoEntry) => item.path)
                }
                .padding({ left: 14, right: 14, bottom: 14 })
                .width('100%')
                .layoutWeight(1)
                .scrollBar(BarState.Off)
                .onScrollIndex((first: number) => {
                  this.curTopIndex = first;
                })
              }
              .onRefreshing(() => {
                this.refreshing = true;
                this.load(this.currentPath, true, true).finally(() => {
                  this.refreshing = false;
                });
              })
              .layoutWeight(1)
              .width('100%')
            }
            .width('100%')
            .layoutWeight(1)
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.theme_bg'))

        if (this.actionTarget !== undefined) {
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor('#80000000')
              .onClick(() => {
                if (!this.deleting) {
                  this.actionTarget = undefined;
                }
              })

            Column({ space: 14 }) {
              Text(this.actionName())
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_main'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.actionHint())
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              // 操作按钮区：后续新增操作（移动/复制等）在此追加按钮
              Column({ space: 10 }) {
                Button('重命名')
                  .width('100%')
                  .height(42)
                  .fontSize(15)
                  .backgroundColor($r('app.color.theme_primary'))
                  .enabled(!this.deleting)
                  .onClick(() => {
                    this.startRename();
                  })
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
                  this.actionTarget = undefined;
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

        if (this.renameTarget !== undefined) {
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor('#80000000')
              .onClick(() => {
                if (!this.renaming) {
                  this.renameTarget = undefined;
                }
              })

            Column({ space: 14 }) {
              Text('重命名')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_main'))
                .width('100%')
              TextInput({ placeholder: '新名称', text: this.renameText })
                .width('100%')
                .height(44)
                .fontSize(15)
                .maxLength(255)
                .enterKeyType(EnterKeyType.Done)
                .onChange((value: string) => {
                  this.renameText = value;
                })
                .onSubmit(() => {
                  this.doRename();
                })
              Row({ space: 12 }) {
                Button('取消')
                  .layoutWeight(1)
                  .height(42)
                  .fontSize(15)
                  .backgroundColor($r('app.color.button_cancel_bg'))
                  .fontColor($r('app.color.text_main'))
                  .enabled(!this.renaming)
                  .onClick(() => {
                    this.renameTarget = undefined;
                  })
                Button(this.renaming ? '重命名中…' : '确定')
                  .layoutWeight(1)
                  .height(42)
                  .fontSize(15)
                  .backgroundColor($r('app.color.theme_primary'))
                  .enabled(!this.renaming)
                  .onClick(() => {
                    this.doRename();
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
