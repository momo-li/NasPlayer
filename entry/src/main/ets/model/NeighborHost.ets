export class NeighborHost {
  ip: string = '';
  dialect: number = 0;

  static of(ip: string, dialect: number): NeighborHost {
    const h = new NeighborHost();
    h.ip = ip;
    h.dialect = dialect;
    return h;
  }

  get dialectText(): string {
    if (this.dialect === 0x0311) {
      return 'SMB 3.1.1';
    }
    if (this.dialect === 0x0302) {
      return 'SMB 3.0.2';
    }
    if (this.dialect === 0x0300) {
      return 'SMB 3.0';
    }
    if (this.dialect === 0x0210) {
      return 'SMB 2.1';
    }
    if (this.dialect === 0x0202) {
      return 'SMB 2.0';
    }
    return '';
  }
}
