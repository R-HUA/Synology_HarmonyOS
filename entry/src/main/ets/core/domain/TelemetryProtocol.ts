import { NasFailure, NasErrorKind, nasRecord, nasString, nasInteger } from './DsmProtocol';

const MAX_TELEMETRY_ROWS = 256;
const MAX_TELEMETRY_TEXT_LENGTH = 256;
const MAX_TELEMETRY_TIMESTAMP = 8640000000000000;

export interface NasTelemetrySystem {
  model?: string;
  dsmVersion?: string;
  temperatureC?: number;
  uptime?: string;
}

export interface NasTelemetryNetwork {
  id: string;
  receiveBytesPerSecond: number;
  sendBytesPerSecond: number;
}

export interface NasTelemetryUtilization {
  cpuPercent?: number;
  memoryTotalBytes?: number;
  memoryUsedBytes?: number;
  memoryUsagePercent?: number;
  /** 磁盘读写速率取自 disk.total，仅当 NAS 返回磁盘采样时才存在。 */
  diskReadBytesPerSecond?: number;
  diskWriteBytesPerSecond?: number;
  networks: NasTelemetryNetwork[];
}

export interface NasTelemetryVolume {
  id: string;
  totalBytes: number;
  usedBytes: number;
  status?: string;
}

function telemetryFailure(): NasFailure {
  return new NasFailure(NasErrorKind.Protocol, 'NAS 运行状态响应格式不正确，请刷新后重试。');
}

function telemetryText(input: Object | undefined): string | undefined {
  if (input === undefined) { return undefined; }
  const value = nasString(input);
  if (value.length > MAX_TELEMETRY_TEXT_LENGTH || value.trim().length === 0 ||
    /[\u0000-\u001f\u007f-\u009f]/.test(value)) { throw telemetryFailure(); }
  return value;
}

function telemetryNumber(input: Object | undefined, minimum: number, maximum: number): number | undefined {
  if (input === undefined) { return undefined; }
  if (typeof input !== 'number' || !Number.isFinite(input) || input < minimum || input > maximum) {
    throw telemetryFailure();
  }
  return input as number;
}

function telemetryInteger(input: Object | undefined): number | undefined {
  return input === undefined ? undefined : nasInteger(input);
}

function telemetryMemoryBytes(input: Object | undefined): number | undefined {
  return input === undefined ? undefined : nasInteger(nasInteger(input) * 1024);
}

/** 字节数：DSM 同一含义的字段可能给十进制字符串（卷容量）或数字（磁盘读写速率），两种形态都按非负安全整数校验。 */
function telemetryByteCount(input: Object | undefined): number | undefined {
  if (input === undefined) { return undefined; }
  if (typeof input === 'string') {
    if (!/^[0-9]{1,256}$/.test(input)) { throw telemetryFailure(); }
    return nasInteger(Number(input));
  }
  return nasInteger(input);
}

function telemetryRows(input: Object): Object[] {
  if (!Array.isArray(input) || input.length > MAX_TELEMETRY_ROWS) { throw telemetryFailure(); }
  return input as Object[];
}

function telemetryId(input: Object | undefined, identities: Set<string>): string | undefined {
  const identity = telemetryText(input);
  if (identity !== undefined) {
    if (identities.has(identity)) { throw telemetryFailure(); }
    identities.add(identity);
  }
  return identity;
}

function telemetryNetworks(input: Object | undefined): NasTelemetryNetwork[] {
  const networks: NasTelemetryNetwork[] = [];
  if (input === undefined) { return networks; }
  const identities = new Set<string>();
  for (const row of telemetryRows(input)) {
    const data = nasRecord(row);
    const identity = telemetryId(data['device'], identities);
    const received = telemetryInteger(data['rx']);
    const sent = telemetryInteger(data['tx']);
    if (identity !== undefined && received !== undefined && sent !== undefined) {
      networks.push({ id: identity, receiveBytesPerSecond: received, sendBytesPerSecond: sent });
    }
  }
  return networks;
}

export function decodeTelemetrySystem(input: Record<string, Object>): NasTelemetrySystem {
  const data = nasRecord(input);
  const system: NasTelemetrySystem = {};
  const model = telemetryText(data['model']);
  const version = telemetryText(data['firmware_ver']);
  const temperature = telemetryNumber(data['sys_temp'], 0, 125);
  const uptime = telemetryText(data['up_time']);
  if (model !== undefined) { system.model = model; }
  if (version !== undefined) { system.dsmVersion = version; }
  if (temperature !== undefined) { system.temperatureC = temperature; }
  if (uptime !== undefined) { system.uptime = uptime; }
  return system;
}

export function decodeTelemetryUtilization(input: Record<string, Object>): NasTelemetryUtilization {
  const data = nasRecord(input);
  const utilization: NasTelemetryUtilization = { networks: telemetryNetworks(data['network']) };
  if (data['cpu'] !== undefined) {
    const cpu = nasRecord(data['cpu']);
    const user = telemetryNumber(cpu['user_load'], 0, 100);
    const system = telemetryNumber(cpu['system_load'], 0, 100);
    const other = telemetryNumber(cpu['other_load'], 0, 100);
    let total = 0;
    if (user !== undefined) { total += user; }
    if (system !== undefined) { total += system; }
    if (other !== undefined) { total += other; }
    if (total > 100) { throw telemetryFailure(); }
    if (user !== undefined && system !== undefined && other !== undefined) { utilization.cpuPercent = total; }
  }
  if (data['memory'] !== undefined) {
    const memory = nasRecord(data['memory']);
    const total = telemetryMemoryBytes(memory['total_real']);
    const available = telemetryMemoryBytes(memory['avail_real']);
    const usage = telemetryNumber(memory['real_usage'], 0, 100);
    if (total !== undefined) { utilization.memoryTotalBytes = total; }
    if (total !== undefined && available !== undefined) {
      if (available > total) { throw telemetryFailure(); }
      utilization.memoryUsedBytes = total - available;
    }
    if (usage !== undefined) { utilization.memoryUsagePercent = usage; }
  }
  if (data['disk'] !== undefined) {
    const disk = nasRecord(data['disk']);
    if (disk['total'] !== undefined) {
      const total = nasRecord(disk['total']);
      const read = telemetryByteCount(total['read_byte']);
      const write = telemetryByteCount(total['write_byte']);
      if (read !== undefined) { utilization.diskReadBytesPerSecond = read; }
      if (write !== undefined) { utilization.diskWriteBytesPerSecond = write; }
    }
  }
  return utilization;
}

export function decodeTelemetryVolumes(input: Record<string, Object>): NasTelemetryVolume[] | undefined {
  const outer = nasRecord(input);
  const data = outer['data'] === undefined ? outer : nasRecord(outer['data']);
  if (data['volumes'] === undefined) { return undefined; }
  const volumes: NasTelemetryVolume[] = [];
  const identities = new Set<string>();
  for (const row of telemetryRows(data['volumes'])) {
    const volume = nasRecord(row);
    const identity = telemetryId(volume['id'], identities);
    const size = volume['size'] === undefined ? undefined : nasRecord(volume['size']);
    const total = size === undefined ? undefined : telemetryByteCount(size['total']);
    const used = size === undefined ? undefined : telemetryByteCount(size['used']);
    const status = telemetryText(volume['status']);
    if (total !== undefined && used !== undefined && used > total) { throw telemetryFailure(); }
    if (identity !== undefined && total !== undefined && used !== undefined) {
      const result: NasTelemetryVolume = { id: identity, totalBytes: total, usedBytes: used };
      if (status !== undefined) { result.status = status; }
      volumes.push(result);
    }
  }
  return volumes;
}

function telemetryDecimal(value: number): string {
  return value.toFixed(1).replace(/\.0$/, '');
}

/** DSM 的卷身份原文形如 volume_1（小写、真实返回值即此形态）。 */
const VOLUME_IDENTITY_PATTERN = /^volume_([0-9]{1,6})$/;

function telemetryVolumeNumber(identity: string): number | undefined {
  const matched = VOLUME_IDENTITY_PATTERN.exec(identity);
  if (matched === null) { return undefined; }
  const parsed = Number(matched[1]);
  return Number.isSafeInteger(parsed) ? parsed : undefined;
}

/** 卷标号 → 展示名：volume_1 显示为「存储空间 1」；无法解析出标号时原样返回，不猜含义。 */
export function telemetryVolumeLabel(identity: string): string {
  const volumeNumber = telemetryVolumeNumber(identity);
  return volumeNumber === undefined ? identity : '存储空间 ' + volumeNumber.toString();
}

/** 按「存储空间」标号从小到大排序；无法解析标号的卷保持原有相对顺序并排在其后。 */
export function telemetryVolumesSorted(volumes: NasTelemetryVolume[]): NasTelemetryVolume[] {
  const ordered = volumes.slice();
  ordered.sort((left: NasTelemetryVolume, right: NasTelemetryVolume): number => {
    const leftNumber = telemetryVolumeNumber(left.id);
    const rightNumber = telemetryVolumeNumber(right.id);
    if (leftNumber === undefined || rightNumber === undefined) {
      return leftNumber === rightNumber ? 0 : (leftNumber === undefined ? 1 : -1);
    }
    return leftNumber - rightNumber;
  });
  return ordered;
}

export function telemetryBytes(bytes: number): string {
  if (!Number.isSafeInteger(bytes) || bytes < 0) {
    throw new NasFailure(NasErrorKind.InvalidInput, '字节数必须是非负安全整数。');
  }
  const units: string[] = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1; }
  if (Math.round(value * 10) / 10 >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1; }
  return telemetryDecimal(value) + ' ' + units[unit];
}

export function telemetryPercent(value: number): string {
  if (!Number.isFinite(value) || value < 0 || value > 100) {
    throw new NasFailure(NasErrorKind.InvalidInput, '百分比必须在 0 到 100 之间。');
  }
  return telemetryDecimal(value) + '%';
}

function telemetryTimePart(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

export function telemetryTimestamp(timestamp: number): string {
  if (!Number.isSafeInteger(timestamp) || timestamp < 0 || timestamp > MAX_TELEMETRY_TIMESTAMP) {
    throw new NasFailure(NasErrorKind.InvalidInput, '状态更新时间不正确。');
  }
  const date = new Date(timestamp);
  return date.getFullYear().toString() + '年' + telemetryTimePart(date.getMonth() + 1) + '月' +
    telemetryTimePart(date.getDate()) + '日 ' + telemetryTimePart(date.getHours()) + ':' +
    telemetryTimePart(date.getMinutes()) + ':' + telemetryTimePart(date.getSeconds());
}
