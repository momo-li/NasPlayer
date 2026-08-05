import { SmbSession } from '../smb/SmbSession';
import { SmbConfig } from '../model/SmbConfig';
import { VideoEntry } from '../model/VideoEntry';

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

  async connect(config: SmbConfig): Promise<void> {
    await this.session.connect(config);
  }

  async readdir(relPath: string): Promise<VideoEntry[]> {
    return this.session.readdir(relPath);
  }

  async getSize(relPath: string): Promise<number> {
    return this.session.getSize(relPath);
  }

  async readRange(relPath: string, offset: number, length: number): Promise<Uint8Array> {
    return this.session.readRange(relPath, offset, length);
  }

  async disconnect(): Promise<void> {
    await this.session.disconnect();
  }
}
