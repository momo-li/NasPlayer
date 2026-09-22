import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SmbService } from './SmbService';

const DOMAIN = 0x0000;
const TAG = 'NasPlayer';
/** 单个 .lrc 文件读取上限，正常歌词文件远小于该值 */
const MAX_LRC_BYTES = 262144;
const MAX_CACHED = 8;
/** ArkTS 不允许正则字面量，统一用 new RegExp；全局正则在每行解析前重置 lastIndex */
const LRC_TAG_REG = new RegExp('\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]', 'g');
const LRC_OFFSET_REG = new RegExp('^\\[offset:\\s*([+-]?\\d+)\\s*\\]$');
const CRLF_REG = new RegExp('\\r\\n', 'g');
const CR_REG = new RegExp('\\r', 'g');

export class LyricLine {
  /** 毫秒时间戳；-1 表示无时间轴 */
  timeMs: number = -1;
  text: string = '';

  static of(timeMs: number, text: string): LyricLine {
    const l = new LyricLine();
    l.timeMs = timeMs;
    l.text = text;
    return l;
  }
}

export class Lyrics {
  lines: LyricLine[] = [];
  /** 是否带时间轴 */
  synced: boolean = false;
  /** 原始歌词文本（标准 LRC 格式，可直接给 AVSession 使用） */
  raw: string = '';

  static of(lines: LyricLine[], synced: boolean, raw: string): Lyrics {
    const l = new Lyrics();
    l.lines = lines;
    l.synced = synced;
    l.raw = raw;
    return l;
  }
}

/** 歌词来源：同名 .lrc 优先（SMB 读取），无则回退音频内嵌歌词（ID3v2 USLT / FLAC Vorbis LYRICS） */
export class LyricsUtil {
  private static instance: LyricsUtil = new LyricsUtil();
  private cache: Map<string, Lyrics> = new Map<string, Lyrics>();
  private keyOrder: string[] = [];

  static getInstance(): LyricsUtil {
    return LyricsUtil.instance;
  }

  async load(audioPath: string, embeddedText: string): Promise<Lyrics> {
    const hit = this.cache.get(audioPath);
    if (hit !== undefined) {
      this.touch(audioPath);
      return hit;
    }
    let result: Lyrics = Lyrics.of([], false, '');
    try {
      const sidecar = await this.readSidecar(audioPath, embeddedText.length === 0);
      if (sidecar.length > 0) {
        result = LyricsUtil.parseLrc(sidecar);
      } else if (embeddedText.length > 0) {
        result = LyricsUtil.parseLrc(embeddedText);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'lyrics load failed path=%{public}s err=%{public}s',
        audioPath, JSON.stringify(e));
      result = Lyrics.of([], false, '');
    }
    this.cachePut(audioPath, result);
    return result;
  }

  /**
   * 读取同目录同名 .lrc。
   * @param allowScan 直接探测失败时是否允许枚举目录兜底（目录枚举需逐个探测条目类型，开销较大，
   *                  仅在内嵌歌词也没有时才值得付出这个代价）
   */
  private async readSidecar(audioPath: string, allowScan: boolean): Promise<string> {
    const lrcPath = await this.findSidecar(audioPath, allowScan);
    if (lrcPath.length === 0) {
      return '';
    }
    const smb = SmbService.getInstance();
    const size = await smb.getSize(lrcPath);
    if (size <= 0) {
      return '';
    }
    const data = await smb.readRange(lrcPath, 0, Math.min(size, MAX_LRC_BYTES));
    if (data.length === 0) {
      return '';
    }
    return LyricsUtil.decodeText(data);
  }

  private async findSidecar(audioPath: string, allowScan: boolean): Promise<string> {
    const slash = audioPath.lastIndexOf('\\');
    const dir = slash >= 0 ? audioPath.substring(0, slash) : '';
    const name = slash >= 0 ? audioPath.substring(slash + 1) : audioPath;
    const dot = name.lastIndexOf('.');
    const base = dot > 0 ? name.substring(0, dot) : name;
    const guess = dir.length === 0 ? base + '.lrc' : dir + '\\' + base + '.lrc';
    try {
      const size = await SmbService.getInstance().getSize(guess);
      if (size > 0) {
        return guess;
      }
    } catch (e) {
      hilog.debug(DOMAIN, TAG, 'lrc probe miss path=%{public}s', guess);
    }
    if (!allowScan) {
      return '';
    }
    try {
      const entries = await SmbService.getInstance().readdir(dir);
      const want = (base + '.lrc').toLowerCase();
      for (let i = 0; i < entries.length; i++) {
        if (entries[i].name.toLowerCase() === want) {
          return entries[i].path;
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'lrc dir scan failed: %{public}s', JSON.stringify(e));
    }
    return '';
  }

  // ---------------- 解析 ----------------

  /** 解析标准 LRC（含一行多时间标签、[offset:] 偏移）；无任何时间标签时退化为纯文本 */
  static parseLrc(text: string): Lyrics {
    const rawLines = LyricsUtil.splitLines(text);
    const parsed: LyricLine[] = [];
    let offset = 0;
    for (let i = 0; i < rawLines.length; i++) {
      const line = rawLines[i];
      const off = LyricsUtil.parseOffset(line);
      if (off !== undefined) {
        offset = off;
        continue;
      }
      LRC_TAG_REG.lastIndex = 0;
      const times: number[] = [];
      let endPos = 0;
      let match: RegExpExecArray | null = LRC_TAG_REG.exec(line);
      while (match !== null) {
        times.push(LyricsUtil.toMs(match[1], match[2], match[3]));
        endPos = LRC_TAG_REG.lastIndex;
        match = LRC_TAG_REG.exec(line);
      }
      if (times.length === 0) {
        continue;
      }
      const content = line.substring(endPos).trim();
      for (let k = 0; k < times.length; k++) {
        parsed.push(LyricLine.of(times[k], content));
      }
    }
    if (parsed.length === 0) {
      return LyricsUtil.parsePlain(text);
    }
    parsed.sort((a: LyricLine, b: LyricLine): number => a.timeMs - b.timeMs);
    if (offset !== 0) {
      for (let i = 0; i < parsed.length; i++) {
        parsed[i].timeMs = Math.max(parsed[i].timeMs - offset, 0);
      }
    }
    return Lyrics.of(parsed, true, text);
  }

  /** 无时间轴歌词：逐行展示，不做高亮滚动 */
  static parsePlain(text: string): Lyrics {
    const rawLines = LyricsUtil.splitLines(text);
    const lines: LyricLine[] = [];
    for (let i = 0; i < rawLines.length; i++) {
      const t = rawLines[i].trim();
      if (t.length > 0) {
        lines.push(LyricLine.of(-1, t));
      }
    }
    return Lyrics.of(lines, false, text);
  }

  private static parseOffset(line: string): number | undefined {
    const match = LRC_OFFSET_REG.exec(line.trim());
    if (match === null) {
      return undefined;
    }
    const v = Number.parseInt(match[1], 10);
    if (Number.isNaN(v)) {
      return undefined;
    }
    return v;
  }

  private static toMs(min: string, sec: string, frac: string | undefined): number {
    const m = Number.parseInt(min, 10);
    const s = Number.parseInt(sec, 10);
    let ms = 0;
    if (frac !== undefined && frac.length > 0) {
      const f = Number.parseInt(frac, 10);
      if (frac.length === 1) {
        ms = f * 100;
      } else if (frac.length === 2) {
        ms = f * 10;
      } else {
        ms = f;
      }
    }
    return (m * 60 + s) * 1000 + ms;
  }

  private static splitLines(text: string): string[] {
    const normalized = text.replace(CRLF_REG, '\n').replace(CR_REG, '\n');
    return normalized.split('\n');
  }

  // ---------------- 内嵌歌词 ----------------

  /** 从已预读的音频文件头解析内嵌歌词；失败返回空串 */
  static extractEmbeddedLyric(data: Uint8Array): string {
    if (data.length < 10) {
      return '';
    }
    try {
      if (data[0] === 0x49 && data[1] === 0x44 && data[2] === 0x33) {
        return LyricsUtil.extractId3Lyric(data);
      }
      if (data[0] === 0x66 && data[1] === 0x4C && data[2] === 0x61 && data[3] === 0x43) {
        return LyricsUtil.extractFlacLyric(data);
      }
    } catch (e) {
      hilog.debug(DOMAIN, TAG, 'embedded lyric parse failed: %{public}s', JSON.stringify(e));
    }
    return '';
  }

  private static extractId3Lyric(data: Uint8Array): string {
    const major = data[3];
    if (major !== 3 && major !== 4) {
      return '';
    }
    const flags = data[5];
    const tagEnd = Math.min(10 + LyricsUtil.syncSafe(data, 6), data.length);
    let pos = 10;
    if ((flags & 0x40) !== 0) {
      // 扩展头：v2.4 长度含自身（syncsafe），v2.3 长度不含自身
      pos += major === 4 ? LyricsUtil.syncSafe(data, pos) : 4 + LyricsUtil.beUint32(data, pos);
    }
    while (pos + 10 <= tagEnd) {
      const id = String.fromCharCode(data[pos], data[pos + 1], data[pos + 2], data[pos + 3]);
      if (id.charCodeAt(0) === 0) {
        break;
      }
      const size = major === 4 ? LyricsUtil.syncSafe(data, pos + 4) : LyricsUtil.beUint32(data, pos + 4);
      const bodyStart = pos + 10;
      if (size <= 0 || bodyStart + size > tagEnd) {
        break;
      }
      const bodyEnd = bodyStart + size;
      const text = LyricsUtil.id3FrameText(data, id, bodyStart, bodyEnd);
      if (text.length > 0) {
        return text;
      }
      pos = bodyEnd;
    }
    return '';
  }

  /** 按帧 ID 取正文：USLT 为「encoding + language + 描述符 + 歌词」；TXXX 为「encoding + 描述 + 值」 */
  private static id3FrameText(data: Uint8Array, id: string, start: number, end: number): string {
    if (id === 'USLT') {
      const enc = data[start];
      const descEnd = LyricsUtil.id3StringEnd(data, start + 4, end, enc);
      return LyricsUtil.decodeId3Bytes(data, descEnd, end, enc).trim();
    }
    if (id !== 'TXXX') {
      return '';
    }
    const enc = data[start];
    const descEnd = LyricsUtil.id3StringEnd(data, start + 1, end, enc);
    const desc = LyricsUtil.decodeId3Bytes(data, start + 1, descEnd, enc).trim().toUpperCase();
    if (desc !== 'LYRICS' && desc !== 'LYRIC' && desc !== 'UNSYNCEDLYRICS') {
      return '';
    }
    return LyricsUtil.decodeId3Bytes(data, descEnd, end, enc).trim();
  }

  /** 返回以 0 结尾的字符串结束位置（含终止符）；UTF-16 为双字节终止符 */
  private static id3StringEnd(data: Uint8Array, start: number, end: number, enc: number): number {
    const doubleByte = enc === 1 || enc === 2;
    let i = start;
    while (i < end) {
      if (doubleByte) {
        if (i + 1 < end && data[i] === 0 && data[i + 1] === 0) {
          return i + 2;
        }
        i += 2;
      } else {
        if (data[i] === 0) {
          return i + 1;
        }
        i += 1;
      }
    }
    return end;
  }

  private static decodeId3Bytes(data: Uint8Array, start: number, end: number, enc: number): string {
    if (end <= start) {
      return '';
    }
    if (enc === 0) {
      return LyricsUtil.decodeWith('iso-8859-1', data.slice(start, end));
    }
    if (enc === 2) {
      return LyricsUtil.decodeWith('utf-16be', data.slice(start, end));
    }
    if (enc === 1) {
      if (end - start >= 2 && data[start] === 0xFF && data[start + 1] === 0xFE) {
        return LyricsUtil.decodeWith('utf-16le', data.slice(start + 2, end));
      }
      if (end - start >= 2 && data[start] === 0xFE && data[start + 1] === 0xFF) {
        return LyricsUtil.decodeWith('utf-16be', data.slice(start + 2, end));
      }
      return LyricsUtil.decodeWith('utf-16le', data.slice(start, end));
    }
    return LyricsUtil.decodeWith('utf-8', data.slice(start, end));
  }

  private static extractFlacLyric(data: Uint8Array): string {
    let pos = 4;
    while (pos + 4 <= data.length) {
      const head = data[pos];
      const isLast = (head & 0x80) !== 0;
      const type = head & 0x7F;
      const len = (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
      const bodyStart = pos + 4;
      const bodyEnd = bodyStart + len;
      if (len < 0 || bodyEnd > data.length) {
        return '';
      }
      if (type === 4) {
        const text = LyricsUtil.parseVorbisLyric(data, bodyStart, bodyEnd);
        if (text.length > 0) {
          return text;
        }
      }
      if (isLast) {
        break;
      }
      pos = bodyEnd;
    }
    return '';
  }

  private static parseVorbisLyric(data: Uint8Array, start: number, end: number): string {
    if (start + 4 > end) {
      return '';
    }
    let pos = start + 4 + LyricsUtil.leUint32(data, start);
    if (pos + 4 > end) {
      return '';
    }
    const count = LyricsUtil.leUint32(data, pos);
    pos += 4;
    for (let i = 0; i < count; i++) {
      if (pos + 4 > end) {
        break;
      }
      const len = LyricsUtil.leUint32(data, pos);
      pos += 4;
      if (len <= 0 || pos + len > end) {
        break;
      }
      const entry = LyricsUtil.decodeWith('utf-8', data.slice(pos, pos + len));
      pos += len;
      const eq = entry.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const key = entry.substring(0, eq).trim().toUpperCase();
      if (key === 'LYRICS' || key === 'LYRIC' || key === 'UNSYNCEDLYRICS') {
        return entry.substring(eq + 1).trim();
      }
    }
    return '';
  }

  private static syncSafe(data: Uint8Array, pos: number): number {
    return ((data[pos] & 0x7F) << 21) | ((data[pos + 1] & 0x7F) << 14) |
      ((data[pos + 2] & 0x7F) << 7) | (data[pos + 3] & 0x7F);
  }

  private static beUint32(data: Uint8Array, pos: number): number {
    return data[pos] * 0x1000000 + (data[pos + 1] << 16) + (data[pos + 2] << 8) + data[pos + 3];
  }

  private static leUint32(data: Uint8Array, pos: number): number {
    return data[pos] + (data[pos + 1] << 8) + (data[pos + 2] << 16) + data[pos + 3] * 0x1000000;
  }

  // ---------------- 编码 ----------------

  /** BOM 优先；无 BOM 时先按 UTF-8 严格解码，失败或出现替换字符再回退 GBK（NAS 上的中文 .lrc 多为 GBK） */
  private static decodeText(data: Uint8Array): string {
    if (data.length >= 3 && data[0] === 0xEF && data[1] === 0xBB && data[2] === 0xBF) {
      return LyricsUtil.decodeWith('utf-8', data.slice(3));
    }
    if (data.length >= 2 && data[0] === 0xFF && data[1] === 0xFE) {
      return LyricsUtil.decodeWith('utf-16le', data.slice(2));
    }
    if (data.length >= 2 && data[0] === 0xFE && data[1] === 0xFF) {
      return LyricsUtil.decodeWith('utf-16be', data.slice(2));
    }
    let text = '';
    try {
      const opts: util.TextDecoderOptions = { fatal: true };
      text = util.TextDecoder.create('utf-8', opts).decodeToString(data);
    } catch (e) {
      text = '';
    }
    if (text.length > 0 && text.indexOf('\uFFFD') < 0) {
      return text;
    }
    try {
      const sd = new util.StringDecoder('gbk');
      const gbk = sd.write(data) + sd.end();
      if (gbk.trim().length > 0) {
        return gbk;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'lrc gbk decode failed: %{public}s', JSON.stringify(e));
    }
    return text;
  }

  private static decodeWith(encoding: string, data: Uint8Array): string {
    try {
      return util.TextDecoder.create(encoding).decodeToString(data);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'lrc decode(%{public}s) failed: %{public}s', encoding, JSON.stringify(e));
      return '';
    }
  }

  // ---------------- 缓存 ----------------

  private touch(path: string): void {
    const idx = this.keyOrder.indexOf(path);
    if (idx >= 0) {
      this.keyOrder.splice(idx, 1);
    }
    this.keyOrder.push(path);
  }

  private cachePut(path: string, lyrics: Lyrics): void {
    this.cache.set(path, lyrics);
    this.touch(path);
    while (this.keyOrder.length > MAX_CACHED) {
      const victim = this.keyOrder.shift();
      if (victim === undefined) {
        break;
      }
      this.cache.delete(victim);
    }
  }
}
