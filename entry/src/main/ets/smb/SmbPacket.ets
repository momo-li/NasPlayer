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
      return '服务器拒绝请求（可能不支持 SMB3.1.1）';
    }
    if (status === 0xc0000072) {
      return '账户已被禁用';
    }
    if (status === 0xc0000071) {
      return '密码已过期';
    }
    if (status === 0xc000015b) {
      return '不允许使用该登录方式';
    }
    if (status === 0xc0000203) {
      return '会话已失效';
    }
    if (status === 0xc0000184) {
      return '协议状态错误（预认证校验失败）';
    }
    if (status === 0xc00000bb) {
      return '服务器不支持该请求';
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

  u16be(v: number): void {
    this.dv.setUint16(this.pos, v & 0xffff, false);
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
  sessionIdLo: number;
  sessionIdHi: number;
  treeId: number;
  flags: number;
}

export class SmbPacket {
  static readonly FLAG_SIGNED = 0x00000008;

  static build(command: number, messageId: number, sessionIdLo: number, sessionIdHi: number,
    treeId: number, processId: number, flags: number, body: Uint8Array): Uint8Array {
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
    w.u32le(sessionIdLo);
    w.u32le(sessionIdHi);
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
    const sessionIdLo = r.u32le();
    const sessionIdHi = r.u32le();
    const header: SmbHeader = {
      command: command,
      status: status,
      messageId: messageId,
      sessionIdLo: sessionIdLo,
      sessionIdHi: sessionIdHi,
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

  static negotiateReq(clientGuid: Uint8Array, host: string): Uint8Array {
    const dialects: number[] = [0x0202, 0x0210, 0x0300, 0x0302, 0x0311];
    const salt = new Uint8Array(32);
    for (let i = 0; i < 32; i++) {
      salt[i] = Math.floor(Math.random() * 256);
    }
    const mkCtx = (t: number, caps: Uint8Array): Uint8Array => {
      const out = new Uint8Array(8 + caps.length);
      out[0] = t & 0xff;
      out[1] = (t >> 8) & 0xff;
      out[2] = caps.length & 0xff;
      out[3] = (caps.length >> 8) & 0xff;
      out.set(caps, 8);
      return out;
    };
    const padCtx = (b: Uint8Array): Uint8Array => {
      const r = b.length % 8;
      if (r === 0) {
        return b;
      }
      const out = new Uint8Array(b.length + 8 - r);
      out.set(b);
      return out;
    };
    const preauthCaps = new Uint8Array(38);
    preauthCaps.set([0x01, 0x00, 0x20, 0x00, 0x01, 0x00], 0);
    preauthCaps.set(salt, 6);
    const cipherCaps = new Uint8Array([0x04, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00]);
    const hn = SmbCrypto.utf16leEncode(host);
    const netnameCaps = new Uint8Array(hn.length);
    netnameCaps.set(hn, 0);
    const signingCaps = new Uint8Array([0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00]);
    const ctxList = SmbCrypto.concat([
      padCtx(mkCtx(1, preauthCaps)),
      padCtx(mkCtx(2, cipherCaps)),
      padCtx(mkCtx(5, netnameCaps)),
      mkCtx(8, signingCaps)
    ]);
    const dialectsBuf = new Uint8Array(dialects.length * 2);
    for (let i = 0; i < dialects.length; i++) {
      SmbPacket.writeU16(dialectsBuf, i * 2, dialects[i]);
    }
    const f = new Uint8Array(36);
    SmbPacket.writeU16(f, 0, 36);
    SmbPacket.writeU16(f, 2, dialects.length);
    SmbPacket.writeU16(f, 4, 0x0002);
    SmbPacket.writeU16(f, 6, 0);
    SmbPacket.writeU32(f, 8, 0x45);
    f.set(clientGuid, 12);
    const ctxOffset = 64 + 36 + dialectsBuf.length;
    const padLen = ctxOffset % 8 === 0 ? 0 : 8 - (ctxOffset % 8);
    SmbPacket.writeU32(f, 28, ctxOffset + padLen);
    SmbPacket.writeU16(f, 32, 4);
    SmbPacket.writeU16(f, 34, 0);
    const out = new Uint8Array(36 + dialectsBuf.length + padLen + ctxList.length);
    out.set(f, 0);
    out.set(dialectsBuf, 36);
    out.set(ctxList, 36 + dialectsBuf.length + padLen);
    return out;
  }

  private static writeU16(buf: Uint8Array, off: number, v: number): void {
    buf[off] = v & 0xff;
    buf[off + 1] = (v >> 8) & 0xff;
  }

  static readU16(buf: Uint8Array, off: number): number {
    return buf[off] | (buf[off + 1] << 8);
  }

  static readU32(buf: Uint8Array, off: number): number {
    return (buf[off] | (buf[off + 1] << 8) | (buf[off + 2] << 16) | (buf[off + 3] << 24)) >>> 0;
  }

  private static writeU32(buf: Uint8Array, off: number, v: number): void {
    buf[off] = v & 0xff;
    buf[off + 1] = (v >> 8) & 0xff;
    buf[off + 2] = (v >> 16) & 0xff;
    buf[off + 3] = (v >> 24) & 0xff;
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
    const fixedLen = 24;
    const micLen = mic !== undefined ? 16 : 0;
    const bufferOffset = 88;
    const w = new ByteWriter(fixedLen + blob.length + micLen);
    w.u16le(25);
    w.u8(0);
    w.u8(0x02);
    w.u32le(0x00000001);
    w.u32le(0);
    w.u16le(bufferOffset);
    w.u16le(blob.length);
    w.u64le(0);
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

  private static asn1Len(len: number): Uint8Array {
    if (len < 0x80) {
      return new Uint8Array([len]);
    }
    if (len < 0x100) {
      return new Uint8Array([0x81, len]);
    }
    return new Uint8Array([0x82, (len >> 8) & 0xff, len & 0xff]);
  }

  static spnegoType1(type1: Uint8Array): Uint8Array {
    const oid = new Uint8Array([0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0a]);
    const mechType = SmbCrypto.concat([new Uint8Array([0xa0, 0x0e, 0x30, 0x0c, 0x06, 0x0a]), oid]);
    const octet = SmbCrypto.concat([new Uint8Array([0x04, type1.length]), type1]);
    const mechToken = SmbCrypto.concat([new Uint8Array([0xa2, octet.length]), octet]);
    const seq = SmbCrypto.concat([new Uint8Array([0x30, mechType.length + mechToken.length]), mechType, mechToken]);
    const mechList = SmbCrypto.concat([new Uint8Array([0xa0, seq.length]), seq]);
    const inner = SmbCrypto.concat([new Uint8Array([0x06, 0x06, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x02]), mechList]);
    return SmbCrypto.concat([new Uint8Array([0x60, inner.length]), inner]);
  }

  static spnegoWrapType3(type3: Uint8Array): Uint8Array {
    const octet = SmbCrypto.concat([new Uint8Array([0x04]), SmbPacket.asn1Len(type3.length), type3]);
    const respTok = SmbCrypto.concat([new Uint8Array([0xa2]), SmbPacket.asn1Len(octet.length), octet]);
    const negState = new Uint8Array([0xa0, 0x03, 0x0a, 0x01, 0x01]);
    const seq = SmbCrypto.concat([new Uint8Array([0x30]), SmbPacket.asn1Len(negState.length + respTok.length), negState, respTok]);
    return SmbCrypto.concat([new Uint8Array([0xa1]), SmbPacket.asn1Len(seq.length), seq]);
  }

  static extractNtlmFromSpnego(blob: Uint8Array): Uint8Array {
    const magic = SmbCrypto.asciiEncode('NTLMSSP\u0000');
    for (let i = 0; i + magic.length <= blob.length; i++) {
      let ok = true;
      for (let j = 0; j < magic.length; j++) {
        if (blob[i + j] !== magic[j]) {
          ok = false;
          break;
        }
      }
      if (ok) {
        return blob.slice(i);
      }
    }
    return blob;
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
    return SmbPacket.createReqWithAccess(fileName, isDirectory, 0x00120089);
  }

  static createPipeReq(pipeName: string): Uint8Array {
    return SmbPacket.createReqWithAccess(pipeName, false, 0x00120183);
  }

  private static createReqWithAccess(fileName: string, isDirectory: boolean, accessMask: number): Uint8Array {
    const name = SmbCrypto.utf16leEncode(fileName);
    const bufLen = name.length === 0 ? 1 : name.length;
    const w = new ByteWriter(56 + bufLen);
    w.u16le(57);
    w.u8(0);
    w.u8(0);
    w.u32le(2);
    w.u64le(0);
    w.u64le(0);
    w.u32le(accessMask);
    w.u32le(isDirectory ? 0x10 : 0);
    w.u32le(0x7);
    w.u32le(0x1);
    w.u32le(isDirectory ? 0x00000001 : 0);
    w.u16le(120);
    w.u16le(name.length);
    w.u32le(0);
    w.u32le(0);
    if (name.length === 0) {
      w.u8(0);
    } else {
      w.bytes(name);
    }
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
    const lastWriteTime = r.u64le();
    r.u64le();
    r.u64le();
    const endOfFile = r.u64le();
    r.u32le();
    r.u32le();
    const fileId = r.bytes(16);
    const info: CreateInfo = {
      fileId: fileId,
      endOfFile: endOfFile,
      lastWriteTime: lastWriteTime
    };
    return info;
  }

  static queryDirectoryReq(fileId: Uint8Array, restart: boolean): Uint8Array {
    const pattern = SmbCrypto.utf16leEncode('*');
    const w = new ByteWriter(32 + pattern.length);
    w.u16le(33);
    w.u8(0x0c);
    w.u8(restart ? 0x01 : 0x00);
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
    while (er.remaining() >= 12) {
      const next = er.u32le();
      er.u32le();
      const nameLen = er.u32le();
      if (nameLen === 0 || er.remaining() < nameLen) {
        break;
      }
      const name = SmbCrypto.utf16leDecode(er.bytes(nameLen));
      const entry: QueryEntry = {
        name: name,
        isDirectory: false,
        size: 0,
        lastWriteTime: 0
      };
      entries.push(entry);
      if (next === 0 || er.remaining() < 4) {
        break;
      }
      er.position = er.position + next - (12 + nameLen);
    }
    return entries;
  }

  static readReq(fileId: Uint8Array, offset: number, length: number): Uint8Array {
    const w = new ByteWriter(49);
    w.u16le(49);
    w.u8(0x50);
    w.u8(0);
    w.u32le(length);
    w.u64le(offset);
    w.bytes(fileId);
    w.u32le(0);
    w.u32le(0);
    w.u32le(0);
    w.u16le(0);
    w.u16le(0);
    w.u8(0);
    return w.finish();
  }

  static parseReadResp(body: Uint8Array): Uint8Array {
    const r = new ByteReader(body);
    r.u16le();
    const off = r.u16le();
    const len = r.u32le();
    r.u32le();
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

  static writeReq(fileId: Uint8Array, data: Uint8Array): Uint8Array {
    const w = new ByteWriter(48 + data.length);
    w.u16le(49);
    w.u16le(112);
    w.u32le(data.length);
    w.u64le(0);
    w.bytes(fileId);
    w.u32le(0);
    w.u32le(0);
    w.u16le(0);
    w.u16le(0);
    w.u32le(0);
    w.bytes(data);
    return w.finish();
  }

  static parseWriteResp(body: Uint8Array): number {
    const r = new ByteReader(body);
    r.u16le();
    r.u16le();
    return r.u32le();
  }

  static logoffReq(): Uint8Array {
    const w = new ByteWriter(4);
    w.u16le(4);
    w.u16le(0);
    return w.finish();
  }

  static rpcBindPdu(callId: number): Uint8Array {
    const srvsvcUuid = SmbPacket.uuidBytes([0x4b324fc8, 0x1670, 0x01d3, 0x1278], [0x5a, 0x47, 0xbf, 0x6e, 0xe1, 0x88]);
    const ndrUuid = SmbPacket.uuidBytes([0x8a885d04, 0x1ceb, 0x11c9, 0x9fe8], [0x08, 0x00, 0x2b, 0x10, 0x48, 0x60]);
    const w = new ByteWriter(72);
    w.u8(5);
    w.u8(0);
    w.u8(0x0b);
    w.u8(0x03);
    w.u32le(0x00000010);
    w.u16le(72);
    w.u16le(0);
    w.u32le(callId);
    w.u16le(0x10b8);
    w.u16le(0x10b8);
    w.u32le(0);
    w.u8(1);
    w.u8(0);
    w.u16le(0);
    w.u16le(0);
    w.u8(1);
    w.u8(0);
    w.bytes(srvsvcUuid);
    w.u32le(3);
    w.bytes(ndrUuid);
    w.u32le(2);
    return w.finish();
  }

  static rpcNetShareEnumPdu(callId: number, host: string): Uint8Array {
    const name = SmbCrypto.utf16leEncode('\\\\' + host + '\u0000');
    const w = new ByteWriter(104);
    w.u8(5);
    w.u8(0);
    w.u8(0x00);
    w.u8(0x03);
    w.u32le(0x00000010);
    w.u16le(104);
    w.u16le(0);
    w.u32le(callId);
    w.u32le(80);
    w.u16le(0);
    w.u16le(15);
    w.u32le(0x0000131a);
    w.u32le(16);
    w.u32le(0);
    w.u32le(16);
    w.bytes(name);
    w.u32le(1);
    w.u32le(1);
    w.u32le(0x00007f3a);
    w.u32le(0);
    w.u32le(0);
    w.u32le(0xffffffff);
    w.u32le(0x00005df1);
    w.u32le(0);
    return w.finish();
  }

  static parseRpcResponseStub(frame: Uint8Array): Uint8Array {
    return frame.slice(24);
  }

  static parseShareInfo1(stub: Uint8Array): RpcShareInfo[] {
    const r = new ByteReader(stub);
    r.u32le();
    r.u32le();
    r.u32le();
    const entriesRead = r.u32le();
    r.u32le();
    r.u32le();
    const entries: RpcShareInfo[] = [];
    if (entriesRead <= 0 || r.remaining() < entriesRead * 12) {
      return entries;
    }
    const names: number[] = [];
    for (let i = 0; i < entriesRead; i++) {
      const namePtr = r.u32le();
      const type = r.u32le();
      const remarkPtr = r.u32le();
      const info: RpcShareInfo = {
        name: '',
        type: type,
        remark: ''
      };
      entries.push(info);
      names.push(namePtr, remarkPtr);
    }
    const strSec = stub.slice(24 + entriesRead * 12);
    const wstrs: string[] = [];
    let wp = 0;
    while (wp + 12 <= strSec.length) {
      const actual = SmbPacket.readU32(strSec, wp + 8);
      const dataLen = actual * 2;
      if (wp + 12 + dataLen > strSec.length) {
        break;
      }
      let s = '';
      for (let i = 0; i < actual; i++) {
        const c = SmbPacket.readU16(strSec, wp + 12 + i * 2);
        if (c === 0) {
          break;
        }
        s += String.fromCharCode(c);
      }
      wstrs.push(s);
      wp = wp + 12 + dataLen;
      wp += (4 - (wp % 4)) % 4;
    }
    for (let i = 0; i < entries.length; i++) {
      entries[i].name = i * 2 < wstrs.length ? wstrs[i * 2] : '';
      entries[i].remark = i * 2 + 1 < wstrs.length ? wstrs[i * 2 + 1] : '';
    }
    return entries;
  }

  private static readUnicodeAt(stub: Uint8Array, ptr: number): string {
    if (ptr <= 0 || ptr >= stub.length) {
      return '';
    }
    let s = '';
    let i = ptr;
    while (i + 1 < stub.length && s.length < 400) {
      const c = stub[i] | (stub[i + 1] << 8);
      if (c === 0) {
        break;
      }
      s += String.fromCharCode(c);
      i += 2;
    }
    return s;
  }

  private static uuidBytes(parts: number[], tail: number[]): Uint8Array {
    const w = new ByteWriter(16);
    w.u32le(parts[0]);
    w.u16le(parts[1]);
    w.u16le(parts[2]);
    w.u16be(parts[3]);
    for (let i = 0; i < tail.length; i++) {
      w.u8(tail[i]);
    }
    return w.finish();
  }
}

export interface RpcShareInfo {
  name: string;
  type: number;
  remark: string;
}

export interface NegotiateInfo {
  securityMode: number;
  dialectRevision: number;
  maxReadSize: number;
}

export interface CreateInfo {
  fileId: Uint8Array;
  endOfFile: number;
  lastWriteTime: number;
}

export interface QueryEntry {
  name: string;
  isDirectory: boolean;
  size: number;
  lastWriteTime: number;
}
