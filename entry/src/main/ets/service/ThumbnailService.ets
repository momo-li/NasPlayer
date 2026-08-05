import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { SmbService } from './SmbService';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'ThumbnailService';
const THUMB_MAX_BYTES = 50 * 1024 * 1024;
const THUMB_DIR = 'thumbs';
const DOWNLOAD_CHUNK = 512 * 1024;
const CACHE_LIMIT = 40;

export class ThumbnailService {
  private static instance: ThumbnailService = new ThumbnailService();
  private context: common.UIAbilityContext | undefined = undefined;
  private cache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private inFlight: Set<string> = new Set<string>();

  static getInstance(): ThumbnailService {
    return ThumbnailService.instance;
  }

  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  async request(path: string, size: number): Promise<image.PixelMap | undefined> {
    const cached = this.cache.get(path);
    if (cached !== undefined) {
      return cached;
    }
    if (size <= 0 || size > THUMB_MAX_BYTES || this.inFlight.has(path)) {
      return undefined;
    }
    this.inFlight.add(path);
    try {
      const pm = await this.load(path, size);
      if (pm !== undefined) {
        this.evictIfNeeded();
        this.cache.set(path, pm);
      }
      return pm;
    } catch (e) {
      hilog.debug(DOMAIN, TAG, 'thumbnail failed for %{public}s: %{public}s', path, JSON.stringify(e));
      return undefined;
    } finally {
      this.inFlight.delete(path);
    }
  }

  private evictIfNeeded(): void {
    while (this.cache.size >= CACHE_LIMIT) {
      const keys = Array.from(this.cache.keys());
      if (keys.length === 0) {
        break;
      }
      const old = this.cache.get(keys[0]);
      if (old !== undefined) {
        old.release();
      }
      this.cache.delete(keys[0]);
    }
  }

  private localFileName(path: string): string {
    const sanitized = path.split('\\').join('_').split('/').join('_').split(':').join('_');
    return sanitized.length > 100 ? sanitized.substring(sanitized.length - 100) : sanitized;
  }

  private async load(path: string, size: number): Promise<image.PixelMap | undefined> {
    if (this.context === undefined) {
      return undefined;
    }
    const dir = this.context.filesDir + '/' + THUMB_DIR;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir);
    }
    const localFile = dir + '/' + this.localFileName(path);
    let file: fs.File | undefined = undefined;
    try {
      if (!fs.accessSync(localFile) || fs.statSync(localFile).size !== size) {
        if (fs.accessSync(localFile)) {
          fs.unlinkSync(localFile);
        }
        file = fs.openSync(localFile, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        let offset = 0;
        while (offset < size) {
          const n = Math.min(DOWNLOAD_CHUNK, size - offset);
          const data = await SmbService.getInstance().readRange(path, offset, n);
          if (data.length === 0) {
            break;
          }
          fs.writeSync(file.fd, data.buffer as ArrayBuffer);
          offset += data.length;
        }
        fs.closeSync(file);
        file = undefined;
      }
      const readFile = fs.openSync(localFile, fs.OpenMode.READ_ONLY);
      const fd = readFile.fd;
      const gen = await media.createAVImageGenerator();
      try {
        const desc: media.AVFileDescriptor = { fd: fd, offset: 0, length: size };
        gen.fdSrc = desc;
        const outSize: media.OutputSize = { width: 360, height: 200 };
        const pm = await gen.fetchScaledFrameByTime(1000000,
          media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST, outSize);
        return pm;
      } catch (e) {
        hilog.debug(DOMAIN, TAG, 'fetchFrame failed: %{public}s', JSON.stringify(e));
        return undefined;
      } finally {
        try {
          await gen.release();
        } catch (e) {
          hilog.debug(DOMAIN, TAG, 'gen release failed');
        }
        fs.closeSync(readFile);
      }
    } finally {
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (e) {
          hilog.debug(DOMAIN, TAG, 'close failed');
        }
      }
    }
  }
}
