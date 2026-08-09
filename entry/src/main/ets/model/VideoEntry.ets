export class VideoEntry {
  path: string = '';
  name: string = '';
  size: number = 0;
  isDirectory: boolean = false;
  modifiedTime: number = 0;
  durationMs: number = 0;

  static of(path: string, name: string, size: number, isDirectory: boolean,
    modifiedTime: number = 0, durationMs: number = 0): VideoEntry {
    const e = new VideoEntry();
    e.path = path;
    e.name = name;
    e.size = size;
    e.isDirectory = isDirectory;
    e.modifiedTime = modifiedTime;
    e.durationMs = durationMs;
    return e;
  }
}
