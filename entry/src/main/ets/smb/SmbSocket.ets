import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'SmbSocket';

export class SmbSocket {
  private tcp: socket.TCPSocket | undefined = undefined;
  private recvBuffer: Uint8Array = new Uint8Array(0);
  private closed: boolean = false;
  private onMessageCb: ((msg: Uint8Array) => void) | undefined = undefined;
  private onClosedCb: (() => void) | undefined = undefined;
  private sendChain: Promise<void> = Promise.resolve();

  get isClosed(): boolean {
    return this.closed;
  }

  setOnMessage(cb: (msg: Uint8Array) => void): void {
    this.onMessageCb = cb;
  }

  setOnClosed(cb: () => void): void {
    this.onClosedCb = cb;
  }

  async connect(host: string, port: number): Promise<void> {
    const tcp = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    const addr: socket.NetAddress = { address: host, port: port, family: 1 };
    const opts: socket.TCPConnectOptions = { address: addr, timeout: 4000 };
    try {
      await tcp.connect(opts);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'tcp connect failed: %{public}s', JSON.stringify(e));
      throw new Error('connect failed');
    }
    tcp.on('message', (info: socket.SocketMessageInfo) => {
      this.handleData(new Uint8Array(info.message));
    });
    tcp.on('close', () => {
      this.closed = true;
      if (this.onClosedCb !== undefined) {
        this.onClosedCb();
      }
    });
    tcp.on('error', (err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'tcp error: %{public}s', JSON.stringify(err));
      this.closed = true;
      if (this.onClosedCb !== undefined) {
        this.onClosedCb();
      }
    });
  }

  async write(data: Uint8Array): Promise<void> {
    if (this.closed || this.tcp === undefined) {
      throw new Error('socket closed');
    }
    const wrapped = new Uint8Array(data.length + 4);
    wrapped[0] = 0x00;
    wrapped[1] = (data.length >> 16) & 0xff;
    wrapped[2] = (data.length >> 8) & 0xff;
    wrapped[3] = data.length & 0xff;
    wrapped.set(data, 4);
    const opts: socket.TCPSendOptions = { data: wrapped.buffer as ArrayBuffer };
    const task = this.sendChain.then(async () => {
      if (this.closed || this.tcp === undefined) {
        throw new Error('socket closed');
      }
      await this.tcp.send(opts);
    });
    this.sendChain = task.catch(() => undefined);
    await task;
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    const tcp = this.tcp;
    this.tcp = undefined;
    if (tcp !== undefined) {
      try {
        await tcp.close();
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'tcp close error: %{public}s', JSON.stringify(e));
      }
    }
  }

  private handleData(chunk: Uint8Array): void {
    const merged = new Uint8Array(this.recvBuffer.length + chunk.length);
    merged.set(this.recvBuffer);
    merged.set(chunk, this.recvBuffer.length);
    this.recvBuffer = merged;
    while (this.recvBuffer.length >= 4) {
      const len = (this.recvBuffer[1] << 16) | (this.recvBuffer[2] << 8) | this.recvBuffer[3];
      if (this.recvBuffer.length < 4 + len) {
        break;
      }
      const msg = this.recvBuffer.slice(4, 4 + len);
      this.recvBuffer = this.recvBuffer.slice(4 + len);
      if (this.onMessageCb !== undefined) {
        this.onMessageCb(msg);
      }
    }
  }
}
