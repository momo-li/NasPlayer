import { SmbCrypto } from './SmbCrypto';
import { SmbSocket } from './SmbSocket';
import { SmbPacket, SmbStatus, CreateInfo, QueryEntry, NegotiateInfo, SmbHeader, RpcShareInfo } from './SmbPacket';
import { Ntlm } from './Ntlm';
import { ShareEntry } from '../model/ShareEntry';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'SmbClient';

const DIALECT_3_1_1 = 0x0311;
const DIALECT_3_0 = 0x0300;
const REQUEST_TIMEOUT_MS = 8000;
const MAX_READ_CHUNK = 65536;
const READ_TRIAL_CHUNK = 262144;
const STATUS_INVALID_PARAMETER = 0xc000000d;

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

interface DirCacheEntry {
  entries: QueryEntry[];
  ts: number;
}

const DIR_CACHE_TTL_MS = 5000;

export class SmbClient {
  private socket: SmbSocket = new SmbSocket();
  private host: string = '';
  private share: string = '';
  private username: string = '';
  private password: string = '';
  private domain: string = '';

  private messageId: number = 0;
  private readonly processId: number = 0xfeed;
  private sessionIdLo: number = 0;
  private sessionIdHi: number = 0;
  private treeId: number = 0;

  private dialectRevision: number = 0;
  private sessionKey: Uint8Array = new Uint8Array(0);
  private serverChallenge: Uint8Array = new Uint8Array(8);

  private preauthMsgs: Uint8Array[] = [];
  private preauthNegotiateReq: Uint8Array = new Uint8Array(0);
  private preauthStep1Resp: Uint8Array = new Uint8Array(0);
  private targetInfo: Uint8Array = new Uint8Array(0);
  private signingKey: Uint8Array = new Uint8Array(0);

  private pending: Map<number, PendingEntry> = new Map<number, PendingEntry>();
  private connected: boolean = false;
  private dirCache: Map<string, DirCacheEntry> = new Map<string, DirCacheEntry>();

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
    this.preauthMsgs.push(buf);
  }

  private async signMessage(raw: Uint8Array): Promise<Uint8Array> {
    if (this.signingKey.length > 0) {
      return SmbCrypto.aes128Cmac(this.signingKey, raw);
    }
    const full = await SmbCrypto.hmacSha256(this.sessionKey, raw);
    return full.slice(0, 16);
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
    let raw = SmbPacket.build(command, id, useSession ? this.sessionIdLo : 0,
      useSession ? this.sessionIdHi : 0, useTree ? this.treeId : 0, this.processId, flags, body);
    if ((flags & SmbPacket.FLAG_SIGNED) !== 0) {
      const sig = await this.signMessage(raw);
      raw = SmbPacket.replaceSignature(raw, sig);
    }
    if (captureReq) {
      this.capture(raw);
    }
    const respPromise = this.waitForResponse(id);
    await this.socket.write(raw);
    const resp = await respPromise;
    if (captureResp) {
      this.capture(resp);
    }
    return resp;
  }

  private async negotiate(): Promise<void> {
    const guid = await SmbCrypto.randomBytes(16);
    const body = SmbPacket.negotiateReq(guid, this.host);
    const id = this.nextMessageId();
    this.preauthNegotiateReq = SmbPacket.build(SmbCommand.NEGOTIATE, id, 0, 0, 0, this.processId, 0, body);
    this.preauthMsgs = [];
    this.preauthMsgs.push(this.preauthNegotiateReq);
    hilog.info(DOMAIN, TAG, 'sending NEGOTIATE %{public}s', this.preauthNegotiateReq.toString());
    const respPromise = this.waitForResponse(id);
    await this.socket.write(this.preauthNegotiateReq);
    const resp = await respPromise;
    this.capture(resp);
    const hdr = SmbPacket.parseHeader(resp);
    if (hdr.status !== SmbStatus.SUCCESS) {
      throw new SmbError(hdr.status, '[NEGOTIATE] ' + SmbStatus.describe(hdr.status));
    }
    const info: NegotiateInfo = SmbPacket.parseNegotiateResp(SmbPacket.body(resp));
    this.dialectRevision = info.dialectRevision;
    hilog.info(DOMAIN, TAG, 'negotiated dialect=0x%{public}x', this.dialectRevision);
  }

  private async sessionSetupStep1(): Promise<void> {
    const type1 = await Ntlm.createType1();
    const blob = SmbPacket.spnegoType1(type1);
    const body = SmbPacket.sessionSetupReq(blob, undefined, undefined);
    const resp = await this.sendRequest(SmbCommand.SESSION_SETUP, body, false, false, false, true, true);
    const hdr = SmbPacket.parseHeader(resp);
    if (hdr.status !== SmbStatus.MORE_PROCESSING_REQUIRED) {
      throw new SmbError(hdr.status, '[SESSION_SETUP#1] ' + SmbStatus.describe(hdr.status));
    }
    this.sessionIdLo = hdr.sessionIdLo;
    this.sessionIdHi = hdr.sessionIdHi;
    this.preauthStep1Resp = resp;
    let type2 = SmbPacket.parseSessionSetupResp(SmbPacket.body(resp));
    type2 = SmbPacket.extractNtlmFromSpnego(type2);
    this.serverChallenge = await Ntlm.parseType2(type2);
    const tiLen = SmbPacket.readU16(type2, 40);
    const tiOff = SmbPacket.readU32(type2, 44);
    if (tiLen > 0 && tiOff + tiLen <= type2.length) {
      this.targetInfo = type2.slice(tiOff, tiOff + tiLen);
    } else {
      this.targetInfo = new Uint8Array(0);
    }
  }

  private async sessionSetupStep2(): Promise<void> {
    const type3 = await Ntlm.createType3(this.username, this.host, this.domain,
      this.serverChallenge, this.password, this.targetInfo);
    this.sessionKey = type3.sessionKey;

    const id = this.nextMessageId();
    const body = SmbPacket.sessionSetupReq(SmbPacket.spnegoWrapType3(type3.message), undefined, undefined);

    const raw = SmbPacket.build(SmbCommand.SESSION_SETUP, id, this.sessionIdLo, this.sessionIdHi,
      0, this.processId, 0, body);
    this.capture(raw);
    const respPromise = this.waitForResponse(id);
    await this.socket.write(raw);
    const resp = await respPromise;
    const hdr = SmbPacket.parseHeader(resp);
    if (hdr.status !== SmbStatus.SUCCESS) {
      throw new SmbError(hdr.status, '[SESSION_SETUP#2] ' + SmbStatus.describe(hdr.status));
    }
    if (this.dialectRevision >= DIALECT_3_0) {
      const chain = await SmbCrypto.preauthChain(this.preauthMsgs);
      this.signingKey = await SmbCrypto.deriveSigningKey(this.sessionKey, chain);
    }
  }

  private async treeConnect(): Promise<void> {
    const unc = '\\\\' + this.host + '\\' + this.share;
    const body = SmbPacket.treeConnectReq(unc);
    const resp = await this.sendRequest(SmbCommand.TREE_CONNECT, body, true, false, true, false, false);
    const hdr = SmbPacket.parseHeader(resp);
    if (hdr.status !== SmbStatus.SUCCESS) {
      throw new SmbError(hdr.status, '[TREE_CONNECT] ' + SmbStatus.describe(hdr.status));
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

    hilog.info(DOMAIN, TAG, 'connecting %{public}s:%{public}d', host, port);
    try {
      await this.socket.connect(host, port);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'tcp connect error: %{public}s stack=%{public}s', JSON.stringify(e),
        e instanceof Error && e.stack !== undefined ? e.stack : '');
      throw e as Error;
    }
    hilog.info(DOMAIN, TAG, 'tcp connected');
    await this.negotiate();
    hilog.info(DOMAIN, TAG, 'negotiate done dialect=0x%{public}x', this.dialectRevision);
    try {
      await this.sessionSetupStep1();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'session setup step1 failed: %{public}s stack=%{public}s',
        e instanceof Error ? e.message : String(e),
        e instanceof Error && e.stack !== undefined ? e.stack : '');
      throw e as Error;
    }
    hilog.info(DOMAIN, TAG, 'session setup step1 done');
    try {
      await this.sessionSetupStep2();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'session setup step2 failed: %{public}s stack=%{public}s',
        e instanceof Error ? e.message : String(e),
        e instanceof Error && e.stack !== undefined ? e.stack : '');
      throw e as Error;
    }
    hilog.info(DOMAIN, TAG, 'session setup step2 done, signingKey=%{public}s', this.signingKey.toString());
    try {
      await this.treeConnect();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'tree connect failed: %{public}s stack=%{public}s',
        e instanceof Error ? e.message : String(e),
        e instanceof Error && e.stack !== undefined ? e.stack : '');
      throw e as Error;
    }
    hilog.info(DOMAIN, TAG, 'tree connect done treeId=0x%{public}x', this.treeId);
    this.connected = true;
  }

  private async create(relPath: string, isDirectory: boolean): Promise<CreateInfo> {
    const body = SmbPacket.createReq(relPath, isDirectory);
    return this.createRaw(body);
  }

  private async createRaw(body: Uint8Array): Promise<CreateInfo> {
    const resp = await this.sendRequest(SmbCommand.CREATE, body, true, true, true, false, false);
    const hdr = SmbPacket.parseHeader(resp);
    if (hdr.status !== SmbStatus.SUCCESS) {
      throw new SmbError(hdr.status, '[CREATE] ' + SmbStatus.describe(hdr.status));
    }
    return SmbPacket.parseCreateResp(SmbPacket.body(resp));
  }

  async treeConnectTo(shareName: string): Promise<void> {
    const unc = '\\\\' + this.host + '\\' + shareName;
    const body = SmbPacket.treeConnectReq(unc);
    const resp = await this.sendRequest(SmbCommand.TREE_CONNECT, body, true, false, true, false, false);
    const hdr = SmbPacket.parseHeader(resp);
    if (hdr.status !== SmbStatus.SUCCESS) {
      throw new SmbError(hdr.status, '[TREE_CONNECT(' + shareName + ')] ' + SmbStatus.describe(hdr.status));
    }
    this.treeId = hdr.treeId;
  }

  private async openPipe(pipeName: string): Promise<Uint8Array> {
    const info = await this.createRaw(SmbPacket.createPipeReq(pipeName));
    return info.fileId;
  }

  private async pipeWrite(fileId: Uint8Array, data: Uint8Array): Promise<void> {
    const body = SmbPacket.writeReq(fileId, data);
    const resp = await this.sendRequest(SmbCommand.WRITE, body, true, true, true, false, false);
    const hdr = SmbPacket.parseHeader(resp);
    if (hdr.status !== SmbStatus.SUCCESS) {
      throw new SmbError(hdr.status, '[READ] ' + SmbStatus.describe(hdr.status));
    }
  }

  private async pipeWriteRpc(fileId: Uint8Array, data: Uint8Array): Promise<void> {
    await this.pipeWrite(fileId, data);
  }

  private async pipeRead(fileId: Uint8Array): Promise<Uint8Array> {
    const body = SmbPacket.readReq(fileId, 0, 65536);
    hilog.info(DOMAIN, TAG, 'pipeRead req=%{public}s', body.toString());
    const resp = await this.sendRequest(SmbCommand.READ, body, true, true, true, false, false);
    const hdr = SmbPacket.parseHeader(resp);
    if (hdr.status !== SmbStatus.SUCCESS) {
      hilog.info(DOMAIN, TAG, 'pipeRead failed status=0x%{public}x', hdr.status);
      throw new SmbError(hdr.status, '[CREATE] ' + SmbStatus.describe(hdr.status));
    }
    const data = SmbPacket.parseReadResp(SmbPacket.body(resp));
    hilog.info(DOMAIN, TAG, 'pipeRead ok len=%{public}d body=%{public}s', data.length, SmbPacket.body(resp).toString());
    return data;
  }

  async enumerateShares(): Promise<ShareEntry[]> {
    const savedTree = this.treeId;
    let pipeId: Uint8Array | undefined = undefined;
    try {
      await this.treeConnectTo('IPC$');
      hilog.info(DOMAIN, TAG, 'enumerate: IPC$ ok treeId=%{public}s', this.treeId.toString());
      pipeId = await this.openPipe('srvsvc');
      hilog.info(DOMAIN, TAG, 'enumerate: pipe ok id=%{public}s', pipeId.toString());
      await this.pipeWriteRpc(pipeId, SmbPacket.rpcBindPdu(0));
      hilog.info(DOMAIN, TAG, 'enumerate: bind written');
      const bindAck = await this.readRpcFrame(pipeId);
      hilog.info(DOMAIN, TAG, 'enumerate: bind_ack len=%{public}d', bindAck.length);
      if (bindAck.length < 16 || bindAck[2] !== 0x0c) {
        throw new SmbError(-1, 'RPC bind 失败');
      }
      await this.pipeWriteRpc(pipeId, SmbPacket.rpcNetShareEnumPdu(1, this.host));
      hilog.info(DOMAIN, TAG, 'enumerate: enum written');
      let stub = new Uint8Array(0);
      let done = false;
      while (!done) {
        const frame = await this.readRpcFrame(pipeId);
        if (frame.length < 16) {
          break;
        }
        const type = frame[2];
        const pfc = frame[3];
        if (type === 0x02) {
          stub = SmbCrypto.concat([stub, SmbPacket.parseRpcResponseStub(frame)]);
        } else if (type === 0x13) {
          throw new SmbError(-1, 'RPC 调用失败');
        }
        done = (pfc & 0x02) !== 0;
      }
      const raw = SmbPacket.parseShareInfo1(stub);
      const out: ShareEntry[] = [];
      for (let i = 0; i < raw.length; i++) {
        const item: RpcShareInfo = raw[i];
        out.push(ShareEntry.of(item.name, item.type, item.remark));
      }
      return out;
    } finally {
      if (pipeId !== undefined) {
        await this.closeFile(pipeId);
      }
      this.treeId = savedTree;
    }
  }

  private async readRpcFrame(pipeId: Uint8Array): Promise<Uint8Array> {
    let buf = new Uint8Array(0);
    while (true) {
      if (buf.length >= 16) {
        const flen = SmbPacket.readU16(buf, 8);
        if (buf.length >= flen) {
          const frame = buf.slice(0, flen);
          return frame;
        }
      }
      const chunk = await this.pipeRead(pipeId);
      if (chunk.length === 0) {
        throw new SmbError(-1, '管道读取失败');
      }
      buf = SmbCrypto.concat([buf, chunk]);
    }
  }

  static async probeDialect(host: string, port: number): Promise<number> {
    const socket = new SmbSocket();
    try {
      await socket.connect(host, port);
      const guid = await SmbCrypto.randomBytes(16);
      const body = SmbPacket.negotiateReq(guid, host);
      const raw = SmbPacket.build(SmbCommand.NEGOTIATE, 0, 0, 0, 0, 0xfeed, 0, body);
      const result: Promise<number> = new Promise<number>((resolve) => {
        const timer = setTimeout(() => {
          resolve(0);
        }, 8000);
        socket.setOnMessage((msg: Uint8Array) => {
          clearTimeout(timer);
          try {
            const hdr = SmbPacket.parseHeader(msg);
            const info: NegotiateInfo = SmbPacket.parseNegotiateResp(SmbPacket.body(msg));
            resolve(hdr.status === SmbStatus.SUCCESS ? info.dialectRevision : 0);
          } catch (e) {
            resolve(0);
          }
        });
      });
      await socket.write(raw);
      return await result;
    } catch (e) {
      return 0;
    } finally {
      await socket.close();
    }
  }

  private async closeFile(fileId: Uint8Array): Promise<void> {
    try {
      const body = SmbPacket.closeReq(fileId);
      await this.sendRequest(SmbCommand.CLOSE, body, true, true, true, false, false);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'close file failed: %{public}s', JSON.stringify(e));
    }
  }

  async readdir(relPath: string, force: boolean = false): Promise<QueryEntry[]> {
    if (!force) {
      const cached = this.dirCache.get(relPath);
      if (cached !== undefined && Date.now() - cached.ts < DIR_CACHE_TTL_MS) {
        return cached.entries;
      }
    }
    const dir = await this.create(relPath, true);
    const entries: QueryEntry[] = [];
    try {
      let done = false;
      let first = true;
      while (!done) {
        const body = SmbPacket.queryDirectoryReq(dir.fileId, first);
        first = false;
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
    await this.probeEntries(relPath, entries);
    this.dirCache.set(relPath, { entries: entries, ts: Date.now() });
    return entries;
  }

  clearDirCache(): void {
    this.dirCache.clear();
  }

  private async probeEntries(relPath: string, entries: QueryEntry[]): Promise<void> {
    const probes: QueryEntry[] = [];
    for (let i = 0; i < entries.length; i++) {
      const e = entries[i];
      if (e.name !== '.' && e.name !== '..') {
        probes.push(e);
      }
    }
    const CONCURRENCY = 8;
    for (let i = 0; i < probes.length; i += CONCURRENCY) {
      const group = probes.slice(i, i + CONCURRENCY);
      await Promise.all(group.map(async (e: QueryEntry) => {
        const full = relPath.length === 0 ? e.name : relPath + '\\' + e.name;
        const dotIdx = e.name.indexOf('.');
        if (dotIdx < 0) {
          try {
            const d = await this.create(full, true);
            e.isDirectory = true;
            e.size = d.endOfFile;
            e.lastWriteTime = d.lastWriteTime;
            await this.closeFile(d.fileId);
            return;
          } catch (err) {
            try {
              const f = await this.create(full, false);
              e.isDirectory = false;
              e.size = f.endOfFile;
              e.lastWriteTime = f.lastWriteTime;
              await this.closeFile(f.fileId);
            } catch (err2) {
              e.isDirectory = false;
              e.size = 0;
              e.lastWriteTime = 0;
            }
            return;
          }
        }
        try {
          const f = await this.create(full, false);
          e.isDirectory = false;
          e.size = f.endOfFile;
          e.lastWriteTime = f.lastWriteTime;
          await this.closeFile(f.fileId);
        } catch (err2) {
          try {
            const d = await this.create(full, true);
            e.isDirectory = true;
            e.size = d.endOfFile;
            e.lastWriteTime = d.lastWriteTime;
            await this.closeFile(d.fileId);
          } catch (err3) {
            e.isDirectory = false;
            e.size = 0;
            e.lastWriteTime = 0;
          }
        }
      }));
    }
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
      const flight: Promise<Uint8Array>[] = [];
      const FLIGHT_LIMIT = 8;
      while (remaining > 0) {
        const n = Math.min(MAX_READ_CHUNK, remaining);
        flight.push(this.readChunk(f.fileId, pos, n));
        pos += n;
        remaining -= n;
        if (flight.length >= FLIGHT_LIMIT) {
          const batch = await Promise.all(flight);
          for (let i = 0; i < batch.length; i++) {
            chunks.push(batch[i]);
          }
          flight.length = 0;
        }
      }
      if (flight.length > 0) {
        const batch = await Promise.all(flight);
        for (let i = 0; i < batch.length; i++) {
          chunks.push(batch[i]);
        }
      }
      if (chunks.length === 0) {
        return new Uint8Array(0);
      }
      return SmbCrypto.concat(chunks);
    } finally {
      await this.closeFile(f.fileId);
    }
  }

  private async readChunk(fileId: Uint8Array, offset: number, length: number): Promise<Uint8Array> {
    const body = SmbPacket.readReq(fileId, offset, length);
    const resp = await this.sendRequest(SmbCommand.READ, body, true, true, true, false, false);
    const hdr = SmbPacket.parseHeader(resp);
    if (hdr.status !== SmbStatus.SUCCESS) {
      throw new SmbError(hdr.status, '[READ] ' + SmbStatus.describe(hdr.status));
    }
    return SmbPacket.parseReadResp(SmbPacket.body(resp));
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
  static readonly WRITE = 0x0009;
  static readonly QUERY_DIRECTORY = 0x000e;
}
