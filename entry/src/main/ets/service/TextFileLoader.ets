import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SmbService } from './SmbService';

const DOMAIN = 0x0000;
const TAG = 'NasPlayer';
/** 单个文本文件读取上限，超过只展示前一部分，避免超大文件拖垮渲染 */
const MAX_TEXT_BYTES = 1024 * 1024;

/** 文本读取结果：text 为解码后的内容，truncated 表示文件超限仅读取了前 MAX_TEXT_BYTES */
export class TextContent {
  readonly text: string;
  readonly truncated: boolean;

  constructor(text: string, truncated: boolean) {
    this.text = text;
    this.truncated = truncated;
  }
}

/** SMB 文本文件加载器：读取字节 → 自动识别编码解码；只读，不写回 */
export class TextFileLoader {
  static async load(relPath: string, size: number): Promise<TextContent> {
    if (size <= 0) {
      throw new Error('文件为空或不可读');
    }
    const truncated = size > MAX_TEXT_BYTES;
    const readLen = Math.min(size, MAX_TEXT_BYTES);
    let data: Uint8Array;
    try {
      data = await SmbService.getInstance().readRange(relPath, 0, readLen);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'text read failed path=%{public}s err=%{public}s', relPath, JSON.stringify(e));
      throw new Error('文本加载失败，请检查网络');
    }
    if (data.length === 0) {
      throw new Error('文件为空或不可读');
    }
    return new TextContent(TextFileLoader.decode(data), truncated);
  }

  /** BOM 优先；无 BOM 时先按 UTF-8 严格解码，失败或出现替换字符再回退 GBK（NAS 上的中文文本多为 GBK） */
  static decode(data: Uint8Array): string {
    if (data.length >= 3 && data[0] === 0xEF && data[1] === 0xBB && data[2] === 0xBF) {
      return TextFileLoader.decodeWith('utf-8', data.slice(3));
    }
    if (data.length >= 2 && data[0] === 0xFF && data[1] === 0xFE) {
      return TextFileLoader.decodeWith('utf-16le', data.slice(2));
    }
    if (data.length >= 2 && data[0] === 0xFE && data[1] === 0xFF) {
      return TextFileLoader.decodeWith('utf-16be', data.slice(2));
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
      hilog.warn(DOMAIN, TAG, 'text gbk decode failed: %{public}s', JSON.stringify(e));
    }
    return text;
  }

  private static decodeWith(encoding: string, data: Uint8Array): string {
    try {
      return util.TextDecoder.create(encoding).decodeToString(data);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'text decode(%{public}s) failed: %{public}s', encoding, JSON.stringify(e));
      return '';
    }
  }
}
