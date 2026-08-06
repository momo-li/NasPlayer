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
    try {
      const random = cryptoFramework.createRandom();
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
    try {
      const md = cryptoFramework.createMd('SHA512');
      const blob: cryptoFramework.DataBlob = { data: data };
      await md.update(blob);
      const out = await md.digest();
      return out.data;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'sha512 failed: %{public}s stack=%{public}s', JSON.stringify(e),
        e instanceof Error && e.stack !== undefined ? e.stack : '');
      throw new Error('crypto(sha512) failed: ' + JSON.stringify(e));
    }
  }

  static async hmac(alg: string, key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    try {
      const gen = cryptoFramework.createSymKeyGenerator('HMAC');
      const keyBlob: cryptoFramework.DataBlob = { data: key };
      const symKey = await gen.convertKey(keyBlob);
      const mac = cryptoFramework.createMac(alg);
      await mac.init(symKey);
      const dataBlob: cryptoFramework.DataBlob = { data: data };
      await mac.update(dataBlob);
      const out = await mac.doFinal();
      return out.data;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'hmac %{public}s failed: %{public}s stack=%{public}s', alg, JSON.stringify(e),
        e instanceof Error && e.stack !== undefined ? e.stack : '');
      throw new Error('crypto(hmac ' + alg + ') failed: ' + JSON.stringify(e));
    }
  }

  static async hmacMd5(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    return SmbCrypto.hmac('MD5', key, data);
  }

  static async hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    return SmbCrypto.hmac('SHA256', key, data);
  }

  private static readonly AES_SBOX: number[] = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16
  ];
  private static readonly AES_RCON: number[] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];

  static aes128Encrypt(key: Uint8Array, block: Uint8Array): Uint8Array {
    const w = new Uint8Array(176);
    w.set(key, 0);
    for (let i = 4; i < 44; i++) {
      let t: number[] = [w[(i - 1) * 4], w[(i - 1) * 4 + 1], w[(i - 1) * 4 + 2], w[(i - 1) * 4 + 3]];
      if (i % 4 === 0) {
        t = [t[1], t[2], t[3], t[0]];
        t = [SmbCrypto.AES_SBOX[t[0]], SmbCrypto.AES_SBOX[t[1]], SmbCrypto.AES_SBOX[t[2]], SmbCrypto.AES_SBOX[t[3]]];
        t[0] ^= SmbCrypto.AES_RCON[i / 4 - 1];
      }
      for (let j = 0; j < 4; j++) {
        w[i * 4 + j] = w[(i - 4) * 4 + j] ^ t[j];
      }
    }
    const s: Uint8Array[] = [new Uint8Array(4), new Uint8Array(4), new Uint8Array(4), new Uint8Array(4)];
    for (let r = 0; r < 4; r++) {
      for (let c = 0; c < 4; c++) {
        s[r][c] = block[r + 4 * c];
      }
    }
    const addRoundKey = (round: number): void => {
      for (let c = 0; c < 4; c++) {
        for (let r = 0; r < 4; r++) {
          s[r][c] ^= w[round * 16 + c * 4 + r];
        }
      }
    };
    const subBytes = (): void => {
      for (let r = 0; r < 4; r++) {
        for (let c = 0; c < 4; c++) {
          s[r][c] = SmbCrypto.AES_SBOX[s[r][c]];
        }
      }
    };
    const shiftRows = (): void => {
      for (let r = 1; r < 4; r++) {
        const row = s[r].slice();
        for (let c = 0; c < 4; c++) {
          s[r][c] = row[(c + r) % 4];
        }
      }
    };
    const xtime = (a: number, b: number): number => {
      let r = 0;
      let aa = a;
      let bb = b;
      for (let i = 0; i < 8; i++) {
        if ((bb & 1) !== 0) {
          r ^= aa;
        }
        const hi = aa & 0x80;
        aa = (aa << 1) & 0xff;
        if (hi !== 0) {
          aa ^= 0x1b;
        }
        bb >>= 1;
      }
      return r & 0xff;
    };
    const mixColumns = (): void => {
      for (let c = 0; c < 4; c++) {
        const a0 = s[0][c];
        const a1 = s[1][c];
        const a2 = s[2][c];
        const a3 = s[3][c];
        s[0][c] = xtime(a0, 2) ^ xtime(a1, 3) ^ a2 ^ a3;
        s[1][c] = a0 ^ xtime(a1, 2) ^ xtime(a2, 3) ^ a3;
        s[2][c] = a0 ^ a1 ^ xtime(a2, 2) ^ xtime(a3, 3);
        s[3][c] = xtime(a0, 3) ^ a1 ^ a2 ^ xtime(a3, 2);
      }
    };
    addRoundKey(0);
    for (let round = 1; round < 10; round++) {
      subBytes();
      shiftRows();
      mixColumns();
      addRoundKey(round);
    }
    subBytes();
    shiftRows();
    addRoundKey(10);
    const out = new Uint8Array(16);
    for (let r = 0; r < 4; r++) {
      for (let c = 0; c < 4; c++) {
        out[r + 4 * c] = s[r][c];
      }
    }
    return out;
  }

  static aes128Cmac(key: Uint8Array, data: Uint8Array): Uint8Array {
    const zeros = new Uint8Array(16);
    let l = SmbCrypto.aes128Encrypt(key, zeros);
    const subkey = (k: Uint8Array): Uint8Array => {
      const msb = (k[0] & 0x80) !== 0;
      const out = new Uint8Array(16);
      for (let i = 0; i < 15; i++) {
        out[i] = ((k[i] << 1) | (k[i + 1] >> 7)) & 0xff;
      }
      out[15] = (k[15] << 1) & 0xff;
      if (msb) {
        out[15] ^= 0x87;
      }
      return out;
    };
    const k1 = subkey(l);
    const k2 = subkey(k1);
    const n = Math.max(1, Math.ceil(data.length / 16));
    let x = new Uint8Array(16);
    for (let i = 0; i < n; i++) {
      const start = i * 16;
      const blk = data.slice(start, start + 16);
      const inp = new Uint8Array(16);
      if (i === n - 1) {
        if (blk.length === 16) {
          for (let j = 0; j < 16; j++) {
            inp[j] = x[j] ^ blk[j] ^ k1[j];
          }
        } else {
          inp.set(blk);
          inp[blk.length] = 0x80;
          for (let j = 0; j < 16; j++) {
            inp[j] ^= x[j] ^ k2[j];
          }
        }
      } else {
        for (let j = 0; j < 16; j++) {
          inp[j] = x[j] ^ blk[j];
        }
      }
      x = SmbCrypto.aes128Encrypt(key, inp);
    }
    return x;
  }

  static async deriveSigningKey(sessionKey: Uint8Array, preauthHash: Uint8Array): Promise<Uint8Array> {
    const label = SmbCrypto.asciiEncode('SMBSigningKey\u0000');
    const input = SmbCrypto.concat([new Uint8Array([0, 0, 0, 1]), label, new Uint8Array([0]),
      preauthHash, new Uint8Array([0, 0, 0, 0x80])]);
    const full = await SmbCrypto.hmacSha256(sessionKey, input);
    return full.slice(0, 16);
  }

  static async preauthChain(messages: Uint8Array[]): Promise<Uint8Array> {
    let h = new Uint8Array(64);
    for (let i = 0; i < messages.length; i++) {
      h = await SmbCrypto.sha512(SmbCrypto.concat([h, messages[i]]));
    }
    return h;
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
