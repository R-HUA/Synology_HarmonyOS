import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NasErrorKind, NasFailure } from '../core/domain/DsmProtocol';

function digestFailure(error: Error): NasFailure {
  if (error instanceof NasFailure) { return error; }
  return new NasFailure(NasErrorKind.Protocol, '本机摘要计算失败，无法完成身份或内容核验。', (error as BusinessError).code);
}

export class SdkDigest {
  private digest: cryptoFramework.Md;
  private expectedLength: number;

  constructor(algorithm: 'SHA256' | 'MD5') {
    if (!canIUse('SystemCapability.Security.CryptoFramework')) {
      throw new NasFailure(NasErrorKind.Unsupported, '当前设备不支持摘要计算，无法安全恢复记录或核验内容。');
    }
    this.expectedLength = algorithm === 'SHA256' ? 32 : 16;
    try { this.digest = cryptoFramework.createMd(algorithm); }
    catch (error) { throw digestFailure(error as Error); }
  }

  async update(bytes: Uint8Array): Promise<void> {
    try { await this.digest.update({ data: bytes }); }
    catch (error) { throw digestFailure(error as Error); }
  }

  async finish(): Promise<string> {
    try {
      const bytes = (await this.digest.digest()).data;
      if (bytes.length !== this.expectedLength) {
        throw new NasFailure(NasErrorKind.Protocol, '本机摘要结果不完整，无法完成身份或内容核验。');
      }
      return bytes.reduce((text: string, byte: number): string => text + byte.toString(16).padStart(2, '0'), '');
    } catch (error) { throw digestFailure(error as Error); }
  }
}

export async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = new SdkDigest('SHA256');
  await digest.update(bytes);
  return digest.finish();
}
