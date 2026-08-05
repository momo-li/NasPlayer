import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
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

  @State index: number = 0;
  @State playing: boolean = false;
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State completed: boolean = false;
  @State currentTime: number = 0;
  @State duration: number = 0;
  @State controlsVisible: boolean = true;
  @State speedIdx: number = 1;

  private speedValues: media.PlaybackSpeed[] = [
    media.PlaybackSpeed.SPEED_FORWARD_0_75_X,
    media.PlaybackSpeed.SPEED_FORWARD_1_00_X,
    media.PlaybackSpeed.SPEED_FORWARD_1_25_X,
    media.PlaybackSpeed.SPEED_FORWARD_1_50_X,
    media.PlaybackSpeed.SPEED_FORWARD_2_00_X
  ];
  private speedLabels: string[] = ['0.75x', '1.0x', '1.25x', '1.5x', '2.0x'];

  private get files(): VideoEntry[] {
    return this.params.files;
  }

  aboutToAppear(): void {
    this.index = this.params.index;
    this.enterLandscape();
  }

  aboutToDisappear(): void {
    this.cleanup();
  }

  onPageHide(): void {
    this.pauseIfPlaying();
  }

  private showToast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private async enterLandscape(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx !== undefined) {
        const win = await window.getLastWindow(ctx);
        await win.setPreferredOrientation(window.Orientation.LANDSCAPE);
        await win.setWindowSystemBarEnable([]);
      }
    } catch (e) {
      console.error('enter landscape failed: ' + JSON.stringify(e));
    }
  }

  private async exitLandscape(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx !== undefined) {
        const win = await window.getLastWindow(ctx);
        await win.setPreferredOrientation(window.Orientation.PORTRAIT);
        await win.setWindowSystemBarEnable(['status', 'navigation']);
      }
    } catch (e) {
      console.error('exit landscape failed: ' + JSON.stringify(e));
    }
  }

  private async cleanup(): Promise<void> {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    const p = this.avPlayer;
    this.avPlayer = undefined;
    if (p !== undefined) {
      try {
        await p.release();
      } catch (e) {
        console.error('release player failed: ' + JSON.stringify(e));
      }
    }
    await StreamServer.getInstance().stop();
    await this.exitLandscape();
  }

  private pauseIfPlaying(): void {
    const p = this.avPlayer;
    if (p !== undefined && this.playing) {
      p.pause();
    }
  }

  private attachEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState) => {
      if (state === 'playing') {
        this.playing = true;
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
      this.loading = false;
      this.errorMsg = '播放失败，请确认视频格式受支持';
    });
    player.on('endOfStream', () => {
      this.completed = true;
    });
  }

  private async playEntry(entry: VideoEntry): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    this.completed = false;
    this.currentTime = 0;
    this.duration = 0;
    try {
      await StreamServer.getInstance().start();
      let player = this.avPlayer;
      if (player === undefined) {
        player = await media.createAVPlayer();
        this.attachEvents(player);
        this.avPlayer = player;
        if (this.surfaceId.length > 0) {
          player.surfaceId = this.surfaceId;
        }
      } else {
        await player.reset();
      }
      player.url = StreamServer.getInstance().urlFor(entry.path);
      await player.prepare();
      this.duration = player.duration;
      if (this.speedIdx !== 1) {
        player.setSpeed(this.speedValues[this.speedIdx]);
      }
      await player.play();
      this.loading = false;
    } catch (e) {
      console.error('play failed: ' + JSON.stringify(e));
      this.loading = false;
      this.errorMsg = '播放失败，请确认视频格式受支持';
    }
  }

  private async togglePlay(): Promise<void> {
    this.showControlsTemporarily();
    const p = this.avPlayer;
    if (p === undefined) {
      return;
    }
    try {
      if (this.playing) {
        await p.pause();
      } else {
        await p.play();
      }
    } catch (e) {
      console.error('toggle play failed: ' + JSON.stringify(e));
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

  private async switchTo(delta: number): Promise<void> {
    if (this.switchInProgress) {
      return;
    }
    const next = this.index + delta;
    if (next < 0) {
      this.showToast('已经是第一部视频');
      return;
    }
    if (next >= this.files.length) {
      this.showToast('已经是最后一部视频');
      return;
    }
    this.switchInProgress = true;
    try {
      this.index = next;
      await this.playEntry(this.files[next]);
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
          .onLoad(() => {
            this.surfaceId = this.xController.getXComponentSurfaceId();
            if (this.index >= 0 && this.index < this.files.length) {
              this.playEntry(this.files[this.index]);
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
                this.playEntry(this.files[this.index]);
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

        if (this.controlsVisible && this.errorMsg.length === 0) {
          Column() {
            Row({ space: 10 }) {
              Text(this.index >= 0 && this.index < this.files.length ? this.files[this.index].name : '')
                .fontSize(15)
                .fontColor(Color.White)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(this.speedLabels[this.speedIdx])
                .fontSize(13)
                .fontColor(Color.White)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor($r('app.color.player_overlay'))
                .borderRadius(12)
                .onClick(() => {
                  this.cycleSpeed();
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14 })

            Blank()

            Row({ space: 40 }) {
              Text('⏮')
                .fontSize(26)
                .fontColor(Color.White)
                .onClick(() => {
                  this.switchTo(-1);
                })
              Text(this.playing ? '⏸' : '▶')
                .fontSize(34)
                .fontColor(Color.White)
                .onClick(() => {
                  this.togglePlay();
                })
              Text('⏭')
                .fontSize(26)
                .fontColor(Color.White)
                .onClick(() => {
                  this.switchTo(1);
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)

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
            .padding({ left: 16, right: 16, bottom: 18 })
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
  }
}

