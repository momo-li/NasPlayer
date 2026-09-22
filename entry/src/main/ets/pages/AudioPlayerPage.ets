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
import { Lyrics, LyricLine, LyricsUtil } from '../service/LyricsUtil';

const DOMAIN = 0x0000;
const TAG = 'NasPlayer';
const SESSION_TAG = 'NasPlayer-Audio';
const SESSION_SYNC_INTERVAL_MS = 1000;
/** 起播后延迟多久预读相邻曲目元数据：太早会和刚起播的流抢带宽 */
const NEIGHBOR_PREFETCH_DELAY_MS = 2000;
/** 预读窗口：沿最近一次切歌方向预读 5 首，反方向保底 1 首（单首仅约 256KB，顺带把流首包也放进缓存） */
const PREFETCH_FORWARD = 5;
const PREFETCH_BACK = 1;

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
  private metaPrefetchTimer: number = -1;
  /** 最近一次切歌方向：+1 下一首 / -1 上一首，决定预读窗口往哪边倾斜 */
  private switchDir: number = 1;
  /** 预读轮次：切歌后旧轮次自动作废 */
  private prefetchSeq: number = 0;
  /** 上一次“播完”的处理时间：endOfStream 与 stateChange 双事件去重 */
  private lastFinishAt: number = 0;
  /** 上一次把 loopMode 上报给系统的时间，用于识别系统回抛 */
  private lastLoopModePushAt: number = 0;
  private lastPushedLoopMode: number = -1;
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
  @State lyrics: LyricLine[] = [];
  @State lyricsSynced: boolean = false;
  @State lyricsRaw: string = '';
  @State lyricIndex: number = -1;
  @State showLyrics: boolean = false;
  @State isLandscape: boolean = false;
  /** 歌词列表实测高度，用于计算首尾留白使任意行都能居中 */
  @State lyricViewH: number = 220;
  private lyricScroller: Scroller = new Scroller();

  
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
    this.lyrics = [];
    this.lyricsSynced = false;
    this.lyricsRaw = '';
    this.lyricIndex = -1;
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
      // 音频没有 moov 尾部，只等文件大小 + 最多 1.2s 头部预取，其余转后台，切换路径不再被预取拖住
      await this.withTimeout(StreamServer.getInstance().warmup(entry.path, 1200, false), 20000, '音频加载');
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
      this.scheduleNeighborMetaPrefetch();
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
        this.onTrackFinished();
      }
      this.syncSessionState();
    });
    player.on('timeUpdate', (time: number) => {
      if (!this.dragging) {
        this.currentTime = time;
        this.updateLyricIndex(time);
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
    // endOfStream 与 stateChange('completed') 都会到达，统一走 onTrackFinished 去重
    player.on('endOfStream', () => {
      this.onTrackFinished();
    });
  }

  /** 一曲播完：去重后延后一拍再续播（不在播放器回调里直接 reset/换源，避免状态机重入卡住） */
  private onTrackFinished(): void {
    if (this.destroyed) {
      return;
    }
    const now = Date.now();
    if (now - this.lastFinishAt < 1500) {
      return;
    }
    this.lastFinishAt = now;
    const finishedIndex = this.index;
    this.playing = false;
    this.completed = true;
    this.syncSessionState();
    hilog.info(DOMAIN, TAG, 'track finished index=%{public}d mode=%{public}d',
      finishedIndex, this.loopMode);
    setTimeout(() => {
      this.autoNext(finishedIndex, 0);
    }, 250);
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
    let target = this.index + delta;
    if (this.loopMode === avSession.LoopMode.LOOP_MODE_SHUFFLE && this.tracks.length > 1) {
      // 随机模式下手动切歌也要跳随机：否则“随机”只在自动续播时生效，用户点下一曲仍按顺序走，看起来像功能失效
      target = Math.floor(Math.random() * this.tracks.length);
      if (target === this.index) {
        target = (target + 1) % this.tracks.length;
      }
    } else {
      if (target < 0) {
        this.showToast('已经是第一首');
        return;
      }
      if (target >= this.tracks.length) {
        this.showToast('已经是最后一首');
        return;
      }
    }
    this.switchInProgress = true;
    try {
      this.switchDir = delta >= 0 ? 1 : -1;
      this.index = target;
      await this.playTrack(this.tracks[target]);
    } finally {
      this.switchInProgress = false;
    }
  }

  /**
   * 播放完成后的续播逻辑，遵循播控中心设置的循环模式。
   * fromIndex 为播完的那一首：若期间用户已手动切歌（index 变了）就不再自动续播，避免覆盖用户选择；
   * 若正处在切歌过程中则稍后重试，而不是把“自动下一首”直接丢掉。
   */
  private autoNext(fromIndex: number, attempt: number): void {
    if (this.destroyed || this.index !== fromIndex) {
      hilog.info(DOMAIN, TAG, 'autoNext skipped destroyed=%{public}s index=%{public}d from=%{public}d',
        String(this.destroyed), this.index, fromIndex);
      return;
    }
    if (this.switchInProgress) {
      hilog.info(DOMAIN, TAG, 'autoNext deferred, switching in progress attempt=%{public}d', attempt);
      if (attempt < 5) {
        setTimeout(() => {
          this.autoNext(fromIndex, attempt + 1);
        }, 400);
      }
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
      this.showToast('已经是最后一首，切换“列表”模式可循环播放');
      return;
    }
    this.switchInProgress = true;
    if (mode !== avSession.LoopMode.LOOP_MODE_SHUFFLE) {
      this.switchDir = 1;
    } else {
      this.switchDir = next >= this.index ? 1 : -1;
    }
    hilog.info(DOMAIN, TAG, 'autoNext from=%{public}d to=%{public}d mode=%{public}d',
      this.index, next, mode);
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
        if (this.speedIdx !== 1) {
          p.setSpeed(this.speedValues[this.speedIdx]);
        }
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
        // 暂停会丢失倍速设置，恢复播放时重新应用，避免界面显示与实际播放速度不一致
        if (this.speedIdx !== 1) {
          p.setSpeed(this.speedValues[this.speedIdx]);
        }
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
    this.updateLyricIndex(target);
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
      this.updateLyricIndex(v);
      return;
    }
    if (m === SliderChangeMode.Moving) {
      this.currentTime = v;
      this.updateLyricIndex(v);
      return;
    }
    this.dragging = false;
    this.seekTo(v);
  }

  // ---------------- 歌词 ----------------

  /** 根据播放进度定位当前歌词行；无时间轴歌词不做高亮与滚动 */
  private updateLyricIndex(time: number): void {
    if (!this.lyricsSynced || this.lyrics.length === 0) {
      return;
    }
    let idx = -1;
    for (let i = 0; i < this.lyrics.length; i++) {
      if (this.lyrics[i].timeMs <= time) {
        idx = i;
      } else {
        break;
      }
    }
    if (idx === this.lyricIndex) {
      return;
    }
    this.lyricIndex = idx;
    this.scrollLyricTo(idx);
  }

  private scrollLyricTo(idx: number): void {
    if (!this.showLyrics || idx < 0) {
      return;
    }
    try {
      // 上下各留半个可视高度，配合 ScrollAlign.CENTER 让当前行停在列表中间
      this.lyricScroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
    } catch (e) {
      hilog.debug(DOMAIN, TAG, 'lyric scroll failed: %{public}s', JSON.stringify(e));
    }
  }

  private toggleLyrics(): void {
    this.showLyrics = !this.showLyrics;
    if (this.showLyrics) {
      // 等 List 挂载后再定位到当前行
      setTimeout(() => {
        this.scrollLyricTo(this.lyricIndex);
      }, 60);
    }
  }

  private lyricSpacerH(): number {
    const h = this.lyricViewH / 2 - 26;
    return h > 30 ? h : 30;
  }

  // ---------------- 元数据 ----------------

  /** 起播后延迟预读相邻曲目的元数据：弱网下切换时标题/封面直接命中缓存，不再等 SMB */
  private scheduleNeighborMetaPrefetch(): void {
    if (this.metaPrefetchTimer >= 0) {
      clearTimeout(this.metaPrefetchTimer);
    }
    this.metaPrefetchTimer = setTimeout(() => {
      this.metaPrefetchTimer = -1;
      this.prefetchNeighborMeta();
    }, NEIGHBOR_PREFETCH_DELAY_MS);
  }

  /** 预读窗口路径：先沿切歌方向由近到远，再补反方向，越界即止 */
  private metaPrefetchPaths(): string[] {
    const paths: string[] = [];
    const total = this.tracks.length;
    const dir = this.switchDir >= 0 ? 1 : -1;
    for (let k = 1; k <= PREFETCH_FORWARD; k++) {
      const i = this.index + dir * k;
      if (i < 0 || i >= total) {
        break;
      }
      paths.push(this.tracks[i].path);
    }
    for (let k = 1; k <= PREFETCH_BACK; k++) {
      const i = this.index - dir * k;
      if (i < 0 || i >= total) {
        break;
      }
      paths.push(this.tracks[i].path);
    }
    return paths;
  }

  /** 串行预读窗口内曲目；用户中途切歌（seq 变化）立刻让路，不抢占正在播放的带宽 */
  private async prefetchNeighborMeta(): Promise<void> {
    const seq = this.prefetchSeq + 1;
    this.prefetchSeq = seq;
    const paths = this.metaPrefetchPaths();
    for (let i = 0; i < paths.length; i++) {
      if (this.destroyed || this.switchInProgress || this.prefetchSeq !== seq) {
        return;
      }
      const path = paths[i];
      try {
        await AudioMetaUtil.getInstance().get(path);
        hilog.info(DOMAIN, TAG, 'neighbor meta prefetched path=%{public}s', path);
      } catch (e) {
        hilog.debug(DOMAIN, TAG, 'neighbor meta prefetch failed: %{public}s', JSON.stringify(e));
      }
    }
  }

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
    this.loadLyrics(entry, meta.lyricText);
  }

  /** 歌词按「同名 .lrc → 内嵌歌词」顺序加载，失败不影响播放 */
  private async loadLyrics(entry: VideoEntry, embeddedText: string): Promise<void> {
    const ly: Lyrics = await LyricsUtil.getInstance().load(entry.path, embeddedText);
    const cur = this.currentEntry();
    if (this.destroyed || cur === undefined || cur.path !== entry.path) {
      return;
    }
    this.lyrics = ly.lines;
    this.lyricsSynced = ly.synced;
    this.lyricsRaw = ly.raw;
    this.lyricIndex = -1;
    hilog.info(DOMAIN, TAG, 'lyrics loaded path=%{public}s lines=%{public}d synced=%{public}s',
      entry.path, ly.lines.length, String(ly.synced));
    this.updateLyricIndex(this.currentTime);
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
        // 系统可能把我们刚上报的 loopMode 回抛（还可能被规范化成别的值），这会直接吃掉用户选的“随机”；
        // 因此刚上报过的短时间内收到不同值时保留本地意图，真正的播控中心操作才覆盖
        if (mode !== this.loopMode && Date.now() - this.lastLoopModePushAt < 1500) {
          hilog.info(DOMAIN, TAG, 'ignore echoed setLoopMode=%{public}d keep=%{public}d', mode, this.loopMode);
          return;
        }
        hilog.info(DOMAIN, TAG, 'session setLoopMode=%{public}d', mode);
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
    if (this.lyricsRaw.length > 0) {
      md.lyric = this.lyricsRaw;
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
    // 记录 loopMode 变更的上报时刻，用于识别系统的回抛（见 setupSession 里的 setLoopMode）
    if (this.lastPushedLoopMode !== this.loopMode) {
      this.lastPushedLoopMode = this.loopMode;
      this.lastLoopModePushAt = Date.now();
    }
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
    if (this.metaPrefetchTimer >= 0) {
      clearTimeout(this.metaPrefetchTimer);
      this.metaPrefetchTimer = -1;
    }
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

  // ---------------- 歌词/控制 @Builder ----------------

  /** 媒体区：封面与歌词共用同一块区域，点击切换；歌词模式背景透明，直接浮在页面底色上 */
  @Builder
  mediaBox(boxW: Length, boxH: Length) {
    Stack({ alignContent: Alignment.Center }) {
      if (this.showLyrics) {
        this.lyricsView(boxH)
      } else if (this.cover !== undefined) {
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
    .width(boxW)
    .height(boxH)
    .backgroundColor(this.showLyrics ? Color.Transparent : $r('app.color.poster_bg'))
    .borderRadius(16)
    .clip(true)
    .onClick(() => {
      this.toggleLyrics();
    })
  }

  /** 歌词列表：当前行高亮并居中。有时间轴时禁用列表自身滚动（交给自动跟随，同时避免吞掉切歌手势），无时间轴时允许手动滚动 */
  @Builder
  lyricsView(boxH: Length) {
    if (this.lyrics.length === 0) {
      Column({ space: 8 }) {
        Text('♪')
          .fontSize(28)
          .fontColor($r('app.color.text_secondary'))
        Text('暂无歌词')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
    } else {
      List({ space: 12, scroller: this.lyricScroller }) {
        ForEach(this.lyrics, (item: LyricLine, idx: number) => {
          ListItem() {
            Text(item.text.length > 0 ? item.text : ' ')
              .fontSize(idx === this.lyricIndex ? 18 : 16)
              .fontWeight(idx === this.lyricIndex ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(idx === this.lyricIndex
                ? $r('app.color.theme_primary')
                : $r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
        }, (item: LyricLine, idx: number) => idx + '|' + item.timeMs + '|' + item.text)
      }
      .width('100%')
      .height(boxH)
      .scrollBar(BarState.Off)
      .enableScrollInteraction(!this.lyricsSynced)
      .contentStartOffset(this.lyricSpacerH())
      .contentEndOffset(this.lyricSpacerH())
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const h = newArea.height;
        if (typeof h === 'number' && h > 0) {
          this.lyricViewH = h;
        }
      })
    }
  }

  @Builder
  titleBlock() {
    Column({ space: 6 }) {
      Text(this.titleText.length > 0 ? this.titleText : this.currentName())
        .fontSize(this.isLandscape ? 21 : 24)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_main'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
      Text(this.subText())
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .width('100%')
    .padding({ left: this.isLandscape ? 8 : 24, right: this.isLandscape ? 8 : 24 })
  }

  @Builder
  playControls() {
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
    .padding({ left: this.isLandscape ? 8 : 20, right: this.isLandscape ? 8 : 20 })

    Row({ space: this.isLandscape ? 10 : 14 }) {
      Button('上一曲')
        .height(this.isLandscape ? 36 : 44)
        .fontSize(this.isLandscape ? 13 : 15)
        .backgroundColor($r('app.color.card_bg'))
        .fontColor($r('app.color.text_main'))
        .onClick(() => {
          this.switchTrack(-1);
        })
      Button(this.playing ? '暂停' : '播放')
        .width(this.isLandscape ? 88 : 104)
        .height(this.isLandscape ? 40 : 48)
        .fontSize(this.isLandscape ? 14 : 16)
        .backgroundColor($r('app.color.theme_primary'))
        .onClick(() => {
          this.togglePlay();
        })
      Button('下一曲')
        .height(this.isLandscape ? 36 : 44)
        .fontSize(this.isLandscape ? 13 : 15)
        .backgroundColor($r('app.color.card_bg'))
        .fontColor($r('app.color.text_main'))
        .onClick(() => {
          this.switchTrack(1);
        })
    }

    Row({ space: this.isLandscape ? 8 : 12 }) {
      Button(this.speedLabels[this.speedIdx])
        .height(this.isLandscape ? 30 : 34)
        .fontSize(this.isLandscape ? 12 : 13)
        .backgroundColor($r('app.color.card_bg'))
        .fontColor($r('app.color.text_main'))
        .onClick(() => {
          this.cycleSpeed();
        })
      Button(this.loopLabel())
        .height(this.isLandscape ? 30 : 34)
        .fontSize(this.isLandscape ? 12 : 13)
        .backgroundColor($r('app.color.card_bg'))
        .fontColor($r('app.color.text_main'))
        .onClick(() => {
          this.cycleLoopMode();
        })
      Button(this.showLyrics ? '封面' : '歌词')
        .height(this.isLandscape ? 30 : 34)
        .fontSize(this.isLandscape ? 12 : 13)
        .backgroundColor($r('app.color.card_bg'))
        .fontColor($r('app.color.text_main'))
        .onClick(() => {
          this.toggleLyrics();
        })
      Text((this.index + 1) + ' / ' + this.tracks.length +
        (this.extText().length > 0 ? ' · ' + this.extText() : ''))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
  }

  build() {
    NavDestination() {
      Stack() {
        if (this.isLandscape) {
          Row({ space: 16 }) {
            Column() {
              // 横屏：海报与歌词共用同一块媒体区（同宽同高），切换时布局不跳变
              this.mediaBox('100%', '100%')
            }
            .width('56%')
            .height('100%')
            .justifyContent(FlexAlign.Center)

            Scroll() {
              Column({ space: 10 }) {
                this.titleBlock()
                this.playControls()
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
            }
            .layoutWeight(1)
            .height('100%')
            .scrollBar(BarState.Off)
          }
          .width('100%')
          .height('100%')
          .padding({ left: 16, right: 16 })
        } else {
          Column({ space: 14 }) {
            if (this.showLyrics) {
              Column() {
                this.mediaBox('100%', '100%')
              }
              .width('100%')
              .layoutWeight(1)
              .padding({ left: 16, right: 16 })
            } else {
              this.mediaBox(220, 220)
            }
            this.titleBlock()
            if (!this.showLyrics) {
              Blank()
            }
            this.playControls()
          }
          .width('100%')
          .height('100%')
          .padding({ top: 26, bottom: 12 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.theme_bg'))
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const w = newArea.width;
        const h = newArea.height;
        if (typeof w === 'number' && typeof h === 'number' && h > 0) {
          const land = w > h * 1.15;
          if (land !== this.isLandscape) {
            this.isLandscape = land;
          }
        }
      })
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
