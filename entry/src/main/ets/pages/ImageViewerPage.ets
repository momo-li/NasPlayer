import { image } from '@kit.ImageKit';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VideoEntry } from '../model/VideoEntry';
import { ImageViewerParams } from '../model/RouteParams';
import { ImageLoader } from '../service/ImageLoader';

const DOMAIN = 0x0000;
const TAG = 'NasPlayer';
const MAX_ZOOM = 4;
const DOUBLE_TAP_ZOOM = 2.5;
const ZOOM_EPS = 1.01;

class ImageDataSource implements IDataSource {
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
struct ImageCell {
  @Prop path: string = '';
  loader: ImageLoader | undefined = undefined;
  onZoomChange: (zoomed: boolean) => void = (zoomed: boolean) => {};

  @State pixelMap: image.PixelMap | undefined = undefined;
  @State failed: boolean = false;
  @State errorText: string = '';
  @State zoomScale: number = 1;
  @State panX: number = 0;
  @State panY: number = 0;

  private alive: boolean = true;
  private baseScale: number = 1;
  private areaW: number = 0;
  private areaH: number = 0;
  private lastZoomed: boolean = false;
  private touchPan: boolean = false;
  private lastTouchX: number = 0;
  private lastTouchY: number = 0;

  aboutToAppear(): void {
    this.startLoad();
  }

  aboutToDisappear(): void {
    this.alive = false;
  }

  private async startLoad(): Promise<void> {
    const l = this.loader;
    if (l === undefined) {
      return;
    }
    this.failed = false;
    this.errorText = '';
    try {
      const pm = await l.load(this.path);
      if (!this.alive) {
        return;
      }
      this.pixelMap = pm;
    } catch (e) {
      if (!this.alive) {
        return;
      }
      this.pixelMap = undefined;
      this.failed = true;
      this.errorText = e instanceof Error ? e.message : '图片加载失败';
      hilog.warn(DOMAIN, TAG, 'image cell load failed path=%{public}s err=%{public}s', this.path,
        this.errorText);
    }
  }

  private retry(): void {
    this.pixelMap = undefined;
    this.failed = false;
    this.startLoad();
  }

  private notifyZoom(): void {
    const z = this.zoomScale > ZOOM_EPS;
    if (z !== this.lastZoomed) {
      this.lastZoomed = z;
      this.onZoomChange(z);
    }
  }

  private resetZoom(): void {
    this.zoomScale = 1;
    this.panX = 0;
    this.panY = 0;
    this.touchPan = false;
    this.notifyZoom();
  }

  private clampPan(v: number, area: number): number {
    const max = Math.max(0, area * (this.zoomScale - 1) / 2);
    return Math.min(Math.max(v, -max), max);
  }

  private updateArea(area: Area): void {
    const w = area.width;
    const h = area.height;
    if (typeof w === 'number') {
      this.areaW = w;
    }
    if (typeof h === 'number') {
      this.areaH = h;
    }
  }

  /** 放大后用 onTouch 平移（此时页面已 disableSwipe，不与 Swiper 争抢手势） */
  private handleTouch(event: TouchEvent): void {
    if (this.zoomScale <= ZOOM_EPS || event.touches.length !== 1) {
      this.touchPan = false;
      return;
    }
    const t = event.touches[0];
    if (event.type === TouchType.Down) {
      this.touchPan = true;
      this.lastTouchX = t.x;
      this.lastTouchY = t.y;
      return;
    }
    if (event.type === TouchType.Move && this.touchPan) {
      const dx = t.x - this.lastTouchX;
      const dy = t.y - this.lastTouchY;
      this.lastTouchX = t.x;
      this.lastTouchY = t.y;
      this.panX = this.clampPan(this.panX + dx, this.areaW);
      this.panY = this.clampPan(this.panY + dy, this.areaH);
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.touchPan = false;
    }
  }

  @Builder
  imageContent() {
    if (this.pixelMap !== undefined) {
      Image(this.pixelMap)
        .objectFit(ImageFit.Contain)
        .width('100%')
        .height('100%')
        .scale({ x: this.zoomScale, y: this.zoomScale })
        .translate({ x: this.panX, y: this.panY })
    } else if (this.failed) {
      Column({ space: 14 }) {
        Text(this.errorText)
          .fontSize(14)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .padding({ left: 30, right: 30 })
        Text('点击重试')
          .fontSize(14)
          .fontColor(Color.White)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor('rgba(255,255,255,0.18)')
          .borderRadius(16)
          .onClick(() => {
            this.retry();
          })
      }
    } else {
      Column({ space: 10 }) {
        LoadingProgress()
          .width(44)
          .height(44)
          .color(Color.White)
        Text('加载中…')
          .fontSize(13)
          .fontColor(Color.White)
      }
    }
  }

  build() {
    Column() {
      this.imageContent()
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      this.updateArea(newArea);
    })
    .onTouch((event: TouchEvent) => {
      this.handleTouch(event);
    })
    .gesture(
      GestureGroup(GestureMode.Parallel,
        PinchGesture({ fingers: 2, distance: 3 })
          .onActionStart(() => {
            this.baseScale = this.zoomScale;
          })
          .onActionUpdate((event: GestureEvent) => {
            this.zoomScale = Math.min(MAX_ZOOM, Math.max(1, this.baseScale * event.scale));
            this.panX = this.clampPan(this.panX, this.areaW);
            this.panY = this.clampPan(this.panY, this.areaH);
            this.notifyZoom();
          })
          .onActionEnd(() => {
            if (this.zoomScale <= ZOOM_EPS) {
              this.resetZoom();
            } else {
              this.notifyZoom();
            }
          }),
        TapGesture({ count: 2 })
          .onAction(() => {
            if (this.zoomScale > ZOOM_EPS) {
              this.resetZoom();
            } else {
              this.zoomScale = DOUBLE_TAP_ZOOM;
              this.notifyZoom();
            }
          })
      )
    )
  }
}

@Component
export default struct ImageViewerPage {
  params: ImageViewerParams = { files: [], index: 0 };
  private navCtx: NavDestinationContext | undefined = undefined;
  private loader: ImageLoader = new ImageLoader();
  private source: ImageDataSource = new ImageDataSource();
  private hideTimer: number = -1;
  private safeAreaListening: boolean = false;
  private startIndex: number = 0;

  @State files: VideoEntry[] = [];
  @State currentIndex: number = 0;
  @State zoomed: boolean = false;
  @State controlsVisible: boolean = true;
  @State topSafeHeight: number = 0;

  aboutToAppear(): void {
    const p = this.params;
    if (p !== undefined && p !== null && p.files !== undefined && p.files !== null && p.files.length > 0) {
      this.files = p.files;
      if (p.index >= 0 && p.index < p.files.length) {
        this.startIndex = p.index;
      }
    }
    this.currentIndex = this.startIndex;
    this.source.setData(this.files);
    this.updateProtected();
    this.enterImmersive();
    this.showControlsTemporarily();
    hilog.info(DOMAIN, TAG, 'image viewer open total=%{public}d index=%{public}d', this.files.length,
      this.currentIndex);
  }

  aboutToDisappear(): void {
    hilog.info(DOMAIN, TAG, 'image viewer close');
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    this.exitImmersive();
    this.loader.clear();
  }

  private enterImmersive(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = ctx.windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true);
      win.setWindowSystemBarEnable([]);
      this.updateSafeArea(win);
      setTimeout(() => {
        this.updateSafeArea(win);
      }, 500);
      if (!this.safeAreaListening) {
        this.safeAreaListening = true;
        win.on('avoidAreaChange', (data) => {
          if (data.type === window.AvoidAreaType.TYPE_SYSTEM ||
            data.type === window.AvoidAreaType.TYPE_CUTOUT ||
            data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
            this.updateSafeArea(win);
          }
        });
      }
    } catch (e) {
      console.error('enter immersive failed: ' + JSON.stringify(e));
    }
  }

  private exitImmersive(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = ctx.windowStage.getMainWindowSync();
      if (this.safeAreaListening) {
        this.safeAreaListening = false;
        win.off('avoidAreaChange');
      }
      win.setWindowLayoutFullScreen(false);
      win.setWindowSystemBarEnable(['status', 'navigation']);
    } catch (e) {
      console.error('exit immersive failed: ' + JSON.stringify(e));
    }
  }

  /** 顶部避让区：全屏时状态栏隐藏，挖孔（TYPE_CUTOUT）与系统区取最大，px→vp */
  private updateSafeArea(win: window.Window): void {
    try {
      const ui = this.getUIContext();
      let top = 0;
      try {
        const cutout = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
        top = Math.max(top, cutout.topRect.height);
      } catch (e) {
        console.error('get cutout area failed: ' + JSON.stringify(e));
      }
      try {
        const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        top = Math.max(top, sys.topRect.height);
      } catch (e) {
        console.error('get system area failed: ' + JSON.stringify(e));
      }
      this.topSafeHeight = ui.px2vp(top);
    } catch (e) {
      console.error('update safe area failed: ' + JSON.stringify(e));
    }
  }

  private updateProtected(): void {
    const paths: string[] = [];
    const i = this.currentIndex;
    if (i - 1 >= 0 && i - 1 < this.files.length) {
      paths.push(this.files[i - 1].path);
    }
    if (i >= 0 && i < this.files.length) {
      paths.push(this.files[i].path);
    }
    if (i + 1 >= 0 && i + 1 < this.files.length) {
      paths.push(this.files[i + 1].path);
    }
    this.loader.setProtected(paths);
  }

  private titleText(): string {
    if (this.currentIndex >= 0 && this.currentIndex < this.files.length) {
      return this.files[this.currentIndex].name;
    }
    return '';
  }

  private counterText(): string {
    if (this.files.length === 0) {
      return '';
    }
    return (this.currentIndex + 1) + ' / ' + this.files.length;
  }

  private showControlsTemporarily(): void {
    this.controlsVisible = true;
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
    }
    this.hideTimer = setTimeout(() => {
      this.hideTimer = -1;
      this.controlsVisible = false;
    }, 3000);
  }

  private toggleControls(): void {
    if (this.controlsVisible) {
      this.controlsVisible = false;
      if (this.hideTimer >= 0) {
        clearTimeout(this.hideTimer);
        this.hideTimer = -1;
      }
    } else {
      this.showControlsTemporarily();
    }
  }

  private goBack(): void {
    const ctx = this.navCtx;
    if (ctx !== undefined) {
      ctx.pathStack.pop();
    }
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Swiper() {
          LazyForEach(this.source, (item: VideoEntry) => {
            ImageCell({
              path: item.path,
              loader: this.loader,
              onZoomChange: (zoomed: boolean) => {
                this.zoomed = zoomed;
              }
            })
          }, (item: VideoEntry) => item.path)
        }
        .index(this.startIndex)
        .vertical(true)
        .loop(false)
        .indicator(false)
        .cachedCount(1)
        .disableSwipe(this.zoomed)
        .duration(200)
        .width('100%')
        .height('100%')
        .onChange((index: number) => {
          this.currentIndex = index;
          this.zoomed = false;
          this.updateProtected();
          this.showControlsTemporarily();
        })

        if (this.controlsVisible) {
          Row({ space: 4 }) {
            Text('‹')
              .fontSize(30)
              .fontColor(Color.White)
              .padding({ left: 10, right: 10, top: 2, bottom: 4 })
              .onClick(() => {
                this.goBack();
              })
            Column({ space: 2 }) {
              Text(this.titleText())
                .fontSize(14)
                .fontColor(Color.White)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.counterText())
                .fontSize(11)
                .fontColor('rgba(255,255,255,0.72)')
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 6, right: 16, top: this.topSafeHeight + 8, bottom: 10 })
          .backgroundColor($r('app.color.player_overlay'))
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.player_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onClick(() => {
        this.toggleControls();
      })
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.player_bg'))
    .onReady((ctx: NavDestinationContext) => {
      this.navCtx = ctx;
    })
    .onShown(() => {
      this.enterImmersive();
    })
    .onHidden(() => {
      this.exitImmersive();
    })
  }
}
