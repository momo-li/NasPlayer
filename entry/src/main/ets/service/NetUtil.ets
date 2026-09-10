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
      return NetUtil.isIPv6Literal(s) ? '' : 'IPv6 地址格式不正确';
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
      const merged = v6.concat(v4);
      const count = Math.min(merged.length, MAX_HOSTNAME_CANDIDATES);
      for (let i = 0; i < count; i++) {
        out.push(merged[i]);
      }
      hilog.info(DOMAIN, TAG, 'resolve %{public}s -> v6=%{public}d v4=%{public}d', h, v6.length, v4.length);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'resolve %{public}s failed: %{public}s', h, JSON.stringify(e));
    }
    if (out.length === 0) {
      const fallback: ResolvedAddress = { address: h, family: 1 };
      out.push(fallback);
    }
    return out;
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
