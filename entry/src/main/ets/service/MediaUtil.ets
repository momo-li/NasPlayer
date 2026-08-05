export class MediaUtil {
  private static readonly VIDEO_EXTS: string[] = ['mp4', 'mkv', 'avi', 'mov', 'ts', 'm2ts', 'webm',
    'wmv', 'flv', 'm4v', '3gp', 'rmvb', 'rm', 'mpg', 'mpeg', 'vob'];

  static isVideo(name: string): boolean {
    const idx = name.lastIndexOf('.');
    if (idx < 0 || idx === name.length - 1) {
      return false;
    }
    const ext = name.substring(idx + 1).toLowerCase();
    return MediaUtil.VIDEO_EXTS.indexOf(ext) >= 0;
  }

  static contentType(path: string): string {
    const idx = path.lastIndexOf('.');
    if (idx < 0) {
      return 'application/octet-stream';
    }
    const ext = path.substring(idx + 1).toLowerCase();
    if (ext === 'mp4' || ext === 'm4v' || ext === 'mov') {
      return 'video/mp4';
    }
    if (ext === 'mkv') {
      return 'video/x-matroska';
    }
    if (ext === 'avi') {
      return 'video/x-msvideo';
    }
    if (ext === 'ts' || ext === 'm2ts') {
      return 'video/mp2t';
    }
    if (ext === 'webm') {
      return 'video/webm';
    }
    if (ext === 'wmv') {
      return 'video/x-ms-wmv';
    }
    if (ext === 'flv') {
      return 'video/x-flv';
    }
    if (ext === 'mpg' || ext === 'mpeg' || ext === 'vob') {
      return 'video/mpeg';
    }
    return 'application/octet-stream';
  }

  static formatSize(bytes: number): string {
    if (bytes < 1024) {
      return bytes + ' B';
    }
    if (bytes < 1024 * 1024) {
      return (bytes / 1024).toFixed(1) + ' KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    }
    return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
  }

  static formatDuration(ms: number): string {
    const totalSec = Math.floor(ms / 1000);
    const h = Math.floor(totalSec / 3600);
    const m = Math.floor((totalSec % 3600) / 60);
    const s = totalSec % 60;
    const mm = m < 10 ? '0' + m : String(m);
    const ss = s < 10 ? '0' + s : String(s);
    if (h > 0) {
      return h + ':' + mm + ':' + ss;
    }
    return mm + ':' + ss;
  }
}
