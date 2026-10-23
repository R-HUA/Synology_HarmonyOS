import { nasRecord, NasErrorKind, NasFailure } from '../../core/domain/DsmProtocol';
import { limitLogText, readArray, readId, readNumber, readText, TextWindow } from '../../core/domain/ReadOnlyProtocol';

export type ContainerState = 'running' | 'stopped' | 'paused' | 'restarting' | 'unknown';
export interface ContainerItem { id: string; name: string; image: string; state: ContainerState; }
export interface ContainerDetail { item: ContainerItem; created: string; started: string; mounts: string[]; ports: string[]; }
export interface ContainerResource { cpu?: number; memory?: number; memoryPercent?: number; sampledAt: number; }

function state(value: Object | undefined): ContainerState {
  switch (value) {
    case 'running': return 'running';
    case 'stopped': case 'exited': case 'created': case 'dead': return 'stopped';
    case 'paused': return 'paused';
    case 'restarting': return 'restarting';
    default: return 'unknown';
  }
}

export function decodeContainers(input: Object): ContainerItem[] {
  const ids = new Set<string>();
  return readArray(nasRecord(input)['containers']).map((raw: Object): ContainerItem => {
    const row = nasRecord(raw), id = readId(row['id']), name = readId(row['name']);
    if (ids.has(id)) { throw new NasFailure(NasErrorKind.Protocol, '容器列表包含重复标识。'); }
    ids.add(id);
    return { id, name, image: readText(row['image']), state: state(row['status']) };
  });
}

export function decodeContainerDetail(input: Object, expected: ContainerItem): ContainerDetail {
  const row = nasRecord(nasRecord(input)['details']);
  if (readId(row['Id']) !== expected.id) { throw new NasFailure(NasErrorKind.Protocol, '容器已被替换，请刷新列表后重新打开。'); }
  const config = row['Config'] === undefined ? undefined : nasRecord(row['Config']);
  const status = row['State'] === undefined ? undefined : nasRecord(row['State']);
  const mounts = row['Mounts'] === undefined ? [] : readArray(row['Mounts']).map((raw: Object): string => {
    const mount = nasRecord(raw);
    return readText(mount['Source']) + ' → ' + readText(mount['Destination']) + (mount['RW'] === false ? '（只读）' : '');
  });
  const network = row['NetworkSettings'] === undefined ? undefined : nasRecord(row['NetworkSettings']);
  const bindings = network?.['Ports'] === undefined || network?.['Ports'] === null ? undefined : nasRecord(network['Ports']);
  const ports: string[] = [];
  if (bindings !== undefined) {
    for (const port of Object.keys(bindings)) {
      if (bindings[port] === null) { ports.push(port); continue; }
      for (const raw of readArray(bindings[port])) {
        const binding = nasRecord(raw);
        ports.push(readText(binding['HostIp']) + ':' + readText(binding['HostPort']) + ' → ' + port);
      }
    }
  }
  return { item: { ...expected, image: config === undefined ? expected.image : readText(config['Image']),
    state: status === undefined ? expected.state : state(status['Status']) }, created: readText(row['Created']),
    started: status === undefined ? '' : readText(status['StartedAt']), mounts, ports };
}

export function decodeContainerResource(input: Object, item: ContainerItem, sampledAt: number = Date.now()): ContainerResource {
  const rows = readArray(nasRecord(input)['resources']).map((raw: Object): Record<string, Object> => nasRecord(raw));
  const matching = rows.filter((row: Record<string, Object>): boolean => row['name'] === item.name);
  if (matching.length > 1) { throw new NasFailure(NasErrorKind.Protocol, '容器资源身份不明确。'); }
  const row = matching[0];
  return row === undefined ? { sampledAt } : { cpu: readNumber(row['cpu']), memory: readNumber(row['memory']),
    memoryPercent: readNumber(row['memoryPercent']), sampledAt };
}

export function decodeContainerLogs(input: Object): TextWindow {
  const data = nasRecord(input), rows = readArray(data['logs']);
  const lines = rows.slice(0, 500).map((raw: Object): string => {
    const row = nasRecord(raw);
    return readText(row['created']) + ' ' + readText(row['stream']) + ' ' + readText(row['text']);
  });
  const window = limitLogText(lines.join('\n'));
  return { text: window.text, truncated: window.truncated || rows.length >= 500 };
}

export function filterContainers(items: ContainerItem[], query: string, filter: ContainerState | 'all'): ContainerItem[] {
  const text = query.trim().toLocaleLowerCase();
  return items.filter((item: ContainerItem): boolean => (filter === 'all' || item.state === filter) && item.name.toLocaleLowerCase().includes(text));
}
