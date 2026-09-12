import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SmbService } from './SmbService';

const DOMAIN = 0x0000;
const TAG = 'NasPlayer';

/** SMB 图片加载器：整文件读取 → PixelMap 解码（按屏幕分辨率降采样）→ LRU 缓存 */
export class ImageLoader {
  private static readonly MAX_CACHED: number = 4;
  private static readonly MAX_FILE_BYTES: number = 32 * 1024 * 1024;

  private cache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private keyOrder: string[] = [];
  private pending: Map<string, Promise<image.PixelMap>> = new Map<string, Promise<image.PixelMap>>();
  private protectedPaths: string[] = [];
  private closed: boolean = false;

  /** 当前页及相邻页路径：缓存淘汰时跳过，避免释放正在显示的图片 */
  setProtected(paths: string[]): void {
    this.protectedPaths = paths;
  }

  async load(path: string): Promise<image.PixelMap> {
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
      const pm = await task;
      if (this.closed) {
        await ImageLoader.releaseQuietly(pm);
        throw new Error('图片查看器已关闭');
      }
      this.cachePut(path, pm);
      return pm;
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

  private async loadInternal(path: string): Promise<image.PixelMap> {
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
      const cap = ImageLoader.decodeCapPx();
      if (w > 0 && h > 0 && (w > cap || h > cap)) {
        const ratio = Math.min(cap / w, cap / h);
        const ds: image.Size = { width: Math.round(w * ratio), height: Math.round(h * ratio) };
        const opts: image.DecodingOptions = { desiredSize: ds };
        const pm = await source.createPixelMap(opts);
        hilog.info(DOMAIN, TAG, 'image decoded path=%{public}s bytes=%{public}d cost=%{public}dms target=%{public}dx%{public}d',
          path, size, Date.now() - startedAt, ds.width, ds.height);
        return pm;
      }
      const pm = await source.createPixelMap();
      hilog.info(DOMAIN, TAG, 'image decoded path=%{public}s bytes=%{public}d cost=%{public}dms native=%{public}dx%{public}d',
        path, size, Date.now() - startedAt, w, h);
      return pm;
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

  private cachePut(path: string, pm: image.PixelMap): void {
    this.cache.set(path, pm);
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

  private static async releaseQuietly(pm: image.PixelMap): Promise<void> {
    try {
      await pm.release();
    } catch (e) {
      hilog.debug(DOMAIN, TAG, 'pixel map release failed: %{public}s', JSON.stringify(e));
    }
  }
}
