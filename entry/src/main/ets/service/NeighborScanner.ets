import { connection, socket } from '@kit.NetworkKit';
import { NeighborHost } from '../model/NeighborHost';
import { SmbClient } from '../smb/SmbClient';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'NeighborScanner';
const SMB_PORT = 445;
const CONNECT_TIMEOUT_MS = 500;
const SCAN_CONCURRENCY = 24;

export class NeighborScanner {
  static async getLocalIPv4(): Promise<string> {
    try {
      const netHandle = await connection.getDefaultNet();
      const props = await connection.getConnectionProperties(netHandle);
      const addresses = props.linkAddresses;
      for (let i = 0; i < addresses.length; i++) {
        const addr = addresses[i].address.address;
        if (addr.indexOf('.') >= 0 && !addr.startsWith('127.')) {
          return addr;
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getLocalIPv4 failed: %{public}s', JSON.stringify(e));
    }
    return '';
  }

  private static computeCandidates(localIp: string): string[] {
    const parts = localIp.split('.');
    if (parts.length !== 4) {
      return [];
    }
    const out: string[] = [];
    const network = parts[0] + '.' + parts[1] + '.' + parts[2] + '.';
    for (let i = 1; i <= 254; i++) {
      const ip = network + i;
      if (ip !== localIp) {
        out.push(ip);
      }
    }
    return out;
  }

  static async scan(progress: (done: number, total: number) => void): Promise<NeighborHost[]> {
    const localIp = await NeighborScanner.getLocalIPv4();
    if (localIp.length === 0) {
      return [];
    }
    const candidates = NeighborScanner.computeCandidates(localIp);
    const found: string[] = [];
    let done = 0;
    for (let off = 0; off < candidates.length; off += SCAN_CONCURRENCY) {
      const chunk = candidates.slice(off, Math.min(off + SCAN_CONCURRENCY, candidates.length));
      await Promise.all(chunk.map((ip: string) => NeighborScanner.probePort(ip, found)));
      done += chunk.length;
      progress(done, candidates.length);
    }
    const hosts: NeighborHost[] = [];
    for (let i = 0; i < found.length; i++) {
      const dialect = await SmbClient.probeDialect(found[i], SMB_PORT);
      hosts.push(NeighborHost.of(found[i], dialect));
    }
    hosts.sort((a: NeighborHost, b: NeighborHost): number => {
      return a.ip.localeCompare(b.ip);
    });
    return hosts;
  }

  private static async probePort(ip: string, found: string[]): Promise<void> {
    const tcp = socket.constructTCPSocketInstance();
    try {
      const addr: socket.NetAddress = { address: ip, port: SMB_PORT, family: 1 };
      const opts: socket.TCPConnectOptions = { address: addr, timeout: CONNECT_TIMEOUT_MS };
      await tcp.connect(opts);
      found.push(ip);
    } catch (e) {
      hilog.debug(DOMAIN, TAG, 'port closed: %{public}s', ip);
    } finally {
      try {
        await tcp.close();
      } catch (e) {
        hilog.debug(DOMAIN, TAG, 'close failed');
      }
    }
  }
}
