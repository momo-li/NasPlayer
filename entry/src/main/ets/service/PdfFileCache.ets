import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SmbService } from './SmbService';

const DOMAIN = 0x0000;
const TAG = 'NasPlayer';
/** 分块下载大小：兼顾内存占用与往返次数 */
const CHUNK = 4 * 1024 * 1024;

/** SMB PDF → 应用沙箱缓存：PdfController 只接受本地路径，需先落地文件再加载 */
export class PdfFileCache {
  private static dir(ctx: common.UIAbilityContext): string {
    return ctx.cacheDir + '/pdf';
  }

  private static localPathFor(ctx: common.UIAbilityContext, relPath: string): string {
    return PdfFileCache.dir(ctx) + '/' + PdfFileCache.hashPath(relPath) + '.pdf';
  }

  /** 分块下载到 cacheDir/pdf；命中同尺寸缓存直接复用。onProgress(已写字节, 总字节) */
  static async prepare(ctx: common.UIAbilityContext, relPath: string, size: number,
    onProgress: (written: number, total: number) => void): Promise<string> {
    if (size <= 0) {
      throw new Error('文件为空或不可读');
    }
    const dir = PdfFileCache.dir(ctx);
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
    const localPath = PdfFileCache.localPathFor(ctx, relPath);
    if (fileIo.accessSync(localPath)) {
      try {
        if (fileIo.statSync(localPath).size === size) {
          return localPath;
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'pdf cache stat failed path=%{public}s err=%{public}s', localPath,
          JSON.stringify(e));
      }
      PdfFileCache.cleanup(localPath);
    }
    const file = fileIo.openSync(localPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    const smb = SmbService.getInstance();
    try {
      let written = 0;
      onProgress(0, size);
      while (written < size) {
        const want = Math.min(CHUNK, size - written);
        const data = await smb.readRange(relPath, written, want);
        if (data.length === 0) {
          throw new Error('读取数据为空');
        }
        const ab = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
        fileIo.writeSync(file.fd, ab);
        written += data.length;
        onProgress(written, size);
      }
    } catch (e) {
      PdfFileCache.closeQuietly(file);
      PdfFileCache.cleanup(localPath);
      hilog.error(DOMAIN, TAG, 'pdf download failed path=%{public}s err=%{public}s', relPath,
        JSON.stringify(e));
      if (e instanceof Error) {
        throw e;
      }
      throw new Error('PDF 下载失败，请检查网络');
    }
    PdfFileCache.closeQuietly(file);
    return localPath;
  }

  static cleanup(localPath: string): void {
    if (localPath.length === 0) {
      return;
    }
    try {
      if (fileIo.accessSync(localPath)) {
        fileIo.unlinkSync(localPath);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'pdf cache cleanup failed path=%{public}s err=%{public}s', localPath,
        JSON.stringify(e));
    }
  }

  private static closeQuietly(file: fileIo.File): void {
    try {
      fileIo.closeSync(file);
    } catch (e) {
      hilog.debug(DOMAIN, TAG, 'pdf file close failed: %{public}s', JSON.stringify(e));
    }
  }

  /** relPath → 稳定短文件名，规避中文/反斜杠等非法字符 */
  private static hashPath(s: string): string {
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) {
      h = (h ^ s.charCodeAt(i)) >>> 0;
      h = Math.imul(h, 0x01000193) >>> 0;
    }
    return h.toString(16);
  }
}
