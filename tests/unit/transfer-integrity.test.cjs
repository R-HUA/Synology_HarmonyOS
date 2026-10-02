const { test } = require('node:test');
const assert = require('node:assert/strict');
const { NasConnector, NAS_DISCOVERY_QUERY } = require('../../work/core-build/network/NasConnector.js');
const protocol = require('../../work/core-build/domain/DsmProtocol.js');
const state = require('../../work/core-build/domain/TransferQueueState.js');

async function connectorFixture(jsonParameters, md5Api = true) {
  const requests = [];
  let response = { success: true, data: { taskid: 'CHECKSUM_001' } };
  const capabilities = {
    'SYNO.API.Auth': { minVersion: 1, maxVersion: 6, path: 'auth.cgi' },
    'SYNO.FileStation.List': { minVersion: 1, maxVersion: 2, path: 'entry.cgi' },
  };
  if (md5Api) capabilities['SYNO.FileStation.MD5'] = { minVersion: 1, maxVersion: 2, path: 'entry.cgi',
    ...(jsonParameters ? { requestFormat: 'JSON' } : {}) };
  const connector = new NasConnector({
    async post(address, body, session) {
      requests.push({ address, body, session });
      const api = new URLSearchParams(body).get('api');
      return { status: 200, text: JSON.stringify(api === 'SYNO.API.Info' ? { success: true, data: capabilities } : response) };
    }, close() {},
  });
  await connector.discover('https://nas.example:5001');
  connector.restoreSession({ sid: 'SYNTHETIC-SID', synoToken: 'SYNTHETIC-TOKEN' });
  return { connector, requests, setResponse: value => { response = value; } };
}

test('checksum uses discovered MD5 v2, exact path/task IDs and the existing authenticated POST contract', async () => {
  assert.ok(NAS_DISCOVERY_QUERY.split(',').includes('SYNO.FileStation.MD5'));
  for (const jsonParameters of [false, true]) {
    const f = await connectorFixture(jsonParameters);
    const name = '/share/中文 & 文件.json';
    assert.equal(await f.connector.startFileChecksum(name), 'CHECKSUM_001');
    const start = f.requests.at(-1);
    const fields = new URLSearchParams(start.body);
    assert.equal(fields.get('api'), 'SYNO.FileStation.MD5');
    assert.equal(fields.get('version'), '2');
    assert.equal(fields.get('method'), 'start');
    assert.equal(fields.get('file_path'), jsonParameters ? JSON.stringify(name) : name);
    assert.equal(start.address, 'https://nas.example:5001/webapi/entry.cgi');
    assert.equal(start.session.sid, 'SYNTHETIC-SID');
    assert.equal(start.body.includes('SYNTHETIC-SID'), false);
    assert.equal(start.address.includes('SYNTHETIC-TOKEN'), false);

    f.setResponse({ success: true, data: { finished: false } });
    assert.deepEqual(await f.connector.fileChecksumStatus('CHECKSUM_001'), { finished: false, md5: '' });
    const status = new URLSearchParams(f.requests.at(-1).body);
    assert.equal(status.get('method'), 'status');
    assert.equal(status.get('taskid'), jsonParameters ? '"CHECKSUM_001"' : 'CHECKSUM_001');
    f.setResponse({ success: true, data: { finished: true, md5: 'ABCDEF0123456789ABCDEF0123456789' } });
    assert.deepEqual(await f.connector.fileChecksumStatus('CHECKSUM_001'), { finished: true, md5: 'abcdef0123456789abcdef0123456789' });
    f.setResponse({ success: true, data: {} });
    await f.connector.stopFileChecksum('CHECKSUM_001');
    assert.equal(new URLSearchParams(f.requests.at(-1).body).get('method'), 'stop');
  }
});

test('missing checksum capability, invalid IDs and malformed results never become content verification', async () => {
  const f = await connectorFixture(true, false);
  await assert.rejects(() => f.connector.startFileChecksum('/share/file'), { kind: protocol.NasErrorKind.Unsupported });
  assert.equal(f.requests.length, 1);
  for (const value of [{}, { taskid: '' }, { taskid: '../secret' }]) assert.throws(() => state.decodeTransferChecksumTask(value));
  for (const value of [{}, { finished: 'true', md5: '1'.repeat(32) }, { finished: true }, { finished: true, md5: 'invalid' },
    { finished: false, error: { code: 408 } }]) assert.throws(() => state.decodeTransferChecksumStatus(value));
  assert.throws(() => state.validateChecksumTaskId('id\nsecret'));
});

test('checksum permission denial remains an error and does not clear a valid session', async () => {
  const f = await connectorFixture(false);
  f.setResponse({ success: false, error: { code: 403 } });
  await assert.rejects(() => f.connector.fileChecksumStatus('CHECKSUM_001'), { kind: protocol.NasErrorKind.Permission });
  assert.ok(f.connector.sessionSnapshot());
});
