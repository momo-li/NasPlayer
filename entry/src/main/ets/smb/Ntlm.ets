import { SmbCrypto } from './SmbCrypto';
import { ByteWriter } from './SmbPacket';

export interface NtlmType3Result {
  message: Uint8Array;
  sessionKey: Uint8Array;
}

const NTLM_FLAGS: number = 0x00000001 | 0x00000004 | 0x00000200 | 0x00008000 |
  0x00080000 | 0x00800000 | 0x20000000 | 0x80000000;

export class Ntlm {
  static async createType1(): Promise<Uint8Array> {
    const w = new ByteWriter(32);
    w.bytes(SmbCrypto.asciiEncode('NTLMSSP\u0000'));
    w.u32le(1);
    w.u32le(NTLM_FLAGS);
    w.u16le(0);
    w.u16le(0);
    w.u32le(0);
    w.u16le(0);
    w.u16le(0);
    w.u32le(0);
    return w.finish();
  }

  static async parseType2(challenge: Uint8Array): Promise<Uint8Array> {
    const serverChallenge = challenge.slice(24, 32);
    return serverChallenge;
  }

  static async createType3(username: string, workstation: string, domain: string,
    serverChallenge: Uint8Array, password: string): Promise<NtlmType3Result> {
    const ntHash = SmbCrypto.md4(SmbCrypto.utf16leEncode(password));
    const userDomain = SmbCrypto.concat([SmbCrypto.utf16leEncode(username.toUpperCase()), SmbCrypto.utf16leEncode(domain)]);
    const ntlmv2Hash = await SmbCrypto.hmacMd5(ntHash, userDomain);
    const lmv2Hash = await SmbCrypto.hmacMd5(ntHash, userDomain);

    const timestamp = Ntlm.fileTimeNow();
    const clientChallenge = await SmbCrypto.randomBytes(8);
    const blob = Ntlm.buildBlob(timestamp, clientChallenge);

    const ntProofStr = await SmbCrypto.hmacMd5(ntlmv2Hash, SmbCrypto.concat([serverChallenge, blob]));
    const ntChallengeResponse = SmbCrypto.concat([ntProofStr, blob]);

    const lmv2Response = await SmbCrypto.hmacMd5(lmv2Hash, SmbCrypto.concat([serverChallenge, clientChallenge]));
    const lmChallengeResponse = SmbCrypto.concat([lmv2Response, clientChallenge]);

    const sessionKey = await SmbCrypto.hmacMd5(ntlmv2Hash, ntProofStr);

    const domainBytes = SmbCrypto.utf16leEncode(domain);
    const userBytes = SmbCrypto.utf16leEncode(username);
    const workstationBytes = SmbCrypto.utf16leEncode(workstation);

    const fixedLen = 52;
    let offset = fixedLen;
    const lmOff = offset;
    offset += lmChallengeResponse.length;
    const ntOff = offset;
    offset += ntChallengeResponse.length;
    const domainOff = offset;
    offset += domainBytes.length;
    const userOff = offset;
    offset += userBytes.length;
    const workstationOff = offset;
    offset += workstationBytes.length;

    const w = new ByteWriter(offset);
    w.bytes(SmbCrypto.asciiEncode('NTLMSSP\u0000'));
    w.u32le(3);
    Ntlm.writeSecurityBuffer(w, lmChallengeResponse.length, lmOff);
    Ntlm.writeSecurityBuffer(w, ntChallengeResponse.length, ntOff);
    Ntlm.writeSecurityBuffer(w, domainBytes.length, domainOff);
    Ntlm.writeSecurityBuffer(w, userBytes.length, userOff);
    Ntlm.writeSecurityBuffer(w, workstationBytes.length, workstationOff);
    Ntlm.writeSecurityBuffer(w, 0, offset);
    w.u32le(NTLM_FLAGS);
    w.bytes(lmChallengeResponse);
    w.bytes(ntChallengeResponse);
    w.bytes(domainBytes);
    w.bytes(userBytes);
    w.bytes(workstationBytes);

    const result: NtlmType3Result = {
      message: w.finish(),
      sessionKey: sessionKey
    };
    return result;
  }

  private static writeSecurityBuffer(w: ByteWriter, len: number, off: number): void {
    w.u16le(len);
    w.u16le(len);
    w.u32le(off);
  }

  private static buildBlob(timestamp: number, clientChallenge: Uint8Array): Uint8Array {
    const w = new ByteWriter(36);
    w.u8(0x01);
    w.u8(0x01);
    w.u16le(0x0000);
    w.u32le(0x00000000);
    w.u64le(timestamp);
    w.bytes(clientChallenge);
    w.u32le(0x00000000);
    w.u16le(0x0000);
    w.u16le(0x0000);
    return w.finish();
  }

  private static fileTimeNow(): number {
    const nowMs = Date.now();
    return (nowMs + 11644473600000) * 10000;
  }
}
