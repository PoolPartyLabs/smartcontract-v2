import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TokenBucket, JupiterClient, RateLimitedError } from '../../clients/swap/jupiter.ts';
import { Q64, rangeWeights, solveRatio } from '../../clients/swap/ratio.ts';

function clock() {
  let now = 0;
  return { now: () => now, sleep: async (milliseconds: number) => { now += milliseconds; }, random: () => 0.5 };
}

const inventory = { balance0: 10000n, balance1: 0n, sqrtLowerX64: Q64 / 2n, sqrtPriceX64: Q64, sqrtUpperX64: Q64 * 2n };

test('CLMM weights balance equal raw units at symmetric range without float conversion', () => {
  const weights = rangeWeights(inventory);
  assert.equal(weights.weight0, weights.weight1);
  assert.throws(() => rangeWeights({ ...inventory, sqrtUpperX64: Q64 / 2n }));
  assert.throws(() => rangeWeights({ ...inventory, balance0: 1n << 64n }));
});

test('ratio solver handles both directions, fees, one-sided ranges, and no-op', async () => {
  assert.deepEqual(await solveRatio(inventory, async (_direction, amount) => amount),
    { zeroForOne: true, amount: 5000n, expectedOutput: 5000n });
  assert.deepEqual(await solveRatio({ ...inventory, balance0: 0n, balance1: 10000n }, async (_direction, amount) => amount),
    { zeroForOne: false, amount: 5000n, expectedOutput: 5000n });
  const fee = await solveRatio(inventory, async (_direction, amount) => amount * 99n / 100n, 12);
  assert.ok(fee && fee.amount > 5000n && fee.amount < 5050n);
  assert.equal(await solveRatio({ ...inventory, balance1: 10000n }, async () => { throw new Error('No quote expected'); }), null);
  assert.equal((await solveRatio({ ...inventory, sqrtPriceX64: Q64 * 3n }, async (_direction, amount) => amount))?.amount, 10000n);
  assert.equal((await solveRatio({ ...inventory, balance0: 0n, balance1: 10000n, sqrtPriceX64: Q64 / 3n }, async (_direction, amount) => amount))?.amount, 10000n);
  await assert.rejects(solveRatio(inventory, async () => 0n), /Invalid quote/);
});

test('capacity-one token bucket serializes concurrent calls and honors cooldown', async () => {
  const time = clock();
  const bucket = new TokenBucket(2100, time);
  const timestamps: number[] = [];
  await Promise.all(Array.from({ length: 5 }, async () => { await bucket.take(); timestamps.push(time.now()); }));
  assert.deepEqual(timestamps, [0, 2100, 4200, 6300, 8400]);
  bucket.block(10000);
  await bucket.take();
  assert.equal(time.now(), 18400);
  assert.throws(() => new TokenBucket(999), /must not exceed/);
});

const mint0 = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
const mint1 = 'So11111111111111111111111111111111111111112';

test('quote cache is short lived, defensive, and venue constrained', async () => {
  const time = clock();
  let calls = 0;
  const transport = async (url: string | URL | Request) => {
    calls++;
    const params = new URL(String(url)).searchParams;
    assert.equal(params.get('dexes'), 'Raydium CLMM');
    assert.equal(params.get('maxAccounts'), '32');
    assert.equal(params.get('onlyDirectRoutes'), 'true');
    return new Response(JSON.stringify({ inputMint: mint0, outputMint: mint1, inAmount: '100', outAmount: '200',
      otherAmountThreshold: '198', slippageBps: 100, swapMode: 'ExactIn', routePlan: [{ swapInfo: { label: 'Raydium CLMM', ammKey: 'pool' } }] }));
  };
  const client = new JupiterClient(undefined, transport as typeof fetch, time);
  const quote = await client.quote(mint0, mint1, 100n, 100);
  quote.outAmount = '1';
  assert.equal((await client.quote(mint0, mint1, 100n, 100)).outAmount, '200');
  assert.equal(calls, 1);
  await time.sleep(2501);
  await client.quote(mint0, mint1, 100n, 100);
  assert.equal(calls, 2);
});

test('429 exponential jitter retries are bounded and yield retry-in error', async () => {
  const time = clock();
  let calls = 0;
  const client = new JupiterClient(undefined, (async () => { calls++; return new Response('', { status: 429 }); }) as typeof fetch, time);
  await assert.rejects(client.quote(mint0, mint1, 100n, 100), (error: unknown) => error instanceof RateLimitedError && error.retryInSeconds === 9);
  assert.equal(calls, 3);
  assert.equal(time.now(), 6800);
});

test('long server reset exits promptly rather than sleeping in request loop', async () => {
  const time = clock();
  let calls = 0;
  const client = new JupiterClient('not-a-real-key', (async () => {
    calls++;
    return new Response('', { status: 429, headers: { 'x-ratelimit-reset': '60' } });
  }) as typeof fetch, time);
  await assert.rejects(client.quote(mint0, mint1, 100n, 100), /retry in 61s/);
  assert.equal(calls, 1);
  assert.equal(time.now(), 0);
});
