import { fileIo } from '@kit.CoreFileKit';
import { NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { closeFile } from '../../platform/SdkFileIO';
import { localSpaceBudget } from '../../platform/LocalSpaceBudget';

/** RCP 没有上传范围字段，前台只生成一次有界读取的剩余文件，不以 JS 循环发送分片。 */
export async function copyDriveUploadRemainder(source: string, destination: string, total: number, offset: number,
  current: () => void): Promise<void> {
  if (!Number.isSafeInteger(offset) || offset < 0 || offset > total) {
    throw new NasFailure(NasErrorKind.Protocol, '无法确认原上传的进度，请核对目标文件。');
  }
  const input = await fileIo.open(source, fileIo.OpenMode.READ_ONLY);
  let inputFailed = false;
  try {
    const stat = await fileIo.stat(input.fd);
    if (!stat.isFile() || stat.size !== total) { throw new NasFailure(NasErrorKind.InvalidInput, '本机上传副本已变化，无法继续原上传。'); }
    await localSpaceBudget.reserve(destination.slice(0, destination.lastIndexOf('/')), destination, total - offset);
    const output = await fileIo.open(destination, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    let outputFailed = false;
    try {
      const buffer = new ArrayBuffer(256 * 1024);
      let copied = 0;
      while (copied < total - offset) {
        current();
        const count = await fileIo.read(input.fd, buffer, { offset: copied === 0 ? offset : 0, length: Math.min(buffer.byteLength, total - offset - copied) });
        if (count < 1 || count > total - offset - copied) { throw new NasFailure(NasErrorKind.Protocol, '本机上传副本无法完整读取。'); }
        let written = 0;
        while (written < count) {
          const size = await fileIo.write(output.fd, buffer.slice(written, count));
          if (size < 1 || size > count - written) { throw new NasFailure(NasErrorKind.Protocol, '本机上传副本无法完整保存。'); }
          written += size;
        }
        copied += count;
        localSpaceBudget.advance(destination, total - offset - copied);
      }
      current();
      if ((await fileIo.stat(output.fd)).size !== total - offset || (await fileIo.stat(input.fd)).size !== total) {
        throw new NasFailure(NasErrorKind.Protocol, '本机上传副本已变化，无法继续原上传。');
      }
      await fileIo.fsync(output.fd);
    } catch (error) { outputFailed = true; throw error as Error; }
    finally { await closeFile(output, outputFailed); }
  } catch (error) { inputFailed = true; throw error as Error; }
  finally { localSpaceBudget.release(destination); await closeFile(input, inputFailed); }
}
