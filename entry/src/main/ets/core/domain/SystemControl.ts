import { decodeNasResponse, nasInteger, nasRecord, NasErrorKind, NasFailure, normalizeNasOrigin } from './DsmProtocol';

export type NasControlAction = 'reboot' | 'shutdown';
export type NasControlState = 'pending' | 'accepted' | 'rejected' | 'resolved';

export interface NasControlRecord {
  id: string;
  origin: string;
  account: string;
  model: string;
  fingerprint: string;
  action: NasControlAction;
  state: NasControlState;
  createdAt: number;
  updatedAt: number;
}

interface NasControlSnapshot { version: number; record: NasControlRecord; }

export class NasControlRejection extends NasFailure {
  constructor(kind: NasErrorKind, message: string, code: number = 0) {
    super(kind, message, code);
    this.name = 'NasControlRejection';
  }
}

function controlProtocolFailure(): NasFailure {
  return new NasFailure(NasErrorKind.Protocol, 'DSM 控制响应格式不符合预期，操作结果尚未确认，请勿自动重试。');
}

export function assertNasControlAccepted(status: number, text: string): void {
  if (status !== 200) {
    decodeNasResponse('SYNO.Core.System', status, text);
    return;
  }
  let parsed: Object;
  try { parsed = JSON.parse(text) as Object; } catch { throw controlProtocolFailure(); }
  const envelope = nasRecord(parsed);
  if (Object.keys(envelope).some((field: string): boolean => !['success', 'data', 'error'].includes(field)) ||
    typeof envelope['success'] !== 'boolean') {
    throw controlProtocolFailure();
  }
  if (envelope['success'] === true) {
    if (envelope['error'] !== undefined) { throw controlProtocolFailure(); }
    decodeNasResponse('SYNO.Core.System', status, text);
    return;
  }
  if (envelope['data'] !== undefined) { throw controlProtocolFailure(); }
  const error = nasRecord(envelope['error']);
  if (Object.keys(error).length !== 1 || Object.keys(error)[0] !== 'code') { throw controlProtocolFailure(); }
  nasInteger(error['code']);
  try { decodeNasResponse('SYNO.Core.System', status, text); } catch (failure) {
    if (failure instanceof NasFailure) { throw new NasControlRejection(failure.kind, failure.message, failure.code); }
    throw failure;
  }
}

export function validateNasControlAction(input: string): NasControlAction {
  if (input !== 'reboot' && input !== 'shutdown') {
    throw new NasFailure(NasErrorKind.InvalidInput, '仅支持重启或关机操作。');
  }
  return input;
}

function controlRecord(input: Object): Record<string, Object> {
  if (input === null || typeof input !== 'object' || Array.isArray(input)) {
    throw new NasFailure(NasErrorKind.InvalidInput, 'NAS 控制记录格式不正确。');
  }
  return input as Record<string, Object>;
}

function controlFields(row: Record<string, Object>, fields: string[]): void {
  const keys = Object.keys(row);
  if (keys.length !== fields.length || keys.some((field: string): boolean => !fields.includes(field))) {
    throw new NasFailure(NasErrorKind.InvalidInput, 'NAS 控制记录字段不正确，请勿保存密码、登录凭据或设备序列号。');
  }
}

function controlText(input: Object | undefined, label: string, trim: boolean): string {
  if (typeof input !== 'string' || /[\u0000-\u001f\u007f-\u009f]/.test(input as string)) {
    throw new NasFailure(NasErrorKind.InvalidInput, label + '格式不正确，不能包含控制字符。');
  }
  const text = trim ? (input as string).trim() : input as string;
  if (text.trim().length === 0 || text.length > 128) {
    throw new NasFailure(NasErrorKind.InvalidInput, label + '不能为空，且不能超过 128 个字符。');
  }
  return text;
}

export function validateNasControlRecord(input: Object): NasControlRecord {
  const row = controlRecord(input);
  controlFields(row, ['id', 'origin', 'account', 'model', 'fingerprint', 'action', 'state', 'createdAt', 'updatedAt']);
  const id = row['id'];
  if (typeof id !== 'string' || !/^(?:[0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$/.test(id as string)) {
    throw new NasFailure(NasErrorKind.InvalidInput, 'NAS 控制记录标识格式不正确。');
  }
  if (typeof row['origin'] !== 'string') { throw new NasFailure(NasErrorKind.InvalidInput, '请输入 HTTPS 连接地址。'); }
  const fingerprint = row['fingerprint'];
  if (typeof fingerprint !== 'string' || !/^[0-9a-f]{64}$/.test(fingerprint as string)) {
    throw new NasFailure(NasErrorKind.InvalidInput, '设备指纹格式不正确，不能保存 NAS 控制记录。');
  }
  const state = row['state'];
  if (state !== 'pending' && state !== 'accepted' && state !== 'rejected' && state !== 'resolved') {
    throw new NasFailure(NasErrorKind.InvalidInput, 'NAS 控制记录状态不正确。');
  }
  const createdAt = row['createdAt'];
  const updatedAt = row['updatedAt'];
  if (typeof createdAt !== 'number' || !Number.isSafeInteger(createdAt) || (createdAt as number) < 0 ||
    typeof updatedAt !== 'number' || !Number.isSafeInteger(updatedAt) || (updatedAt as number) < (createdAt as number)) {
    throw new NasFailure(NasErrorKind.InvalidInput, 'NAS 控制记录时间不正确。');
  }
  return {
    id: id as string,
    origin: normalizeNasOrigin(row['origin'] as string),
    account: controlText(row['account'], '账号', true),
    model: controlText(row['model'], '设备型号', false),
    fingerprint: fingerprint as string,
    action: validateNasControlAction(row['action'] as string),
    state: state as NasControlState,
    createdAt: createdAt as number,
    updatedAt: updatedAt as number
  };
}

export function encodeNasControlRecord(record: NasControlRecord): string {
  const snapshot: NasControlSnapshot = { version: 1, record: validateNasControlRecord(record) };
  return JSON.stringify(snapshot);
}

export function decodeNasControlRecord(text: string): NasControlRecord {
  try {
    const root = controlRecord(JSON.parse(text) as Object);
    controlFields(root, ['version', 'record']);
    if (root['version'] !== 1) { throw new NasFailure(NasErrorKind.Protocol, 'NAS 控制记录版本不受支持。'); }
    return validateNasControlRecord(root['record']);
  } catch {
    throw new NasFailure(NasErrorKind.Protocol, 'NAS 控制记录损坏或版本不受支持，请保留记录并重试读取。');
  }
}

export function nasControlUnresolved(record: NasControlRecord | undefined): boolean {
  return record !== undefined && (record.state === 'pending' || record.state === 'accepted');
}
