const { test } = require('node:test');
const assert = require('node:assert/strict');
const { NasConnector } = require('../../work/core-build/network/NasConnector.js');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');
const { NasControlRejection } = require('../../work/core-build/domain/SystemControl.js');
const origin = 'https://synthetic-nas.example.test:5001';
const session = { sid: 'synthetic-independent-sid', synoToken: 'synthetic-token' };
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });

function fixture(category = 'NasControl') {
  const calls = [];
  const state = { reply: ok(undefined), error: undefined, gate: undefined };
  const transport = {
    async post(url, body, credentials) {
      const fields = Object.fromEntries(new URLSearchParams(body));
      calls.push({ url, fields, credentials });
      if (fields.api === 'SYNO.API.Info') return ok({
        'SYNO.API.Auth': { path: 'auth.cgi', minVersion: 6, maxVersion: 6 },
        'SYNO.FileStation.List': { path: 'entry.cgi', minVersion: 2, maxVersion: 2 },
        'SYNO.Core.System': { path: 'core/system.cgi', minVersion: 1, maxVersion: 1 },
      });
      if (fields.api === 'SYNO.API.Auth') return fields.method === 'login' ? ok({ sid: session.sid, synotoken: session.synoToken }) : fields.method === 'token' ? state.reply : ok(undefined);
      if (state.gate) await state.gate;
      if (state.error) throw state.error;
      return state.reply;
    },
    close() {},
  };
  const connector = new NasConnector(transport);
  return { connector, calls, state };
}

test('control shares the primary login and keeps credentials out of the control form and URL', async () => {
  const { connector, calls } = fixture();
  await connector.discover(origin);
  await connector.login('admin', 'synthetic-password', '123456');
  await connector.systemControl('reboot');
  await connector.logout();
  assert.equal(calls[1].fields.session, undefined);
  assert.equal(calls[3].fields.session, undefined);
  assert.equal(calls[2].url, origin + '/webapi/core/system.cgi');
  assert.deepEqual(calls[2].fields, { api: 'SYNO.Core.System', version: '1', method: 'reboot' });
  assert.deepEqual(calls[2].credentials, session);
  assert.equal(calls[2].url.includes('sid'), false);
  assert.equal(calls[2].url.includes('passwd'), false);
  assert.equal(calls[2].url.includes('?'), false);
});

test('the current primary login executes control without another login request', async () => {
  const { connector, calls } = fixture('FileStation');
  await connector.discover(origin);
  await connector.login('alice', 'synthetic-password', '');
  assert.equal(calls[1].fields.session, undefined);
  await connector.systemControl('reboot');
  assert.equal(calls.length, 3);
  await connector.logout();
  assert.equal(calls[3].fields.session, undefined);
});

test('only shutdown sends local=true; no session or unsafe extra business fields are added', async () => {
  const { connector, calls } = fixture();
  await connector.discover(origin);
  connector.restoreSession({ sid: session.sid, synoToken: session.synoToken });
  await connector.systemControl('shutdown');
  assert.deepEqual(calls[1].fields, { api: 'SYNO.Core.System', version: '1', method: 'shutdown', local: 'true' });
});

test('unknown actions and missing login cannot issue a control request', async () => {
  const { connector, calls } = fixture();
  await connector.discover(origin);
  await assert.rejects(connector.systemControl('reboot'), error => error.kind === K.SessionExpired);
  connector.restoreSession({ sid: session.sid, synoToken: session.synoToken });
  for (const action of ['restart', 'upgrade', 'Reboot', '', undefined]) {
    await assert.rejects(connector.systemControl(action), error => error.kind === K.InvalidInput);
  }
  assert.equal(calls.length, 1);
});

test('a valid DSM rejection is distinguished from HTTP errors, malformed envelopes and transport uncertainty', async () => {
  for (const scenario of [
    { reply: { status: 200, text: JSON.stringify({ success: false, error: { code: 105 } }) }, rejected: true },
    { reply: { status: 503, text: '{}' }, rejected: false },
    { reply: { status: 302, text: '{}' }, rejected: false },
    { reply: { status: 200, text: '<html>offline</html>' }, rejected: false },
    { reply: { status: 200, text: JSON.stringify({ success: false, error: { code: '105' } }) }, rejected: false },
    { error: new NasFailure(K.Network, 'synthetic-timeout'), rejected: false },
  ]) {
    const { connector, calls, state } = fixture();
    await connector.discover(origin);
    connector.restoreSession({ sid: session.sid, synoToken: session.synoToken });
    Object.assign(state, scenario);
    await assert.rejects(connector.systemControl('reboot'), error => (error instanceof NasControlRejection) === scenario.rejected);
    assert.equal(calls.filter(call => call.fields.method === 'reboot').length, 1);
  }
});

test('closing a control connection during dispatch leaves cancellation uncertain rather than fabricating a rejection', async () => {
  const { connector, calls, state } = fixture();
  await connector.discover(origin);
  connector.restoreSession({ sid: session.sid, synoToken: session.synoToken });
  let release;
  state.gate = new Promise(resolve => { release = resolve; });
  const pending = connector.systemControl('reboot');
  connector.close();
  release();
  await assert.rejects(pending, error => error.kind === K.Cancelled && !(error instanceof NasControlRejection));
  assert.equal(calls.filter(call => call.fields.method === 'reboot').length, 1);
});

test('a confirmed control session expiry removes only its authorization and blocks later control dispatch', async () => {
  const { connector, calls, state } = fixture();
  await connector.discover(origin);
  connector.restoreSession({ sid: session.sid, synoToken: session.synoToken });
  state.reply = { status: 200, text: JSON.stringify({ success: false, error: { code: 119 } }) };
  await assert.rejects(connector.systemControl('reboot'), error => error instanceof NasControlRejection && error.kind === K.SessionExpired);
  assert.equal(connector.sessionSnapshot(), undefined);
  const count = calls.length;
  await assert.rejects(connector.systemControl('reboot'), error => error.kind === K.SessionExpired && !(error instanceof NasControlRejection));
  assert.equal(calls.length, count);
});
