import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SmbService } from './SmbService';
import { MediaUtil } from './MediaUtil';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'StreamServer';
const CHUNK = 262144;

interface HttpRequest {
  method: string;
  path: string;
  rangeStart: number | undefined;
  rangeEnd: number | undefined;
}

export class StreamServer {
  private static instance: StreamServer = new StreamServer();
  private server: socket.TCPSocketServer | undefined = undefined;
  private port: number = 0;
  private running: boolean = false;

  static getInstance(): StreamServer {
    return StreamServer.instance;
  }

  get isRunning(): boolean {
    return this.running;
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
  }

  private handleConnection(conn: socket.TCPSocketConnection): void {
    let buffer = new Uint8Array(0);
    let request: HttpRequest | undefined = undefined;
    conn.on('message', (info: socket.SocketMessageInfo) => {
      const chunk = new Uint8Array(info.message);
      const merged = new Uint8Array(buffer.length + chunk.length);
      merged.set(buffer);
      merged.set(chunk, buffer.length);
      buffer = merged;
      if (request === undefined) {
        const headerEnd = StreamServer.findHeaderEnd(buffer);
        if (headerEnd >= 0) {
          const headText = StreamServer.asciiDecode(buffer.slice(0, headerEnd));
          request = StreamServer.parseRequest(headText);
          this.serve(conn, request);
        }
      }
    });
    conn.on('close', () => {
      hilog.debug(DOMAIN, TAG, 'client connection closed');
    });
    conn.on('error', (err: BusinessError) => {
      hilog.debug(DOMAIN, TAG, 'client error: %{public}s', JSON.stringify(err));
    });
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

  private async serve(conn: socket.TCPSocketConnection, req: HttpRequest): Promise<void> {
    try {
      const qIdx = req.path.indexOf('?f=');
      let relPath = '';
      if (qIdx >= 0) {
        relPath = decodeURIComponent(req.path.substring(qIdx + 3));
      }
      if (relPath.length === 0) {
        await StreamServer.sendText(conn, 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
        return;
      }
      const size = await SmbService.getInstance().getSize(relPath);
      const type = MediaUtil.contentType(relPath);
      if (req.method === 'HEAD') {
        await StreamServer.sendText(conn, 'HTTP/1.1 200 OK\r\nContent-Length: ' + size +
          '\r\nAccept-Ranges: bytes\r\nContent-Type: ' + type + '\r\nConnection: close\r\n\r\n');
        return;
      }
      if (req.rangeStart !== undefined) {
        let start = req.rangeStart;
        if (req.rangeEnd !== undefined && req.rangeEnd >= 0) {
          start = Math.min(start, req.rangeEnd);
        }
        if (start >= size) {
          await StreamServer.sendText(conn, 'HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
          return;
        }
        const end = size - 1;
        const len = end - start + 1;
        await StreamServer.sendText(conn, 'HTTP/1.1 206 Partial Content\r\nContent-Range: bytes ' + start +
          '-' + end + '/' + size + '\r\nContent-Length: ' + len +
          '\r\nAccept-Ranges: bytes\r\nContent-Type: ' + type + '\r\nConnection: close\r\n\r\n');
        await this.streamRange(conn, relPath, start, len);
      } else {
        await StreamServer.sendText(conn, 'HTTP/1.1 200 OK\r\nContent-Length: ' + size +
          '\r\nAccept-Ranges: bytes\r\nContent-Type: ' + type + '\r\nConnection: close\r\n\r\n');
        await this.streamRange(conn, relPath, 0, size);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'serve failed: %{public}s', JSON.stringify(e));
      try {
        await StreamServer.sendText(conn, 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
      } catch (e2) {
        hilog.debug(DOMAIN, TAG, 'send 404 failed');
      }
    } finally {
      try {
        await conn.close();
      } catch (e) {
        hilog.debug(DOMAIN, TAG, 'close conn failed');
      }
    }
  }

  private async streamRange(conn: socket.TCPSocketConnection, relPath: string,
    start: number, len: number): Promise<void> {
    let remaining = len;
    let pos = start;
    while (remaining > 0) {
      const n = Math.min(CHUNK, remaining);
      const data = await SmbService.getInstance().readRange(relPath, pos, n);
      if (data.length === 0) {
        break;
      }
      const opts: socket.TCPSendOptions = { data: data.buffer as ArrayBuffer };
      await conn.send(opts);
      pos += data.length;
      remaining -= data.length;
    }
  }

  private static async sendText(conn: socket.TCPSocketConnection, text: string): Promise<void> {
    const opts: socket.TCPSendOptions = { data: StreamServer.asciiEncode(text).buffer as ArrayBuffer };
    await conn.send(opts);
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
