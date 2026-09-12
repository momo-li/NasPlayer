import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SmbService } from './SmbService';

const DOMAIN = 0x0000;
const TAG = 'NasPlayer';
/** 预读文件头长度：MP3/FLAC/WAV 的标签与封面通常在文件头部 */
const HEAD_BYTES = 1048576;
const MAX_CACHED = 8;

export class AudioMeta {
  title: string = '';
  artist: string = '';
  album: string = '';
  cover: image.PixelMap | undefined = undefined;

  static of(title: string, artist: string, album: string, cover: image.PixelMap | undefined): AudioMeta {
    const m = new AudioMeta();
    m.title = title;
    m.artist = artist;
    m.album = album;
    m.cover = cover;
    return m;
  }
}

/** 解析音频 ID3 元数据：SMB 预读文件头 → AVMetadataExtractor（内存 dataSrc 同步供应）→ 标题/艺术家/封面 */
export class AudioMetaUtil {
  private static instance: AudioMetaUtil = new AudioMetaUtil();
  private cache: Map<string, AudioMeta> = new Map<string, AudioMeta>();
  private keyOrder: string[] = [];

  static getInstance(): AudioMetaUtil {
    return AudioMetaUtil.instance;
  }

  async get(path: string): Promise<AudioMeta> {
    const hit = this.cache.get(path);
    if (hit !== undefined) {
      this.touch(path);
      return hit;
    }
    let meta: AudioMeta;
    try {
      meta = await this.extract(path);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'audio meta failed path=%{public}s err=%{public}s',
        path, JSON.stringify(e));
      meta = AudioMeta.of(AudioMetaUtil.baseName(path), '', '', undefined);
    }
    this.cachePut(path, meta);
    return meta;
  }

  private async extract(path: string): Promise<AudioMeta> {
    const smb = SmbService.getInstance();
    const size = await smb.getSize(path);
    if (size <= 0) {
      throw new Error('文件为空');
    }
    const headLen = Math.min(size, HEAD_BYTES);
    const data = await smb.readRange(path, 0, headLen);
    if (data.length === 0) {
      throw new Error('读取失败');
    }
    const extractor = await media.createAVMetadataExtractor();
    try {
      const src: media.AVDataSrcDescriptor = {
        fileSize: data.length,
        callback: (buffer: ArrayBuffer, length: number, pos?: number): number => {
          const start = pos === undefined ? 0 : pos;
          if (start >= data.length) {
            return -1;
          }
          const n = Math.min(length, data.length - start);
          const dst = new Uint8Array(buffer);
          dst.set(data.slice(start, start + n));
          return n;
        }
      };
      extractor.dataSrc = src;
      const md: media.AVMetadata = await extractor.fetchMetadata();
      let title = AudioMetaUtil.baseName(path);
      if (md.title !== undefined && md.title.length > 0) {
        title = md.title;
      }
      let artist = '';
      if (md.artist !== undefined) {
        artist = md.artist;
      }
      let album = '';
      if (md.album !== undefined) {
        album = md.album;
      }
      let cover: image.PixelMap | undefined = undefined;
      try {
        cover = await extractor.fetchAlbumCover();
      } catch (e) {
        cover = undefined;
      }
      hilog.info(DOMAIN, TAG, 'audio meta ok path=%{public}s title=%{public}s artist=%{public}s cover=%{public}s',
        path, title, artist, String(cover !== undefined));
      return AudioMeta.of(title, artist, album, cover);
    } finally {
      try {
        await extractor.release();
      } catch (e) {
        hilog.debug(DOMAIN, TAG, 'metadata extractor release failed: %{public}s', JSON.stringify(e));
      }
    }
  }

  /** 无标签时回退为“去掉扩展名的文件名” */
  private static baseName(path: string): string {
    const slash = path.lastIndexOf('\\');
    const name = slash >= 0 ? path.substring(slash + 1) : path;
    const dot = name.lastIndexOf('.');
    if (dot > 0) {
      return name.substring(0, dot);
    }
    return name;
  }

  private touch(path: string): void {
    const idx = this.keyOrder.indexOf(path);
    if (idx >= 0) {
      this.keyOrder.splice(idx, 1);
    }
    this.keyOrder.push(path);
  }

  private cachePut(path: string, meta: AudioMeta): void {
    this.cache.set(path, meta);
    this.touch(path);
    while (this.keyOrder.length > MAX_CACHED) {
      const victim = this.keyOrder.shift();
      if (victim === undefined) {
        break;
      }
      // 封面 PixelMap 只丢引用，由 GC 回收，避免释放正在显示的图
      this.cache.delete(victim);
    }
  }
}
