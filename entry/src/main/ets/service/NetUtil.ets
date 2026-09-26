import { connection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'NetUtil';
const MAX_HOSTNAME_CANDIDATES = 3;

export interface ResolvedAddress {
  address: string;
  family: number;
}

export class NetUtil {
  static normalize(input: string): string {
    let s = input.trim();
    if (s.length >= 2 && s.charAt(0) === '[' && s.charAt(s.length - 1) === ']') {
      s = s.substring(1, s.length - 1).trim();
    }
    return s;
  }

  static stripZone(host: string): string {
    const idx = host.indexOf('%');
    if (idx >= 0) {
      return host.substring(0, idx);
    }
    return host;
  }

  static formatForDisplay(host: string): string {
    if (NetUtil.isIPv6Literal(host)) {
      return '[' + host + ']';
    }
    return host;
  }

  static isIPv4Literal(s: string): boolean {
    const parts = s.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i];
      if (p.length === 0 || p.length > 3) {
        return false;
      }
      for (let j = 0; j < p.length; j++) {
        const code = p.charCodeAt(j);
        if (code < 48 || code > 57) {
          return false;
        }
      }
      if (Number(p) > 255) {
        return false;
      }
    }
    return true;
  }

  static isIPv6Literal(s: string): boolean {
    if (s.length < 2) {
      return false;
    }
    let body = s;
    const zoneIdx = s.indexOf('%');
    if (zoneIdx >= 0) {
      body = s.substring(0, zoneIdx);
      const zone = s.substring(zoneIdx + 1);
      if (zone.length === 0 || s.indexOf('%', zoneIdx + 1) >= 0) {
        return false;
      }
      for (let i = 0; i < zone.length; i++) {
        if (!NetUtil.isZoneChar(zone.charAt(i))) {
          return false;
        }
      }
    }
    if (body.indexOf(':') < 0) {
      return false;
    }
    for (let i = 0; i < body.length; i++) {
      const c = body.charAt(i);
      if (c !== ':' && c !== '.' && !NetUtil.isHexDigit(c)) {
        return false;
      }
    }
    if (body.indexOf(':::') >= 0) {
      return false;
    }
    const compressIdx = body.indexOf('::');
    if (compressIdx >= 0 && body.indexOf('::', compressIdx + 2) >= 0) {
      return false;
    }
    if (body.charAt(0) === ':' && compressIdx !== 0) {
      return false;
    }
    if (body.charAt(body.length - 1) === ':' && compressIdx !== body.length - 2) {
      return false;
    }
    if (compressIdx >= 0) {
      const left = body.substring(0, compressIdx);
      const right = body.substring(compressIdx + 2);
      if (NetUtil.countGroups(left) + NetUtil.countGroups(right) > 7) {
        return false;
      }
      return NetUtil.isValidGroupList(left) && NetUtil.isValidGroupList(right);
    }
    if (NetUtil.countGroups(body) !== 8) {
      return false;
    }
    return NetUtil.isValidGroupList(body);
  }

  static familyOf(s: string): number {
    if (NetUtil.isIPv4Literal(s)) {
      return 1;
    }
    if (NetUtil.isIPv6Literal(s)) {
      return 2;
    }
    return 0;
  }

  static isHostName(s: string): boolean {
    if (s.length === 0 || s.length > 253) {
      return false;
    }
    const first = s.charAt(0);
    const last = s.charAt(s.length - 1);
    if (first === '-' || first === '.' || last === '-' || last === '.') {
      return false;
    }
    const labels = s.split('.');
    for (let i = 0; i < labels.length; i++) {
      const label = labels[i];
      if (label.length === 0 || label.length > 63) {
        return false;
      }
      if (label.charAt(0) === '-' || label.charAt(label.length - 1) === '-') {
        return false;
      }
      for (let j = 0; j < label.length; j++) {
        const c = label.charAt(j);
        const code = c.charCodeAt(0);
        const isDigit = code >= 48 && code <= 57;
        const isUpper = code >= 65 && code <= 90;
        const isLower = code >= 97 && code <= 122;
        if (!isDigit && !isUpper && !isLower && c !== '-' && c !== '_') {
          return false;
        }
      }
    }
    return true;
  }

  static validate(input: string): string {
    const t = input.trim();
    if (t.length === 0) {
      return '请输入主机地址';
    }
    for (let i = 0; i < t.length; i++) {
      const c = t.charAt(i);
      if (c === ' ' || c === '\t') {
        return '地址不能包含空格';
      }
    }
    const first = t.charAt(0);
    const last = t.charAt(t.length - 1);
    if ((t.indexOf('[') >= 0 || t.indexOf(']') >= 0) && !(first === '[' && last === ']')) {
      return 'IPv6 地址括号不完整';
    }
    const s = NetUtil.normalize(t);
    if (s.length === 0) {
      return '请输入主机地址';
    }
    if (s.indexOf(':') >= 0) {
      if (s.indexOf('%') === s.length - 1) {
        return '作用域标识不完整，如 fe80::1%wlan0';
      }
      if (NetUtil.isIPv6Literal(s)) {
        return '';
      }
      // 常见误输入形如 nas.local:445 / 192.168.1.5:445：给明确提示，而不是笼统报“IPv6 格式不正确”
      const colon = s.indexOf(':');
      const tail = s.substring(colon + 1);
      if (s.indexOf(':', colon + 1) < 0 && NetUtil.isAllDigits(tail)) {
        return '主机地址请不要带端口（端口固定使用 445）';
      }
      if (s.indexOf('.') >= 0) {
        return '主机名请不要带端口（端口固定使用 445）';
      }
      return 'IPv6 地址格式不正确';
    }
    let dotCount = 0;
    let numberOnly = true;
    for (let i = 0; i < s.length; i++) {
      const c = s.charAt(i);
      if (c === '.') {
        dotCount++;
      } else if (c < '0' || c > '9') {
        numberOnly = false;
      }
    }
    if (numberOnly && dotCount > 0) {
      return NetUtil.isIPv4Literal(s) ? '' : 'IPv4 地址格式不正确';
    }
    return NetUtil.isHostName(s) ? '' : '主机名格式不正确';
  }

  static async resolve(host: string): Promise<ResolvedAddress[]> {
    const h = NetUtil.normalize(host);
    const out: ResolvedAddress[] = [];
    const family = NetUtil.familyOf(h);
    if (family === 1) {
      const only: ResolvedAddress = { address: h, family: 1 };
      out.push(only);
      return out;
    }
    if (family === 2) {
      const scoped = await NetUtil.withZone(h);
      const only: ResolvedAddress = { address: scoped, family: 2 };
      out.push(only);
      return out;
    }
    try {
      const list = await connection.getAddressesByName(h);
      const v6: ResolvedAddress[] = [];
      const v4: ResolvedAddress[] = [];
      for (let i = 0; i < list.length; i++) {
        const addr = list[i].address;
        if (addr.length === 0) {
          continue;
        }
        const fam = list[i].family === 2 ? 2 : 1;
        const item: ResolvedAddress = { address: addr, family: fam };
        if (fam === 2) {
          v6.push(item);
        } else {
          v4.push(item);
        }
      }
      // IPv4 优先：公网 445 与多数家庭/NAS 网络只走 IPv4，IPv6 作为备选，避免先卡在不可达的 IPv6 上
      const merged = v4.concat(v6);
      const count = Math.min(merged.length, MAX_HOSTNAME_CANDIDATES);
      for (let i = 0; i < count; i++) {
        out.push(merged[i]);
      }
      hilog.info(DOMAIN, TAG, 'resolve %{public}s -> v4=%{public}d v6=%{public}d picked=%{public}d',
        h, v4.length, v6.length, out.length);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'resolve %{public}s failed: %{public}s', h, JSON.stringify(e));
    }
    if (out.length === 0) {
      // 系统解析没结果：把主机名原样交给 NETSTACK 兜底解析
      hilog.warn(DOMAIN, TAG, 'resolve %{public}s got no address, fallback to raw host', h);
      const fallback: ResolvedAddress = { address: h, family: 1 };
      out.push(fallback);
    }
    return out;
  }

  /** 是否拿到了真正解析出来的地址（而不是原样主机名兜底） */
  static hasResolvedAddress(host: string, list: ResolvedAddress[]): boolean {
    const h = NetUtil.normalize(host);
    for (let i = 0; i < list.length; i++) {
      if (list[i].address !== h && NetUtil.familyOf(list[i].address) !== 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 把底层连接失败翻译成可行动的中文提示。
   * detail 为底层错误消息（可能是英文），code 为 BusinessError.code（取不到时传 0）。
   */
  static describeConnectError(host: string, detail: string, code: number): string {
    const target = NetUtil.normalize(host);
    const isName = NetUtil.familyOf(target) === 0;
    const d = detail.toLowerCase();
    if (d.indexOf('无法解析') >= 0 || d.indexOf('resolve') >= 0 || d.indexOf('unknown host') >= 0 ||
      d.indexOf('dns') >= 0 || code === 2303001 || code === 2303002) {
      return '无法解析主机名 ' + target + '：请检查网络与 DNS 设置，或改用 IP 地址连接';
    }
    if (d.indexOf('超时') >= 0 || d.indexOf('timeout') >= 0 || d.indexOf('timed out') >= 0 || code === 2303210) {
      return isName
        ? '连接 ' + target + ' 超时：主机不可达，或未开放远程访问（需做端口映射并放行 445）'
        : '连接 ' + target + ' 超时：主机无响应，请确认它与手机在同一网络且已开放 445 端口';
    }
    if (d.indexOf('refused') >= 0 || d.indexOf('unreachable') >= 0 || d.indexOf('network is down') >= 0 ||
      d.indexOf('2303200') >= 0 || code === 2303200) {
      return isName
        ? '无法连接 ' + target + '：主机不可达或 445 端口未开放（远程访问需在路由器做端口映射）'
        : '无法连接 ' + target + '：目标不可达或 445 端口未开放';
    }
    if (d.indexOf('cannot assign') >= 0 || d.indexOf('2303199') >= 0 || code === 2303199) {
      return '本机网络暂不可用（无法分配地址），请检查 Wi-Fi / 移动网络后重试';
    }
    if (d.indexOf('permission') >= 0 || code === 201) {
      return '缺少网络访问权限，请在系统设置中允许本应用联网';
    }
    const suffix = detail.length > 0 ? '（' + detail + '）' : '';
    return isName
      ? '无法连接主机名 ' + target + '：请确认主机可访问且开启了文件共享，或改用 IP 地址' + suffix
      : '无法连接主机 ' + target + '：请确认它与手机在同一网络且已开启文件共享' + suffix;
  }

  static async hasLocalIPv4(): Promise<boolean> {
    try {
      const netHandle = await connection.getDefaultNet();
      const props = await connection.getConnectionProperties(netHandle);
      const addresses = props.linkAddresses;
      for (let i = 0; i < addresses.length; i++) {
        const addr = addresses[i].address.address;
        if (addr.indexOf('.') >= 0 && !addr.startsWith('127.')) {
          return true;
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'hasLocalIPv4 failed: %{public}s', JSON.stringify(e));
    }
    return false;
  }

  private static async withZone(ipv6: string): Promise<string> {
    if (ipv6.indexOf('%') >= 0) {
      return ipv6;
    }
    if (!ipv6.toLowerCase().startsWith('fe80:')) {
      return ipv6;
    }
    try {
      const netHandle = await connection.getDefaultNet();
      const props = await connection.getConnectionProperties(netHandle);
      const iface = props.interfaceName;
      if (iface !== undefined && iface.length > 0) {
        return ipv6 + '%' + iface;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'withZone failed: %{public}s', JSON.stringify(e));
    }
    return ipv6;
  }

  private static isAllDigits(s: string): boolean {
    if (s.length === 0) {
      return false;
    }
    for (let i = 0; i < s.length; i++) {
      const code = s.charCodeAt(i);
      if (code < 48 || code > 57) {
        return false;
      }
    }
    return true;
  }

  private static isHexDigit(c: string): boolean {
    const code = c.charCodeAt(0);
    const isDigit = code >= 48 && code <= 57;
    const isLower = code >= 97 && code <= 102;
    const isUpper = code >= 65 && code <= 70;
    return isDigit || isLower || isUpper;
  }

  private static isZoneChar(c: string): boolean {
    const code = c.charCodeAt(0);
    const isDigit = code >= 48 && code <= 57;
    const isUpper = code >= 65 && code <= 90;
    const isLower = code >= 97 && code <= 122;
    return isDigit || isUpper || isLower || c === '_' || c === '-';
  }

  private static countGroups(part: string): number {
    if (part.length === 0) {
      return 0;
    }
    const groups = part.split(':');
    let n = 0;
    for (let i = 0; i < groups.length; i++) {
      if (groups[i].indexOf('.') >= 0) {
        n += 2;
      } else {
        n += 1;
      }
    }
    return n;
  }

  private static isValidGroupList(part: string): boolean {
    if (part.length === 0) {
      return true;
    }
    const groups = part.split(':');
    for (let i = 0; i < groups.length; i++) {
      const g = groups[i];
      if (g.length === 0) {
        return false;
      }
      if (g.indexOf('.') >= 0) {
        if (i !== groups.length - 1 || !NetUtil.isIPv4Literal(g)) {
          return false;
        }
      } else {
        if (g.length > 4) {
          return false;
        }
        for (let j = 0; j < g.length; j++) {
          if (!NetUtil.isHexDigit(g.charAt(j))) {
            return false;
          }
        }
      }
    }
    return true;
  }
}
