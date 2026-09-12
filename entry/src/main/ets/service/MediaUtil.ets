export class MediaUtil {
  private static readonly VIDEO_EXTS: string[] = ['mp4', 'mkv', 'avi', 'mov', 'ts', 'm2ts', 'webm',
    'wmv', 'flv', 'm4v', '3gp', 'rmvb', 'rm', 'mpg', 'mpeg', 'vob'];

  private static readonly IMAGE_EXTS: string[] = ['jpg', 'jpeg', 'jfif', 'png', 'gif', 'webp',
    'bmp', 'heif', 'heic', 'avif', 'ico'];

  /** AVPlayer 支持的音频格式：M4A、AAC、MP3、OGG、WAV、FLAC、AMR */
  private static readonly AUDIO_EXTS: string[] = ['mp3', 'm4a', 'aac', 'wav', 'ogg', 'oga', 'flac', 'amr'];

  static isVideo(name: string): boolean {
    const idx = name.lastIndexOf('.');
    if (idx < 0 || idx === name.length - 1) {
      return false;
    }
    const ext = name.substring(idx + 1).toLowerCase();
    return MediaUtil.VIDEO_EXTS.indexOf(ext) >= 0;
  }

  static isImage(name: string): boolean {
    const idx = name.lastIndexOf('.');
    if (idx < 0 || idx === name.length - 1) {
      return false;
    }
    const ext = name.substring(idx + 1).toLowerCase();
    return MediaUtil.IMAGE_EXTS.indexOf(ext) >= 0;
  }

  static isAudio(name: string): boolean {
    const idx = name.lastIndexOf('.');
    if (idx < 0 || idx === name.length - 1) {
      return false;
    }
    const ext = name.substring(idx + 1).toLowerCase();
    return MediaUtil.AUDIO_EXTS.indexOf(ext) >= 0;
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
    if (ext === 'mp3') {
      return 'audio/mpeg';
    }
    if (ext === 'm4a') {
      return 'audio/mp4';
    }
    if (ext === 'aac') {
      return 'audio/aac';
    }
    if (ext === 'wav') {
      return 'audio/wav';
    }
    if (ext === 'flac') {
      return 'audio/flac';
    }
    if (ext === 'ogg' || ext === 'oga') {
      return 'audio/ogg';
    }
    if (ext === 'amr') {
      return 'audio/amr';
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

  static formatTime(ms: number): string {
    if (ms <= 0) {
      return '--';
    }
    const d = new Date(ms);
    const year = d.getFullYear();
    const month = d.getMonth() + 1;
    const day = d.getDate();
    const h = d.getHours();
    const min = d.getMinutes();
    const yy = String(year);
    const mm = month < 10 ? '0' + month : String(month);
    const dd = day < 10 ? '0' + day : String(day);
    const hh = h < 10 ? '0' + h : String(h);
    const mi = min < 10 ? '0' + min : String(min);
    return yy + '-' + mm + '-' + dd + ' ' + hh + ':' + mi;
  }
}
