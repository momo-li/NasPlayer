export class ShareEntry {
  name: string = '';
  type: number = 0;
  remark: string = '';

  static of(name: string, type: number, remark: string): ShareEntry {
    const e = new ShareEntry();
    e.name = name;
    e.type = type;
    e.remark = remark;
    return e;
  }

  get isDisk(): boolean {
    return (this.type & 0x1) !== 0;
  }

  get isIpc(): boolean {
    return (this.type & 0x4) !== 0;
  }
}
