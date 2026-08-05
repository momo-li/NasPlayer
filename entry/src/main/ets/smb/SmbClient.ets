import { SmbCrypto } from './SmbCrypto';
import { SmbSocket } from './SmbSocket';
import { SmbPacket, SmbStatus, CreateInfo, QueryEntry, NegotiateInfo, SmbHeader } from './SmbPacket';
import { Ntlm } from './Ntlm';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'SmbClient';

const DIALECT_3_1_1 = 0x0311;
const DIALECT_3_0 = 0x0300;
const REQUEST_TIMEOUT_MS = 30000;
const MAX_READ_CHUNK = 65536;

export class SmbError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

interface PendingEntry {
  timer: number;
  onMessage: (raw: Uint8Array) => void;
  onError: (err: Error) => void;
}

export class SmbClient {
  private socket: SmbSocket = new SmbSocket();
  private host: string = '';
  private share: string = '';
  private username: string = '';
  private password: string = '';
  private domain: string = '';

  private messageId: number = 1;
  private readonly processId: number = 0xfeed;
  private sessionId: number = 0;
  private treeId: number = 0;

  private dialectRevision: number = 0;
  private sessionKey: Uint8Array = new Uint8Array(0);
  private serverChallenge: Uint8Array = new Uint8Array(8);

  private preauthBuffer: Uint8Array = new Uint8Array(0);
  private preauthNegotiateReq: Uint8Array = new Uint8Array(0);
  private preauthStep1Resp: Uint8Array = new Uint8Array(0);

  private pending: Map<number, PendingEntry> = new Map<number, PendingEntry>();
  private connected: boolean = false;

  get isConnected(): boolean {
    return this.connected;
  }

  get dialect(): number {
    return this.dialectRevision;
  }

  private nextMessageId(): number {
    const id = this.messageId;
    this.messageId += 1;
    return id;
  }

  private capture(buf: Uint8Array): void {
    this.preauthBuffer = SmbCrypto.concat([this.preauthBuffer, buf]);
  }

  private onClosed(): void {
    if (this.connected) {
      this.connected = false;
      hilog.warn(DOMAIN, TAG, 'connection closed by remote');
    }
    const ids = Array.from(this.pending.keys());
    for (let i = 0; i < ids.length; i++) {
      const entry = this.pending.get(ids[i]);
      if (entry !== undefined) {
        clearTimeout(entry.timer);
        this.pending.delete(ids[i]);
        entry.onError(new Error('连接已断开'));
      }
    }
  }

  private waitForResponse(id: number): Promise<Uint8Array> {
    return new Promise<Uint8Array>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error('请求超时'));
      }, REQUEST_TIMEOUT_MS);
      const entry: PendingEntry = {
        timer: timer,
        onMessage: (raw: Uint8Array) => {
          resolve(raw);
        },
        onError: (err: Error) => {
          reject(err);
        }
      };
      this.pending.set(id, entry);
    });
  }

  private onMessage(raw: Uint8Array): void {
    let hdr: SmbHeader;
    try {
      hdr = SmbPacket.parseHeader(raw);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'parse header failed: %{public}s', JSON.stringify(e));
      return;
    }
    const entry = this.pending.get(hdr.messageId);
    if (entry !== undefined) {
      clearTimeout(entry.timer);
      this.pending.delete(hdr.messageId);
      entry.onMessage(raw);
    } else {
      hilog.debug(DOMAIN, TAG, 'unsolicited response, msgId=%{public}d', hdr.messageId);
    }
  }

  private async sendRequest(command: number, body: Uint8Array, useSession: boolean, useTree: boolean,
    sign: boolean, captureReq: boolean, captureResp: boolean): Promise<Uint8Array> {
    if (this.socket.isClosed) {
      throw new SmbError(-1, '连接已断开');
    }
    const id = this.nextMessageId();
    let flags = 0;
    if (sign && this.sessionKey.length > 0) {
      flags = SmbPacket.FLAG_SIGNED;
    }
    let raw = SmbPacket.build(command, id, useSession ? this.sessionId : 0,
      useTree ? this.treeId : 0, this.processId, flags, body);
    if ((flags & SmbPacket.FLAG_SIGNED) !== 0) {
      const sig = await SmbCrypto.hmacSha256(this.sessionKey, raw);
      raw = SmbPacket.replaceSignature(raw, sig);
    }
    if (captureReq) {
      this.capture(raw);
    }
    await this.socket.write(raw);
    const resp = await this.waitForResponse(id);
    if (captureResp) {
      this.capture(resp);
    }
    return resp;
  }

  private async negotiate(): Promise<void> {
    const guid = await SmbCrypto.randomBytes(16);
    const body = SmbPacket.negotiateReq(guid);
    const id = this.nextMessageId();
    this.preauthNegotiateReq = SmbPacket.build(SmbCommand.NEGOTIATE, id, 0, 0, this.processId, 0, body);
    this.preauthBuffer = this.preauthNegotiateReq;
    await this.socket.write(this.preauthNegotiateReq);
    const resp = await this.waitForResponse(id);
    this.capture(resp);
    const hdr = SmbPacket.parseHeader(resp);
    if (hdr.status !== SmbStatus.SUCCESS) {
      throw new SmbError(hdr.status, SmbStatus.describe(hdr.status));
    }
    const info: NegotiateInfo = SmbPacket.parseNegotiateResp(SmbPacket.body(resp));
    this.dialectRevision = info.dialectRevision;
    hilog.info(DOMAIN, TAG, 'negotiated dialect=0x%{public}x', this.dialectRevision);
  }

  private async sessionSetupStep1(): Promise<void> {
    const type1 = await Ntlm.createType1();
    let preauth: Uint8Array | undefined = undefined;
    if (this.dialectRevision === DIALECT_3_1_1) {
      preauth = await SmbCrypto.sha512(this.preauthBuffer);
    }
    const body = SmbPacket.sessionSetupReq(type1, preauth, undefined);
    const resp = await this.sendRequest(SmbCommand.SESSION_SETUP, body, false, false, false, true, true);
    const hdr = SmbPacket.parseHeader(resp);
    if (hdr.status !== SmbStatus.MORE_PROCESSING_REQUIRED) {
      throw new SmbError(hdr.status, SmbStatus.describe(hdr.status));
    }
    this.sessionId = hdr.sessionId;
    this.preauthStep1Resp = resp;
    const type2 = SmbPacket.parseSessionSetupResp(SmbPacket.body(resp));
    this.serverChallenge = await Ntlm.parseType2(type2);
  }

  private async sessionSetupStep2(): Promise<void> {
    const type3 = await Ntlm.createType3(this.username, this.host, this.domain,
      this.serverChallenge, this.password);
    this.sessionKey = type3.sessionKey;

    let preauth: Uint8Array | undefined = undefined;
    if (this.dialectRevision === DIALECT_3_1_1) {
      preauth = await SmbCrypto.sha512(this.preauthBuffer);
    }

    const id = this.nextMessageId();
    let body: Uint8Array;
    if (this.dialectRevision >= DIALECT_3_0) {
      const micZero = new Uint8Array(16);
      body = SmbPacket.sessionSetupReq(type3.message, preauth, micZero);
      const rawForMic = SmbPacket.build(SmbCommand.SESSION_SETUP, id, this.sessionId, 0,
        this.processId, 0, body);
      const micInput = SmbCrypto.concat([this.preauthNegotiateReq, this.preauthStep1Resp, rawForMic]);
      const mic = await SmbCrypto.hmacSha256(this.sessionKey, micInput);
      body = SmbPacket.sessionSetupReq(type3.message, preauth, mic);
    } else {
      body = SmbPacket.sessionSetupReq(type3.message, preauth, undefined);
    }

    const raw = SmbPacket.build(SmbCommand.SESSION_SETUP, id, this.sessionId, 0, this.processId, 0, body);
    this.capture(raw);
    await this.socket.write(raw);
    const resp = await this.waitForResponse(id);
    this.capture(resp);
    const hdr = SmbPacket.parseHeader(resp);
    if (hdr.status !== SmbStatus.SUCCESS) {
      throw new SmbError(hdr.status, SmbStatus.describe(hdr.status));
    }
  }

  private async treeConnect(): Promise<void> {
    const unc = '\\\\' + this.host + '\\' + this.share;
    const body = SmbPacket.treeConnectReq(unc);
    const resp = await this.sendRequest(SmbCommand.TREE_CONNECT, body, true, false, true, false, false);
    const hdr = SmbPacket.parseHeader(resp);
    if (hdr.status !== SmbStatus.SUCCESS) {
      throw new SmbError(hdr.status, SmbStatus.describe(hdr.status));
    }
    this.treeId = hdr.treeId;
  }

  async connect(host: string, share: string, username: string, password: string, domain: string,
    port: number): Promise<void> {
    this.host = host;
    this.share = share;
    this.username = username;
    this.password = password;
    this.domain = domain.length > 0 ? domain : 'WORKGROUP';

    this.socket.setOnMessage((raw: Uint8Array) => {
      this.onMessage(raw);
    });
    this.socket.setOnClosed(() => {
      this.onClosed();
    });

    await this.socket.connect(host, port);
    await this.negotiate();
    await this.sessionSetupStep1();
    await this.sessionSetupStep2();
    await this.treeConnect();
    this.connected = true;
  }

  private async create(relPath: string, isDirectory: boolean): Promise<CreateInfo> {
    const body = SmbPacket.createReq(relPath, isDirectory);
    const resp = await this.sendRequest(SmbCommand.CREATE, body, true, true, true, false, false);
    const hdr = SmbPacket.parseHeader(resp);
    if (hdr.status !== SmbStatus.SUCCESS) {
      throw new SmbError(hdr.status, SmbStatus.describe(hdr.status));
    }
    return SmbPacket.parseCreateResp(SmbPacket.body(resp));
  }

  private async closeFile(fileId: Uint8Array): Promise<void> {
    try {
      const body = SmbPacket.closeReq(fileId);
      await this.sendRequest(SmbCommand.CLOSE, body, true, true, true, false, false);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'close file failed: %{public}s', JSON.stringify(e));
    }
  }

  async readdir(relPath: string): Promise<QueryEntry[]> {
    const dir = await this.create(relPath, true);
    const entries: QueryEntry[] = [];
    try {
      let done = false;
      while (!done) {
        const body = SmbPacket.queryDirectoryReq(dir.fileId);
        const resp = await this.sendRequest(SmbCommand.QUERY_DIRECTORY, body, true, true, true, false, false);
        const hdr = SmbPacket.parseHeader(resp);
        if (hdr.status === SmbStatus.NO_MORE_FILES) {
          done = true;
        } else if (hdr.status === SmbStatus.SUCCESS || hdr.status === SmbStatus.BUFFER_OVERFLOW) {
          const batch = SmbPacket.parseQueryDirectoryResp(SmbPacket.body(resp));
          for (let i = 0; i < batch.length; i++) {
            entries.push(batch[i]);
          }
          if (hdr.status === SmbStatus.SUCCESS) {
            done = true;
          }
        } else {
          throw new SmbError(hdr.status, SmbStatus.describe(hdr.status));
        }
      }
    } finally {
      await this.closeFile(dir.fileId);
    }
    return entries;
  }

  async getSize(relPath: string): Promise<number> {
    const f = await this.create(relPath, false);
    await this.closeFile(f.fileId);
    return f.endOfFile;
  }

  async readRange(relPath: string, offset: number, length: number): Promise<Uint8Array> {
    if (length <= 0) {
      return new Uint8Array(0);
    }
    const f = await this.create(relPath, false);
    try {
      const chunks: Uint8Array[] = [];
      let remaining = length;
      let pos = offset;
      while (remaining > 0) {
        const n = Math.min(MAX_READ_CHUNK, remaining);
        const body = SmbPacket.readReq(f.fileId, pos, n);
        const resp = await this.sendRequest(SmbCommand.READ, body, true, true, true, false, false);
        const hdr = SmbPacket.parseHeader(resp);
        if (hdr.status !== SmbStatus.SUCCESS) {
          throw new SmbError(hdr.status, SmbStatus.describe(hdr.status));
        }
        const data = SmbPacket.parseReadResp(SmbPacket.body(resp));
        if (data.length === 0) {
          break;
        }
        chunks.push(data);
        pos += data.length;
        remaining -= data.length;
      }
      if (chunks.length === 0) {
        return new Uint8Array(0);
      }
      return SmbCrypto.concat(chunks);
    } finally {
      await this.closeFile(f.fileId);
    }
  }

  async disconnect(): Promise<void> {
    this.connected = false;
    if (!this.socket.isClosed) {
      try {
        const body = SmbPacket.logoffReq();
        await this.sendRequest(SmbCommand.LOGOFF, body, true, false, true, false, false);
      } catch (e) {
        hilog.debug(DOMAIN, TAG, 'logoff failed: %{public}s', JSON.stringify(e));
      }
    }
    await this.socket.close();
  }
}

class SmbCommand {
  static readonly NEGOTIATE = 0x0000;
  static readonly SESSION_SETUP = 0x0001;
  static readonly LOGOFF = 0x0002;
  static readonly TREE_CONNECT = 0x0003;
  static readonly CREATE = 0x0005;
  static readonly CLOSE = 0x0006;
  static readonly READ = 0x0008;
  static readonly QUERY_DIRECTORY = 0x000e;
}
