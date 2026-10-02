import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { NasErrorKind, NasFailure } from '../core/domain/DsmProtocol';

export function decodeUtf8Complete(bytes: Uint8Array): string {
  try {
    return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes, { stream: false });
  } catch (error) {
    throw new NasFailure(NasErrorKind.Protocol, '服务器业务响应不是有效的 UTF-8 文本。', (error as BusinessError).code);
  }
}

export function decodeResponsePrefix(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8', { fatal: false }).decodeToString(bytes, { stream: false });
}
