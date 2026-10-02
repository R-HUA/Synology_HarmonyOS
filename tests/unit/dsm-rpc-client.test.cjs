const { test } = require('node:test');
const assert = require('node:assert/strict');
const { DsmRpcClient } = require('../../work/core-build/network/DsmRpcClient.js');
const { selectVerifiedApi } = require('../../work/core-build/network/ApiVersionPolicy.js');
const { NasErrorKind } = require('../../work/core-build/domain/DsmProtocol.js');
const descriptor = { name: 'SYNO.FileStation.List', path: 'entry.cgi', minVersion: 1, maxVersion: 20, jsonParameters: true };

test('version choice uses only the intersection with client-verified versions', () => {
  assert.equal(selectVerifiedApi([descriptor], descriptor.name, [1, 2]).version, 2);
  assert.equal(selectVerifiedApi([{ ...descriptor, maxVersion: 1 }], descriptor.name, [2, 1]).version, 1);
  for (const versions of [[], [0, 1.5, NaN], [21]]) {
    assert.throws(() => selectVerifiedApi([descriptor], descriptor.name, versions), error => error.kind === NasErrorKind.Unsupported);
  }
});

test('RPC copies credentials to the transport channel and preserves exact parameter encoding', async () => {
  const calls = [];
  const reply = { status: 200, text: '{"success":true}' };
  const client = new DsmRpcClient({ post(...args) { calls.push(args); return Promise.resolve(reply); } });
  const session = { sid: 'private-sid', synoToken: 'private-token' };
  assert.equal(await client.request('https://NAS.example:5001', descriptor, 2, 'list', [
    { name: 'folder_path', content: JSON.stringify('/中文/&+report') },
  ], session), reply);
  const [address, body, authorization] = calls[0];
  assert.equal(address, 'https://nas.example:5001/webapi/entry.cgi');
  assert.equal(new URLSearchParams(body).get('folder_path'), JSON.stringify('/中文/&+report'));
  assert.deepEqual(authorization, session);
  assert.notEqual(authorization, session);
  assert.doesNotMatch(body + address, /private-sid|private-token/);
});

test('RPC rejects insecure destinations, unsupported versions and reserved parameter overrides before sending', () => {
  const client = new DsmRpcClient({ post() { assert.fail('must not send'); } });
  assert.throws(() => client.request('http://nas.example', descriptor, 2, 'list', []));
  assert.throws(() => client.request('https://nas.example', { ...descriptor, path: '../evil.cgi' }, 2, 'list', []));
  assert.throws(() => client.request('https://nas.example', descriptor, 21, 'list', []));
  for (const name of ['api', 'version', 'method', '_sid', 'SynoToken']) {
    assert.throws(() => client.request('https://nas.example', descriptor, 2, 'list', [{ name, content: 'override' }]));
  }
  assert.throws(() => client.request('https://nas.example', descriptor, 2, 'list', [
    { name: 'path', content: 'a' }, { name: 'path', content: 'b' },
  ]));
});

test('discovery remains a single unauthenticated POST and transport failure never replays a write', async () => {
  const calls = [];
  const failure = new Error('unreachable');
  const client = new DsmRpcClient({ post(...args) { calls.push(args); return Promise.reject(failure); } });
  await assert.rejects(client.discover('https://nas.example', 'SYNO.API.Auth'), error => error === failure);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], 'https://nas.example/webapi/query.cgi');
  assert.equal(calls[0][2], undefined);
  await assert.rejects(client.request('https://nas.example', descriptor, 2, 'create', []), error => error === failure);
  assert.equal(calls.length, 2);
});
