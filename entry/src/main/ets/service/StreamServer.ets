import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SmbService } from './SmbService';
import { MediaUtil } from './MediaUtil';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'StreamServer';
const CHUNK = 1048576;
const SEND_TIMEOUT_MS = 5000;
const PREFETCH_TAIL = 4 * 1048576;
const PREFETCH_HEAD = 1048576;
const CACHE_LIMIT = 32 * 1048576;

interface HttpRequest {
  method: string;
  path: string;
  rangeStart: number | undefined;
  rangeEnd: number | undefined;
}

interface CacheBlock {
  start: number;
  data: Uint8Array;
}

class ClientSendError extends Error {
  constructor(message: string) {
    super(message);
  }
}

export class StreamServer {
  private static instance: StreamServer = new StreamServer();
  private server: socket.TCPSocketServer | undefined = undefined;
  private port: number = 0;
  private running: boolean = false;
  private connections: socket.TCPSocketConnection[] = [];
  private lastServeError: string = '';
  private sizeCache: Map<string, number> = new Map<string, number>();
  private connSeq: number = 0;
  private rangeCache: Map<string, CacheBlock[]> = new Map<string, CacheBlock[]>();
  private cacheQueue: string[] = [];
  private cacheBytes: number = 0;
  private prefetched: Map<string, boolean> = new Map<string, boolean>();

  static getInstance(): StreamServer {
    return StreamServer.instance;
  }

  get isRunning(): boolean {
    return this.running;
  }

  getLastServeError(): string {
    return this.lastServeError;
  }

  clearLastServeError(): void {
    this.lastServeError = '';
  }

  getPort(): number {
    return this.port;
  }

  urlFor(path: string): string {
    return 'http://127.0.0.1:' + this.port + '/stream?f=' + encodeURIComponent(path);
  }

  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    const server = socket.constructTCPSocketServerInstance();
    let bound = false;
    for (let attempt = 0; attempt < 60 && !bound; attempt++) {
      const port = 20000 + Math.floor(Math.random() * 40000);
      const addr: socket.NetAddress = { address: '127.0.0.1', port: port, family: 1 };
      try {
        await server.listen(addr);
        this.port = port;
        bound = true;
      } catch (e) {
        hilog.debug(DOMAIN, TAG, 'bind %{public}d failed, retry', port);
      }
    }
    if (!bound) {
      throw new Error('无法启动本地流服务');
    }
    server.on('connect', (conn: socket.TCPSocketConnection) => {
      this.handleConnection(conn);
    });
    server.on('error', (err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'server error: %{public}s', JSON.stringify(err));
    });
    this.server = server;
    this.running = true;
    hilog.info(DOMAIN, TAG, 'stream server listening on %{public}d', this.port);
  }

  async restart(): Promise<void> {
    if (this.running) {
      this.running = false;
      const s = this.server;
      this.server = undefined;
      if (s !== undefined) {
        try {
          await s.close();
        } catch (e) {
          hilog.debug(DOMAIN, TAG, 'restart close old failed: %{public}s', JSON.stringify(e));
        }
      }
      const conns = this.connections;
      this.connections = [];
      for (let i = 0; i < conns.length; i++) {
        try {
          await conns[i].close();
        } catch (e) {
          hilog.debug(DOMAIN, TAG, 'restart close conn failed');
        }
      }
      this.sizeCache.clear();
      this.clearRangeCache();
      // 等待 NETSTACK 释放旧 accept 循环，避免 accept fail (errno 22)
      await new Promise<void>((r) => {
        setTimeout(() => {
          r();
        }, 500);
      });
    }
    await this.start();
  }

  /** 预热：确保 SMB 连接就绪、缓存文件大小，并预取头部与尾部（moov）。
   *  远端链路较慢时，预取耗时数秒，但可让 AVPlayer 首次起播的 Range 请求全部命中内存。 */
  async warmup(relPath: string): Promise<number> {
    let size = this.sizeCache.get(relPath);
    if (size === undefined) {
      size = await SmbService.getInstance().getSize(relPath);
      this.sizeCache.set(relPath, size);
    }
    if (this.prefetched.get(relPath) !== true) {
      this.prefetched.set(relPath, true);
      try {
        await this.prefetchRange(relPath, 0, Math.min(PREFETCH_HEAD, size));
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'prefetch head failed: %{public}s', JSON.stringify(e));
      }
      try {
        const tailLen = Math.min(PREFETCH_TAIL, size);
        await this.prefetchRange(relPath, Math.max(0, size - tailLen), tailLen);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'prefetch tail failed: %{public}s', JSON.stringify(e));
      }
    }
    return size;
  }

  private async prefetchRange(relPath: string, start: number, len: number): Promise<void> {
    const startedAt = Date.now();
    const data = await SmbService.getInstance().readRange(relPath, start, len);
    if (data.length === 0) {
      return;
    }
    this.cachePut(relPath, start, data);
    hilog.info(DOMAIN, TAG, 'prefetch off=%{public}d len=%{public}d cost=%{public}dms path=%{public}s',
      start, data.length, Date.now() - startedAt, relPath);
  }

  private cachePut(relPath: string, start: number, data: Uint8Array): void {
    let blocks = this.rangeCache.get(relPath);
    if (blocks === undefined) {
      blocks = [];
      this.rangeCache.set(relPath, blocks);
    }
    blocks.push({ start: start, data: data });
    this.cacheBytes += data.length;
    if (this.cacheQueue.indexOf(relPath) < 0) {
      this.cacheQueue.push(relPath);
    }
    while (this.cacheBytes > CACHE_LIMIT && this.cacheQueue.length > 1) {
      const oldest = this.cacheQueue.shift();
      if (oldest === undefined) {
        break;
      }
      const oldBlocks = this.rangeCache.get(oldest);
      if (oldBlocks !== undefined) {
        for (let i = 0; i < oldBlocks.length; i++) {
          this.cacheBytes -= oldBlocks[i].data.length;
        }
        this.rangeCache.delete(oldest);
      }
    }
  }

  /** 返回缓存中从 pos 开始连续可用的数据（可能短于 want，也可能为空） */
  private cacheSlice(relPath: string, pos: number, want: number): Uint8Array {
    const blocks = this.rangeCache.get(relPath);
    if (blocks === undefined) {
      return new Uint8Array(0);
    }
    for (let i = 0; i < blocks.length; i++) {
      const b = blocks[i];
      if (pos >= b.start && pos < b.start + b.data.length) {
        const from = pos - b.start;
        const n = Math.min(b.data.length - from, want);
        return b.data.slice(from, from + n);
      }
    }
    return new Uint8Array(0);
  }

  private clearRangeCache(): void {
    this.rangeCache.clear();
    this.cacheQueue = [];
    this.cacheBytes = 0;
    this.prefetched.clear();
  }

  async stop(): Promise<void> {
    if (!this.running) {
      return;
    }
    this.running = false;
    const s = this.server;
    this.server = undefined;
    if (s !== undefined) {
      try {
        await s.close();
      } catch (e) {
        hilog.debug(DOMAIN, TAG, 'stop failed: %{public}s', JSON.stringify(e));
      }
    }
    const conns = this.connections;
    this.connections = [];
    for (let i = 0; i < conns.length; i++) {
      try {
        await conns[i].close();
      } catch (e) {
        hilog.debug(DOMAIN, TAG, 'stop close conn failed');
      }
    }
    this.sizeCache.clear();
    this.clearRangeCache();
  }

  private handleConnection(conn: socket.TCPSocketConnection): void {
    this.connections.push(conn);
    const connId = this.connSeq + 1;
    this.connSeq = connId;
    hilog.info(DOMAIN, TAG, 'conn#%{public}d accepted total=%{public}d', connId, this.connections.length);
    let buffer = new Uint8Array(0);
    let chain: Promise<void> = Promise.resolve();
    conn.on('message', (info: socket.SocketMessageInfo) => {
      const chunk = new Uint8Array(info.message);
      const merged = new Uint8Array(buffer.length + chunk.length);
      merged.set(buffer);
      merged.set(chunk, buffer.length);
      buffer = merged;
      let headerEnd = StreamServer.findHeaderEnd(buffer);
      while (headerEnd >= 0) {
        const headText = StreamServer.asciiDecode(buffer.slice(0, headerEnd));
        const req = StreamServer.parseRequest(headText);
        buffer = buffer.slice(headerEnd + 4);
        headerEnd = StreamServer.findHeaderEnd(buffer);
        chain = chain.then(async () => {
          await this.serve(conn, req, connId);
        }).catch((e: BusinessError) => {
          hilog.debug(DOMAIN, TAG, 'conn#%{public}d serve task error: %{public}s', connId, JSON.stringify(e));
        });
      }
    });
    conn.on('close', () => {
      hilog.info(DOMAIN, TAG, 'conn#%{public}d closed by client', connId);
      this.removeConnection(conn);
    });
    conn.on('error', (err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'conn#%{public}d client error: %{public}s', connId, JSON.stringify(err));
      this.removeConnection(conn);
    });
  }

  private removeConnection(conn: socket.TCPSocketConnection): void {
    const idx = this.connections.indexOf(conn);
    if (idx >= 0) {
      this.connections.splice(idx, 1);
    }
  }

  private static findHeaderEnd(buffer: Uint8Array): number {
    for (let i = 0; i + 3 < buffer.length; i++) {
      if (buffer[i] === 13 && buffer[i + 1] === 10 && buffer[i + 2] === 13 && buffer[i + 3] === 10) {
        return i;
      }
    }
    return -1;
  }

  private static parseRequest(headText: string): HttpRequest {
    const lines = headText.split('\r\n');
    let method = 'GET';
    let path = '';
    let rangeStart: number | undefined = undefined;
    let rangeEnd: number | undefined = undefined;
    if (lines.length > 0) {
      const parts = lines[0].split(' ');
      if (parts.length >= 2) {
        method = parts[0];
        path = parts[1];
      }
    }
    for (let i = 1; i < lines.length; i++) {
      const line = lines[i];
      const colon = line.indexOf(':');
      if (colon > 0) {
        const key = line.substring(0, colon).trim().toLowerCase();
        const value = line.substring(colon + 1).trim();
        if (key === 'range') {
          const m = value.indexOf('=');
          if (m >= 0) {
            const spec = value.substring(m + 1);
            const dash = spec.indexOf('-');
            if (dash > 0) {
              rangeStart = Number(spec.substring(0, dash));
              rangeEnd = Number(spec.substring(dash + 1));
            } else if (dash === 0) {
              rangeEnd = -1;
            } else {
              rangeStart = Number(spec);
            }
          }
        }
      }
    }
    const req: HttpRequest = {
      method: method,
      path: path,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd
    };
    return req;
  }

  private async getCachedSize(relPath: string): Promise<number> {
    const cached = this.sizeCache.get(relPath);
    if (cached !== undefined) {
      return cached;
    }
    const size = await SmbService.getInstance().getSize(relPath);
    this.sizeCache.set(relPath, size);
    return size;
  }

  private async serve(conn: socket.TCPSocketConnection, req: HttpRequest, connId: number): Promise<void> {
    const startedAt = Date.now();
    try {
      const qIdx = req.path.indexOf('?f=');
      let relPath = '';
      if (qIdx >= 0) {
        relPath = decodeURIComponent(req.path.substring(qIdx + 3));
      }
      hilog.info(DOMAIN, TAG, 'conn#%{public}d req method=%{public}s range=[%{public}s,%{public}s] path=%{public}s',
        connId, req.method, String(req.rangeStart), String(req.rangeEnd), relPath);
      if (relPath.length === 0) {
        await StreamServer.sendText(conn, 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n');
        return;
      }
      const size = await this.getCachedSize(relPath);
      hilog.info(DOMAIN, TAG, 'getSize ok size=%{public}d', size);
      const type = MediaUtil.contentType(relPath);
      if (req.method === 'HEAD') {
        await StreamServer.sendText(conn, 'HTTP/1.1 200 OK\r\nContent-Length: ' + size +
          '\r\nAccept-Ranges: bytes\r\nContent-Type: ' + type + '\r\n\r\n');
        hilog.info(DOMAIN, TAG, 'HEAD responded');
        return;
      }
      if (req.rangeStart !== undefined) {
        let start = req.rangeStart;
        let end = size - 1;
        if (req.rangeEnd !== undefined && req.rangeEnd >= 0) {
          end = Math.min(end, req.rangeEnd);
          start = Math.min(start, end);
        }
        if (start >= size || start > end) {
          await StreamServer.sendText(conn, 'HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\n\r\n');
          return;
        }
        const len = end - start + 1;
        await StreamServer.sendText(conn, 'HTTP/1.1 206 Partial Content\r\nContent-Range: bytes ' + start +
          '-' + end + '/' + size + '\r\nContent-Length: ' + len +
          '\r\nAccept-Ranges: bytes\r\nContent-Type: ' + type + '\r\n\r\n');
        await this.streamRange(conn, relPath, start, len, connId);
        hilog.info(DOMAIN, TAG, 'conn#%{public}d range done len=%{public}d cost=%{public}dms',
          connId, len, Date.now() - startedAt);
      } else {
        await StreamServer.sendText(conn, 'HTTP/1.1 200 OK\r\nContent-Length: ' + size +
          '\r\nAccept-Ranges: bytes\r\nContent-Type: ' + type + '\r\n\r\n');
        await this.streamRange(conn, relPath, 0, size, connId);
        hilog.info(DOMAIN, TAG, 'conn#%{public}d full done len=%{public}d cost=%{public}dms',
          connId, size, Date.now() - startedAt);
      }
    } catch (e) {
      const cost = Date.now() - startedAt;
      if (e instanceof ClientSendError) {
        hilog.warn(DOMAIN, TAG, 'conn#%{public}d client send aborted cost=%{public}dms: %{public}s',
          connId, cost, e.message);
      } else {
        hilog.error(DOMAIN, TAG, 'conn#%{public}d serve failed cost=%{public}dms: %{public}s',
          connId, cost, JSON.stringify(e));
        this.lastServeError = JSON.stringify(e);
      }
      try {
        await StreamServer.sendText(conn, 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n');
      } catch (e2) {
        hilog.debug(DOMAIN, TAG, 'conn#%{public}d send 404 failed', connId);
      }
    }
  }

  private async streamRange(conn: socket.TCPSocketConnection, relPath: string,
    start: number, len: number, connId: number): Promise<void> {
    let remaining = len;
    let pos = start;
    while (remaining > 0) {
      const n = Math.min(CHUNK, remaining);
      const cached = this.cacheSlice(relPath, pos, n);
      if (cached.length > 0) {
        const cachedOpts: socket.TCPSendOptions = { data: cached.buffer as ArrayBuffer };
        try {
          await StreamServer.sendWithTimeout(conn, cachedOpts);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'conn#%{public}d cache send failed pos=%{public}d: %{public}s',
            connId, pos, JSON.stringify(e));
          throw new ClientSendError(JSON.stringify(e));
        }
        hilog.debug(DOMAIN, TAG, 'conn#%{public}d cache hit pos=%{public}d len=%{public}d',
          connId, pos, cached.length);
        pos += cached.length;
        remaining -= cached.length;
        continue;
      }
      const smbStartedAt = Date.now();
      let data: Uint8Array;
      try {
        data = await SmbService.getInstance().readRange(relPath, pos, n);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'conn#%{public}d SMB read failed pos=%{public}d len=%{public}d cost=%{public}dms: %{public}s',
          connId, pos, n, Date.now() - smbStartedAt, JSON.stringify(e));
        throw e as Error;
      }
      if (data.length === 0) {
        hilog.warn(DOMAIN, TAG, 'conn#%{public}d read empty at pos=%{public}d remaining=%{public}d',
          connId, pos, remaining);
        break;
      }
      const smbMs = Date.now() - smbStartedAt;
      const opts: socket.TCPSendOptions = { data: data.buffer as ArrayBuffer };
      const sendStartedAt = Date.now();
      try {
        await StreamServer.sendWithTimeout(conn, opts);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'conn#%{public}d local send failed pos=%{public}d len=%{public}d: %{public}s',
          connId, pos, data.length, JSON.stringify(e));
        throw new ClientSendError(JSON.stringify(e));
      }
      hilog.debug(DOMAIN, TAG, 'conn#%{public}d chunk pos=%{public}d len=%{public}d smb=%{public}dms send=%{public}dms',
        connId, pos, data.length, smbMs, Date.now() - sendStartedAt);
      pos += data.length;
      remaining -= data.length;
    }
  }

  private static async sendWithTimeout(conn: socket.TCPSocketConnection,
    opts: socket.TCPSendOptions): Promise<void> {
    await Promise.race([
      conn.send(opts),
      new Promise<void>((resolve, reject) => {
        setTimeout(() => {
          reject(new Error('发送超时'));
        }, SEND_TIMEOUT_MS);
      })
    ]);
  }

  private static async sendText(conn: socket.TCPSocketConnection, text: string): Promise<void> {
    const opts: socket.TCPSendOptions = { data: StreamServer.asciiEncode(text).buffer as ArrayBuffer };
    try {
      await StreamServer.sendWithTimeout(conn, opts);
    } catch (e) {
      throw new ClientSendError(JSON.stringify(e));
    }
  }

  private static asciiEncode(s: string): Uint8Array {
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) {
      out[i] = s.charCodeAt(i) & 0xff;
    }
    return out;
  }

  private static asciiDecode(b: Uint8Array): string {
    let s = '';
    for (let i = 0; i < b.length; i++) {
      s += String.fromCharCode(b[i]);
    }
    return s;
  }
}
