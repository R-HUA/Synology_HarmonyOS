const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const protocol = require('../../work/core-build/domain/DsmProtocol.js');
const load = require('../helpers/load-sdk-digest.cjs');

test('missing crypto capability rejects before constructing an SDK digest', async () => {
  let created = false;
  const { sha256, SdkDigest } = load({ createMd() { created = true; } }, protocol, name => {
    assert.equal(name, 'SystemCapability.Security.CryptoFramework'); return false;
  });
  await assert.rejects(sha256(new Uint8Array()), error => error.kind === protocol.NasErrorKind.Unsupported);
  assert.throws(() => new SdkDigest('MD5'), error => error.kind === protocol.NasErrorKind.Unsupported);
  assert.equal(created, false);
});

test('digest boundary preserves SHA256 identity bytes and streaming MD5 content hashes', async () => {
  const { sha256, SdkDigest } = load({ createMd(algorithm) {
    const hash = crypto.createHash(algorithm.toLowerCase());
    return { async update({ data }) { hash.update(data); }, async digest() { return { data: new Uint8Array(hash.digest()) }; } };
  } }, protocol);
  for (const text of ['', '["https://nas.example"," alice "]', '["群晖","synthetic-serial"]']) {
    const bytes = new TextEncoder().encode(text);
    assert.equal(await sha256(bytes), crypto.createHash('sha256').update(bytes).digest('hex'));
  }
  const bytes = new TextEncoder().encode('跨块中文😀');
  const digest = new SdkDigest('MD5');
  for (const byte of bytes) await digest.update(new Uint8Array([byte]));
  assert.equal(await digest.finish(), crypto.createHash('md5').update(bytes).digest('hex'));
});

test('SDK synchronous and asynchronous failures retain error codes without leaking input', async () => {
  for (const stage of ['create', 'update-sync', 'update-async', 'digest-sync', 'digest-async']) {
    const failure = Object.assign(new Error('secret account or serial'), { code: 17630001 });
    const { sha256 } = load({ createMd() {
      if (stage === 'create') throw failure;
      return {
        update() {
          if (stage === 'update-sync') throw failure;
          return stage === 'update-async' ? Promise.reject(failure) : Promise.resolve();
        },
        digest() {
          if (stage === 'digest-sync') throw failure;
          return Promise.reject(failure);
        },
      };
    } }, protocol);
    await assert.rejects(sha256(new Uint8Array([65])), error =>
      error.kind === protocol.NasErrorKind.Protocol && error.code === 17630001 && !/secret/.test(error.message));
  }
});

test('truncated and oversized digest results cannot become storage scopes or content verification', async () => {
  for (const algorithm of ['SHA256', 'MD5']) {
    for (const length of [0, 1, 15, 17, 31, 33]) {
      const { SdkDigest } = load({ createMd() {
        return { async update() {}, async digest() { return { data: new Uint8Array(length) }; } };
      } }, protocol);
      const digest = new SdkDigest(algorithm);
      await assert.rejects(digest.finish(), error => error.kind === protocol.NasErrorKind.Protocol);
    }
  }
});
