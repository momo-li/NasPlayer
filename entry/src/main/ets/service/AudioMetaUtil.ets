import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SmbService } from './SmbService';
import { LyricsUtil } from './LyricsUtil';
import { StreamServer } from './StreamServer';

const DOMAIN = 0x0000;
const TAG = 'NasPlayer';
/** 首次读取的文件头长度：覆盖绝大多数 ID3v2/FLAC 标签，并留出音频帧供时长探测 */
const MIN_HEAD_BYTES = 262144;
/** 标签很大（如整轨内嵌封面）时的读取上限 */
const MAX_HEAD_BYTES = 1048576;
const MAX_CACHED = 8;

export class AudioMeta {
  title: string = '';
  artist: string = '';
  album: string = '';
  cover: image.PixelMap | undefined = undefined;
  /** 内嵌歌词原文（ID3v2 USLT / FLAC Vorbis LYRICS）；侧车 .lrc 优先，这里只做兜底 */
  lyricText: string = '';

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
    const data = await this.readHead(path, size);
    if (data.length === 0) {
      throw new Error('读取失败');
    }
    // 顺手把已读到的文件头交给流服务：音频起播的首个 Range 请求可直接命中内存，省掉一次重复读取
    StreamServer.getInstance().cacheHead(path, data);
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
      const meta = AudioMeta.of(title, artist, album, cover);
      // 复用已预读的文件头解析内嵌歌词，避免为歌词再走一次 SMB 读取
      meta.lyricText = LyricsUtil.extractEmbeddedLyric(data);
      return meta;
    } finally {
      try {
        await extractor.release();
      } catch (e) {
        hilog.debug(DOMAIN, TAG, 'metadata extractor release failed: %{public}s', JSON.stringify(e));
      }
    }
  }

  /** 按标签实际长度决定读多少：先 256KB，标签更大（整轨封面/多图）再补读，避免弱网下白读 1MB */
  private async readHead(path: string, size: number): Promise<Uint8Array> {
    const smb = SmbService.getInstance();
    const firstLen = Math.min(size, MIN_HEAD_BYTES);
    const data = await smb.readRange(path, 0, firstLen);
    if (data.length === 0 || firstLen >= size || firstLen >= MAX_HEAD_BYTES) {
      return data;
    }
    const need = AudioMetaUtil.tagEnd(data);
    if (need <= data.length) {
      return data;
    }
    const want = Math.min(size, Math.min(need + MIN_HEAD_BYTES, MAX_HEAD_BYTES));
    const more = await smb.readRange(path, 0, want);
    return more.length > data.length ? more : data;
  }

  /** 标签结束位置（含）用于判断是否读全：ID3v2 用声明长度，FLAC 累加元数据块；无法判断返回 0 */
  private static tagEnd(data: Uint8Array): number {
    if (data.length < 10) {
      return 0;
    }
    if (data[0] === 0x49 && data[1] === 0x44 && data[2] === 0x33) {
      const size = ((data[6] & 0x7F) << 21) | ((data[7] & 0x7F) << 14) |
        ((data[8] & 0x7F) << 7) | (data[9] & 0x7F);
      return size + 10;
    }
    if (data[0] === 0x66 && data[1] === 0x4C && data[2] === 0x61 && data[3] === 0x43) {
      let pos = 4;
      while (pos + 4 <= data.length) {
        const head = data[pos];
        const isLast = (head & 0x80) !== 0;
        const len = (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
        if (len < 0) {
          return 0;
        }
        pos = pos + 4 + len;
        if (isLast) {
          return pos;
        }
      }
      return pos;
    }
    return 0;
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
