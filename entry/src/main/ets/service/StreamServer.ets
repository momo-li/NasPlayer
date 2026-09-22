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
  private headPrefetched: Map<string, boolean> = new Map<string, boolean>();
  private tailPrefetched: Map<string, boolean> = new Map<string, boolean>();
  private prefetchTasks: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  private prefetchQueue: string[] = [];
  private prefetchTail: Map<string, boolean> = new Map<string, boolean>();
  private prefetchBusy: boolean = false;
  /** 最近一次被请求流式播放的路径：缓存淘汰时保护它 */
  private activePath: string = '';

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

  /** 预热：只等文件大小（一次 CREATE，很快），头/尾预取转后台，不再阻塞起播。
   *  waitHeadMs 表示最多为“头部就绪”等多久：快链路通常能命中缓存，慢链路上宁可先起播、
   *  缺的数据由 streamRange 的 cache miss 分支按需读 SMB，避免把几 MB 预取压在切换路径上。
   *  withTail=false 用于音频（没有 moov 尾部，预取尾部纯属浪费带宽）。 */
  async warmup(relPath: string, waitHeadMs: number = 0, withTail: boolean = true): Promise<number> {
    const size = await this.ensureSize(relPath);
    const task = this.ensurePrefetch(relPath, size, withTail);
    if (waitHeadMs > 0) {
      await StreamServer.raceTimeout(task, waitHeadMs);
    }
    return size;
  }

  /** 外部已读到的文件头直接塞进缓存（图片/音频元数据解析读的就是头部），让首包无需二次读 SMB */
  cacheHead(relPath: string, data: Uint8Array): void {
    if (data.length === 0 || this.rangeCache.get(relPath) !== undefined) {
      return;
    }
    this.cachePut(relPath, 0, data);
  }

  /**
   * 重建预取窗口：丢弃已不在窗口内的待办，再按传入顺序（由近到远）重新排队。
   * 每次切歌都调用一次，这样快速连滑时预取始终跟着当前位置走，不会去补早被划过的条目。
   */
  setPrefetchWindow(paths: string[], withTail: boolean = false): void {
    this.prefetchQueue = [];
    this.prefetchTail.clear();
    let queued = false;
    for (let i = 0; i < paths.length; i++) {
      if (this.enqueuePrefetch(paths[i], withTail)) {
        queued = true;
      }
    }
    if (queued) {
      this.drainPrefetchQueue();
    }
  }

  /** 入队（去重 + 跳过已预取过的）：返回是否真的入队 */
  private enqueuePrefetch(relPath: string, withTail: boolean): boolean {
    if (relPath.length === 0) {
      return false;
    }
    const headDone = this.headPrefetched.get(relPath) === true;
    const tailDone = this.tailPrefetched.get(relPath) === true;
    if (headDone && (!withTail || tailDone)) {
      return false;
    }
    if (this.prefetchQueue.indexOf(relPath) >= 0) {
      return false;
    }
    this.prefetchQueue.push(relPath);
    this.prefetchTail.set(relPath, withTail);
    return true;
  }

  private drainPrefetchQueue(): void {
    if (this.prefetchBusy) {
      return;
    }
    const next = this.prefetchQueue.shift();
    if (next === undefined) {
      return;
    }
    const tail = this.prefetchTail.get(next) !== false;
    this.prefetchTail.delete(next);
    this.prefetchBusy = true;
    this.prefetchFull(next, tail).then(() => {
      this.prefetchBusy = false;
      this.drainPrefetchQueue();
    }).catch((e: Error) => {
      hilog.debug(DOMAIN, TAG, 'prefetch failed path=%{public}s err=%{public}s', next, e.message);
      this.prefetchBusy = false;
      this.drainPrefetchQueue();
    });
  }

  private async prefetchFull(relPath: string, withTail: boolean): Promise<void> {
    const size = await this.ensureSize(relPath);
    await this.ensurePrefetch(relPath, size, withTail);
  }

  private async ensureSize(relPath: string): Promise<number> {
    const cached = this.sizeCache.get(relPath);
    if (cached !== undefined) {
      return cached;
    }
    const size = await SmbService.getInstance().getSize(relPath);
    this.sizeCache.set(relPath, size);
    return size;
  }

  /** 每个文件的头/尾各只跑一次：已在跑就复用同一 Promise，已跑过就直接返回 */
  private ensurePrefetch(relPath: string, size: number, withTail: boolean): Promise<void> {
    const running = this.prefetchTasks.get(relPath);
    if (running !== undefined) {
      return running;
    }
    const needHead = this.headPrefetched.get(relPath) !== true;
    const needTail = withTail && this.tailPrefetched.get(relPath) !== true;
    if (!needHead && !needTail) {
      return Promise.resolve();
    }
    if (needHead) {
      this.headPrefetched.set(relPath, true);
    }
    if (needTail) {
      this.tailPrefetched.set(relPath, true);
    }
    const task = this.prefetchSegments(relPath, size, needHead, needTail);
    this.prefetchTasks.set(relPath, task);
    task.then(() => {
      this.prefetchTasks.delete(relPath);
    }).catch((e: Error) => {
      this.prefetchTasks.delete(relPath);
      hilog.debug(DOMAIN, TAG, 'prefetch task failed path=%{public}s err=%{public}s', relPath, e.message);
    });
    return task;
  }

  private async prefetchSegments(relPath: string, size: number, head: boolean, tail: boolean): Promise<void> {
    if (head) {
      try {
        await this.prefetchRange(relPath, 0, Math.min(PREFETCH_HEAD, size));
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'prefetch head failed: %{public}s', JSON.stringify(e));
      }
    }
    if (!tail) {
      return;
    }
    try {
      const tailLen = Math.min(PREFETCH_TAIL, size);
      await this.prefetchRange(relPath, Math.max(0, size - tailLen), tailLen);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'prefetch tail failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 到点就放行：慢链路上不为预取干等 */
  private static raceTimeout(task: Promise<void>, ms: number): Promise<void> {
    return Promise.race([task, new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    })]);
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
    // 淘汰时永远跳过“正在播放的文件”：窗口预取会写入大量缓存，不能把当前内容挤出去
    while (this.cacheBytes > CACHE_LIMIT && this.cacheQueue.length > 1) {
      let victim = '';
      for (let i = 0; i < this.cacheQueue.length; i++) {
        if (this.cacheQueue[i] !== this.activePath) {
          victim = this.cacheQueue[i];
          break;
        }
      }
      if (victim.length === 0) {
        break;
      }
      const victimIdx = this.cacheQueue.indexOf(victim);
      if (victimIdx >= 0) {
        this.cacheQueue.splice(victimIdx, 1);
      }
      const oldBlocks = this.rangeCache.get(victim);
      if (oldBlocks !== undefined) {
        for (let i = 0; i < oldBlocks.length; i++) {
          this.cacheBytes -= oldBlocks[i].data.length;
        }
      }
      this.rangeCache.delete(victim);
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
    this.headPrefetched.clear();
    this.tailPrefetched.clear();
    this.prefetchTasks.clear();
    this.prefetchQueue = [];
    this.prefetchTail.clear();
    this.prefetchBusy = false;
    this.activePath = '';
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
      this.activePath = relPath;
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
