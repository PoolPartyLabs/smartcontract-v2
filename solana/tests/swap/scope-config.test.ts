import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PublicKey } from '@solana/web3.js';
import { policyBytes, policyDigest } from './production-client.ts';

test('Scope mode defaults OFF and changing it changes EVM creation consent', () => {
  const apiKey = new Uint8Array(32).fill(42);
  const disabled = policyBytes(apiKey);
  const enabled = policyBytes(apiKey, true);
  assert.deepEqual(disabled.subarray(-2), Buffer.from([0, 0]));
  assert.deepEqual(enabled.subarray(-2), Buffer.from([1, 1]));
  assert.equal(disabled.length, enabled.length);
  assert.deepEqual(disabled.subarray(0, -2), enabled.subarray(0, -2));
  const binding = Buffer.alloc(32, 2); const fund = new PublicKey(new Uint8Array(32).fill(3));
  assert.notDeepEqual(policyDigest(disabled, binding, fund, Buffer.alloc(20, 4)),
    policyDigest(enabled, binding, fund, Buffer.alloc(20, 4)));
});
