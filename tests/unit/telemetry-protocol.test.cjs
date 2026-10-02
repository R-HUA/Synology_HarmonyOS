const test = require('node:test').test;
const assert = require('node:assert/strict');
const telemetry = require('../../work/core-build/domain/TelemetryProtocol.js');
const protocol = require('../../work/core-build/domain/DsmProtocol.js');

const SYNTHETIC_SYSTEM = {
  model: 'DS-test', firmware_ver: '7.2-test', sys_temp: 42, up_time: '12 days 03:04:05',
  serial: 'SYNTHETIC_PRIVATE_SERIAL', mac: 'SYNTHETIC_PRIVATE_MAC'
};
const SYNTHETIC_UTILIZATION = {
  cpu: { user_load: 12.5, system_load: 7.5, other_load: 5, '1min_load': 950 },
  memory: { total_real: 8192, avail_real: 2048, real_usage: 41, cached: 1024, buffer: 128 },
  network: [
    { device: 'total', rx: 1500, tx: 300 },
    { device: 'eth0', rx: 1000, tx: 200 },
    { device: 'bond0', rx: 500, tx: 100 }
  ]
};
const SYNTHETIC_STORAGE = {
  volumes: [
    { id: 'volume_1', size: { total: '1099511627776', used: '274877906944' }, status: 'normal' },
    { id: 'volume_2', size: { total: 1024, used: 0 } }
  ],
  disks: [{ id: 'SYNTHETIC_DISK' }], storagePools: [{ id: 'SYNTHETIC_POOL' }]
};
const SYNTHETIC_INVALID_BYTES = [NaN, Infinity, -Infinity, -1, 1.5, Number.MAX_SAFE_INTEGER + 1,
  null, true, {}, []];
const SYNTHETIC_INVALID_PERCENTAGES = [NaN, Infinity, -Infinity, -1, 100.01, '25', null, true, {}, []];
const SYNTHETIC_INVALID_TEXT = ['', ' ', '\t', 'a\nb', 'a\u0000b', 'a\u007fb', 'a\u0085b',
  'a'.repeat(257), 0, null, true, {}, []];
const SYNTHETIC_INVALID_RECORDS = [null, 0, 'record', true, []];

function isFailure(kind) {
  return error => error instanceof protocol.NasFailure && error.kind === kind;
}

function rejectsProtocol(callback) {
  assert.throws(callback, isFailure(protocol.NasErrorKind.Protocol));
}

test('SYNTHETIC system maps only approved fields without retaining identity data', () => {
  const input = structuredClone(SYNTHETIC_SYSTEM);
  assert.deepEqual(telemetry.decodeTelemetrySystem(input), {
    model: 'DS-test', dsmVersion: '7.2-test', temperatureC: 42, uptime: '12 days 03:04:05'
  });
  assert.deepEqual(input, SYNTHETIC_SYSTEM);
});

test('SYNTHETIC missing system fields stay absent while zero temperature is retained', () => {
  assert.deepEqual(telemetry.decodeTelemetrySystem({}), {});
  assert.deepEqual(telemetry.decodeTelemetrySystem({ serial: 'SYNTHETIC_PRIVATE_SERIAL' }), {});
  assert.deepEqual(telemetry.decodeTelemetrySystem({ sys_temp: 0 }), { temperatureC: 0 });
  assert.deepEqual(telemetry.decodeTelemetrySystem({ sys_temp: 125 }), { temperatureC: 125 });
});

test('SYNTHETIC system rejects malformed text and invalid temperatures', () => {
  for (const field of ['model', 'firmware_ver', 'up_time']) {
    for (const value of SYNTHETIC_INVALID_TEXT) {
      rejectsProtocol(() => telemetry.decodeTelemetrySystem({ [field]: value }));
    }
    assert.ok(Object.values(telemetry.decodeTelemetrySystem({ [field]: 'a'.repeat(256) })).length === 1);
  }
  for (const value of [NaN, Infinity, -Infinity, -1, 125.01, '42', null, true, {}, []]) {
    rejectsProtocol(() => telemetry.decodeTelemetrySystem({ sys_temp: value }));
  }
});

test('SYNTHETIC utilization sums CPU percentages without interpreting average load', () => {
  const input = structuredClone(SYNTHETIC_UTILIZATION);
  assert.equal(telemetry.decodeTelemetryUtilization(input).cpuPercent, 25);
  assert.deepEqual(telemetry.decodeTelemetryUtilization({ cpu: { '1min_load': 950 } }), { networks: [] });
  assert.deepEqual(input, SYNTHETIC_UTILIZATION);
});

test('SYNTHETIC memory converts KiB and keeps DSM real_usage separate from total minus available', () => {
  const decoded = telemetry.decodeTelemetryUtilization(SYNTHETIC_UTILIZATION);
  assert.equal(decoded.memoryTotalBytes, 8388608);
  assert.equal(decoded.memoryUsedBytes, 6291456);
  assert.equal(decoded.memoryUsagePercent, 41);
  assert.notEqual(decoded.memoryUsagePercent, decoded.memoryUsedBytes / decoded.memoryTotalBytes * 100);
});

test('SYNTHETIC networks retain original IDs and B/s without adding total or calculating deltas', () => {
  const expected = [
    { id: 'total', receiveBytesPerSecond: 1500, sendBytesPerSecond: 300 },
    { id: 'eth0', receiveBytesPerSecond: 1000, sendBytesPerSecond: 200 },
    { id: 'bond0', receiveBytesPerSecond: 500, sendBytesPerSecond: 100 }
  ];
  assert.deepEqual(telemetry.decodeTelemetryUtilization(SYNTHETIC_UTILIZATION).networks, expected);
  assert.deepEqual(telemetry.decodeTelemetryUtilization(SYNTHETIC_UTILIZATION).networks, expected);
  assert.deepEqual(telemetry.decodeTelemetryUtilization({ network: [
    { device: 'eth0', rx: 0, tx: 0 }
  ] }).networks, [{ id: 'eth0', receiveBytesPerSecond: 0, sendBytesPerSecond: 0 }]);
});

test('SYNTHETIC empty utilization produces no fake indicators and preserves measured zeros', () => {
  assert.deepEqual(telemetry.decodeTelemetryUtilization({}), { networks: [] });
  assert.deepEqual(telemetry.decodeTelemetryUtilization({ cpu: {}, memory: {}, network: [] }), { networks: [] });
  assert.deepEqual(telemetry.decodeTelemetryUtilization({
    cpu: { user_load: 0, system_load: 0, other_load: 0 },
    memory: { total_real: 0, avail_real: 0, real_usage: 0 }
  }), { networks: [], cpuPercent: 0, memoryTotalBytes: 0, memoryUsedBytes: 0, memoryUsagePercent: 0 });
});

test('SYNTHETIC partial utilization does not invent missing CPU, memory or network values', () => {
  for (const missing of ['user_load', 'system_load', 'other_load']) {
    const cpu = { user_load: 1, system_load: 2, other_load: 3 };
    delete cpu[missing];
    assert.deepEqual(telemetry.decodeTelemetryUtilization({ cpu }), { networks: [] });
  }
  assert.deepEqual(telemetry.decodeTelemetryUtilization({ memory: { total_real: 2 } }),
    { networks: [], memoryTotalBytes: 2048 });
  assert.deepEqual(telemetry.decodeTelemetryUtilization({ memory: { avail_real: 2 } }), { networks: [] });
  assert.deepEqual(telemetry.decodeTelemetryUtilization({ memory: { real_usage: 0 } }),
    { networks: [], memoryUsagePercent: 0 });
  assert.deepEqual(telemetry.decodeTelemetryUtilization({ network: [
    { device: 'eth0', rx: 1 }, { rx: 1, tx: 2 }, { device: 'eth1', tx: 2 }, {}
  ] }), { networks: [] });
});

test('SYNTHETIC utilization rejects invalid percentages and CPU totals even on partial responses', () => {
  for (const field of ['user_load', 'system_load', 'other_load']) {
    for (const value of SYNTHETIC_INVALID_PERCENTAGES) {
      rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ cpu: { [field]: value } }));
    }
  }
  for (const value of SYNTHETIC_INVALID_PERCENTAGES) {
    rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ memory: { real_usage: value } }));
  }
  rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ cpu: {
    user_load: 60, system_load: 30, other_load: 11
  } }));
  rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ cpu: { user_load: 60, system_load: 60 } }));
  assert.equal(telemetry.decodeTelemetryUtilization({ cpu: {
    user_load: 100, system_load: 0, other_load: 0
  } }).cpuPercent, 100);
});

test('SYNTHETIC memory rejects invalid KiB, unsafe converted bytes and available greater than total', () => {
  for (const field of ['total_real', 'avail_real']) {
    for (const value of SYNTHETIC_INVALID_BYTES.concat(['1', Number.MAX_SAFE_INTEGER,
      Math.floor(Number.MAX_SAFE_INTEGER / 1024) + 1])) {
      rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ memory: { [field]: value } }));
    }
    const largest = Math.floor(Number.MAX_SAFE_INTEGER / 1024);
    assert.doesNotThrow(() => telemetry.decodeTelemetryUtilization({ memory: { [field]: largest } }));
  }
  rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ memory: { total_real: 1, avail_real: 2 } }));
  assert.equal(telemetry.decodeTelemetryUtilization({ memory: {
    total_real: 2, avail_real: 2
  } }).memoryUsedBytes, 0);
});

test('SYNTHETIC networks reject invalid present fields, duplicate IDs and oversized arrays', () => {
  for (const value of SYNTHETIC_INVALID_TEXT) {
    rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ network: [{ device: value }] }));
  }
  for (const field of ['rx', 'tx']) {
    for (const value of SYNTHETIC_INVALID_BYTES.concat(['1'])) {
      rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ network: [{ [field]: value }] }));
    }
  }
  for (const identity of ['eth0', 'total']) {
    rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ network: [
      { device: identity, rx: 1, tx: 2 }, { device: identity, rx: 1, tx: 2 }
    ] }));
    rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ network: [
      { device: identity }, { device: identity }
    ] }));
  }
  const rows = Array.from({ length: 256 }, (value, index) => ({ device: 'eth' + index, rx: 0, tx: 0 }));
  assert.equal(telemetry.decodeTelemetryUtilization({ network: rows }).networks.length, 256);
  rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ network: rows.concat({ device: 'eth256', rx: 0, tx: 0 }) }));
});

test('SYNTHETIC storage maps decimal byte strings or numbers with optional one-level data wrapper', () => {
  const input = structuredClone(SYNTHETIC_STORAGE);
  const expected = [
    { id: 'volume_1', totalBytes: 1099511627776, usedBytes: 274877906944, status: 'normal' },
    { id: 'volume_2', totalBytes: 1024, usedBytes: 0 }
  ];
  assert.deepEqual(telemetry.decodeTelemetryVolumes(input), expected);
  assert.deepEqual(telemetry.decodeTelemetryVolumes({ data: input }), expected);
  assert.deepEqual(input, SYNTHETIC_STORAGE);
});

test('SYNTHETIC storage distinguishes absent and empty volumes and does not infer disks or pools', () => {
  assert.equal(telemetry.decodeTelemetryVolumes({}), undefined);
  assert.equal(telemetry.decodeTelemetryVolumes({ data: {} }), undefined);
  assert.equal(telemetry.decodeTelemetryVolumes({ disks: [], storagePools: [] }), undefined);
  assert.deepEqual(telemetry.decodeTelemetryVolumes({ volumes: [] }), []);
  assert.deepEqual(telemetry.decodeTelemetryVolumes({ data: { volumes: [] } }), []);
  assert.deepEqual(telemetry.decodeTelemetryVolumes({ volumes: [
    { id: 'zero', size: { total: '0', used: '0' } }
  ] }), [{ id: 'zero', totalBytes: 0, usedBytes: 0 }]);
});

test('SYNTHETIC partial volumes are omitted without defaulting missing fields to zero', () => {
  assert.deepEqual(telemetry.decodeTelemetryVolumes({ volumes: [
    {}, { id: 'no-size' }, { id: 'no-total', size: { used: 0 } },
    { id: 'no-used', size: { total: 1 } }, { size: { total: 1, used: 0 } }
  ] }), []);
});

test('SYNTHETIC volume bytes strictly reject malformed decimal strings and unsafe numbers', () => {
  const invalid = SYNTHETIC_INVALID_BYTES.concat([
    '', ' ', '-1', '+1', '1.5', '1e3', '0x10', 'NaN', 'Infinity', '1\n', ' 1', '1 ',
    '9007199254740992', '9007199254740993', '9'.repeat(256), '0'.repeat(257)
  ]);
  for (const field of ['total', 'used']) {
    for (const value of invalid) {
      rejectsProtocol(() => telemetry.decodeTelemetryVolumes({ volumes: [{ size: { [field]: value } }] }));
    }
  }
  assert.deepEqual(telemetry.decodeTelemetryVolumes({ volumes: [
    { id: 'safe', size: { total: String(Number.MAX_SAFE_INTEGER), used: Number.MAX_SAFE_INTEGER } },
    { id: 'leading-zero', size: { total: '0001', used: '0'.repeat(256) } }
  ] }), [
    { id: 'safe', totalBytes: Number.MAX_SAFE_INTEGER, usedBytes: Number.MAX_SAFE_INTEGER },
    { id: 'leading-zero', totalBytes: 1, usedBytes: 0 }
  ]);
});

test('SYNTHETIC volumes reject invalid present text, excess used bytes, duplicates and oversized arrays', () => {
  for (const field of ['id', 'status']) {
    for (const value of SYNTHETIC_INVALID_TEXT) {
      rejectsProtocol(() => telemetry.decodeTelemetryVolumes({ volumes: [{ [field]: value }] }));
    }
  }
  rejectsProtocol(() => telemetry.decodeTelemetryVolumes({ volumes: [{ size: { total: '0', used: '1' } }] }));
  rejectsProtocol(() => telemetry.decodeTelemetryVolumes({ volumes: [
    { id: 'duplicate', size: { total: 1, used: 0 } }, { id: 'duplicate', size: { total: 1, used: 0 } }
  ] }));
  rejectsProtocol(() => telemetry.decodeTelemetryVolumes({ volumes: [{ id: 'duplicate' }, { id: 'duplicate' }] }));
  const rows = Array.from({ length: 256 }, (value, index) => ({ id: 'volume_' + index, size: { total: 0, used: 0 } }));
  assert.equal(telemetry.decodeTelemetryVolumes({ volumes: rows }).length, 256);
  rejectsProtocol(() => telemetry.decodeTelemetryVolumes({ volumes: rows.concat({ id: 'extra', size: { total: 0, used: 0 } }) }));
});

test('SYNTHETIC decoders reject malformed root, nested records, arrays and rows', () => {
  for (const decoder of [telemetry.decodeTelemetrySystem, telemetry.decodeTelemetryUtilization,
    telemetry.decodeTelemetryVolumes]) {
    for (const value of SYNTHETIC_INVALID_RECORDS) { rejectsProtocol(() => decoder(value)); }
  }
  for (const value of SYNTHETIC_INVALID_RECORDS) {
    rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ cpu: value }));
    rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ memory: value }));
    rejectsProtocol(() => telemetry.decodeTelemetryVolumes({ data: value }));
    rejectsProtocol(() => telemetry.decodeTelemetryVolumes({ volumes: [{ size: value }] }));
    rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ network: [value] }));
    rejectsProtocol(() => telemetry.decodeTelemetryVolumes({ volumes: [value] }));
  }
  for (const value of [null, 0, 'array', true, {}]) {
    rejectsProtocol(() => telemetry.decodeTelemetryUtilization({ network: value }));
    rejectsProtocol(() => telemetry.decodeTelemetryVolumes({ volumes: value }));
  }
});

test('SYNTHETIC byte formatting uses concise IEC units through TiB', () => {
  for (const example of [
    [0, '0 B'], [1, '1 B'], [1023, '1023 B'], [1024, '1 KiB'], [1536, '1.5 KiB'],
    [1024 ** 2, '1 MiB'], [1024 ** 3, '1 GiB'], [1024 ** 4, '1 TiB'],
    [1024 ** 4 * 1.5, '1.5 TiB'], [1024 ** 2 - 1, '1 MiB']
  ]) { assert.equal(telemetry.telemetryBytes(example[0]), example[1]); }
  assert.match(telemetry.telemetryBytes(Number.MAX_SAFE_INTEGER), /^\d+(\.\d)? TiB$/);
});

test('SYNTHETIC percentage formatting preserves zero and bounds without unnecessary decimals', () => {
  for (const example of [[0, '0%'], [100, '100%'], [25, '25%'], [12.5, '12.5%'], [12.56, '12.6%']]) {
    assert.equal(telemetry.telemetryPercent(example[0]), example[1]);
  }
});

test('SYNTHETIC timestamp formatting uses local time from Unix epoch milliseconds', () => {
  const timestamp = new Date(2026, 9, 2, 3, 4, 5).getTime();
  assert.equal(telemetry.telemetryTimestamp(timestamp), '2026年10月02日 03:04:05');
  assert.match(telemetry.telemetryTimestamp(0), /^\d{4}年\d{2}月\d{2}日 \d{2}:\d{2}:\d{2}$/);
  assert.doesNotThrow(() => telemetry.telemetryTimestamp(8640000000000000));
});

test('SYNTHETIC formatters reject invalid numeric inputs instead of emitting fake values', () => {
  for (const value of SYNTHETIC_INVALID_BYTES.concat(['1'])) {
    assert.throws(() => telemetry.telemetryBytes(value), isFailure(protocol.NasErrorKind.InvalidInput));
  }
  for (const value of SYNTHETIC_INVALID_PERCENTAGES) {
    assert.throws(() => telemetry.telemetryPercent(value), isFailure(protocol.NasErrorKind.InvalidInput));
  }
  for (const value of [NaN, Infinity, -Infinity, -1, 1.5, 8640000000000001, Number.MAX_SAFE_INTEGER,
    '0', null, true, {}, []]) {
    assert.throws(() => telemetry.telemetryTimestamp(value), isFailure(protocol.NasErrorKind.InvalidInput));
  }
});
