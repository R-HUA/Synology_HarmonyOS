// 复用应用核心协议；凭证从标准输入读取，结果仅保存白名单诊断字段。
const { spawn } = require('node:child_process');
const { writeFileSync, mkdirSync } = require('node:fs');
const { resolve, dirname } = require('node:path');
const { NasConnector } = require('../work/core-build/network/NasConnector.js');
const { DsmRpcClient } = require('../work/core-build/network/DsmRpcClient.js');
const { NasFailure, NasErrorKind, decodeNasResponse } = require('../work/core-build/domain/DsmProtocol.js');

class CurlNasTransport {
  active = new Set();
  post(address, body, authorization) {
    return new Promise((resolveReply, reject) => {
      const child = spawn('curl.exe', ['--silent', '--show-error', '--connect-timeout', '10', '--max-time', '20',
        '--request', 'POST', '--header', 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8',
        '--header', 'Accept: application/json', '--header', 'Cache-Control: no-store',
        '--config', '-', '--write-out', '\nNAS_STATUS:%{http_code}', address], { windowsHide: true });
      this.active.add(child);
      let result = '';
      let overflow = false;
      child.stdout.setEncoding('utf8');
      child.stdout.on('data', chunk => {
        result += chunk;
        if (result.length > 1024 * 1024) { overflow = true; child.kill(); }
      });
      // 不将原始 stderr/响应写入日志；curl 退出码足够定位 TLS 与连通故障。
      child.stderr.resume();
      child.stdin.on('error', () => {}); // 进程提前退出后的 EPIPE 由 close 的退出码处理。
      child.on('error', () => {
        this.active.delete(child);
        reject(new NasFailure(NasErrorKind.Network, '无法启动 curl.exe。'));
      });
      child.on('close', code => {
        this.active.delete(child);
        if (overflow) { reject(new NasFailure(NasErrorKind.Protocol, '诊断响应超过允许大小。')); return; }
        if (code !== 0) {
          reject(new NasFailure(code === 60 ? NasErrorKind.Tls : NasErrorKind.Network, 'HTTPS 请求失败。', code ?? -1));
          return;
        }
        const marker = result.lastIndexOf('\nNAS_STATUS:');
        if (marker < 0) { reject(new NasFailure(NasErrorKind.Protocol, '没有收到 HTTP 状态。')); return; }
        resolveReply({ status: Number(result.slice(marker + 12)), text: result.slice(0, marker) });
      });
      const configValue = value => '"' + value.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
      let config = 'data-binary = ' + configValue(body) + '\n';
      if (authorization !== undefined) {
        config += 'header = ' + configValue('Cookie: id=' + authorization.sid) + '\n';
        if (authorization.synoToken) config += 'header = ' + configValue('X-SYNO-TOKEN: ' + authorization.synoToken) + '\n';
      }
      child.stdin.end(config);
    });
  }
  close() { for (const child of this.active) child.kill(); this.active.clear(); }
}

async function main() {
  const address = process.argv[2];
  if (!address) throw new Error('请通过 probe-nas.ps1 提供 HTTPS 地址。');
  let accountInput;
  if (process.argv.includes('--login')) {
    let input = '';
    for await (const chunk of process.stdin) {
      input += chunk;
      if (input.length > 16384) throw new Error('凭证输入过长。');
    }
    accountInput = JSON.parse(input);
  }
  const transport = new CurlNasTransport();
  const connector = new NasConnector(transport);
  const report = { observedAt: new Date().toISOString(), tlsVerified: false,
    discoveryPassed: false, authentication: 'not-tested', tokenValidation: 'not-tested',
    shares: 'not-tested', logout: 'not-tested', capabilities: [] };
  try {
    report.capabilities = await connector.discover(address);
    report.tlsVerified = /^https:\/\//i.test(address);
    report.discoveryPassed = true;
    if (accountInput) {
      try {
        await connector.login(accountInput.account, accountInput.password, accountInput.otp ?? '');
      } finally { accountInput.password = ''; accountInput.otp = ''; }
      report.authentication = 'passed';
      await connector.validateSession();
      const auth = report.capabilities.find(api => api.name === 'SYNO.API.Auth');
      const rpc = new DsmRpcClient(transport);
      const proofs = [];
      for (const credentials of [undefined, { sid: 'invalid-unified-session-probe', synoToken: '' }]) {
        const reply = await rpc.request(address, auth, 6, 'token', [], credentials);
        let rejected = false;
        try { decodeNasResponse(auth.name, reply.status, reply.text); }
        catch (error) {
          if (!(error instanceof NasFailure) || error.kind !== NasErrorKind.SessionExpired) throw error;
          rejected = true;
        }
        proofs.push(rejected);
      }
      report.tokenValidation = { validSessionAccepted: true, anonymousRejected: proofs[0], invalidSessionRejected: proofs[1] };
      if (!proofs.every(Boolean)) throw new NasFailure(NasErrorKind.Protocol, '认证接口不能区分无效会话，登录恢复验收未通过。');
      try {
        const page = await connector.list('');
        report.shares = { state: 'passed', returned: page.entries.length, total: page.total };
      } catch (error) {
        if (!(error instanceof NasFailure) || ![NasErrorKind.Permission, NasErrorKind.Unsupported].includes(error.kind)) throw error;
        report.shares = { state: 'unavailable', kind: NasErrorKind[error.kind], code: error.code };
      }
      await connector.logout();
      report.logout = 'passed';
    }
  } catch (error) {
    // 保存错误类别与数值，不保存原始请求、账号、文件路径和响应。
    report.failure = error instanceof NasFailure ? { kind: NasErrorKind[error.kind], code: error.code } : { kind: 'Unexpected' };
    process.exitCode = 1;
  } finally {
    if (report.authentication === 'passed' && report.logout !== 'passed') {
      try { await connector.logout(); report.logout = 'passed'; }
      catch { report.logout = 'not-confirmed'; }
    }
    connector.close();
    const output = resolve(__dirname, '../work/diagnostics/latest-probe.json');
    mkdirSync(dirname(output), { recursive: true });
    writeFileSync(output, JSON.stringify(report, null, 2) + '\n', 'utf8');
    console.log(JSON.stringify(report, null, 2));
    console.log('诊断结果：' + output);
  }
}

main().catch(() => { console.error('诊断未启动，请检查地址、运行环境与标准输入。'); process.exitCode = 1; });
