import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { TransactionInstruction, ComputeBudgetProgram, SystemProgram } from '@solana/web3.js';
import { ADDRESSES, publicKey } from '../helpers/addresses.ts';
import { decodePool, decodeReserve, discriminator, spotRatio } from '../helpers/layouts.ts';
import { localConnection, sendLocal, testAta, testWallet } from '../helpers/localnet.ts';

test('cloned mainnet programs execute and fixture balances are local-only', { timeout: 60_000 }, async () => {
  const connection = localConnection();
  const manager = testWallet();
  const manifest = JSON.parse(readFileSync(new URL('../../.localnet/manifest.json', import.meta.url), 'utf8'));
  for (const program of [ADDRESSES.raydium, ADDRESSES.kamino, ADDRESSES.cctpTransmitter,
    ADDRESSES.cctpMessenger, ADDRESSES.wormhole, ADDRESSES.token2022, ADDRESSES.spoke]) {
    assert.ok((await connection.getAccountInfo(publicKey(program)))?.executable, program);
  }
  assert.ok(await connection.getBalance(manager.publicKey) > 1_000_000_000);
  for (const mint of [ADDRESSES.usdc, ADDRESSES.tslax]) {
    const token = await connection.getTokenAccountBalance(testAta(mint, manager.publicKey));
    assert.ok(BigInt(token.value.amount) > 0n);
  }
  for (const address of [ADDRESSES.tslaxPool, ADDRESSES.solPool]) {
    const account = await connection.getAccountInfo(publicKey(address));
    assert.equal(account?.owner.toBase58(), ADDRESSES.raydium);
    const pool = decodePool(account!.data);
    assert.ok(pool.sqrtPriceX64 > 0n);
    assert.ok(pool.liquidity > 0n);
    assert.ok(spotRatio(pool) > 0);
    console.log(`Raydium ${address}: tick ${pool.tickCurrent}, spot ratio ${spotRatio(pool).toFixed(8)} (diagnostic, not NAV).`);
  }
  const reserveBefore = decodeReserve((await connection.getAccountInfo(publicKey(ADDRESSES.reserve)))!.data);
  assert.equal(reserveBefore.market, ADDRESSES.market);
  assert.equal(reserveBefore.mint, ADDRESSES.usdc);
  assert.ok(reserveBefore.available > 0n);
  const refresh = new TransactionInstruction({
    programId: publicKey(ADDRESSES.kamino),
    keys: [
      { pubkey: publicKey(ADDRESSES.reserve), isSigner: false, isWritable: true },
      { pubkey: publicKey(ADDRESSES.market), isSigner: false, isWritable: false },
    ],
    data: Buffer.concat([discriminator('global', 'refresh_reserves_batch'), Buffer.from([1])]),
  });
  const signature = await sendLocal(connection, manager, [ComputeBudgetProgram.setComputeUnitLimit({ units: 300_000 }), refresh]);
  const transaction = await connection.getTransaction(signature, { commitment: 'confirmed', maxSupportedTransactionVersion: 0 });
  assert.equal(transaction?.meta?.err, null);
  assert.ok(transaction?.meta?.logMessages?.some(line => line.includes(`Program ${ADDRESSES.kamino} success`)));
  const reserveAfter = decodeReserve((await connection.getAccountInfo(publicKey(ADDRESSES.reserve)))!.data);
  assert.ok(reserveAfter.lastUpdateSlot >= BigInt(manifest.warpSlot));
  console.log(`Kamino refresh_reserves_batch executed: ${transaction?.meta?.computeUnitsConsumed} CU, reserve update slot ${reserveAfter.lastUpdateSlot}.`);
});

test('loaded spoke rejects incomplete initialization accounts without state changes', { timeout: 30_000 }, async () => {
  const connection = localConnection();
  const manager = testWallet();
  const instruction = new TransactionInstruction({
    programId: publicKey(ADDRESSES.spoke),
    keys: [
      { pubkey: manager.publicKey, isSigner: true, isWritable: true },
      { pubkey: manager.publicKey, isSigner: false, isWritable: true },
      { pubkey: manager.publicKey, isSigner: false, isWritable: true },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    data: Buffer.concat([discriminator('global', 'initialize_fund'), Buffer.alloc(4)]),
  });
  const { Transaction } = await import('@solana/web3.js');
  const transaction = new Transaction({ feePayer: manager.publicKey, recentBlockhash: (await connection.getLatestBlockhash()).blockhash }).add(instruction);
  transaction.sign(manager);
  const before = await connection.getAccountInfo(manager.publicKey);
  const result = await connection.simulateTransaction(transaction);
  assert.deepEqual(result.value.err, { InstructionError: [0, { Custom: 3005 }] });
  assert.ok(result.value.logs?.some(line => line.includes('AccountNotEnoughKeys')));
  const after = await connection.getAccountInfo(manager.publicKey);
  assert.equal(after?.lamports, before?.lamports);
  assert.ok(after?.data.equals(before!.data));
});
