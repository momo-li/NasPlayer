import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'SmbCrypto';

export class SmbCrypto {
  static concat(arrays: Uint8Array[]): Uint8Array {
    let total = 0;
    for (let i = 0; i < arrays.length; i++) {
      total += arrays[i].length;
    }
    const out = new Uint8Array(total);
    let off = 0;
    for (let i = 0; i < arrays.length; i++) {
      out.set(arrays[i], off);
      off += arrays[i].length;
    }
    return out;
  }

  static utf16leEncode(s: string): Uint8Array {
    const out = new Uint8Array(s.length * 2);
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      out[i * 2] = c & 0xff;
      out[i * 2 + 1] = (c >> 8) & 0xff;
    }
    return out;
  }

  static utf16leDecode(b: Uint8Array): string {
    let s = '';
    for (let i = 0; i + 1 < b.length; i += 2) {
      const c = b[i] | (b[i + 1] << 8);
      s += String.fromCharCode(c);
    }
    return s;
  }

  static asciiEncode(s: string): Uint8Array {
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) {
      out[i] = s.charCodeAt(i) & 0xff;
    }
    return out;
  }

  static async randomBytes(n: number): Promise<Uint8Array> {
    const random = cryptoFramework.createRandom();
    try {
      const blob = await random.generateRandom(n);
      return blob.data;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'randomBytes failed: %{public}s', JSON.stringify(e));
      const out = new Uint8Array(n);
      for (let i = 0; i < n; i++) {
        out[i] = Math.floor(Math.random() * 256);
      }
      return out;
    }
  }

  static async sha512(data: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA512');
    const blob: cryptoFramework.DataBlob = { data: data };
    await md.update(blob);
    const out = await md.digest();
    return out.data;
  }

  static async hmac(alg: string, key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    const gen = cryptoFramework.createSymKeyGenerator('HMAC');
    const keyBlob: cryptoFramework.DataBlob = { data: key };
    const symKey = await gen.convertKey(keyBlob);
    const mac = cryptoFramework.createMac(alg);
    await mac.init(symKey);
    const dataBlob: cryptoFramework.DataBlob = { data: data };
    await mac.update(dataBlob);
    const out = await mac.doFinal();
    return out.data;
  }

  static async hmacMd5(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    return SmbCrypto.hmac('HMAC|MD5', key, data);
  }

  static async hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    return SmbCrypto.hmac('HMAC|SHA256', key, data);
  }

  static md4(data: Uint8Array): Uint8Array {
    const A = 0x67452301;
    const B = 0xefcdab89;
    const C = 0x98badcfe;
    const D = 0x10325476;

    const bitLen = data.length * 8;
    const paddedLen = (((data.length + 8) >> 6) + 1) << 6;
    const padded = new Uint8Array(paddedLen);
    padded.set(data);
    padded[data.length] = 0x80;
    const dv = new DataView(padded.buffer);
    dv.setUint32(paddedLen - 8, bitLen >>> 0, true);
    dv.setUint32(paddedLen - 4, Math.floor(bitLen / 0x100000000), true);

    let a = A;
    let b = B;
    let c = C;
    let d = D;

    const x = new Array<number>(16);
    for (let off = 0; off < paddedLen; off += 64) {
      for (let i = 0; i < 16; i++) {
        x[i] = dv.getUint32(off + i * 4, true);
      }
      const aa = a;
      const bb = b;
      const cc = c;
      const dd = d;

      const rotl = (v: number, s: number): number => {
        const u = v >>> 0;
        return ((u << s) | (u >>> (32 - s))) >>> 0;
      };
      const add = (v: number, w: number): number => (v + w) >>> 0;

      const round1Order: number[] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
      const round1Shift: number[] = [3, 7, 11, 19];
      for (let i = 0; i < 16; i++) {
        const f = ((b & c) | ((~b) & d)) >>> 0;
        a = rotl(add(add(a, f), x[round1Order[i]]), round1Shift[i % 4]);
        const t = d;
        d = c;
        c = b;
        b = a;
        a = t;
      }

      const round2Order: number[] = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15];
      const round2Shift: number[] = [3, 5, 9, 13];
      for (let i = 0; i < 16; i++) {
        const g = (((b & c) | (b & d) | (c & d))) >>> 0;
        a = rotl(add(add(add(a, g), x[round2Order[i]]), 0x5a827999), round2Shift[i % 4]);
        const t = d;
        d = c;
        c = b;
        b = a;
        a = t;
      }

      const round3Order: number[] = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15];
      const round3Shift: number[] = [3, 9, 11, 15];
      for (let i = 0; i < 16; i++) {
        const h = (b ^ c ^ d) >>> 0;
        a = rotl(add(add(add(a, h), x[round3Order[i]]), 0x6ed9eba1), round3Shift[i % 4]);
        const t = d;
        d = c;
        c = b;
        b = a;
        a = t;
      }

      a = add(a, aa);
      b = add(b, bb);
      c = add(c, cc);
      d = add(d, dd);
    }

    const out = new Uint8Array(16);
    const outDv = new DataView(out.buffer);
    outDv.setUint32(0, a >>> 0, true);
    outDv.setUint32(4, b >>> 0, true);
    outDv.setUint32(8, c >>> 0, true);
    outDv.setUint32(12, d >>> 0, true);
    return out;
  }
}
