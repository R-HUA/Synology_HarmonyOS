const { test } = require('node:test');
const assert = require('node:assert/strict');
const { TransferRates, transferRemainingSeconds } = require('../../work/core-build/domain/TransferRates.js');

test('rate uses elapsed progress and excludes paused time, rollback and previous accounts', () => {
  const rates = new TransferRates();
  assert.equal(rates.sample('a', 100, 'running', 0), undefined);
  assert.equal(rates.sample('a', 300, 'running', 1000), 200);
  assert.equal(transferRemainingSeconds(1000, 300, 200), 4);
  assert.equal(rates.sample('a', 300, 'paused', 2000), undefined);
  assert.equal(rates.sample('a', 300, 'running', 10000), undefined);
  assert.equal(rates.sample('a', 100, 'running', 11000), undefined);
  assert.equal(rates.sample('a', 500, 'running', 12000), 400);
  rates.clear();
  assert.equal(rates.sample('a', 500, 'running', 13000), undefined);
  assert.equal(transferRemainingSeconds(1000, 500, 0), undefined);
  assert.equal(transferRemainingSeconds(undefined, 500, 400), undefined);
  assert.equal(transferRemainingSeconds(1000, 1000, 400), undefined);
});
