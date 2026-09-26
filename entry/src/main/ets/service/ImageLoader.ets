import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SmbService } from './SmbService';

const DOMAIN = 0x0000;
const TAG = 'NasPlayer';

/** 解码结果：静态图为单帧，动图（GIF / 动态 WebP）为多帧并带每帧时长 */
export class LoadedImage {
  readonly frames: image.PixelMap[];
  readonly durations: number[];
  readonly animated: boolean;

  constructor(frames: image.PixelMap[], durations: number[], animated: boolean) {
    this.frames = frames;
    this.durations = durations;
    this.animated = animated;
  }
}

/** SMB 图片加载器：整文件读取 → PixelMap 解码（按屏幕分辨率降采样）→ LRU 缓存 */
export class ImageLoader {
  private static readonly MAX_CACHED: number = 3;
  private static readonly MAX_FILE_BYTES: number = 32 * 1024 * 1024;
  private static readonly MAX_ANIM_FRAMES: number = 200;
  private static readonly MAX_ANIM_PIXELS: number = 48 * 1024 * 1024;
  private static readonly MIN_ANIM_SIDE: number = 160;
  private static readonly DEFAULT_FRAME_DELAY: number = 100;

  private cache: Map<string, LoadedImage> = new Map<string, LoadedImage>();
  private keyOrder: string[] = [];
  private pending: Map<string, Promise<LoadedImage>> = new Map<string, Promise<LoadedImage>>();
  private protectedPaths: string[] = [];
  private closed: boolean = false;

  /** 当前页及相邻页路径：缓存淘汰时跳过，避免释放正在显示的图片 */
  setProtected(paths: string[]): void {
    this.protectedPaths = paths;
  }

  async load(path: string): Promise<LoadedImage> {
    if (this.closed) {
      throw new Error('图片查看器已关闭');
    }
    const hit = this.cache.get(path);
    if (hit !== undefined) {
      this.touch(path);
      return hit;
    }
    const inFlight = this.pending.get(path);
    if (inFlight !== undefined) {
      return inFlight;
    }
    const task = this.loadInternal(path);
    this.pending.set(path, task);
    try {
      const img = await task;
      if (this.closed) {
        await ImageLoader.releaseAll(img.frames);
        throw new Error('图片查看器已关闭');
      }
      this.cachePut(path, img);
      return img;
    } finally {
      this.pending.delete(path);
    }
  }

  /** 页面退出：清空引用并拒绝后续加载；不做显式 release，避免释放仍被渲染的 PixelMap */
  clear(): void {
    this.closed = true;
    this.cache.clear();
    this.keyOrder = [];
    this.pending.clear();
    this.protectedPaths = [];
  }

  private async loadInternal(path: string): Promise<LoadedImage> {
    const startedAt = Date.now();
    const smb = SmbService.getInstance();
    let size = 0;
    try {
      size = await smb.getSize(path);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'image size failed path=%{public}s err=%{public}s', path, JSON.stringify(e));
      throw new Error('图片加载失败，请检查网络');
    }
    if (size <= 0) {
      throw new Error('图片文件为空或不可读');
    }
    if (size > ImageLoader.MAX_FILE_BYTES) {
      throw new Error('图片过大，暂不支持查看');
    }
    let data: Uint8Array;
    try {
      data = await smb.readRange(path, 0, size);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'image read failed path=%{public}s err=%{public}s', path, JSON.stringify(e));
      throw new Error('图片加载失败，请检查网络');
    }
    if (data.length === 0) {
      throw new Error('图片文件为空或不可读');
    }
    const ab = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
    let source: image.ImageSource | undefined = undefined;
    try {
      source = image.createImageSource(ab);
      const info: image.ImageInfo = source.getImageInfoSync();
      const w = info.size.width;
      const h = info.size.height;
      let frameCount = 1;
      try {
        frameCount = await source.getFrameCount();
      } catch (e) {
        frameCount = 1;
      }
      if (frameCount > 1) {
        try {
          const anim = await ImageLoader.decodeAnimated(source, w, h, frameCount);
          if (anim.animated) {
            hilog.info(DOMAIN, TAG,
              'animated decoded path=%{public}s bytes=%{public}d frames=%{public}d cost=%{public}dms',
              path, size, anim.frames.length, Date.now() - startedAt);
            return anim;
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'animated decode failed, fallback static path=%{public}s err=%{public}s',
            path, JSON.stringify(e));
        }
      }
      const cap = ImageLoader.decodeCapPx();
      if (w > 0 && h > 0 && (w > cap || h > cap)) {
        const ratio = Math.min(cap / w, cap / h);
        const ds: image.Size = { width: Math.round(w * ratio), height: Math.round(h * ratio) };
        const opts: image.DecodingOptions = { desiredSize: ds };
        const pm = await source.createPixelMap(opts);
        hilog.info(DOMAIN, TAG, 'image decoded path=%{public}s bytes=%{public}d cost=%{public}dms target=%{public}dx%{public}d',
          path, size, Date.now() - startedAt, ds.width, ds.height);
        return new LoadedImage([pm], [], false);
      }
      const pm = await source.createPixelMap();
      hilog.info(DOMAIN, TAG, 'image decoded path=%{public}s bytes=%{public}d cost=%{public}dms native=%{public}dx%{public}d',
        path, size, Date.now() - startedAt, w, h);
      return new LoadedImage([pm], [], false);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'image decode failed path=%{public}s err=%{public}s', path, JSON.stringify(e));
      throw new Error('无法解码该图片');
    } finally {
      if (source !== undefined) {
        try {
          await source.release();
        } catch (e) {
          hilog.debug(DOMAIN, TAG, 'image source release failed: %{public}s', JSON.stringify(e));
        }
      }
    }
  }

  /**
   * 逐帧解码动图：frameCount 超限时按 stride 抽帧，并为抽取后的帧累加时长，
   * 避免 createPixelMapList 一次性解码全部帧带来的内存峰值。
   */
  private static async decodeAnimated(source: image.ImageSource, w: number, h: number,
    frameCount: number): Promise<LoadedImage> {
    let delays: number[] = [];
    try {
      delays = await source.getDelayTimeList();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'animated delay list failed: %{public}s', JSON.stringify(e));
    }
    const stride = Math.max(1, Math.ceil(frameCount / ImageLoader.MAX_ANIM_FRAMES));
    const count = Math.max(1, Math.ceil(frameCount / stride));
    const ds = ImageLoader.animatedSize(w, h, count);
    const frames: image.PixelMap[] = [];
    const durations: number[] = [];
    for (let i = 0; i < frameCount; i += stride) {
      const opts: image.DecodingOptions = {
        desiredSize: ds,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        index: i
      };
      const pm = await source.createPixelMap(opts);
      let delay = 0;
      for (let k = i; k < i + stride && k < delays.length; k++) {
        delay += delays[k];
      }
      if (delay <= 0) {
        delay = ImageLoader.DEFAULT_FRAME_DELAY * stride;
      }
      frames.push(pm);
      durations.push(delay);
    }
    return new LoadedImage(frames, durations, frames.length > 1);
  }

  /** 动图解码尺寸：先按屏幕长边降采样，再按总帧像素预算继续缩小 */
  private static animatedSize(w: number, h: number, frameCount: number): image.Size {
    const cap = ImageLoader.decodeCapPx();
    let ratio = 1;
    if (w > 0 && h > 0 && (w > cap || h > cap)) {
      ratio = Math.min(cap / w, cap / h);
    }
    let dw = Math.max(1, Math.round(w > 0 ? w * ratio : 1));
    let dh = Math.max(1, Math.round(h > 0 ? h * ratio : 1));
    while (frameCount * dw * dh > ImageLoader.MAX_ANIM_PIXELS &&
      Math.min(dw, dh) > ImageLoader.MIN_ANIM_SIDE) {
      dw = Math.max(1, Math.floor(dw * 0.85));
      dh = Math.max(1, Math.floor(dh * 0.85));
    }
    const size: image.Size = { width: dw, height: dh };
    return size;
  }

  /** 解码目标上限取屏幕长边（px），小图按原尺寸解码，不放大 */
  private static decodeCapPx(): number {
    try {
      const d = display.getDefaultDisplaySync();
      const cap = Math.max(d.width, d.height);
      if (cap > 0) {
        return cap;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'get display size failed: %{public}s', JSON.stringify(e));
    }
    return 2560;
  }

  private touch(path: string): void {
    const idx = this.keyOrder.indexOf(path);
    if (idx >= 0) {
      this.keyOrder.splice(idx, 1);
    }
    this.keyOrder.push(path);
  }

  private cachePut(path: string, img: LoadedImage): void {
    this.cache.set(path, img);
    this.touch(path);
    this.evictIfNeeded();
  }

  private evictIfNeeded(): void {
    while (this.keyOrder.length > ImageLoader.MAX_CACHED) {
      let victimIdx = -1;
      for (let i = 0; i < this.keyOrder.length; i++) {
        if (this.protectedPaths.indexOf(this.keyOrder[i]) < 0) {
          victimIdx = i;
          break;
        }
      }
      if (victimIdx < 0) {
        break;
      }
      const victim = this.keyOrder[victimIdx];
      this.keyOrder.splice(victimIdx, 1);
      this.cache.delete(victim);
    }
  }

  private static async releaseAll(frames: image.PixelMap[]): Promise<void> {
    for (let i = 0; i < frames.length; i++) {
      await ImageLoader.releaseQuietly(frames[i]);
    }
  }

  private static async releaseQuietly(pm: image.PixelMap): Promise<void> {
    try {
      await pm.release();
    } catch (e) {
      hilog.debug(DOMAIN, TAG, 'pixel map release failed: %{public}s', JSON.stringify(e));
    }
  }
}
