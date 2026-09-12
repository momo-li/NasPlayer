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
  private reconnecting: Promise<void> | undefined = undefined;

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
    await this.connectWithConfig(config.host, config.share, config.username, config.password,
      config.domain, config.port);
  }

  async connectHost(host: string, username: string, password: string, domain: string,
    port: number): Promise<void> {
    await this.disconnect();
    await this.connectWithConfig(host, 'IPC$', username, password, domain, port);
  }

  private async connectWithConfig(host: string, share: string, username: string, password: string,
    domain: string, port: number): Promise<void> {
    const client = new SmbClient();
    await client.connect(host, share, username, password, domain, port);
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

  async readdir(relPath: string, force: boolean = false): Promise<VideoEntry[]> {
    try {
      return await this.readdirOnce(relPath, force);
    } catch (e) {
      if (SmbSession.isNetworkError(e) && this.config !== undefined) {
        hilog.warn(DOMAIN, TAG, 'readdir network error, reconnect and retry');
        await this.reconnect();
        return await this.readdirOnce(relPath, force);
      }
      throw e as Error;
    }
  }

  private async readdirOnce(relPath: string, force: boolean): Promise<VideoEntry[]> {
    const pending = this.reconnecting;
    if (pending !== undefined) {
      await pending;
    }
    if (this.client === undefined) {
      throw new Error('未连接');
    }
    const raw = await this.client.readdir(relPath, force);
    const out: VideoEntry[] = [];
    for (let i = 0; i < raw.length; i++) {
      const e: QueryEntry = raw[i];
      if (e.name === '.' || e.name === '..') {
        continue;
      }
      const full = relPath.length === 0 ? e.name : relPath + '\\' + e.name;
      out.push(VideoEntry.of(full, e.name, e.size, e.isDirectory,
        SmbSession.fileTimeToMs(e.lastWriteTime)));
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
    try {
      return await this.getSizeOnce(relPath);
    } catch (e) {
      if (SmbSession.isNetworkError(e) && this.config !== undefined) {
        hilog.warn(DOMAIN, TAG, 'getSize network error, reconnect and retry');
        await this.reconnect();
        return await this.getSizeOnce(relPath);
      }
      throw e as Error;
    }
  }

  private async getSizeOnce(relPath: string): Promise<number> {
    const pending = this.reconnecting;
    if (pending !== undefined) {
      await pending;
    }
    if (this.client === undefined) {
      throw new Error('未连接');
    }
    return this.client.getSize(relPath);
  }

  async readRange(relPath: string, offset: number, length: number): Promise<Uint8Array> {
    try {
      return await this.readRangeOnce(relPath, offset, length);
    } catch (e) {
      if (SmbSession.isNetworkError(e) && this.config !== undefined) {
        hilog.warn(DOMAIN, TAG, 'readRange network error, reconnect and retry');
        await this.reconnect();
        return await this.readRangeOnce(relPath, offset, length);
      }
      throw e as Error;
    }
  }

  private async readRangeOnce(relPath: string, offset: number, length: number): Promise<Uint8Array> {
    const pending = this.reconnecting;
    if (pending !== undefined) {
      await pending;
    }
    if (this.client === undefined) {
      throw new Error('未连接');
    }
    return this.client.readRange(relPath, offset, length);
  }

  async delete(relPath: string, isDirectory: boolean): Promise<void> {
    try {
      await this.deleteOnce(relPath, isDirectory);
    } catch (e) {
      if (SmbSession.isNetworkError(e) && this.config !== undefined) {
        hilog.warn(DOMAIN, TAG, 'delete network error, reconnect and retry');
        await this.reconnect();
        await this.deleteOnce(relPath, isDirectory);
        return;
      }
      throw e as Error;
    }
  }

  private async deleteOnce(relPath: string, isDirectory: boolean): Promise<void> {
    const pending = this.reconnecting;
    if (pending !== undefined) {
      await pending;
    }
    if (this.client === undefined) {
      throw new Error('未连接');
    }
    await this.client.deleteEntry(relPath, isDirectory);
  }

  private static isNetworkError(e: Error): boolean {
    const msg = e.message;
    return msg.indexOf('Network') >= 0 || msg.indexOf('socket') >= 0 || msg.indexOf('closed') >= 0 ||
      msg.indexOf('断开') >= 0 || msg.indexOf('connect') >= 0 || msg.indexOf('timeout') >= 0;
  }

  static fileTimeToMs(fileTime: number): number {
    if (fileTime <= 0) {
      return 0;
    }
    return Math.floor(fileTime / 10000) - 11644473600000;
  }

  private async reconnect(): Promise<void> {
    const pending = this.reconnecting;
    if (pending !== undefined) {
      await pending;
      return;
    }
    const task = this.doReconnect();
    this.reconnecting = task;
    try {
      await task;
    } finally {
      this.reconnecting = undefined;
    }
  }

  private async doReconnect(): Promise<void> {
    const cfg = this.config;
    if (cfg === undefined) {
      return;
    }
    await this.disconnect();
    await this.connectWithConfig(cfg.host, cfg.share, cfg.username, cfg.password, cfg.domain, cfg.port);
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

