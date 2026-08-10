import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { settings } from '@kit.BasicServicesKit';
import { VideoEntry } from '../model/VideoEntry';
import { PlayerParams } from '../model/RouteParams';
import { StreamServer } from '../service/StreamServer';
import { MediaUtil } from '../service/MediaUtil';

@Component
export default struct PlayerPage {
  params: PlayerParams = { files: [], index: 0 };
  private xController: XComponentController = new XComponentController();
  private avPlayer: media.AVPlayer | undefined = undefined;
  private surfaceId: string = '';
  private switchInProgress: boolean = false;
  private hideTimer: number = -1;
  private dragging: boolean = false;
  private startupDone: boolean = false;
  private destroyed: boolean = false;
  @State isLandscape: boolean = false;
  private resumePosition: number = 0;

  @State videoFiles: VideoEntry[] = [];
  @State index: number = 0;
  @State playing: boolean = false;
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State completed: boolean = false;
  @State currentTime: number = 0;
  @State duration: number = 0;
  @State controlsVisible: boolean = true;
  @State speedIdx: number = 1;
  @State scaleIdx: number = 0;
  @State xScale: number = 1;
  @State yScale: number = 1;
  @State screenBrightness: number = 0.8;
  @State brightnessPanel: boolean = false;
  // 挖孔/刘海安全区避让高度（vp）
  @State topSafeHeight: number = 0;
  @State bottomSafeHeight: number = 0;
  private safeAreaListening: boolean = false;

  private scaleValues: media.VideoScaleType[] = [
    media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT,
    media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP
  ];
  private scaleLabels: string[] = ['适应', '裁剪'];

  private speedValues: media.PlaybackSpeed[] = [
    media.PlaybackSpeed.SPEED_FORWARD_0_75_X,
    media.PlaybackSpeed.SPEED_FORWARD_1_00_X,
    media.PlaybackSpeed.SPEED_FORWARD_1_25_X,
    media.PlaybackSpeed.SPEED_FORWARD_1_50_X,
    media.PlaybackSpeed.SPEED_FORWARD_2_00_X
  ];
  private speedLabels: string[] = ['0.75x', '1.0x', '1.25x', '1.5x', '2.0x'];

  aboutToAppear(): void {
    const p = this.params;
    if (p !== undefined && p !== null && p.files !== undefined && p.files !== null && p.files.length > 0) {
      this.videoFiles = p.files;
      this.index = p.index;
    }
    // 根据当前状态决定全屏/显示系统栏
    this.applyFullscreenState();
  }

  private updateScale(): void {
    const p = this.avPlayer;
    this.xScale = 1;
    this.yScale = 1;
    if (p === undefined) {
      return;
    }
    // 横竖屏统一遵循用户选择的缩放模式（适应/裁剪）
    const type: media.VideoScaleType = this.scaleValues[this.scaleIdx];
    try {
      p.videoScaleType = type;
    } catch (e) {
      console.error('set scale failed: ' + JSON.stringify(e));
    }
  }

  aboutToDisappear(): void {
    hilog.info(0x0000, 'NasPlayer', 'player aboutToDisappear');
    this.exitLandscape();
    this.exitFullscreen();
    this.cleanup();
  }

  onPageHide(): void {
    hilog.info(0x0000, 'NasPlayer', 'player onPageHide');
    this.exitLandscape();
    this.exitFullscreen();
    this.pauseIfPlaying();
  }

  private onWillDisappear(): void {
    hilog.info(0x0000, 'NasPlayer', 'player onWillDisappear');
    this.exitLandscape();
    this.exitFullscreen();
    this.cleanup();
  }

  private showToast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private async readBrightness(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const raw = settings.getValueSync(ctx, settings.display.SCREEN_BRIGHTNESS_STATUS, '128');
      const v = Number(raw);
      if (v > 0) {
        this.screenBrightness = v / 255;
      }
    } catch (e) {
      console.error('get brightness failed: ' + JSON.stringify(e));
    }
  }

  private async setBrightness(v: number): Promise<void> {
    this.screenBrightness = v;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = ctx.windowStage.getMainWindowSync();
      win.setWindowBrightness(v);
    } catch (e) {
      console.error('set brightness failed: ' + JSON.stringify(e));
    }
  }

  private toggleBrightnessPanel(): void {
    this.showControlsTemporarily();
    this.brightnessPanel = !this.brightnessPanel;
    if (this.brightnessPanel) {
      this.readBrightness();
    }
  }

  /** 根据状态决定全屏/显示系统栏：裁剪模式或横屏时全屏，适应模式竖屏时显示系统栏 */
  private applyFullscreenState(): void {
    const needFullscreen: boolean = this.isLandscape || this.scaleIdx === 1;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = ctx.windowStage.getMainWindowSync();
      if (needFullscreen) {
        win.setWindowLayoutFullScreen(true);
        win.setWindowSystemBarEnable([]);
        // 全屏布局异步生效，延迟读取避让区确保拿到真实值
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
      } else {
        // 竖屏适应模式：显示状态栏/导航栏，正常布局
        if (this.safeAreaListening) {
          this.safeAreaListening = false;
          win.off('avoidAreaChange');
        }
        this.topSafeHeight = 0;
        this.bottomSafeHeight = 0;
        win.setWindowLayoutFullScreen(false);
        win.setWindowSystemBarEnable(['status', 'navigation']);
      }
    } catch (e) {
      console.error('apply fullscreen state failed: ' + JSON.stringify(e));
    }
  }

  /** 读取系统避让区（挖孔/刘海/手势条），换算为 vp 供 UI padding 使用 */
  private updateSafeArea(win: window.Window): void {
    try {
      const ui = this.getUIContext();
      let top = 0;
      let bottom = 0;
      // 挖孔/刘海区域（前置摄像头）——全屏时状态栏隐藏，TYPE_SYSTEM 可能为 0，必须用 TYPE_CUTOUT
      try {
        const cutout = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
        top = Math.max(top, cutout.topRect.height);
      } catch (e) {
        console.error('get cutout area failed: ' + JSON.stringify(e));
      }
      // 系统避让区（状态栏兜底）
      try {
        const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        top = Math.max(top, sys.topRect.height);
        bottom = Math.max(bottom, sys.bottomRect.height);
      } catch (e) {
        console.error('get system area failed: ' + JSON.stringify(e));
      }
      // 底部导航指示条
      try {
        const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        bottom = Math.max(bottom, nav.bottomRect.height);
      } catch (e) {
        console.error('get nav indicator failed: ' + JSON.stringify(e));
      }
      this.topSafeHeight = ui.px2vp(top);
      this.bottomSafeHeight = ui.px2vp(bottom);
      hilog.info(0x0000, 'NasPlayer', 'safe area updated top=%{public}d bottom=%{public}d',
        top, bottom);
    } catch (e) {
      console.error('update safe area failed: ' + JSON.stringify(e));
    }
  }

  /** 退出全屏：恢复状态栏/导航栏显示，恢复正常布局 */
  private exitFullscreen(): void {
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
      console.error('exit fullscreen failed: ' + JSON.stringify(e));
    }
  }

  private async enterLandscape(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = ctx.windowStage.getMainWindowSync();
      win.setPreferredOrientation(window.Orientation.LANDSCAPE);
      this.isLandscape = true;
      this.updateScale();
      this.applyFullscreenState();
    } catch (e) {
      console.error('enter landscape failed: ' + JSON.stringify(e));
    }
  }

  private async exitLandscape(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = ctx.windowStage.getMainWindowSync();
      win.setPreferredOrientation(window.Orientation.PORTRAIT);
      this.isLandscape = false;
      this.updateScale();
      this.applyFullscreenState();
    } catch (e) {
      console.error('exit landscape failed: ' + JSON.stringify(e));
    }
  }

  private async toggleLandscape(): Promise<void> {
    if (this.isLandscape) {
      await this.exitLandscape();
    } else {
      await this.enterLandscape();
    }
    this.showControlsTemporarily();
  }

  private async cleanup(): Promise<void> {
    hilog.info(0x0000, 'NasPlayer', 'player cleanup start, hasPlayer=%{public}s', String(this.avPlayer !== undefined));
    this.destroyed = true;
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = ctx.windowStage.getMainWindowSync();
      win.setWindowBrightness(-1);
    } catch (e) {
      console.error('restore brightness failed: ' + JSON.stringify(e));
    }
    const p = this.avPlayer;
    this.avPlayer = undefined;
    if (p !== undefined) {
      try {
        await p.release();
        hilog.info(0x0000, 'NasPlayer', 'player release done');
      } catch (e) {
        console.error('release player failed: ' + JSON.stringify(e));
      }
    }
    await StreamServer.getInstance().stop();
    hilog.info(0x0000, 'NasPlayer', 'player cleanup done');
  }

  private pauseIfPlaying(): void {
    const p = this.avPlayer;
    if (p !== undefined && this.playing) {
      p.pause();
    }
  }

  private attachEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState) => {
      hilog.info(0x0000, 'NasPlayer', 'avplayer stateChange -> %{public}s', state);
      if (state === 'playing') {
        this.playing = true;
        this.errorMsg = '';
        this.showControlsTemporarily();
      } else if (state === 'paused') {
        this.playing = false;
      } else if (state === 'completed') {
        this.playing = false;
        this.completed = true;
      }
    });
    player.on('timeUpdate', (time: number) => {
      if (!this.dragging) {
        this.currentTime = time;
      }
      if (this.duration === 0) {
        this.duration = player.duration;
      }
    });
    player.on('error', (err: BusinessError) => {
      console.error('player error: ' + JSON.stringify(err));
      // 加载/准备期间出错由 playEntry catch 统一提示，这里避免重复弹提示
      if (!this.loading) {
        this.loading = false;
        this.errorMsg = PlayerPage.describePlayerError(err, StreamServer.getInstance().getLastServeError());
      }
    });
    player.on('endOfStream', () => {
      this.completed = true;
    });
    player.on('videoSizeChange', (width: number, height: number) => {
      if (width > 0 && height > 0) {
        this.updateScale();
      }
    });
  }

  private waitForState(player: media.AVPlayer, target: media.AVPlayerState, timeoutMs: number): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      if (player.state === target) {
        resolve(true);
        return;
      }
      const timer = setTimeout(() => {
        player.off('stateChange', handler);
        hilog.info(0x0000, 'NasPlayer', 'waitForState timeout, want=%{public}s cur=%{public}s',
          target, player.state);
        resolve(false);
      }, timeoutMs);
      const handler = (state: media.AVPlayerState): void => {
        hilog.info(0x0000, 'NasPlayer', 'waitForState see %{public}s want %{public}s', state, target);
        if (state === target) {
          clearTimeout(timer);
          player.off('stateChange', handler);
          resolve(true);
        } else if (state === 'error') {
          clearTimeout(timer);
          player.off('stateChange', handler);
          resolve(false);
        }
      };
      player.on('stateChange', handler);
    });
  }

  private async playEntry(entry: VideoEntry, retryCount: number = 0): Promise<void> {
    hilog.info(0x0000, 'NasPlayer', 'playEntry start, destroyed=%{public}s, surface=%{public}s',
      String(this.destroyed), this.surfaceId);
    if (this.destroyed) {
      return;
    }
    this.loading = true;
    this.errorMsg = '';
    this.completed = false;
    this.currentTime = 0;
    this.duration = 0;
    try {
      await StreamServer.getInstance().start();
      hilog.info(0x0000, 'NasPlayer', 'playEntry: stream server started, port=%{public}d',
        StreamServer.getInstance().getPort());
      let player = this.avPlayer;
      if (player === undefined) {
        player = await media.createAVPlayer();
        this.attachEvents(player);
        this.avPlayer = player;
        hilog.info(0x0000, 'NasPlayer', 'playEntry: avplayer created');
      } else {
        await player.reset();
        hilog.info(0x0000, 'NasPlayer', 'playEntry: avplayer reset');
      }
      if (this.surfaceId.length === 0) {
        throw new Error('视频 surface 未就绪');
      }
      // 预热：提前确保 SMB 连接就绪并缓存文件大小，避免 AVPlayer 请求时等太久。
      // 预热失败直接抛出，快速进入重试，避免在 AVPlayer 阶段白等
      await this.withTimeout(StreamServer.getInstance().warmup(entry.path), 6000, '视频信息加载');
      const url = StreamServer.getInstance().urlFor(entry.path);
      player.url = url;
      hilog.info(0x0000, 'NasPlayer', 'playEntry: url set, state=%{public}s', player.state);
      const ready = await this.waitForState(player, 'initialized', 8000);
      hilog.info(0x0000, 'NasPlayer', 'playEntry: wait initialized ready=%{public}s state=%{public}s',
        String(ready), player.state);
      if (!ready) {
        throw new Error('视频源加载超时');
      }
      player.surfaceId = this.surfaceId;
      // prepare 加超时保护：网络瞬断（如 USB 连接导致 Wi-Fi 闪断）时避免无限卡加载
      await this.prepareWithTimeout(player, 10000);
      hilog.info(0x0000, 'NasPlayer', 'playEntry: prepared, state=%{public}s', player.state);
      this.updateScale();
      this.duration = player.duration;
      if (this.resumePosition > 0) {
        try {
          player.seek(this.resumePosition);
        } catch (e) {
          console.error('seek failed: ' + JSON.stringify(e));
        }
        this.resumePosition = 0;
      }
      if (this.speedIdx !== 1) {
        player.setSpeed(this.speedValues[this.speedIdx]);
      }
      await player.play();
      hilog.info(0x0000, 'NasPlayer', 'playEntry: play() ok, state=%{public}s', player.state);
      this.playing = true;
      this.errorMsg = '';
      this.loading = false;
    } catch (e) {
      console.error('play failed: ' + JSON.stringify(e));
      hilog.error(0x0000, 'NasPlayer', 'playEntry failed: %{public}s', JSON.stringify(e));
      // 网络类失败：静默自动重试（保持加载中，不弹提示），最多 2 次
      if (retryCount < 2 && PlayerPage.isNetworkish(e, StreamServer.getInstance().getLastServeError())) {
        hilog.info(0x0000, 'NasPlayer', 'playEntry network issue, silent retry %{public}d/2', retryCount + 1);
        // 重试前重建播放器，避免残留状态
        try {
          const old = this.avPlayer;
          this.avPlayer = undefined;
          if (old !== undefined) {
            await old.release();
          }
        } catch (e2) {
          console.error('release old player failed: ' + JSON.stringify(e2));
        }
        await new Promise<void>((r) => {
          setTimeout(() => {
            r();
          }, 500);
        });
        await this.playEntry(entry, retryCount + 1);
        return;
      }
      this.loading = false;
      this.errorMsg = PlayerPage.describePlayFailure(e, StreamServer.getInstance().getLastServeError());
    }
  }

  private static isNetworkish(e: Object, serveErr: string): boolean {
    const detail = JSON.stringify(e);
    if (serveErr.length > 0 &&
      (serveErr.indexOf('2303200') >= 0 || serveErr.indexOf('Network') >= 0 ||
        serveErr.indexOf('closed') >= 0 || serveErr.indexOf('超时') >= 0)) {
      return true;
    }
    return detail.indexOf('超时') >= 0 || detail.indexOf('Network') >= 0 ||
      detail.indexOf('closed') >= 0 || detail.indexOf('socket') >= 0 ||
      detail.indexOf('5400102') >= 0 || detail.indexOf('5400103') >= 0;
  }

  private prepareWithTimeout(player: media.AVPlayer, timeoutMs: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error('视频准备超时'));
      }, timeoutMs);
      player.prepare().then(() => {
        clearTimeout(timer);
        resolve();
      }).catch((e: Error) => {
        clearTimeout(timer);
        reject(e);
      });
    });
  }

  private withTimeout<T>(promise: Promise<T>, timeoutMs: number, what: string): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(what + '超时'));
      }, timeoutMs);
      promise.then((v: T) => {
        clearTimeout(timer);
        resolve(v);
      }).catch((e: Error) => {
        clearTimeout(timer);
        reject(e);
      });
    });
  }

  private static describePlayFailure(e: Object, serveErr: string): string {
    if (e instanceof Error) {
      const msg = e.message;
      if (msg.indexOf('surface') >= 0) {
        return '视频画面初始化失败，请重试';
      }
      if (msg.indexOf('超时') >= 0) {
        return '视频加载超时，请检查网络或稍后重试';
      }
      if (msg.indexOf('流服务') >= 0) {
        return '本地流服务启动失败，请重启应用';
      }
    }
    const detail = JSON.stringify(e);
    if (detail.indexOf('5400102') >= 0) {
      if (serveErr.length > 0) {
        return PlayerPage.describeServeError(serveErr);
      }
      return '视频加载失败：无法获取视频数据，请检查网络后重试';
    }
    if (detail.indexOf('5400103') >= 0) {
      return '视频读取失败：网络中断或文件不可读，请检查网络';
    }
    if (detail.indexOf('5400101') >= 0) {
      return '系统内存不足，无法创建播放器';
    }
    return '播放失败，请确认视频格式受支持';
  }

  private static describePlayerError(err: BusinessError, serveErr: string): string {
    if (err.code === 5400102 && serveErr.length > 0) {
      return PlayerPage.describeServeError(serveErr);
    }
    if (err.code === 5400103) {
      return '视频读取失败：网络中断或文件不可读，请检查网络';
    }
    if (err.code === 5400101) {
      return '系统内存不足，无法创建播放器';
    }
    return '播放失败，请确认视频格式受支持';
  }

  private static describeServeError(serveErr: string): string {
    if (serveErr.indexOf('2303200') >= 0 || serveErr.indexOf('Network is down') >= 0) {
      return '网络连接已断开，无法读取视频数据，请检查网络后重试';
    }
    if (serveErr.indexOf('2303111') >= 0 || serveErr.indexOf('unavailable') >= 0) {
      return '本地流服务繁忙，请稍后重试';
    }
    if (serveErr.indexOf('2303199') >= 0 || serveErr.indexOf('Address not available') >= 0) {
      return '无法访问视频文件，请确认文件路径正确';
    }
    return '视频加载失败：本地流服务异常，请重试';
  }

  private playIcon(): string {
    return this.playing ? '暂停' : '播放';
  }

  private async togglePlay(): Promise<void> {
    this.showControlsTemporarily();
    const p = this.avPlayer;
    hilog.info(0x0000, 'NasPlayer', 'togglePlay: player=%{public}s playing=%{public}s state=%{public}s',
      String(p !== undefined), String(this.playing), p !== undefined ? p.state : 'none');
    if (p === undefined) {
      return;
    }
    try {
      const st = p.state;
      if (st === 'playing') {
        await p.pause();
        this.playing = false;
        hilog.info(0x0000, 'NasPlayer', 'togglePlay: pause() ok');
      } else if (st === 'paused' || st === 'prepared' || st === 'completed') {
        await p.play();
        this.playing = true;
        hilog.info(0x0000, 'NasPlayer', 'togglePlay: play() ok');
      } else {
        hilog.info(0x0000, 'NasPlayer', 'togglePlay: state=%{public}s not operable', st);
      }
    } catch (e) {
      console.error('toggle play failed: ' + JSON.stringify(e));
      hilog.error(0x0000, 'NasPlayer', 'togglePlay failed: %{public}s', JSON.stringify(e));
    }
  }

  private cycleSpeed(): void {
    this.speedIdx = (this.speedIdx + 1) % this.speedValues.length;
    const p = this.avPlayer;
    if (p !== undefined) {
      p.setSpeed(this.speedValues[this.speedIdx]);
    }
    this.showControlsTemporarily();
  }

  private cycleScale(): void {
    this.scaleIdx = (this.scaleIdx + 1) % this.scaleValues.length;
    this.updateScale();
    this.applyFullscreenState();
    this.showControlsTemporarily();
  }

  private async switchTo(delta: number): Promise<void> {
    if (this.switchInProgress) {
      return;
    }
    const next = this.index + delta;
    if (next < 0) {
      this.showToast('已经是第一部视频');
      return;
    }
    if (next >= this.videoFiles.length) {
      this.showToast('已经是最后一部视频');
      return;
    }
    this.switchInProgress = true;
    try {
      this.index = next;
      await this.playEntry(this.videoFiles[next]);
    } finally {
      this.switchInProgress = false;
    }
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

  private showControlsTemporarily(): void {
    this.controlsVisible = true;
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
    }
    this.hideTimer = setTimeout(() => {
      this.hideTimer = -1;
      if (this.playing) {
        this.controlsVisible = false;
      }
    }, 3000);
  }

  private onSliderChange(v: number, m: SliderChangeMode): void {
    if (m === SliderChangeMode.Begin) {
      this.dragging = true;
      this.currentTime = v;
      return;
    }
    if (m === SliderChangeMode.Moving) {
      this.currentTime = v;
      return;
    }
    this.dragging = false;
    this.currentTime = v;
    const p = this.avPlayer;
    if (p !== undefined) {
      p.seek(v);
    }
    this.showControlsTemporarily();
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Center }) {
        XComponent({ id: 'playerSurface', type: XComponentType.SURFACE, controller: this.xController })
          .width('100%')
          .height('100%')
          .scale({ x: this.xScale, y: this.yScale })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
          .onLoad(() => {
            const newId = this.xController.getXComponentSurfaceId();
            hilog.info(0x0000, 'NasPlayer', 'xcomp onLoad surfaceId=%{public}s startup=%{public}s', newId, String(this.startupDone));
            if (newId === this.surfaceId && this.startupDone) {
              return;
            }
            this.surfaceId = newId;
            this.startupDone = true;
            if (this.index >= 0 && this.index < this.videoFiles.length) {
              this.playEntry(this.videoFiles[this.index]);
            }
          })

        if (this.loading) {
          Column({ space: 10 }) {
            LoadingProgress()
              .width(48)
              .height(48)
              .color(Color.White)
            Text('加载中…')
              .fontSize(14)
              .fontColor(Color.White)
          }
        }

        if (this.errorMsg.length > 0) {
          Column({ space: 14 }) {
            Text(this.errorMsg)
              .fontSize(15)
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .padding({ left: 30, right: 30 })
            Button('重试')
              .fontSize(14)
              .height(38)
              .onClick(() => {
                this.errorMsg = '';
                this.playEntry(this.videoFiles[this.index]);
              })
          }
        }

        if (this.completed) {
          Column({ space: 14 }) {
            Text('播放完成')
              .fontSize(18)
              .fontColor(Color.White)
            Button('下一部')
              .fontSize(14)
              .height(38)
              .onClick(() => {
                this.completed = false;
                this.switchTo(1);
              })
          }
        }

        if (this.brightnessPanel) {
          Column({ space: 14 }) {
            Text('亮度 ' + Math.round(this.screenBrightness * 100) + '%')
              .fontSize(15)
              .fontColor(Color.White)
            Row({ space: 10 }) {
              Text('☾')
                .fontSize(16)
                .fontColor(Color.White)
              Slider({
                value: this.screenBrightness,
                min: 0,
                max: 1,
                step: 0.01,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .onChange((v: number) => {
                  this.setBrightness(v);
                })
              Text('☀')
                .fontSize(16)
                .fontColor(Color.White)
            }
            .width(260)
            Button('完成')
              .fontSize(13)
              .height(32)
              .backgroundColor($r('app.color.theme_primary'))
              .onClick(() => {
                this.brightnessPanel = false;
              })
          }
          .padding({ left: 20, right: 20, top: 16, bottom: 16 })
          .backgroundColor('rgba(0,0,0,0.72)')
          .borderRadius(14)
          .onClick(() => {
            this.brightnessPanel = false;
          })
        }

        if (this.controlsVisible && this.errorMsg.length === 0) {
          Column() {
            Row({ space: 10 }) {
              Text(this.index >= 0 && this.videoFiles.length > 0 && this.index < this.videoFiles.length ?
                this.videoFiles[this.index].name : '')
                .fontSize(13)
                .fontColor(Color.White)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: this.topSafeHeight + 14 })

            Blank()

            Row({ space: 8 }) {
              Text(MediaUtil.formatDuration(this.currentTime))
                .fontSize(12)
                .fontColor(Color.White)
              Slider({
                value: this.currentTime,
                min: 0,
                max: Math.max(this.duration, 1),
                step: 1,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .onChange((v: number, m: SliderChangeMode) => {
                  this.onSliderChange(v, m);
                })
              Text(MediaUtil.formatDuration(this.duration))
                .fontSize(12)
                .fontColor(Color.White)
            }
            .width('100%')
            .padding({ left: 16, right: 16 })

            Row({ space: 10 }) {
              Text(this.playIcon())
                .fontSize(13)
                .fontColor(Color.White)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor('rgba(255,255,255,0.18)')
                .borderRadius(14)
                .onClick(() => {this.togglePlay();
                })
              Blank()
              Text(this.speedLabels[this.speedIdx])
                .fontSize(13)
                .fontColor(Color.White)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor('rgba(255,255,255,0.18)')
                .borderRadius(14)
                .onClick(() => {this.cycleSpeed();
                })
              Text(this.scaleLabels[this.scaleIdx])
                .fontSize(13)
                .fontColor(Color.White)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor('rgba(255,255,255,0.18)')
                .borderRadius(14)
                .onClick(() => {this.cycleScale();
                })
              Text('亮度')
                .fontSize(13)
                .fontColor(Color.White)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(this.brightnessPanel ? 'rgba(30,136,229,0.6)' : 'rgba(255,255,255,0.18)')
                .borderRadius(14)
                .onClick(() => {this.toggleBrightnessPanel();
                })
              Text(this.isLandscape ? '竖屏' : '横屏')
                .fontSize(13)
                .fontColor(Color.White)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor('rgba(255,255,255,0.18)')
                .borderRadius(14)
                .onClick(() => {this.toggleLandscape();
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: this.bottomSafeHeight + 18 })
          }
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.player_overlay'))
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.player_bg'))
      .onClick(() => {
        this.toggleControls();
      })
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          PanGesture({ direction: PanDirection.Up, distance: 30 })
            .onActionEnd(() => {
              this.switchTo(1);
            }),
          PanGesture({ direction: PanDirection.Down, distance: 30 })
            .onActionEnd(() => {
              this.switchTo(-1);
            })
        )
      )
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.player_bg'))
    .onWillDisappear(() => {
      this.onWillDisappear();
    })
    .onHidden(() => {
      this.exitLandscape();
      this.exitFullscreen();
      this.pauseIfPlaying();
    })
  }
}

