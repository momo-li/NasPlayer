import { SmbClient, SmbError } from './SmbClient';
import { QueryEntry } from './SmbPacket';
import { VideoEntry } from '../model/VideoEntry';
import { SmbConfig } from '../model/SmbConfig';
import { ShareEntry } from '../model/ShareEntry';
import { NetUtil } from '../service/NetUtil';
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
    // 主机名可能解析出多个地址（如同时有 IPv4/IPv6，或 DDNS 返回多条）：
    // 逐个做「完整 SMB 建连」。只认第一个 TCP 能通的地址，会在该地址其实不可用时直接失败——
    // 这是“以前能用主机名连、现在连不上”的典型原因（DNS 多出一条不可达的 IPv6 记录）。
    const candidates = await NetUtil.resolve(host);
    const dnsResolved = NetUtil.hasResolvedAddress(host, candidates);
    let lastError: Error = new Error('无法连接主机 ' + host);
    for (let i = 0; i < candidates.length; i++) {
      const addr = candidates[i].address;
      const client = new SmbClient();
      try {
        await client.connect(addr, share, username, password, domain, port);
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
        if (addr !== host) {
          hilog.info(DOMAIN, TAG, 'connected via resolved %{public}s (host=%{public}s)', addr, host);
        }
        return;
      } catch (e) {
        lastError = e instanceof Error ? e : new Error('无法连接主机 ' + host);
        hilog.warn(DOMAIN, TAG, 'candidate %{public}s failed: %{public}s', addr, lastError.message);
        try {
          await client.disconnect();
        } catch (e2) {
          hilog.debug(DOMAIN, TAG, 'disconnect failed candidate %{public}s', addr);
        }
        // 已经收到 SMB 应答（账号/权限/共享问题）说明这个地址是通的，换地址也不会变好，直接上报
        if (e instanceof SmbError) {
          throw lastError;
        }
      }
    }
    // 全部候选失败且解析没拿到任何地址时，明确告诉调用方是“主机名解析不出来”，避免上层给出误导性提示
    if (!(lastError instanceof SmbError) && NetUtil.familyOf(NetUtil.normalize(host)) === 0 && !dnsResolved) {
      throw new Error('无法解析主机名 ' + NetUtil.normalize(host) + '（DNS 未返回地址）');
    }
    throw lastError;
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

  async rename(relPath: string, newName: string, isDirectory: boolean): Promise<void> {
    try {
      await this.renameOnce(relPath, newName, isDirectory);
    } catch (e) {
      if (SmbSession.isNetworkError(e) && this.config !== undefined) {
        hilog.warn(DOMAIN, TAG, 'rename network error, reconnect and retry');
        await this.reconnect();
        await this.renameOnce(relPath, newName, isDirectory);
        return;
      }
      throw e as Error;
    }
  }

  private async renameOnce(relPath: string, newName: string, isDirectory: boolean): Promise<void> {
    const pending = this.reconnecting;
    if (pending !== undefined) {
      await pending;
    }
    if (this.client === undefined) {
      throw new Error('未连接');
    }
    await this.client.renameEntry(relPath, newName, isDirectory);
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

