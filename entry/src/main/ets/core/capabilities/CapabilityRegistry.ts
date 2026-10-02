import { NasErrorKind, NasFailure } from '../domain/DsmProtocol';
import type { NasApiDescriptor } from '../domain/DsmProtocol';
import { selectVerifiedApi } from '../network/ApiVersionPolicy';

export type CapabilityState = 'available' | 'notInstalled' | 'unsupportedVersion' | 'unauthorized' |
  'unreachable' | 'schemaMismatch' | 'unverified';

export interface CapabilityDefinition {
  feature: string;
  api: string;
  verifiedVersions: number[];
}

export interface CapabilitySnapshot {
  feature: string;
  state: CapabilityState;
  apiVersion: number;
  packageVersion: string;
  checkedAt: number;
  errorKind?: NasErrorKind;
  errorCode?: number;
  reason: string;
}

export class CapabilityRegistry {
  private entries: Map<string, CapabilitySnapshot> = new Map();
  private requests: Map<string, number> = new Map();
  private generation: number = 0;

  constructor(private definitions: CapabilityDefinition[]) {}

  discover(apis: NasApiDescriptor[], checkedAt: number = Date.now()): void {
    this.clear();
    for (const definition of this.definitions) {
      const snapshot: CapabilitySnapshot = { feature: definition.feature, state: 'unverified', apiVersion: 0,
        packageVersion: '', checkedAt: checkedAt, reason: 'apiNotDiscovered' };
      if (apis.some((api: NasApiDescriptor): boolean => api.name === definition.api)) {
        try {
          snapshot.apiVersion = selectVerifiedApi(apis, definition.api, definition.verifiedVersions).version;
          snapshot.reason = 'readNotVerified';
        } catch (error) {
          if (!(error instanceof NasFailure) || error.kind !== NasErrorKind.Unsupported) { throw error; }
          snapshot.state = 'unsupportedVersion';
          snapshot.reason = 'noVerifiedVersion';
        }
      }
      this.entries.set(definition.feature, snapshot);
    }
  }

  snapshots(): CapabilitySnapshot[] {
    const result: CapabilitySnapshot[] = [];
    this.entries.forEach((snapshot: CapabilitySnapshot): void => { result.push({ ...snapshot }); });
    return result;
  }

  clear(): void {
    this.generation++;
    this.entries.clear();
    this.requests.clear();
  }

  async read<T>(feature: string, readAndValidate: () => Promise<T>): Promise<T> {
    const snapshot = this.entries.get(feature);
    if (snapshot === undefined) {
      throw new NasFailure(NasErrorKind.Cancelled, '功能状态已失效，请重新连接。');
    }
    const generation = this.generation;
    const request = (this.requests.get(feature) ?? 0) + 1;
    this.requests.set(feature, request);
    try {
      const result = await readAndValidate();
      if (generation === this.generation && request === this.requests.get(feature) && snapshot.apiVersion > 0) {
        this.entries.set(feature, { feature: feature, state: 'available', apiVersion: snapshot.apiVersion,
          packageVersion: snapshot.packageVersion, checkedAt: Date.now(), reason: 'readVerified' });
      }
      return result;
    } catch (error) {
      if (generation === this.generation && request === this.requests.get(feature) && error instanceof NasFailure &&
        error.kind !== NasErrorKind.Cancelled && error.kind !== NasErrorKind.InvalidInput) {
        let state: CapabilityState = snapshot.state === 'unsupportedVersion' ? 'unsupportedVersion' : 'unverified';
        if (error.kind === NasErrorKind.Permission || error.kind === NasErrorKind.Credentials || error.kind === NasErrorKind.SessionExpired) {
          state = 'unauthorized';
        } else if (error.kind === NasErrorKind.Network || error.kind === NasErrorKind.Tls) { state = 'unreachable'; }
        else if (error.kind === NasErrorKind.Protocol) { state = 'schemaMismatch'; }
        this.entries.set(feature, { feature: feature, state: state, apiVersion: snapshot.apiVersion,
          packageVersion: snapshot.packageVersion, checkedAt: Date.now(), errorKind: error.kind,
          errorCode: error.code, reason: 'readFailed' });
      }
      throw error;
    }
  }
}
