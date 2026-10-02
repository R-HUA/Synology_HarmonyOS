import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure } from '../core/domain/DsmProtocol';

export async function closeFile(file: fileIo.File, operationFailed: boolean = false): Promise<void> {
  try { await fileIo.close(file); }
  catch (error) {
    const code = (error as BusinessError).code;
    if (!operationFailed) { throw new NasFailure(NasErrorKind.Protocol, '本机文件关闭失败，操作未完成。', code); }
    hilog.error(0x0000, 'NasFileIO', 'operation=close result=failed code=%{public}d', code);
  }
}

export async function writePrivateSnapshot(path: string, bytes: Uint8Array): Promise<void> {
  const temporary = path + '.tmp';
  let opened = false;
  let operation = 'open';
  try {
    const file = await fileIo.open(temporary, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    opened = true;
    let failed = false;
    try {
      operation = 'write';
      let offset = 0;
      while (offset < bytes.length) {
        const count = await fileIo.write(file.fd, bytes.slice(offset).buffer as ArrayBuffer);
        if (count < 1) { throw new NasFailure(NasErrorKind.Protocol, '本机记录写入不完整，未保存更改。'); }
        offset += count;
      }
      operation = 'fsync';
      await fileIo.fsync(file.fd);
    } catch (error) {
      failed = true;
      throw error as Error;
    } finally { await closeFile(file, failed); }
    operation = 'rename';
    await fileIo.rename(temporary, path);
  } catch (error) {
    if (opened) {
      try { await fileIo.unlink(temporary); }
      catch (cleanupError) {
        const code = (cleanupError as BusinessError).code;
        if (code !== 13900002) {
          hilog.error(0x0000, 'NasFileIO', 'operation=snapshot_cleanup result=failed code=%{public}d', code);
        }
      }
    }
    if (error instanceof NasFailure) { throw error; }
    const code = (error as BusinessError).code;
    hilog.error(0x0000, 'NasFileIO', 'operation=%{public}s result=failed code=%{public}d', operation, code);
    throw new NasFailure(NasErrorKind.Protocol, '本机记录保存失败，原记录未替换，请重试。', code);
  }
}
