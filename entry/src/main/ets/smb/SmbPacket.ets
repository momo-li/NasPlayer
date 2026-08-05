import { SmbCrypto } from './SmbCrypto';

export const SMB2_HEADER_LEN = 64;

export class SmbCommand {
  static readonly NEGOTIATE = 0x0000;
  static readonly SESSION_SETUP = 0x0001;
  static readonly LOGOFF = 0x0002;
  static readonly TREE_CONNECT = 0x0003;
  static readonly CREATE = 0x0005;
  static readonly CLOSE = 0x0006;
  static readonly READ = 0x0008;
  static readonly QUERY_DIRECTORY = 0x000e;
}

export class SmbStatus {
  static readonly SUCCESS = 0x00000000;
  static readonly MORE_PROCESSING_REQUIRED = 0xc0000016;
  static readonly BUFFER_OVERFLOW = 0x80000005;
  static readonly NO_MORE_FILES = 0x80000006;
  static readonly LOGON_FAILURE = 0xc000006d;
  static readonly ACCESS_DENIED = 0xc0000022;
  static readonly BAD_NETWORK_NAME = 0xc00000cc;
  static readonly NETWORK_NAME_DELETED = 0xc00000c9;
  static readonly OBJECT_NAME_NOT_FOUND = 0xc0000034;
  static readonly OBJECT_PATH_NOT_FOUND = 0xc000003a;
  static readonly INVALID_PARAMETER = 0xc000000d;

  static describe(status: number): string {
    if (status === SmbStatus.LOGON_FAILURE) {
      return '登录失败：用户名或密码错误';
    }
    if (status === SmbStatus.ACCESS_DENIED) {
      return '访问被拒绝';
    }
    if (status === SmbStatus.BAD_NETWORK_NAME || status === SmbStatus.NETWORK_NAME_DELETED) {
      return '共享不存在或不可用';
    }
    if (status === SmbStatus.OBJECT_NAME_NOT_FOUND || status === SmbStatus.OBJECT_PATH_NOT_FOUND) {
      return '路径不存在';
    }
    if (status === SmbStatus.INVALID_PARAMETER) {
      return '服务器拒绝请求（可能不支持 SMB3.1.1，请联系 NAS 开启 SMB2/3）';
    }
    return 'SMB 错误 0x' + (status >>> 0).toString(16).toUpperCase();
  }
}

export class ByteWriter {
  private buf: Uint8Array;
  private dv: DataView;
  private pos: number = 0;

  constructor(capacity: number) {
    this.buf = new Uint8Array(capacity);
    this.dv = new DataView(this.buf.buffer);
  }

  get position(): number {
    return this.pos;
  }

  set position(v: number) {
    this.pos = v;
  }

  u8(v: number): void {
    this.dv.setUint8(this.pos, v & 0xff);
    this.pos += 1;
  }

  u16le(v: number): void {
    this.dv.setUint16(this.pos, v & 0xffff, true);
    this.pos += 2;
  }

  u32le(v: number): void {
    this.dv.setUint32(this.pos, v >>> 0, true);
    this.pos += 4;
  }

  u64le(v: number): void {
    const lo = v >>> 0;
    const hi = Math.floor(v / 4294967296) >>> 0;
    this.dv.setUint32(this.pos, lo, true);
    this.dv.setUint32(this.pos + 4, hi, true);
    this.pos += 8;
  }

  bytes(b: Uint8Array): void {
    this.buf.set(b, this.pos);
    this.pos += b.length;
  }

  utf16le(s: string): void {
    const b = SmbCrypto.utf16leEncode(s);
    this.bytes(b);
  }

  finish(): Uint8Array {
    return this.buf.slice(0, this.pos);
  }
}

export class ByteReader {
  private buf: Uint8Array;
  private dv: DataView;
  private pos: number;

  constructor(b: Uint8Array, start: number = 0) {
    this.buf = b;
    this.dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    this.pos = start;
  }

  get position(): number {
    return this.pos;
  }

  set position(v: number) {
    this.pos = v;
  }

  remaining(): number {
    return this.buf.length - this.pos;
  }

  u8(): number {
    const v = this.dv.getUint8(this.pos);
    this.pos += 1;
    return v;
  }

  u16le(): number {
    const v = this.dv.getUint16(this.pos, true);
    this.pos += 2;
    return v;
  }

  u32le(): number {
    const v = this.dv.getUint32(this.pos, true);
    this.pos += 4;
    return v;
  }

  u64le(): number {
    const lo = this.dv.getUint32(this.pos, true);
    const hi = this.dv.getUint32(this.pos + 4, true);
    this.pos += 8;
    return hi * 4294967296 + lo;
  }

  bytes(n: number): Uint8Array {
    const out = this.buf.slice(this.pos, this.pos + n);
    this.pos += n;
    return out;
  }
}

export interface SmbHeader {
  command: number;
  status: number;
  messageId: number;
  sessionId: number;
  treeId: number;
  flags: number;
}

export class SmbPacket {
  static readonly FLAG_SIGNED = 0x00000008;

  static build(command: number, messageId: number, sessionId: number, treeId: number,
    processId: number, flags: number, body: Uint8Array): Uint8Array {
    const w = new ByteWriter(SMB2_HEADER_LEN + body.length);
    w.bytes(new Uint8Array([0xfe, 0x53, 0x4d, 0x42]));
    w.u16le(64);
    w.u16le(0);
    w.u32le(0);
    w.u16le(command);
    w.u16le(126);
    w.u32le(flags);
    w.u32le(0);
    w.u64le(messageId);
    w.u32le(processId);
    w.u32le(treeId);
    w.u64le(sessionId);
    w.bytes(new Uint8Array(16));
    w.bytes(body);
    return w.finish();
  }

  static parseHeader(raw: Uint8Array): SmbHeader {
    const r = new ByteReader(raw);
    r.bytes(4);
    r.u16le();
    r.u16le();
    const status = r.u32le();
    const command = r.u16le();
    r.u16le();
    const flags = r.u32le();
    r.u32le();
    const messageId = r.u64le();
    r.u32le();
    const treeId = r.u32le();
    const sessionId = r.u64le();
    const header: SmbHeader = {
      command: command,
      status: status,
      messageId: messageId,
      sessionId: sessionId,
      treeId: treeId,
      flags: flags
    };
    return header;
  }

  static replaceSignature(raw: Uint8Array, signature: Uint8Array): Uint8Array {
    const out = raw.slice();
    out.set(signature, 48);
    return out;
  }

  static body(raw: Uint8Array): Uint8Array {
    return raw.slice(SMB2_HEADER_LEN);
  }

  static negotiateReq(clientGuid: Uint8Array): Uint8Array {
    const dialects: number[] = [0x0202, 0x0210, 0x0300, 0x0302, 0x0311];
    const w = new ByteWriter(36 + dialects.length * 2);
    w.u16le(36);
    w.u16le(dialects.length);
    w.u16le(0x0001);
    w.u16le(0);
    w.u32le(0);
    w.bytes(clientGuid);
    w.u64le(0);
    for (let i = 0; i < dialects.length; i++) {
      w.u16le(dialects[i]);
    }
    return w.finish();
  }

  static parseNegotiateResp(body: Uint8Array): NegotiateInfo {
    const r = new ByteReader(body);
    r.u16le();
    const securityMode = r.u16le();
    const dialectRevision = r.u16le();
    const info: NegotiateInfo = {
      securityMode: securityMode,
      dialectRevision: dialectRevision,
      maxReadSize: 0
    };
    if (r.remaining() >= 44) {
      r.bytes(2);
      r.bytes(16);
      r.u32le();
      r.u32le();
      r.u32le();
      r.u32le();
      info.maxReadSize = r.u32le();
    }
    return info;
  }

  static sessionSetupReq(blob: Uint8Array, preauthHash: Uint8Array | undefined, mic: Uint8Array | undefined): Uint8Array {
    const fixedLen = 88;
    const micLen = mic !== undefined ? 16 : 0;
    const w = new ByteWriter(fixedLen + blob.length + micLen);
    w.u16le(25);
    w.u8(0);
    w.u8(0x01);
    w.u32le(0x00000001);
    w.u32le(0);
    w.u16le(fixedLen);
    w.u16le(blob.length);
    w.u64le(0);
    w.u32le(0);
    if (preauthHash !== undefined) {
      w.bytes(preauthHash);
    } else {
      w.bytes(new Uint8Array(64));
    }
    w.bytes(blob);
    if (mic !== undefined) {
      w.bytes(mic);
    }
    return w.finish();
  }

  static parseSessionSetupResp(body: Uint8Array): Uint8Array {
    const r = new ByteReader(body);
    r.u16le();
    r.u16le();
    const off = r.u16le();
    const len = r.u16le();
    if (len === 0) {
      return new Uint8Array(0);
    }
    return body.slice(off - SMB2_HEADER_LEN, off - SMB2_HEADER_LEN + len);
  }

  static treeConnectReq(uncPath: string): Uint8Array {
    const path = SmbCrypto.utf16leEncode(uncPath);
    const w = new ByteWriter(8 + path.length);
    w.u16le(9);
    w.u16le(0);
    w.u16le(72);
    w.u16le(path.length);
    w.bytes(path);
    return w.finish();
  }

  static createReq(fileName: string, isDirectory: boolean): Uint8Array {
    const name = SmbCrypto.utf16leEncode(fileName);
    const w = new ByteWriter(56 + name.length);
    w.u16le(57);
    w.u8(0);
    w.u8(0);
    w.u32le(2);
    w.u64le(0);
    w.u64le(0);
    w.u32le(0x00120089);
    w.u32le(0);
    w.u32le(0x7);
    w.u32le(0x1);
    w.u32le(isDirectory ? 0x00200000 : 0);
    w.u16le(120);
    w.u16le(name.length);
    w.u32le(0);
    w.u32le(0);
    w.bytes(name);
    return w.finish();
  }

  static parseCreateResp(body: Uint8Array): CreateInfo {
    const r = new ByteReader(body);
    r.u16le();
    r.u8();
    r.u8();
    r.u32le();
    r.u64le();
    r.u64le();
    r.u64le();
    r.u64le();
    r.u64le();
    r.u64le();
    const endOfFile = r.u64le();
    r.u32le();
    r.u32le();
    const fileId = r.bytes(16);
    const info: CreateInfo = {
      fileId: fileId,
      endOfFile: endOfFile
    };
    return info;
  }

  static queryDirectoryReq(fileId: Uint8Array): Uint8Array {
    const pattern = SmbCrypto.utf16leEncode('*');
    const w = new ByteWriter(32 + pattern.length);
    w.u16le(33);
    w.u8(3);
    w.u8(0);
    w.u32le(0);
    w.bytes(fileId);
    w.u16le(96);
    w.u16le(pattern.length);
    w.u32le(65536);
    w.bytes(pattern);
    return w.finish();
  }

  static parseQueryDirectoryResp(body: Uint8Array): QueryEntry[] {
    const r = new ByteReader(body);
    r.u16le();
    const off = r.u16le();
    const len = r.u32le();
    const data = body.slice(off - SMB2_HEADER_LEN, off - SMB2_HEADER_LEN + len);
    const entries: QueryEntry[] = [];
    const er = new ByteReader(data);
    while (er.remaining() >= 4) {
      const next = er.u32le();
      er.u32le();
      er.u64le();
      er.u64le();
      er.u64le();
      er.u64le();
      const endOfFile = er.u64le();
      er.u64le();
      const attributes = er.u32le();
      const nameLen = er.u32le();
      er.u32le();
      er.u8();
      er.u8();
      er.bytes(24);
      const name = SmbCrypto.utf16leDecode(er.bytes(nameLen));
      const isDir = (attributes & 0x10) !== 0;
      const entry: QueryEntry = {
        name: name,
        isDirectory: isDir,
        size: endOfFile
      };
      entries.push(entry);
      if (next === 0 || er.remaining() < 4) {
        break;
      }
      er.position = er.position + next - (94 + nameLen);
    }
    return entries;
  }

  static readReq(fileId: Uint8Array, offset: number, length: number): Uint8Array {
    const w = new ByteWriter(48);
    w.u16le(49);
    w.u8(0);
    w.u8(0);
    w.u32le(length);
    w.u64le(offset);
    w.bytes(fileId);
    w.u32le(0);
    w.u32le(0);
    w.u32le(0);
    w.u16le(0);
    w.u16le(0);
    return w.finish();
  }

  static parseReadResp(body: Uint8Array): Uint8Array {
    const r = new ByteReader(body);
    r.u16le();
    const off = r.u16le();
    r.u32le();
    const len = r.u32le();
    return body.slice(off - SMB2_HEADER_LEN, off - SMB2_HEADER_LEN + len);
  }

  static closeReq(fileId: Uint8Array): Uint8Array {
    const w = new ByteWriter(24);
    w.u16le(24);
    w.u16le(0);
    w.u32le(0);
    w.bytes(fileId);
    return w.finish();
  }

  static logoffReq(): Uint8Array {
    const w = new ByteWriter(4);
    w.u16le(4);
    w.u16le(0);
    return w.finish();
  }
}

export interface NegotiateInfo {
  securityMode: number;
  dialectRevision: number;
  maxReadSize: number;
}

export interface CreateInfo {
  fileId: Uint8Array;
  endOfFile: number;
}

export interface QueryEntry {
  name: string;
  isDirectory: boolean;
  size: number;
}
