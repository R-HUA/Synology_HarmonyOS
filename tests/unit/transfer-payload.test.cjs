const { test } = require('node:test');
const assert = require('node:assert/strict');
const { transferChunk, matchesTransferChunk, TRANSFER_CHUNK_BYTES } = require('../../work/core-build/domain/TransferPayload.js');

test('file generation bounds allocations even beyond four GiB and preserves absolute byte offsets', () => {
  const seed = new TextEncoder().encode('随机内容 &+');
  const total = 5 * 1024 ** 3 + 7;
  for (const offset of [0, TRANSFER_CHUNK_BYTES, 4 * 1024 ** 3 + 3, total - 7, total]) {
    const chunk = transferChunk(seed, total, offset);
    assert.equal(chunk.length, Math.min(TRANSFER_CHUNK_BYTES, total - offset));
    assert.equal(matchesTransferChunk(seed, offset, chunk), true);
    if (chunk.length) assert.equal(chunk[0], seed[offset % seed.length]);
  }
});

test('content verification rejects changed bytes and handles partial reads and final chunks', () => {
  const seed = new TextEncoder().encode('nonce-unique\n');
  const offset = TRANSFER_CHUNK_BYTES + 1;
  const bytes = transferChunk(seed, offset + 53, offset);
  assert.equal(matchesTransferChunk(seed, offset, bytes.subarray(0, 7)), true);
  assert.equal(matchesTransferChunk(seed, offset + 7, bytes.subarray(7)), true);
  bytes[10] ^= 1;
  assert.equal(matchesTransferChunk(seed, offset, bytes), false);
});

test('invalid file sizes and offsets fail before allocating buffers', () => {
  const seed = new Uint8Array([1]);
  for (const args of [[seed, -1, 0], [seed, 2, 3], [seed, 2, 0.5], [seed, Infinity, 0], [new Uint8Array(), 2, 0]]) {
    assert.throws(() => transferChunk(...args));
  }
});
