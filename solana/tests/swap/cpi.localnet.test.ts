import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PublicKey, TransactionInstruction, TransactionMessage, VersionedTransaction, ComputeBudgetProgram } from '@solana/web3.js';
import { localConnection, testWallet, requireLoopback } from '../helpers/localnet.ts';

const connection = localConnection();
const manager = testWallet();

function fixture(pair: string) {
  return JSON.parse(readFileSync(new URL(`./fixtures/${pair}.json`, import.meta.url), 'utf8'));
}

async function build(pair: string, negative?: string) {
  const route = fixture(pair);
  const swap = structuredClone(route.instructions.swapInstruction);
  const data = Buffer.from(swap.data, 'base64');
  const payload = Buffer.alloc(86 + data.length);
  new PublicKey(route.quote.inputMint).toBuffer().copy(payload, 0);
  new PublicKey(negative === 'mint' ? route.probe : route.quote.outputMint).toBuffer().copy(payload, 32);
  payload.writeBigUInt64LE(BigInt(route.quote.inAmount), 64);
  const minimum = negative === 'min_out' ? (1n << 64n) - 1n
    : (BigInt(route.quote.outAmount) * 9800n + 9999n) / 10000n;
  payload.writeBigUInt64LE(minimum, 72);
  payload.writeUInt16LE(200, 80);
  payload.writeUInt32LE(data.length, 82);
  data.copy(payload, 86);
  if (negative === 'output') swap.accounts[3].pubkey = swap.accounts[2].pubkey;
  if (negative === 'extra_vault') swap.accounts[15].pubkey = fixture('tslax').instructions.swapInstruction.accounts[3].pubkey;
  const instruction = new TransactionInstruction({ programId: new PublicKey(route.probe), data: payload, keys: [
    { pubkey: manager.publicKey, isSigner: negative !== 'unauthorized', isWritable: false },
    { pubkey: new PublicKey(route.fund), isSigner: false, isWritable: false },
    { pubkey: new PublicKey(route.vault), isSigner: false, isWritable: false },
    { pubkey: new PublicKey(swap.programId), isSigner: false, isWritable: false },
    ...swap.accounts.map(account => ({ pubkey: new PublicKey(account.pubkey), isSigner: false, isWritable: account.isWritable })),
  ] });
  const lookups = await Promise.all(route.instructions.addressLookupTableAddresses.map(async address => {
    const lookup = (await connection.getAddressLookupTable(new PublicKey(address))).value;
    if (!lookup) throw new Error('Cloned route ALT missing');
    return lookup;
  }));
  const blockhash = await connection.getLatestBlockhash();
  const payer = negative === 'unauthorized' ? testWallet('keeper') : manager;
  const transaction = new VersionedTransaction(new TransactionMessage({ payerKey: payer.publicKey,
    recentBlockhash: blockhash.blockhash, instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }), instruction],
  }).compileToV0Message(lookups));
  transaction.sign([payer]);
  return { transaction, blockhash, route, bytes: transaction.serialize().length };
}

async function balances(route: any) {
  const accounts = await connection.getMultipleAccountsInfo(route.instructions.swapInstruction.accounts.slice(2, 4).map(account => new PublicKey(account.pubkey)));
  return accounts.map(account => account!.data.readBigUInt64LE(64));
}

for (const pair of ['tslax', 'nvdax', 'wsol']) {
  test(`real Jupiter ${pair} CPI executes against cloned mainnet state`, async () => {
    requireLoopback(connection.rpcEndpoint);
    const { transaction, route, blockhash, bytes } = await build(pair);
    const before = await balances(route);
    const simulation = await connection.simulateTransaction(transaction);
    assert.equal(simulation.value.err, null, JSON.stringify({ error: simulation.value.err, logs: simulation.value.logs }));
    assert.ok(bytes <= 1232);
    const signature = await connection.sendRawTransaction(transaction.serialize());
    assert.equal((await connection.confirmTransaction({ signature, ...blockhash }, 'confirmed')).value.err, null);
    const after = await balances(route);
    assert.equal(before[0] - after[0], BigInt(route.quote.inAmount));
    assert.ok(after[1] - before[1] >= BigInt(route.quote.otherAmountThreshold));
    console.log(`${pair}: CPI units=${simulation.value.unitsConsumed}, tx bytes=${bytes}, actual out=${after[1] - before[1]}`);
  });
}

for (const negative of ['output', 'min_out', 'extra_vault', 'mint']) {
  test(`reject ${negative} without vault mutation`, async () => {
    const { transaction, route } = await build('wsol', negative);
    const before = await balances(route);
    const simulation = await connection.simulateTransaction(transaction);
    assert.notEqual(simulation.value.err, null);
    assert.deepEqual(await balances(route), before);
    console.log(`${negative}: rejected ${JSON.stringify(simulation.value.err)}`);
  });
}

test('probe rejects absent manager signature independently of fee payer', async () => {
  const { transaction } = await build('wsol', 'unauthorized');
  const simulation = await connection.simulateTransaction(transaction);
  assert.notEqual(simulation.value.err, null);
});
