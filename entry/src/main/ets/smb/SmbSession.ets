import { SmbClient } from './SmbClient';
import { QueryEntry } from './SmbPacket';
import { VideoEntry } from '../model/VideoEntry';
import { SmbConfig } from '../model/SmbConfig';
import { ShareEntry } from '../model/ShareEntry';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'SmbSession';

export class SmbSession {
  private client: SmbClient | undefined = undefined;
  private config: SmbConfig | undefined = undefined;

  get isConnected(): boolean {
    return this.client !== undefined && this.client.isConnected;
  }

  get currentConfig(): SmbConfig | undefined {
    return this.config;
  }

  get currentHost(): string {
    if (this.config !== undefined) {
      return this.config.host;
    }
    return '';
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
    try {
      await this.connectWithLegacy(config.host, config.share, config.username, config.password,
        config.domain, config.port, false);
    } catch (e) {
      if (SmbSession.shouldRetryLegacy(e)) {
        hilog.warn(DOMAIN, TAG, 'connect failed, retry with SMB 2.1 dialect');
        await this.connectWithLegacy(config.host, config.share, config.username, config.password,
          config.domain, config.port, true);
      } else {
        throw e as Error;
      }
    }
  }

  async connectHost(host: string, username: string, password: string, domain: string,
    port: number): Promise<void> {
    await this.disconnect();
    try {
      await this.connectWithLegacy(host, 'IPC$', username, password, domain, port, false);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      const stack = e instanceof Error && e.stack !== undefined ? e.stack : '';
      hilog.error(DOMAIN, TAG, 'connectHost first attempt failed: %{public}s stack=%{public}s', msg, stack);
      if (SmbSession.shouldRetryLegacy(e)) {
        hilog.warn(DOMAIN, TAG, 'connectHost failed, retry with SMB 2.1 dialect');
        await this.connectWithLegacy(host, 'IPC$', username, password, domain, port, true);
      } else {
        throw e as Error;
      }
    }
  }

  private static shouldRetryLegacy(e: Error): boolean {
    const msg = e.message;
    return msg.indexOf('断开') >= 0 || msg.indexOf('closed') >= 0 || msg.indexOf('超时') >= 0 ||
      msg.indexOf('socket') >= 0 || msg.indexOf('服务器拒绝请求') >= 0;
  }

  private async connectWithLegacy(host: string, share: string, username: string, password: string,
    domain: string, port: number, legacy: boolean): Promise<void> {
    const client = new SmbClient();
    await client.connect(host, share, username, password, domain, port, legacy);
    this.client = client;
    const cfg: SmbConfig = {
      host: host,
      port: port,
      share: share,
      username: username,
      password: password,
      domain: domain
    };
    this.config = cfg;
  }

  async enumerateShares(): Promise<ShareEntry[]> {
    if (this.client === undefined) {
      throw new Error('未连接');
    }
    return this.client.enumerateShares();
  }

  async enterShare(shareName: string): Promise<void> {
    if (this.client === undefined || this.config === undefined) {
      throw new Error('未连接');
    }
    await this.client.treeConnectTo(shareName);
    this.config.share = shareName;
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

