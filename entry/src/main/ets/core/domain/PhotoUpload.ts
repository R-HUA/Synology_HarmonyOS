import { NasErrorKind, NasFailure, NasFormField } from './DsmProtocol';

/** 本地媒体的日期使用秒，与 Photos 的 mtime 字段一致。 */
export function photoDateDirectory(takenAt: number, modifiedAt: number): string {
  const seconds = takenAt > 0 ? takenAt : modifiedAt;
  const date = new Date(seconds * 1000);
  if (!Number.isFinite(seconds) || seconds <= 0 || !Number.isFinite(date.getTime())) {
    throw new NasFailure(NasErrorKind.InvalidInput, '照片缺少可用日期，无法按日期上传。');
  }
  return date.getFullYear().toString() + '/' + (date.getMonth() + 1).toString().padStart(2, '0');
}

/** Photos 网页客户端的目标目录上传合同；重名保留两份原文件。 */
export function photoUploadFields(folderId: number, name: string, modifiedAt: number): NasFormField[] {
  if (!Number.isSafeInteger(folderId) || folderId < 0 || !Number.isSafeInteger(modifiedAt) || modifiedAt <= 0) {
    throw new NasFailure(NasErrorKind.InvalidInput, '照片上传目标或修改日期无效。');
  }
  return [{ name: 'target_folder_id', content: folderId.toString() }, { name: 'name', content: JSON.stringify(name) },
    { name: 'mtime', content: modifiedAt.toString() }, { name: 'duplicate', content: JSON.stringify('rename') }];
}
