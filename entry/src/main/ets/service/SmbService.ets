import { SmbSession } from '../smb/SmbSession';
import { SmbConfig } from '../model/SmbConfig';
import { VideoEntry } from '../model/VideoEntry';
import { ShareEntry } from '../model/ShareEntry';

export class SmbService {
  private static instance: SmbService = new SmbService();
  private session: SmbSession = new SmbSession();

  static getInstance(): SmbService {
    return SmbService.instance;
  }

  get isConnected(): boolean {
    return this.session.isConnected;
  }

  get dialectText(): string {
    return this.session.dialectText;
  }

  get currentConfig(): SmbConfig | undefined {
    return this.session.currentConfig;
  }

  get currentHost(): string {
    return this.session.currentHost;
  }

  async connect(config: SmbConfig): Promise<void> {
    await this.session.connect(config);
  }

  async connectHost(host: string, username: string, password: string, domain: string,
    port: number): Promise<void> {
    await this.session.connectHost(host, username, password, domain, port);
  }

  async enumerateShares(): Promise<ShareEntry[]> {
    return this.session.enumerateShares();
  }

  async enterShare(shareName: string): Promise<void> {
    await this.session.enterShare(shareName);
  }

  async readdir(relPath: string, force: boolean = false): Promise<VideoEntry[]> {
    return this.session.readdir(relPath, force);
  }

  async getSize(relPath: string): Promise<number> {
    return this.session.getSize(relPath);
  }

  async readRange(relPath: string, offset: number, length: number): Promise<Uint8Array> {
    return this.session.readRange(relPath, offset, length);
  }

  async deleteEntry(relPath: string, isDirectory: boolean): Promise<void> {
    await this.session.delete(relPath, isDirectory);
  }

  async renameEntry(relPath: string, newName: string, isDirectory: boolean): Promise<void> {
    await this.session.rename(relPath, newName, isDirectory);
  }

  async disconnect(): Promise<void> {
    await this.session.disconnect();
  }
}
