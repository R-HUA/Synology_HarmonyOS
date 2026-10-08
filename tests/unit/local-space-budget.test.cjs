const { test } = require('node:test');
const assert = require('node:assert/strict');
const protocol = require('../../work/core-build/domain/DsmProtocol.js');
const load = require('../helpers/load-space-budget.cjs');
const MiB = 1024 ** 2;

test('concurrent modules cannot reserve the same free space and written bytes are counted once', async () => {
  let free = 100 * MiB;
  const { localSpaceBudget: budget } = load(protocol, async () => free);
  const results = await Promise.allSettled([budget.reserve('/private', 'photo', 40 * MiB), budget.reserve('/private', 'drive', 40 * MiB)]);
  assert.equal(results[0].status, 'fulfilled'); assert.equal(results[1].status, 'rejected');
  free -= 20 * MiB; budget.advance('photo', 20 * MiB);
  await budget.reserve('/private', 'drive', 28 * MiB);
  await assert.rejects(budget.reserve('/private', 'another', 1), /空间不足/);
  budget.release('photo'); budget.release('drive');
  await budget.reserve('/private', 'another', 48 * MiB);
});

test('failed free-space checks do not consume a reservation or prevent later recovery', async () => {
  let failed = true;
  const { localSpaceBudget: budget } = load(protocol, async () => { if (failed) throw new Error('statfs denied'); return 64 * MiB; });
  await assert.rejects(budget.reserve('/private', 'copy', MiB), /statfs denied/);
  failed = false;
  await budget.reserve('/private', 'copy', 32 * MiB);
  budget.release('copy');
  await budget.reserve('/private', 'recovered', 32 * MiB);
});
