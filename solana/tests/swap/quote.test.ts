import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PublicKey } from '@solana/web3.js';
import { encodeQuote, quoteDigest, routeHash } from '../../clients/swap/quote.ts';

test('TypeScript quote digest and Borsh encoding match the Rust golden vector', () => {
  const bytes = readFileSync(new URL('./fixtures/v2/api-quote.bin', import.meta.url));
  const vector = JSON.parse(readFileSync(new URL('./fixtures/v2/api-quote-vector.json', import.meta.url), 'utf8'));
  const quote = {
    fund: new PublicKey(bytes.subarray(0, 32)), tokenIn: new PublicKey(bytes.subarray(32, 64)),
    tokenOut: new PublicKey(bytes.subarray(64, 96)), legsHash: bytes.subarray(96, 128),
    quotedAmountIn: bytes.readBigUInt64LE(128), minAmountOut: bytes.readBigUInt64LE(136),
    deadline: bytes.readBigUInt64LE(144), nonce: bytes.readBigUInt64LE(152), signature: bytes.subarray(160),
  };
  const domain = { chainId: BigInt(vector.domain.chainId),
    verifyingContract: Buffer.from(vector.domain.verifyingContract, 'hex'), program: new PublicKey(vector.domain.program) };
  assert.deepEqual(encodeQuote(quote), bytes);
  assert.equal(quoteDigest(quote, domain).toString('hex'), vector.digest);
  assert.notDeepEqual(quoteDigest({ ...quote, nonce: quote.nonce + 1n }, domain), quoteDigest(quote, domain));
});

test('route hash binds ordered accounts, writable privileges and route bytes', () => {
  const fixture = JSON.parse(readFileSync(new URL('./fixtures/v2/wsol.json', import.meta.url), 'utf8'));
  const instruction = fixture.build.swapInstruction;
  const vault = new PublicKey(fixture.vault);
  const expected = routeHash(instruction, vault);
  const reordered = structuredClone(instruction);
  [reordered.accounts[10], reordered.accounts[11]] = [reordered.accounts[11], reordered.accounts[10]];
  assert.notDeepEqual(routeHash(reordered, vault), expected);
  const writable = structuredClone(instruction);
  writable.accounts[10].isWritable = !writable.accounts[10].isWritable;
  assert.notDeepEqual(routeHash(writable, vault), expected);
  const data = Buffer.from(instruction.data, 'base64'); data[16] ^= 1;
  assert.notDeepEqual(routeHash({ ...instruction, data: data.toString('base64') }, vault), expected);
});
