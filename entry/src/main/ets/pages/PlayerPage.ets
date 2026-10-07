import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window, display } from '@kit.ArkUI';
import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { avSession } from '@kit.AVSessionKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { settings } from '@kit.BasicServicesKit';
import { VideoEntry } from '../model/VideoEntry';
import { PlayerParams } from '../model/RouteParams';
import { StreamServer } from '../service/StreamServer';
import { MediaUtil } from '../service/MediaUtil';
import { SmbService } from '../service/SmbService';
import { ConfigStore } from '../service/ConfigStore';
import { showDeleteConfirm, parentDir, markDirDirty } from '../service/DeleteUtil';

const DOMAIN = 0x0000;
const TAG = 'NasPlayer';
/** 视频后台播放的播控中心会话 tag（与音频页 NasPlayer-Audio 区分） */
const SESSION_TAG_VIDEO = 'NasPlayer-Video';
/** 播控中心状态同步节流间隔 */
const SESSION_SYNC_INTERVAL_MS = 1000;

/** 起播后延迟多久开始预热相邻视频：太早会和刚起播的流抢带宽，太晚则来不及 */
const NEIGHBOR_PREFETCH_DELAY_MS = 2500;
/** 预热窗口：沿最近一次滑动方向预取 5 部，反方向保底 1 部（快速连滑时不用等反向回补） */
const PREFETCH_FORWARD = 5;
const PREFETCH_BACK = 1;

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
  private prefetchTimer: number = -1;
  /** 最近一次切换方向：+1 下一部 / -1 上一部，决定预取窗口往哪边倾斜 */
  private switchDir: number = 1;
  @State holdX2Tip: boolean = false;

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
  /** 右侧挖孔避让宽度（vp，横屏挖孔在右侧时使用） */
  @State rightSafeWidth: number = 0;
  /** 播放器可视区域宽度（vp，用于把亮度弹窗贴到屏幕左侧） */
  @State screenWidth: number = 0;
  private safeAreaListening: boolean = false;
  private navCtx: NavDestinationContext | undefined = undefined;
  @State deleting: boolean = false;
  @State actionMenuOpen: boolean = false;

  // ---------------- 后台听视频（后台任务 + 播控中心） ----------------
  private session: avSession.AVSession | undefined = undefined;
  private bgStarted: boolean = false;
  private launchAgent: WantAgent | undefined = undefined;
  private lastSessionSync: number = 0;
  /** 上一次“播完”的处理时间：endOfStream 与 stateChange('completed') 双事件去重 */
  private lastFinishAt: number = 0;
  /** 是否处于后台（退到后台继续播放时用于播完自动续播） */
  private backgrounded: boolean = false;
  /** 后台播放开关：退到后台/锁屏后是否继续播放声音，默认开启 */
  @State bgPlayEnabled: boolean = true;

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
  /** 与 speedValues 对应的数值（用于播控中心展示倍速） */
  private speedNumbers: number[] = [0.75, 1.0, 1.25, 1.5, 2.0];

  aboutToAppear(): void {
    const p = this.params;
    if (p !== undefined && p !== null && p.files !== undefined && p.files !== null && p.files.length > 0) {
      this.videoFiles = p.files;
      this.index = p.index;
    }
    // 根据当前状态决定全屏/显示系统栏
    this.applyFullscreenState();
    this.loadBgSetting();
    this.setupSession();
  }

  private async loadBgSetting(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.bgPlayEnabled = await ConfigStore.loadVideoBgPlay(ctx);
    } catch (e) {
      this.bgPlayEnabled = true;
    }
  }

  private updateScale(): void {
    const p = this.avPlayer;
    this.xScale = 1;
    this.yScale = 1;
    if (p === undefined) {
      return;
    }
    // videoScaleType 只能在 prepared/playing/paused/completed 下设置：
    // 加载阶段（onAreaChange 早触发）设置会抛 5400102 并误触 on('error')
    const st = p.state;
    if (st !== 'prepared' && st !== 'playing' && st !== 'paused' && st !== 'completed') {
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
    this.backgrounded = true;
    if (this.bgPlayEnabled) {
      // 后台听视频：保持播放，返回前台再同步状态（NavDestination 实际走 onHidden）
      this.syncSessionState();
      return;
    }
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

  /** 亮度弹窗宽度（vp） */
  private static readonly BRIGHTNESS_PANEL_W = 72;
  /** 亮度弹窗距屏幕边缘的距离（避让右侧挖孔 + 12vp） */
  private static readonly BRIGHTNESS_PANEL_MARGIN = 12;

  /** 亮度弹窗水平偏移：横竖屏都贴屏幕右侧（父容器居中布局，正偏移向右） */
  private brightnessPanelOffsetX(): number {
    const w = this.screenWidth > 0 ? this.screenWidth : 360;
    const panelHalf = PlayerPage.BRIGHTNESS_PANEL_W / 2;
    const margin = this.rightSafeWidth + PlayerPage.BRIGHTNESS_PANEL_MARGIN;
    return w / 2 - panelHalf - margin;
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
      let right = 0;
      // 挖孔/刘海区域（前置摄像头）——全屏时状态栏隐藏，TYPE_SYSTEM 可能为 0，必须用 TYPE_CUTOUT
      try {
        const cutout = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
        top = Math.max(top, cutout.topRect.height);
        right = Math.max(right, cutout.rightRect.width);
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
      this.rightSafeWidth = ui.px2vp(right);
      hilog.info(0x0000, 'NasPlayer', 'safe area updated top=%{public}d bottom=%{public}d right=%{public}d',
        top, bottom, right);
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
    this.setKeepScreenOn(false);
    await this.stopBackgroundTask();
    await this.teardownSession();
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    if (this.prefetchTimer >= 0) {
      clearTimeout(this.prefetchTimer);
      this.prefetchTimer = -1;
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

  /** 视频播放期间保持屏幕常亮；暂停/播放结束/退出页面必须复位为 false，
   *  否则系统会判定为滥用常亮而强制恢复自动熄屏（官方规范用法）。 */
  private setKeepScreenOn(on: boolean): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = ctx.windowStage.getMainWindowSync();
      win.setWindowKeepScreenOn(on).catch((e: BusinessError) => {
        console.error('set keep screen on failed: ' + JSON.stringify(e));
      });
    } catch (e) {
      console.error('set keep screen on failed: ' + JSON.stringify(e));
    }
  }

  // ---------------- 后台听视频：播控中心与后台任务 ----------------

  private async setupSession(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const s = await avSession.createAVSession(ctx, SESSION_TAG_VIDEO, 'video');
      s.on('play', () => {
        this.resumePlayback();
      });
      s.on('pause', () => {
        this.pausePlayback();
      });
      s.on('stop', () => {
        this.handleSessionStop();
      });
      s.on('playNext', () => {
        this.switchTo(1);
      });
      s.on('playPrevious', () => {
        this.switchTo(-1);
      });
      s.on('seek', (time: number) => {
        this.seekTo(time);
      });
      this.session = s;
      // 点击播控中心卡片时拉起应用
      const agent = await this.getLaunchAgent();
      if (agent !== undefined) {
        this.launchAgent = agent;
        await s.setLaunchAbility(agent);
      }
      // 官方要求：元数据与控制命令注册完成后再 activate
      this.syncSessionMetadata();
      await s.activate();
      hilog.info(DOMAIN, TAG, 'video session activated');
      this.syncSessionState();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'video session setup failed: %{public}s', JSON.stringify(e));
    }
  }

  private async teardownSession(): Promise<void> {
    const s = this.session;
    this.session = undefined;
    if (s === undefined) {
      return;
    }
    try {
      s.off('play');
      s.off('pause');
      s.off('stop');
      s.off('playNext');
      s.off('playPrevious');
      s.off('seek');
      await s.deactivate();
      await s.destroy();
      hilog.info(DOMAIN, TAG, 'video session destroyed');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'destroy video session failed: %{public}s', JSON.stringify(e));
    }
  }

  private async getLaunchAgent(): Promise<WantAgent | undefined> {
    if (this.launchAgent !== undefined) {
      return this.launchAgent;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name
      };
      const wants: Want[] = [want];
      const info: wantAgent.WantAgentInfo = {
        wants: wants,
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      this.launchAgent = agent;
      return agent;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'video get launch agent failed: %{public}s', JSON.stringify(e));
      return undefined;
    }
  }

  private async handleSessionStop(): Promise<void> {
    await this.pausePlayback();
    await this.stopBackgroundTask();
  }

  private syncSessionMetadata(): void {
    const s = this.session;
    if (s === undefined) {
      return;
    }
    const entry = (this.index >= 0 && this.index < this.videoFiles.length) ? this.videoFiles[this.index] : undefined;
    // 注意：可选字段不能显式传 undefined（会触发 401 参数校验失败），只设置有值的字段
    const md: avSession.AVMetadata = {
      assetId: entry !== undefined ? entry.path : SESSION_TAG_VIDEO,
      title: entry !== undefined ? entry.name : '视频'
    };
    md.artist = '本地视频';
    if (this.duration > 0) {
      md.duration = this.duration;
    }
    // previous/nextAssetId 决定播控中心上一部/下一部按钮是否可用
    if (this.index - 1 >= 0 && this.index - 1 < this.videoFiles.length) {
      md.previousAssetId = this.videoFiles[this.index - 1].path;
    }
    if (this.index + 1 >= 0 && this.index + 1 < this.videoFiles.length) {
      md.nextAssetId = this.videoFiles[this.index + 1].path;
    }
    s.setAVMetadata(md).catch((e: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'video setAVMetadata failed code=%{public}d msg=%{public}s', e.code, e.message);
    });
  }

  private syncSessionState(): void {
    const s = this.session;
    if (s === undefined) {
      return;
    }
    const pos: avSession.PlaybackPosition = {
      elapsedTime: this.currentTime,
      updateTime: Date.now()
    };
    const st: avSession.AVPlaybackState = {
      state: this.playing
        ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      position: pos,
      speed: this.speedNumbers[this.speedIdx]
    };
    s.setAVPlaybackState(st).catch((e: Error) => {
      hilog.debug(DOMAIN, TAG, 'video setAVPlaybackState failed: %{public}s', JSON.stringify(e));
    });
  }

  private async ensureBackgroundTask(): Promise<void> {
    if (this.bgStarted || !this.bgPlayEnabled) {
      return;
    }
    this.bgStarted = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const agent = await this.getLaunchAgent();
      if (agent === undefined) {
        throw new Error('无法创建 WantAgent');
      }
      await backgroundTaskManager.startBackgroundRunning(ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      hilog.info(DOMAIN, TAG, 'video background task started');
    } catch (e) {
      this.bgStarted = false;
      hilog.warn(DOMAIN, TAG, 'video background task failed: %{public}s', JSON.stringify(e));
      this.showToast('后台播放未开启：' + (e instanceof Error ? e.message : String(e)));
    }
  }

  private async stopBackgroundTask(): Promise<void> {
    if (!this.bgStarted) {
      return;
    }
    this.bgStarted = false;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      hilog.info(DOMAIN, TAG, 'video background task stopped');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'stop video background task failed: %{public}s', JSON.stringify(e));
    }
  }

  private async resumePlayback(): Promise<void> {
    const p = this.avPlayer;
    if (p === undefined) {
      return;
    }
    try {
      if (p.state === 'paused' || p.state === 'prepared' || p.state === 'completed') {
        await p.play();
        this.playing = true;
        // 暂停会丢失倍速设置，恢复播放时重新应用，避免界面显示与实际播放速度不一致
        if (this.speedIdx !== 1) {
          p.setSpeed(this.speedValues[this.speedIdx]);
        }
        this.syncSessionState();
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'video resume failed: %{public}s', JSON.stringify(e));
    }
  }

  private async pausePlayback(): Promise<void> {
    const p = this.avPlayer;
    if (p === undefined) {
      return;
    }
    try {
      if (p.state === 'playing') {
        await p.pause();
        this.playing = false;
        this.syncSessionState();
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'video pause failed: %{public}s', JSON.stringify(e));
    }
  }

  private seekTo(time: number): void {
    const p = this.avPlayer;
    if (p === undefined || this.duration <= 0) {
      return;
    }
    const target = Math.min(Math.max(time, 0), this.duration);
    this.currentTime = target;
    try {
      p.seek(target);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'video seek failed: %{public}s', JSON.stringify(e));
    }
    this.syncSessionState();
  }

  private attachEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState) => {
      hilog.info(0x0000, 'NasPlayer', 'avplayer stateChange -> %{public}s', state);
      if (state === 'playing') {
        this.playing = true;
        this.errorMsg = '';
        this.setKeepScreenOn(true);
        this.showControlsTemporarily();
      } else if (state === 'paused') {
        this.playing = false;
        this.setKeepScreenOn(false);
      } else if (state === 'completed') {
        this.onVideoFinished();
        return;
      }
      this.syncSessionState();
    });
    player.on('timeUpdate', (time: number) => {
      if (!this.dragging) {
        this.currentTime = time;
      }
      if (this.duration === 0) {
        this.duration = player.duration;
      }
      const now = Date.now();
      if (now - this.lastSessionSync >= SESSION_SYNC_INTERVAL_MS) {
        this.lastSessionSync = now;
        this.syncSessionState();
      }
    });
    player.on('error', (err: BusinessError) => {
      hilog.error(0x0000, 'NasPlayer', 'player error: %{public}s serveErr=%{public}s',
        JSON.stringify(err), StreamServer.getInstance().getLastServeError());
      // 加载/准备期间出错由 playEntry catch 统一提示，这里避免重复弹提示
      if (!this.loading) {
        this.loading = false;
        this.setKeepScreenOn(false);
        this.errorMsg = PlayerPage.describePlayerError(err, StreamServer.getInstance().getLastServeError());
      }
    });
    player.on('endOfStream', () => {
      this.onVideoFinished();
    });
    player.on('videoSizeChange', (width: number, height: number) => {
      if (width > 0 && height > 0) {
        this.updateScale();
      }
    });
  }

  /** 当前视频播完：去重后延时处理，后台时自动续播下一部，前台维持“播放完成”UI */
  private onVideoFinished(): void {
    if (this.destroyed) {
      return;
    }
    const now = Date.now();
    if (now - this.lastFinishAt < 1500) {
      return;
    }
    this.lastFinishAt = now;
    this.playing = false;
    this.completed = true;
    this.setKeepScreenOn(false);
    this.syncSessionState();
    if (!this.backgrounded) {
      return;
    }
    const next = this.index + 1;
    if (next < this.videoFiles.length) {
      hilog.info(DOMAIN, TAG, 'video finished in background, auto next from=%{public}d', this.index);
      setTimeout(() => {
        if (!this.destroyed && this.backgrounded) {
          this.switchTo(1);
        }
      }, 250);
    }
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
      StreamServer.getInstance().clearLastServeError();
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
      // 预热只等文件大小 + 最多 1.5s 的头部预取：几 MB 的头/尾预取转后台，
      // 不再把完整预取耗时压在切换路径上（弱网下这是切换慢的主因）
      await this.withTimeout(StreamServer.getInstance().warmup(entry.path, 1500), 20000, '视频信息加载');
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
      // prepare() 的 Promise 会早于 stateChange('prepared') 抵达主线程（实测早约 60ms），
      // 此刻 player.state 仍是 initialized。若在 initialized 下设置 videoScaleType / 调 play()，
      // AVPlayer 会抛 5400102（Operate Not Permit）导致本次播放直接失败——大文件 prepare 越久越必现。
      const prepared = await this.waitForState(player, 'prepared', 5000);
      hilog.info(0x0000, 'NasPlayer', 'playEntry: prepared, state=%{public}s', player.state);
      if (!prepared) {
        throw new Error(player.state === 'error' ? '视频源准备失败' : '视频准备超时');
      }
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
      this.scheduleNeighborPrefetch();
      this.ensureBackgroundTask();
      this.syncSessionMetadata();
      this.syncSessionState();
    } catch (e) {
      console.error('play failed: ' + JSON.stringify(e));
      hilog.error(0x0000, 'NasPlayer', 'playEntry failed: %{public}s serveErr=%{public}s',
        JSON.stringify(e), StreamServer.getInstance().getLastServeError());
      // 网络类失败：静默自动重试（保持加载中，不弹提示），最多 3 次
      if (retryCount < 3 && PlayerPage.isNetworkish(e, StreamServer.getInstance().getLastServeError())) {
        hilog.info(0x0000, 'NasPlayer', 'playEntry network issue, silent retry %{public}d/3', retryCount + 1);
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
        // 重试前把（后台还在跑的）头/尾预取等完：第二次尝试的 Range 请求大概率直接命中内存
        try {
          await this.withTimeout(StreamServer.getInstance().warmup(entry.path, 6000), 8000, '视频预取');
        } catch (e3) {
          hilog.warn(0x0000, 'NasPlayer', 'retry wait prefetch failed: %{public}s', JSON.stringify(e3));
        }
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
      this.syncSessionState();
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
    this.syncSessionState();
  }

  private cycleScale(): void {
    this.scaleIdx = (this.scaleIdx + 1) % this.scaleValues.length;
    this.updateScale();
    this.applyFullscreenState();
    this.showControlsTemporarily();
  }

  /** 起播后延迟预热相邻视频：弱网下上下切换时数据已在内存，接近秒开。
   *  只预取头部 1MB：尾部 4MB 会让后台流量挤占正在播放的带宽，弱网下反而更卡。
   *  窗口随滑动方向自适应（前后各 5 部 + 反向 1 部），每次切歌重建队列，跟得上快速连滑。 */
  private scheduleNeighborPrefetch(): void {
    if (this.prefetchTimer >= 0) {
      clearTimeout(this.prefetchTimer);
    }
    this.prefetchTimer = setTimeout(() => {
      this.prefetchTimer = -1;
      if (this.destroyed) {
        return;
      }
      if (this.loading) {
        // 当前还没起播：让出带宽，稍后再试
        this.scheduleNeighborPrefetch();
        return;
      }
      StreamServer.getInstance().setPrefetchWindow(this.prefetchWindowPaths(), false);
    }, NEIGHBOR_PREFETCH_DELAY_MS);
  }

  /** 预取窗口路径：先沿滑动方向由近到远，再补反方向，越界即止 */
  private prefetchWindowPaths(): string[] {
    const paths: string[] = [];
    const total = this.videoFiles.length;
    const dir = this.switchDir >= 0 ? 1 : -1;
    for (let k = 1; k <= PREFETCH_FORWARD; k++) {
      const i = this.index + dir * k;
      if (i < 0 || i >= total) {
        break;
      }
      paths.push(this.videoFiles[i].path);
    }
    for (let k = 1; k <= PREFETCH_BACK; k++) {
      const i = this.index - dir * k;
      if (i < 0 || i >= total) {
        break;
      }
      paths.push(this.videoFiles[i].path);
    }
    return paths;
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
      this.switchDir = delta >= 0 ? 1 : -1;
      this.index = next;
      await this.playEntry(this.videoFiles[next]);
    } finally {
      this.switchInProgress = false;
    }
  }

  /** 打开“更多”菜单：停掉控制栏自动隐藏，避免菜单打开时锚点按钮被移除 */
  private openActionMenu(): void {
    this.actionMenuOpen = true;
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  /** 切换“后台播放”开关：落盘；开启时申请后台任务，关闭时释放 */
  private toggleBgPlay(): void {
    this.bgPlayEnabled = !this.bgPlayEnabled;
    const enabled = this.bgPlayEnabled;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ConfigStore.saveVideoBgPlay(ctx, enabled).catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'save video bg play failed code=%{public}d', e.code);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'save video bg play failed: %{public}s', JSON.stringify(e));
    }
    if (enabled) {
      this.ensureBackgroundTask();
      this.showToast('后台播放已开启');
    } else {
      this.stopBackgroundTask();
      this.showToast('后台播放已关闭');
    }
    this.showControlsTemporarily();
  }

  /** 删除当前视频：红色按钮 + 二次确认，避免误触；删除后自动切到下一部 */
  private confirmDeleteCurrent(): void {
    if (this.deleting || this.switchInProgress) {
      return;
    }
    if (this.index < 0 || this.index >= this.videoFiles.length) {
      return;
    }
    const target = this.videoFiles[this.index];
    showDeleteConfirm(this.getUIContext(), target.name, '视频', () => {
      this.doDeleteCurrent(target);
    });
  }

  private async doDeleteCurrent(target: VideoEntry): Promise<void> {
    if (this.deleting) {
      return;
    }
    this.deleting = true;
    // 先暂停，避免删除瞬间 SMB 读失败弹出播放器错误提示
    this.pauseIfPlaying();
    try {
      await SmbService.getInstance().deleteEntry(target.path, false);
      const next: VideoEntry[] = [];
      for (let i = 0; i < this.videoFiles.length; i++) {
        if (i !== this.index) {
          next.push(this.videoFiles[i]);
        }
      }
      this.videoFiles = next;
      markDirDirty(parentDir(target.path));
      this.showToast('已删除：' + target.name);
      if (this.videoFiles.length === 0) {
        await this.cleanup();
        if (this.navCtx !== undefined) {
          this.navCtx.pathStack.pop();
        }
        return;
      }
      if (this.index >= this.videoFiles.length) {
        this.index = this.videoFiles.length - 1;
      }
      await this.playEntry(this.videoFiles[this.index]);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      hilog.error(0x0000, 'NasPlayer', 'delete current video failed path=%{public}s err=%{public}s',
        target.path, msg);
      this.showToast('删除失败：' + msg);
    } finally {
      this.deleting = false;
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
    this.syncSessionState();
  }

  /** 快进/快退：目标位置夹在 [0, duration]，更新进度并提示 */
  private async seekBy(deltaMs: number, showToast: boolean): Promise<void> {
    const p = this.avPlayer;
    if (p === undefined || this.duration <= 0) {
      return;
    }
    const target = Math.min(Math.max(this.currentTime + deltaMs, 0), this.duration);
    this.currentTime = target;
    try {
      p.seek(target);
    } catch (e) {
      console.error('seek by failed: ' + JSON.stringify(e));
    }
    this.showControlsTemporarily();
    if (showToast) {
      this.showToast((deltaMs >= 0 ? '+' : '') + (deltaMs / 1000) + 's');
    }
    this.syncSessionState();
  }

  /** 长按半屏：X2 倍速播放（替代高频 seek，避免卡顿）。AVPlayer 不支持倒放，左右统一 X2 倍速 */
  private startHoldSeek(): void {
    const p = this.avPlayer;
    if (p === undefined || p.state !== 'playing') {
      return;
    }
    this.holdX2Tip = true;
    this.showControlsTemporarily();
    try {
      p.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_2_00_X);
    } catch (e) {
      console.error('set x2 speed failed: ' + JSON.stringify(e));
    }
  }

  private stopHoldSeek(): void {
    this.holdX2Tip = false;
    const p = this.avPlayer;
    if (p !== undefined && p.state === 'playing') {
      try {
        p.setSpeed(this.speedValues[this.speedIdx]);
      } catch (e) {
        console.error('restore speed failed: ' + JSON.stringify(e));
      }
    }
    this.showControlsTemporarily();
  }

  /** 更多操作菜单：后续新增操作项在此追加 */
  @Builder
  actionMenu() {
    Column() {
      Text(this.bgPlayEnabled ? '后台播放：开' : '后台播放：关')
        .fontSize(13)
        .fontColor($r('app.color.text_main'))
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 9, bottom: 9 })
        .onClick(() => {
          this.actionMenuOpen = false;
          this.toggleBgPlay();
        })
      Text('删除')
        .fontSize(13)
        .fontColor($r('app.color.text_error'))
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 9, bottom: 9 })
        .onClick(() => {
          this.actionMenuOpen = false;
          this.confirmDeleteCurrent();
        })
      // 后续新增操作项在此追加
    }
    .width(120)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(10)
    .shadow({ radius: 12, color: '#26000000', offsetX: 0, offsetY: 4 })
    .clip(true)
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

        if (this.holdX2Tip) {
          Text('X2')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
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
              Column({ space: 5 }) {
                Circle().width(3).height(3).fill(Color.White)
                Circle().width(3).height(3).fill(Color.White)
                Circle().width(3).height(3).fill(Color.White)
              }
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .onClick(() => {
                this.openActionMenu();
              })
              .bindMenu(this.actionMenuOpen, this.actionMenu, {
                enableArrow: true,
                onDisappear: () => {
                  this.actionMenuOpen = false;
                  this.showControlsTemporarily();
                }
              })
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

        // 亮度弹窗：竖直显示在屏幕右侧，且吞掉自身范围内的滑动/长按，避免误触发切视频、快进快退与 X2 倍速
        if (this.brightnessPanel) {
          Column({ space: 12 }) {
            Text('☀')
              .fontSize(16)
              .fontColor(Color.White)
            Slider({
              value: this.screenBrightness,
              min: 0,
              max: 1,
              step: 0.01,
              style: SliderStyle.OutSet,
              direction: Axis.Vertical,
              reverse: true
            })
              .width(40)
              .height(170)
              .onChange((v: number) => {
                this.setBrightness(v);
              })
            Text(Math.round(this.screenBrightness * 100) + '%')
              .fontSize(12)
              .fontColor(Color.White)
          }
          .width(PlayerPage.BRIGHTNESS_PANEL_W)
          .padding({ left: 12, right: 12, top: 14, bottom: 14 })
          .backgroundColor('rgba(0,0,0,0.35)')
          .borderRadius(14)
          .offset({ x: this.brightnessPanelOffsetX() })
          .onClick(() => {
            this.brightnessPanel = false;
          })
          .gesture(
            GestureGroup(GestureMode.Parallel,
              PanGesture({ direction: PanDirection.All, distance: 5 })
                .onActionEnd(() => {
                }),
              LongPressGesture({ repeat: false, duration: 400 })
                .onAction(() => {
                })
            )
          )
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.player_bg'))
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const w = newArea.width;
        if (typeof w === 'number') {
          this.screenWidth = w;
        }
      })
      .onClick(() => {
        if (this.brightnessPanel) {
          this.brightnessPanel = false;
          return;
        }
        if (this.actionMenuOpen) {
          return;
        }
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
            }),
          PanGesture({ direction: PanDirection.Right, distance: 30 })
            .onActionEnd(() => {
              this.seekBy(10000, true);
            }),
          PanGesture({ direction: PanDirection.Left, distance: 30 })
            .onActionEnd(() => {
              this.seekBy(-10000, true);
            }),
          LongPressGesture({ repeat: false, duration: 400 })
            .onAction(() => {
              this.startHoldSeek();
            })
            .onActionEnd(() => {
              this.stopHoldSeek();
            })
        )
      )
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.player_bg'))
    .onReady((ctx: NavDestinationContext) => {
      this.navCtx = ctx;
    })
    .onWillDisappear(() => {
      this.onWillDisappear();
    })
    .onHidden(() => {
      this.backgrounded = true;
      if (this.bgPlayEnabled) {
        // 后台听视频：不暂停、不做窗口/方向变更，返回前台保持原横竖屏与全屏状态
        this.syncSessionState();
      } else {
        this.exitLandscape();
        this.exitFullscreen();
        this.pauseIfPlaying();
      }
    })
    .onShown(() => {
      this.backgrounded = false;
      // 退后台期间窗口不可见，常亮可能被系统复位，返回前台重新申请
      this.setKeepScreenOn(this.playing);
      this.syncSessionState();
    })
  }
}

