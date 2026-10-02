import { selectNasApi } from '../domain/DsmProtocol';
import type { NasApiDescriptor } from '../domain/DsmProtocol';

export interface VerifiedApiVersion { api: NasApiDescriptor; version: number; }

export function selectVerifiedApi(capabilities: NasApiDescriptor[], name: string, verifiedVersions: number[]): VerifiedApiVersion {
  const versions = verifiedVersions.filter((version: number): boolean => Number.isSafeInteger(version) && version > 0);
  const api = selectNasApi(capabilities, name, versions);
  const compatible = versions.filter((version: number): boolean => version >= api.minVersion && version <= api.maxVersion);
  return { api: api, version: Math.max(...compatible) };
}
