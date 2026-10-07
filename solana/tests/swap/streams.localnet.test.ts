import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PublicKey, TransactionInstruction, TransactionMessage, VersionedTransaction, ComputeBudgetProgram } from '@solana/web3.js';
import { secp256k1 } from '@noble/curves/secp256k1';
import { keccak_256 } from '@noble/hashes/sha3';
import { localConnection, testWallet, requireLoopback } from '../helpers/localnet.ts';

const connection = localConnection();
const manager = testWallet();
const fixture = JSON.parse(readFileSync(new URL('../../.localnet/verifier-fixture.json', import.meta.url), 'utf8'));
const word = (value: bigint) => { const data = Buffer.alloc(32); let remaining = value;
  for (let index = 31; index >= 0; index--) { data[index] = Number(remaining & 255n); remaining >>= 8n; } return data; };
const hash = (bytes: Buffer) => Buffer.from(keccak_256(bytes));

function snappyLiteral(bytes: Buffer): Buffer {
  const length: number[] = []; let remaining = bytes.length;
  while (remaining >= 128) { length.push((remaining & 127) | 128); remaining >>= 7; } length.push(remaining);
  const encodedLength = bytes.length - 1;
  return Buffer.concat([Buffer.from(length), Buffer.from([61 << 2, encodedLength & 255, encodedLength >> 8]), bytes]);
}

async function build(negative?: string) {
  const slot = await connection.getSlot(); const timestamp = BigInt((await connection.getBlockTime(slot)) ?? Math.floor(Date.now() / 1000));
  const feed = Buffer.alloc(32); feed[1] = 10;
  const report = Buffer.concat([feed, word(timestamp - 1n), word(timestamp), word(0n), word(0n), word(timestamp + 120n),
    word((negative === 'stale' ? timestamp - 200n : timestamp - 1n) * 1_000_000_000n), word(120n * 10n ** 18n),
    word(negative === 'closed' ? 1n : 2n), word(10n ** 18n), word(0n), word(0n), word(120n * 10n ** 18n)]);
  const context = Buffer.concat([Buffer.from(fixture.configDigest, 'hex'), Buffer.alloc(64)]);
  const digest = hash(Buffer.concat([hash(report), context]));
  const signatures = [42, negative === 'forged' ? 44 : 43].map(value => secp256k1.sign(digest, Buffer.alloc(32, value)));
  const rawVs = Buffer.alloc(32); signatures.forEach((signature, index) => rawVs[index] = signature.recovery);
  const reportPart = Buffer.concat([word(BigInt(report.length)), report]);
  const rs = Buffer.concat([word(2n), ...signatures.map(signature => Buffer.from(signature.toCompactRawBytes()).subarray(0, 32))]);
  const ss = Buffer.concat([word(2n), ...signatures.map(signature => Buffer.from(signature.toCompactRawBytes()).subarray(32))]);
  const signed = Buffer.concat([context, word(224n), word(BigInt(224 + reportPart.length)), word(BigInt(224 + reportPart.length + rs.length)), rawVs, reportPart, rs, ss]);
  const instruction = new TransactionInstruction({ programId: new PublicKey(Buffer.alloc(32, 77)),
    data: Buffer.concat([Buffer.from([2]), snappyLiteral(signed)]), keys: [
      { pubkey: new PublicKey(fixture.verifier), isSigner: false, isWritable: false },
      { pubkey: new PublicKey(fixture.state), isSigner: false, isWritable: false },
      { pubkey: new PublicKey(fixture.controller), isSigner: false, isWritable: false },
      { pubkey: manager.publicKey, isSigner: true, isWritable: false },
      { pubkey: new PublicKey(fixture.config), isSigner: false, isWritable: false },
    ] });
  const blockhash = await connection.getLatestBlockhash();
  const transaction = new VersionedTransaction(new TransactionMessage({ payerKey: manager.publicKey, recentBlockhash: blockhash.blockhash,
    instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }), instruction] }).compileToV0Message());
  transaction.sign([manager]); return transaction;
}

for (const negative of [undefined, 'forged', 'closed', 'stale']) {
  test(`cloned Streams verifier CPI ${negative ?? 'accepts local DON-signed v10'}`, async () => {
    requireLoopback(connection.rpcEndpoint);
    const transaction = await build(negative);
    const simulation = await connection.simulateTransaction(transaction);
    if (!negative) {
      assert.equal(simulation.value.err, null, JSON.stringify(simulation.value.logs));
      assert.ok(simulation.value.logs?.some(log => log.includes('STOCK PROBE:')));
    } else {
      assert.ok(simulation.value.err, JSON.stringify(simulation.value));
      const expected = { forged: 'BadVerification', closed: 'MarketClosed', stale: 'Stale' }[negative];
      assert.ok(simulation.value.logs?.some(log => log.includes(`Error Code: ${expected}.`)), JSON.stringify(simulation.value.logs));
    }
    console.log(`Streams ${negative ?? 'happy'}: CU=${simulation.value.unitsConsumed}, bytes=${transaction.serialize().length}`);
  });
}
