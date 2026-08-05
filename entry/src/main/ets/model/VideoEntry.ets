export class VideoEntry {
  path: string = '';
  name: string = '';
  size: number = 0;
  isDirectory: boolean = false;

  static of(path: string, name: string, size: number, isDirectory: boolean): VideoEntry {
    const e = new VideoEntry();
    e.path = path;
    e.name = name;
    e.size = size;
    e.isDirectory = isDirectory;
    return e;
  }
}
