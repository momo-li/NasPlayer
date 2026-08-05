import { SmbClient } from './SmbClient';
import { QueryEntry } from './SmbPacket';
import { VideoEntry } from '../model/VideoEntry';
import { SmbConfig } from '../model/SmbConfig';

export class SmbSession {
  private client: SmbClient | undefined = undefined;
  private config: SmbConfig | undefined = undefined;

  get isConnected(): boolean {
    return this.client !== undefined && this.client.isConnected;
  }

  get currentConfig(): SmbConfig | undefined {
    return this.config;
  }

  get dialectText(): string {
    if (this.client === undefined || !this.client.isConnected) {
      return '';
    }
    const d = this.client.dialect;
    if (d === 0x0311) {
      return 'SMB 3.1.1';
    }
    if (d === 0x0302) {
      return 'SMB 3.0.2';
    }
    if (d === 0x0300) {
      return 'SMB 3.0';
    }
    if (d === 0x0210) {
      return 'SMB 2.1';
    }
    return 'SMB 2.0.2';
  }

  async connect(config: SmbConfig): Promise<void> {
    await this.disconnect();
    const client = new SmbClient();
    await client.connect(config.host, config.share, config.username, config.password,
      config.domain, config.port);
    this.client = client;
    this.config = config;
  }

  async readdir(relPath: string): Promise<VideoEntry[]> {
    if (this.client === undefined) {
      throw new Error('未连接');
    }
    const raw = await this.client.readdir(relPath);
    const out: VideoEntry[] = [];
    for (let i = 0; i < raw.length; i++) {
      const e: QueryEntry = raw[i];
      if (e.name === '.' || e.name === '..') {
        continue;
      }
      const full = relPath.length === 0 ? e.name : relPath + '\\' + e.name;
      out.push(VideoEntry.of(full, e.name, e.size, e.isDirectory));
    }
    out.sort((a: VideoEntry, b: VideoEntry): number => {
      if (a.isDirectory !== b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.localeCompare(b.name);
    });
    return out;
  }

  async getSize(relPath: string): Promise<number> {
    if (this.client === undefined) {
      throw new Error('未连接');
    }
    return this.client.getSize(relPath);
  }

  async readRange(relPath: string, offset: number, length: number): Promise<Uint8Array> {
    if (this.client === undefined) {
      throw new Error('未连接');
    }
    return this.client.readRange(relPath, offset, length);
  }

  async disconnect(): Promise<void> {
    if (this.client !== undefined) {
      const c = this.client;
      this.client = undefined;
      this.config = undefined;
      await c.disconnect();
    }
  }
}
