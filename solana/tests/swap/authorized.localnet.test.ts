import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { AddressLookupTableAccount, PublicKey, TransactionInstruction, TransactionMessage, VersionedTransaction, ComputeBudgetProgram } from '@solana/web3.js';
import { secp256k1 } from '@noble/curves/secp256k1';
import { localConnection, testWallet, requireLoopback } from '../helpers/localnet.ts';
import { encodeQuote, quoteDigest, routeHash } from '../../clients/swap/quote.ts';
import type { ApiInstruction } from '../../clients/swap/jupiter.ts';

const connection = localConnection();
const manager = testWallet();
const oracleKeys = ['7AviUf9nL62mcxNbQGKm4nKDQnPjswo6c5MX4D57HmyE', '6HAuqASbHEh4w4REJEUUUCginTLfj1kwCh215ZLtMkrT', 'CH31Xns5z3M1cTAbKW34jcxPPciazARpijcHj9rxtemt'].map(key => new PublicKey(key));
const snapshot = (key: PublicKey) => JSON.parse(readFileSync(new URL(`../../.localnet/accounts/${key.toBase58()}.json`, import.meta.url), 'utf8'));
const sol = Buffer.from(snapshot(oracleKeys[0]).account.data[0], 'base64');
const now = sol.readBigInt64LE(93);

async function build(negative?: string) {
  const fixture = JSON.parse(readFileSync(new URL('./fixtures/v2/wsol.json', import.meta.url), 'utf8'));
  const swap: ApiInstruction = fixture.build.swapInstruction;
  const program = new PublicKey(fixture.probe);
  const fund = new PublicKey(fixture.fund);
  const route = Buffer.from(swap.data, 'base64');
  if (negative === 'impact') {
    route.writeBigUInt64LE(route.readBigUInt64LE(16) * 9n / 10n, 16);
    swap.data = route.toString('base64');
  }
  const quote = { fund, tokenIn: new PublicKey(fixture.build.inputMint), tokenOut: new PublicKey(fixture.build.outputMint),
    legsHash: routeHash(swap, new PublicKey(fixture.vault)), quotedAmountIn: BigInt(fixture.build.inAmount),
    minAmountOut: (route.readBigUInt64LE(16) * 9800n + 9999n) / 10000n,
    deadline: negative === 'expired' ? now - 1n : now + 500n, nonce: 0n, signature: Buffer.alloc(65) };
  if (negative === 'stock') quote.tokenOut = new PublicKey('XsDoVfqeBukxuZHWhdvWHBhgEHjGNst4MLodqsJHzoB');
  const signature = secp256k1.sign(quoteDigest(quote, { chainId: 42161n, verifyingContract: Buffer.alloc(20, 5), program }), Buffer.alloc(32, negative === 'forged' ? 43 : 42));
  quote.signature = Buffer.concat([Buffer.from(signature.toCompactRawBytes()), Buffer.from([signature.recovery + 27])]);
  const trailer = Buffer.alloc(6); trailer.writeUInt16LE(negative === 'impact' ? 1 : 500); trailer.writeUInt32LE(route.length, 2);
  const time = Buffer.alloc(8); time.writeBigInt64LE(negative === 'stale' ? now + 1000n : now);
  if (negative === 'stale') {
    quote.deadline = now + 2000n;
    const freshSignature = secp256k1.sign(quoteDigest(quote, { chainId: 42161n, verifyingContract: Buffer.alloc(20, 5), program }), Buffer.alloc(32, 42));
    quote.signature = Buffer.concat([Buffer.from(freshSignature.toCompactRawBytes()), Buffer.from([freshSignature.recovery + 27])]);
  }
  const instruction = new TransactionInstruction({ programId: program, data: Buffer.concat([Buffer.from([1]), time, encodeQuote(quote), trailer, route, Buffer.from([0])]), keys: [
    { pubkey: manager.publicKey, isSigner: true, isWritable: false }, { pubkey: fund, isSigner: false, isWritable: true },
    { pubkey: new PublicKey(fixture.vault), isSigner: false, isWritable: false }, { pubkey: new PublicKey(swap.programId), isSigner: false, isWritable: false },
    ...oracleKeys.map(pubkey => ({ pubkey, isSigner: false, isWritable: false })),
    ...swap.accounts.map(account => ({ pubkey: new PublicKey(account.pubkey), isSigner: false, isWritable: account.isWritable })),
  ] });
  const lookups = await Promise.all((fixture.build.addressLookupTableAddresses as string[]).map(async address => (await connection.getAddressLookupTable(new PublicKey(address))).value));
  const blockhash = await connection.getLatestBlockhash();
  const transaction = new VersionedTransaction(new TransactionMessage({ payerKey: manager.publicKey, recentBlockhash: blockhash.blockhash,
    instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }), instruction] }).compileToV0Message(lookups.filter(Boolean) as AddressLookupTableAccount[]));
  transaction.sign([manager]);
  return { transaction, blockhash, fund };
}

for (const negative of ['forged', 'expired', 'stale', 'stock', 'impact']) {
  test(`authorized swap rejects ${negative} before CPI and nonce mutation`, async () => {
    requireLoopback(connection.rpcEndpoint);
    const { transaction, fund } = await build(negative);
    const before = (await connection.getAccountInfo(fund))!.data;
    const simulation = await connection.simulateTransaction(transaction);
    const expected = { forged: 'InvalidSignature', expired: 'Expired', stale: 'Stale', stock: 'StockDisabled', impact: 'Impact' }[negative];
    assert.ok(simulation.value.err, JSON.stringify(simulation.value));
    assert.ok(simulation.value.logs?.some(log => log.includes(`Error Code: ${expected}.`)), JSON.stringify(simulation.value.logs));
    assert.ok(!simulation.value.logs?.some(log => log.includes('Instruction: RouteV2')));
    assert.deepEqual((await connection.getAccountInfo(fund))!.data, before);
    console.log(`${negative}: rejected ${expected}, CU=${simulation.value.unitsConsumed}`);
  });
}

test('API-signed SOL swap executes and replay fails atomically', async () => {
  const { transaction, fund, blockhash } = await build();
  const simulation = await connection.simulateTransaction(transaction);
  assert.equal(simulation.value.err, null, JSON.stringify(simulation.value.logs));
  assert.ok(transaction.serialize().length <= 1232);
  const signature = await connection.sendRawTransaction(transaction.serialize());
  assert.equal((await connection.confirmTransaction({ signature, ...blockhash }, 'confirmed')).value.err, null);
  assert.equal((await connection.getAccountInfo(fund))!.data.readBigUInt64LE(), 1n);
  const replay = await build();
  const rejected = await connection.simulateTransaction(replay.transaction);
  assert.ok(rejected.value.logs?.some(log => log.includes('Error Code: Replay.')), JSON.stringify(rejected.value));
  console.log(`signed SOL: CU=${simulation.value.unitsConsumed}, bytes=${transaction.serialize().length}; replay rejected`);
});
