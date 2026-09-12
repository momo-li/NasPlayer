import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { avSession } from '@kit.AVSessionKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { VideoEntry } from '../model/VideoEntry';
import { AudioPlayerParams } from '../model/RouteParams';
import { StreamServer } from '../service/StreamServer';
import { AudioMeta, AudioMetaUtil } from '../service/AudioMetaUtil';
import { MediaUtil } from '../service/MediaUtil';

const DOMAIN = 0x0000;
const TAG = 'NasPlayer';
const SESSION_TAG = 'NasPlayer-Audio';
const SESSION_SYNC_INTERVAL_MS = 1000;

@Component
export default struct AudioPlayerPage {
  params: AudioPlayerParams = { files: [], index: 0 };
  private avPlayer: media.AVPlayer | undefined = undefined;
  private session: avSession.AVSession | undefined = undefined;
  private bgStarted: boolean = false;
  private switchInProgress: boolean = false;
  private dragging: boolean = false;
  private destroyed: boolean = false;
  private lastSessionSync: number = 0;
  private launchAgent: WantAgent | undefined = undefined;
  @State loopMode: avSession.LoopMode = avSession.LoopMode.LOOP_MODE_SEQUENCE;

  @State tracks: VideoEntry[] = [];
  @State index: number = 0;
  @State playing: boolean = false;
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State completed: boolean = false;
  @State currentTime: number = 0;
  @State duration: number = 0;
  @State speedIdx: number = 1;
  @State titleText: string = '';
  @State artistText: string = '';
  @State albumText: string = '';
  @State cover: image.PixelMap | undefined = undefined;

  private speedValues: media.PlaybackSpeed[] = [
    media.PlaybackSpeed.SPEED_FORWARD_0_75_X,
    media.PlaybackSpeed.SPEED_FORWARD_1_00_X,
    media.PlaybackSpeed.SPEED_FORWARD_1_25_X,
    media.PlaybackSpeed.SPEED_FORWARD_1_50_X,
    media.PlaybackSpeed.SPEED_FORWARD_2_00_X
  ];
  private speedLabels: string[] = ['0.75x', '1.0x', '1.25x', '1.5x', '2.0x'];
  /** 与 speedValues 对应的数值（用于 AVSession 播控中心展示倍速） */
  private speedNumbers: number[] = [0.75, 1.0, 1.25, 1.5, 2.0];

  aboutToAppear(): void {
    const p = this.params;
    if (p !== undefined && p !== null && p.files !== undefined && p.files !== null && p.files.length > 0) {
      this.tracks = p.files;
      if (p.index >= 0 && p.index < p.files.length) {
        this.index = p.index;
      }
    }
    hilog.info(DOMAIN, TAG, 'audio page open total=%{public}d index=%{public}d', this.tracks.length, this.index);
    this.setupSession();
    if (this.index >= 0 && this.index < this.tracks.length) {
      this.playTrack(this.tracks[this.index]);
    }
  }

  aboutToDisappear(): void {
    hilog.info(DOMAIN, TAG, 'audio page close');
    this.destroyed = true;
    this.releaseAll();
  }

  private showToast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private currentEntry(): VideoEntry | undefined {
    if (this.index >= 0 && this.index < this.tracks.length) {
      return this.tracks[this.index];
    }
    return undefined;
  }

  private currentName(): string {
    const e = this.currentEntry();
    return e !== undefined ? e.name : '';
  }

  private extText(): string {
    const name = this.currentName();
    const idx = name.lastIndexOf('.');
    if (idx < 0 || idx === name.length - 1) {
      return '';
    }
    return name.substring(idx + 1).toUpperCase();
  }

  private subText(): string {
    const parts: string[] = [];
    if (this.artistText.length > 0) {
      parts.push(this.artistText);
    }
    if (this.albumText.length > 0) {
      parts.push(this.albumText);
    }
    if (parts.length === 0) {
      return '未知艺术家';
    }
    return parts.join(' · ');
  }

  // ---------------- 播放 ----------------

  private async playTrack(entry: VideoEntry, retryCount: number = 0): Promise<void> {
    if (this.destroyed) {
      return;
    }
    this.loading = true;
    this.errorMsg = '';
    this.completed = false;
    this.currentTime = 0;
    this.duration = 0;
    this.loadMeta(entry);
    try {
      StreamServer.getInstance().clearLastServeError();
      await StreamServer.getInstance().start();
      let player = this.avPlayer;
      if (player === undefined) {
        player = await media.createAVPlayer();
        this.attachEvents(player);
        this.avPlayer = player;
      } else {
        await player.reset();
      }
      await this.withTimeout(StreamServer.getInstance().warmup(entry.path), 20000, '音频加载');
      player.url = StreamServer.getInstance().urlFor(entry.path);
      const ready = await this.waitForState(player, 'initialized', 8000);
      if (!ready) {
        throw new Error('音频源加载超时');
      }
      // 音频播放无需设置 surfaceId
      await this.prepareWithTimeout(player, 10000);
      this.duration = player.duration;
      if (this.speedIdx !== 1) {
        player.setSpeed(this.speedValues[this.speedIdx]);
      }
      await player.play();
      this.playing = true;
      this.loading = false;
      hilog.info(DOMAIN, TAG, 'audio play ok path=%{public}s', entry.path);
      this.ensureBackgroundTask();
      this.syncSessionState();
      this.syncSessionMetadata();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'audio play failed: %{public}s serveErr=%{public}s',
        JSON.stringify(e), StreamServer.getInstance().getLastServeError());
      if (retryCount < 3 && AudioPlayerPage.isNetworkish(e, StreamServer.getInstance().getLastServeError())) {
        try {
          const old = this.avPlayer;
          this.avPlayer = undefined;
          if (old !== undefined) {
            await old.release();
          }
        } catch (e2) {
          hilog.warn(DOMAIN, TAG, 'audio release old player failed: %{public}s', JSON.stringify(e2));
        }
        await new Promise<void>((r) => {
          setTimeout(() => {
            r();
          }, 500);
        });
        await this.playTrack(entry, retryCount + 1);
        return;
      }
      this.loading = false;
      this.errorMsg = AudioPlayerPage.describePlayFailure(e, StreamServer.getInstance().getLastServeError());
    }
  }

  private attachEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState) => {
      hilog.info(DOMAIN, TAG, 'audio stateChange -> %{public}s', state);
      if (state === 'playing') {
        this.playing = true;
        this.errorMsg = '';
      } else if (state === 'paused') {
        this.playing = false;
      } else if (state === 'completed') {
        this.playing = false;
        this.completed = true;
        this.autoNext();
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
      hilog.error(DOMAIN, TAG, 'audio player error: %{public}s serveErr=%{public}s',
        JSON.stringify(err), StreamServer.getInstance().getLastServeError());
      if (!this.loading) {
        this.loading = false;
        this.errorMsg = AudioPlayerPage.describePlayFailure(err, StreamServer.getInstance().getLastServeError());
        this.syncSessionState();
      }
    });
    player.on('endOfStream', () => {
      this.completed = true;
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
        hilog.info(DOMAIN, TAG, 'audio waitForState timeout want=%{public}s cur=%{public}s', target, player.state);
        resolve(false);
      }, timeoutMs);
      const handler = (state: media.AVPlayerState): void => {
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

  private prepareWithTimeout(player: media.AVPlayer, timeoutMs: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error('音频准备超时'));
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

  private static isNetworkish(e: Object, serveErr: string): boolean {
    if (serveErr.length > 0 &&
      (serveErr.indexOf('2303200') >= 0 || serveErr.indexOf('Network') >= 0 ||
        serveErr.indexOf('closed') >= 0 || serveErr.indexOf('超时') >= 0)) {
      return true;
    }
    const detail = JSON.stringify(e);
    return detail.indexOf('超时') >= 0 || detail.indexOf('Network') >= 0 ||
      detail.indexOf('closed') >= 0 || detail.indexOf('socket') >= 0 ||
      detail.indexOf('5400102') >= 0 || detail.indexOf('5400103') >= 0;
  }

  private static describePlayFailure(e: Object, serveErr: string): string {
    if (e instanceof Error) {
      const msg = e.message;
      if (msg.indexOf('超时') >= 0) {
        return '音频加载超时，请检查网络或稍后重试';
      }
      if (msg.indexOf('流服务') >= 0) {
        return '本地流服务启动失败，请重启应用';
      }
    }
    const detail = JSON.stringify(e);
    if (detail.indexOf('5400102') >= 0) {
      if (serveErr.length > 0) {
        return AudioPlayerPage.describeServeError(serveErr);
      }
      return '音频加载失败：无法获取音频数据，请检查网络后重试';
    }
    if (detail.indexOf('5400103') >= 0) {
      return '音频读取失败：网络中断或文件不可读，请检查网络';
    }
    if (detail.indexOf('5400101') >= 0) {
      return '系统内存不足，无法创建播放器';
    }
    return '播放失败，可能是不支持的音频格式';
  }

  private static describeServeError(serveErr: string): string {
    if (serveErr.indexOf('2303200') >= 0 || serveErr.indexOf('Network is down') >= 0) {
      return '网络连接已断开，无法读取音频数据，请检查网络后重试';
    }
    if (serveErr.indexOf('2303111') >= 0 || serveErr.indexOf('unavailable') >= 0) {
      return '本地流服务繁忙，请稍后重试';
    }
    if (serveErr.indexOf('2303199') >= 0 || serveErr.indexOf('Address not available') >= 0) {
      return '无法访问音频文件，请确认文件路径正确';
    }
    return '音频加载失败：本地流服务异常，请重试';
  }

  // ---------------- 切歌与控制 ----------------

  private async switchTrack(delta: number): Promise<void> {
    if (this.switchInProgress) {
      return;
    }
    const next = this.index + delta;
    if (next < 0) {
      this.showToast('已经是第一首');
      return;
    }
    if (next >= this.tracks.length) {
      this.showToast('已经是最后一首');
      return;
    }
    this.switchInProgress = true;
    try {
      this.index = next;
      await this.playTrack(this.tracks[next]);
    } finally {
      this.switchInProgress = false;
    }
  }

  /** 播放完成后的续播逻辑，遵循播控中心设置的循环模式 */
  private autoNext(): void {
    if (this.switchInProgress || this.destroyed) {
      return;
    }
    const mode = this.loopMode;
    if (mode === avSession.LoopMode.LOOP_MODE_SINGLE) {
      const cur = this.currentEntry();
      if (cur !== undefined) {
        this.switchInProgress = true;
        this.playTrack(cur).finally(() => {
          this.switchInProgress = false;
        });
      }
      return;
    }
    let next = this.index + 1;
    if (mode === avSession.LoopMode.LOOP_MODE_SHUFFLE) {
      if (this.tracks.length > 1) {
        next = Math.floor(Math.random() * this.tracks.length);
        if (next === this.index) {
          next = (next + 1) % this.tracks.length;
        }
      } else {
        next = 0;
      }
    } else if (mode === avSession.LoopMode.LOOP_MODE_LIST && next >= this.tracks.length) {
      next = 0;
    }
    if (next >= this.tracks.length) {
      this.showToast('列表已播放完');
      return;
    }
    this.switchInProgress = true;
    this.index = next;
    this.playTrack(this.tracks[next]).finally(() => {
      this.switchInProgress = false;
    });
  }

  private async togglePlay(): Promise<void> {
    const p = this.avPlayer;
    if (p === undefined) {
      if (this.errorMsg.length > 0) {
        const e = this.currentEntry();
        if (e !== undefined) {
          await this.playTrack(e);
        }
      }
      return;
    }
    try {
      const st = p.state;
      if (st === 'playing') {
        await p.pause();
        this.playing = false;
      } else if (st === 'paused' || st === 'prepared' || st === 'completed') {
        await p.play();
        this.playing = true;
      }
      this.syncSessionState();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'audio toggle play failed: %{public}s', JSON.stringify(e));
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
        this.syncSessionState();
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'audio resume failed: %{public}s', JSON.stringify(e));
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
      hilog.warn(DOMAIN, TAG, 'audio pause failed: %{public}s', JSON.stringify(e));
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
      hilog.warn(DOMAIN, TAG, 'audio seek failed: %{public}s', JSON.stringify(e));
    }
    this.syncSessionState();
  }

  private seekBy(deltaMs: number): void {
    this.seekTo(this.currentTime + deltaMs);
  }

  private cycleSpeed(): void {
    this.speedIdx = (this.speedIdx + 1) % this.speedValues.length;
    const p = this.avPlayer;
    if (p !== undefined && p.state === 'playing') {
      p.setSpeed(this.speedValues[this.speedIdx]);
    }
    this.syncSessionState();
  }

  private loopLabel(): string {
    if (this.loopMode === avSession.LoopMode.LOOP_MODE_SINGLE) {
      return '单曲';
    }
    if (this.loopMode === avSession.LoopMode.LOOP_MODE_LIST) {
      return '列表';
    }
    if (this.loopMode === avSession.LoopMode.LOOP_MODE_SHUFFLE) {
      return '随机';
    }
    return '顺序';
  }

  private cycleLoopMode(): void {
    if (this.loopMode === avSession.LoopMode.LOOP_MODE_SEQUENCE) {
      this.loopMode = avSession.LoopMode.LOOP_MODE_LIST;
    } else if (this.loopMode === avSession.LoopMode.LOOP_MODE_LIST) {
      this.loopMode = avSession.LoopMode.LOOP_MODE_SINGLE;
    } else if (this.loopMode === avSession.LoopMode.LOOP_MODE_SINGLE) {
      this.loopMode = avSession.LoopMode.LOOP_MODE_SHUFFLE;
    } else {
      this.loopMode = avSession.LoopMode.LOOP_MODE_SEQUENCE;
    }
    this.syncSessionState();
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
    this.seekTo(v);
  }

  // ---------------- 元数据 ----------------

  private async loadMeta(entry: VideoEntry): Promise<void> {
    this.titleText = entry.name;
    this.artistText = '';
    this.albumText = '';
    this.cover = undefined;
    const meta: AudioMeta = await AudioMetaUtil.getInstance().get(entry.path);
    const cur = this.currentEntry();
    if (this.destroyed || cur === undefined || cur.path !== entry.path) {
      return;
    }
    this.titleText = meta.title.length > 0 ? meta.title : entry.name;
    this.artistText = meta.artist;
    this.albumText = meta.album;
    this.cover = meta.cover;
    this.syncSessionMetadata();
  }

  // ---------------- AVSession 与后台任务 ----------------

  private async setupSession(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const s = await avSession.createAVSession(ctx, SESSION_TAG, 'audio');
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
        this.switchTrack(1);
      });
      s.on('playPrevious', () => {
        this.switchTrack(-1);
      });
      s.on('seek', (time: number) => {
        this.seekTo(time);
      });
      s.on('setLoopMode', (mode: avSession.LoopMode) => {
        this.loopMode = mode;
        this.syncSessionState();
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
      hilog.info(DOMAIN, TAG, 'audio session activated');
      this.syncSessionState();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'audio session setup failed: %{public}s', JSON.stringify(e));
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
      hilog.warn(DOMAIN, TAG, 'get launch agent failed: %{public}s', JSON.stringify(e));
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
    const entry = this.currentEntry();
    const title = this.titleText.length > 0 ? this.titleText : this.currentName();
    // 注意：可选字段不能显式传 undefined（会触发 401 参数校验失败），只设置有值的字段
    const md: avSession.AVMetadata = {
      assetId: entry !== undefined ? entry.path : SESSION_TAG,
      title: title
    };
    if (this.artistText.length > 0) {
      md.artist = this.artistText;
    }
    if (this.albumText.length > 0) {
      md.album = this.albumText;
    }
    if (this.duration > 0) {
      md.duration = this.duration;
    }
    if (this.cover !== undefined) {
      md.mediaImage = this.cover;
    }
    // previous/nextAssetId 决定播控中心上一曲/下一曲按钮是否可用
    if (this.index - 1 >= 0 && this.index - 1 < this.tracks.length) {
      md.previousAssetId = this.tracks[this.index - 1].path;
    }
    if (this.index + 1 >= 0 && this.index + 1 < this.tracks.length) {
      md.nextAssetId = this.tracks[this.index + 1].path;
    }
    s.setAVMetadata(md).then(() => {
      hilog.info(DOMAIN, TAG, 'setAVMetadata ok title=%{public}s prev=%{public}s next=%{public}s',
        title, String(md.previousAssetId !== undefined), String(md.nextAssetId !== undefined));
    }).catch((e: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'setAVMetadata failed code=%{public}d msg=%{public}s', e.code, e.message);
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
      speed: this.speedNumbers[this.speedIdx],
      loopMode: this.loopMode
    };
    s.setAVPlaybackState(st).catch((e: Error) => {
      hilog.debug(DOMAIN, TAG, 'setAVPlaybackState failed: %{public}s', JSON.stringify(e));
    });
  }

  private async ensureBackgroundTask(): Promise<void> {
    if (this.bgStarted) {
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
      hilog.info(DOMAIN, TAG, 'audio background task started');
    } catch (e) {
      this.bgStarted = false;
      hilog.warn(DOMAIN, TAG, 'audio background task failed: %{public}s', JSON.stringify(e));
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
      hilog.info(DOMAIN, TAG, 'audio background task stopped');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'stop background task failed: %{public}s', JSON.stringify(e));
    }
  }

  private async releaseAll(): Promise<void> {
    await this.stopBackgroundTask();
    const s = this.session;
    this.session = undefined;
    if (s !== undefined) {
      try {
        s.off('play');
        s.off('pause');
        s.off('stop');
        s.off('playNext');
        s.off('playPrevious');
        s.off('seek');
        s.off('setLoopMode');
        await s.deactivate();
        await s.destroy();
        hilog.info(DOMAIN, TAG, 'audio session destroyed');
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'destroy session failed: %{public}s', JSON.stringify(e));
      }
    }
    const p = this.avPlayer;
    this.avPlayer = undefined;
    if (p !== undefined) {
      try {
        await p.release();
        hilog.info(DOMAIN, TAG, 'audio player released');
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'release player failed: %{public}s', JSON.stringify(e));
      }
    }
    await StreamServer.getInstance().stop();
    this.cover = undefined;
  }

  // ---------------- UI ----------------

  build() {
    NavDestination() {
      Column({ space: 16 }) {
        Stack({ alignContent: Alignment.Center }) {
          if (this.cover !== undefined) {
            Image(this.cover)
              .objectFit(ImageFit.Cover)
              .width('100%')
              .height('100%')
          } else {
            Text('♪')
              .fontSize(64)
              .fontColor($r('app.color.text_secondary'))
          }
        }
        .width(220)
        .height(220)
        .backgroundColor($r('app.color.poster_bg'))
        .borderRadius(16)
        .clip(true)
        .margin({ top: 26 })

        Column({ space: 6 }) {
          Text(this.titleText.length > 0 ? this.titleText : this.currentName())
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_main'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
            .width('100%')
          Text(this.subText())
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        .width('100%')
        .padding({ left: 24, right: 24 })

        if (this.loading) {
          Column({ space: 8 }) {
            LoadingProgress()
              .width(36)
              .height(36)
              .color($r('app.color.theme_primary'))
            Text('加载中…')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
        }

        if (this.errorMsg.length > 0) {
          Column({ space: 12 }) {
            Text(this.errorMsg)
              .fontSize(14)
              .fontColor($r('app.color.text_main'))
              .textAlign(TextAlign.Center)
              .padding({ left: 30, right: 30 })
            Button('重试')
              .fontSize(14)
              .height(36)
              .backgroundColor($r('app.color.theme_primary'))
              .onClick(() => {
                const e = this.currentEntry();
                if (e !== undefined) {
                  this.playTrack(e);
                }
              })
          }
        }

        Row({ space: 8 }) {
          Text(MediaUtil.formatDuration(this.currentTime))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
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
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ left: 20, right: 20 })

        Row({ space: 14 }) {
          Button('上一曲')
            .height(44)
            .fontSize(15)
            .backgroundColor($r('app.color.card_bg'))
            .fontColor($r('app.color.text_main'))
            .onClick(() => {
              this.switchTrack(-1);
            })
          Button(this.playing ? '暂停' : '播放')
            .width(104)
            .height(48)
            .fontSize(16)
            .backgroundColor($r('app.color.theme_primary'))
            .onClick(() => {
              this.togglePlay();
            })
          Button('下一曲')
            .height(44)
            .fontSize(15)
            .backgroundColor($r('app.color.card_bg'))
            .fontColor($r('app.color.text_main'))
            .onClick(() => {
              this.switchTrack(1);
            })
        }

        Row({ space: 12 }) {
          Button(this.speedLabels[this.speedIdx])
            .height(34)
            .fontSize(13)
            .backgroundColor($r('app.color.card_bg'))
            .fontColor($r('app.color.text_main'))
            .onClick(() => {
              this.cycleSpeed();
            })
          Button(this.loopLabel())
            .height(34)
            .fontSize(13)
            .backgroundColor($r('app.color.card_bg'))
            .fontColor($r('app.color.text_main'))
            .onClick(() => {
              this.cycleLoopMode();
            })
          Text((this.index + 1) + ' / ' + this.tracks.length +
            (this.extText().length > 0 ? ' · ' + this.extText() : ''))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .margin({ bottom: 10 })

        Blank()
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.theme_bg'))
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          PanGesture({ direction: PanDirection.Up, distance: 30 })
            .onActionEnd(() => {
              this.switchTrack(1);
            }),
          PanGesture({ direction: PanDirection.Down, distance: 30 })
            .onActionEnd(() => {
              this.switchTrack(-1);
            }),
          PanGesture({ direction: PanDirection.Right, distance: 30 })
            .onActionEnd(() => {
              this.seekBy(10000);
            }),
          PanGesture({ direction: PanDirection.Left, distance: 30 })
            .onActionEnd(() => {
              this.seekBy(-10000);
            })
        )
      )
    }
    .title('正在播放')
    .hideTitleBar(false)
    .backgroundColor($r('app.color.theme_bg'))
  }
}
