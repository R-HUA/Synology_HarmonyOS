import { nasInteger, nasRecord, nasString, NasErrorKind, NasFailure } from './DsmProtocol';

export type ExtensionFeature = 'fileSharing' | 'nasDownloads' | 'photos';
export interface ExtensionPendingWrite {
  feature: ExtensionFeature;
  operation: string;
  createdAt: number;
  photoId?: number;
  photoSpace?: number;
  taskId?: number;
}
export interface ExtensionWriteSnapshot {
  version: number;
  scope: string;
  pending: ExtensionPendingWrite[];
}

export function decodeExtensionWrites(text: string, scope: string): ExtensionPendingWrite[] {
  let parsed: Object;
  try { parsed = JSON.parse(text) as Object; }
  catch { throw new NasFailure(NasErrorKind.Protocol, '扩展操作记录损坏，请先修复记录，不能重复提交。'); }
  const data = nasRecord(parsed);
  if (data['version'] !== 1 || data['scope'] !== scope || !Array.isArray(data['pending']) || data['pending'].length > 3) {
    throw new NasFailure(NasErrorKind.Protocol, '扩展操作记录不匹配，暂不能提交新的操作。');
  }
  const result: ExtensionPendingWrite[] = [];
  for (const item of data['pending'] as Object[]) {
    const record = nasRecord(item);
    const feature = nasString(record['feature']);
    const operation = nasString(record['operation']);
    const createdAt = nasInteger(record['createdAt']);
    if ((feature !== 'fileSharing' && feature !== 'nasDownloads' && feature !== 'photos') ||
      !(feature === 'photos' ? ['favorite', 'delete', 'album', 'share', 'copy', 'move'] : ['create', 'edit', 'delete', 'pause', 'resume']).includes(operation) || createdAt < 1 ||
      result.some((existing: ExtensionPendingWrite): boolean => existing.feature === feature)) {
      throw new NasFailure(NasErrorKind.Protocol, '扩展操作记录无效，暂不能提交新的操作。');
    }
    const pending: ExtensionPendingWrite = { feature: feature as ExtensionFeature, operation, createdAt };
    if (feature === 'photos') {
      pending.photoId = nasInteger(record['photoId']); pending.photoSpace = nasInteger(record['photoSpace']);
      if (![0, 1].includes(pending.photoSpace)) { throw new NasFailure(NasErrorKind.Protocol, '照片操作来源无效。'); }
      if (record['taskId'] !== undefined) { pending.taskId = nasInteger(record['taskId']); }
    }
    result.push(pending);
  }
  return result;
}

export function extensionWriteIsUncertain(error: Error): boolean {
  return !(error instanceof NasFailure) || [NasErrorKind.Network, NasErrorKind.Tls, NasErrorKind.Http,
    NasErrorKind.Protocol, NasErrorKind.Cancelled].includes(error.kind);
}
