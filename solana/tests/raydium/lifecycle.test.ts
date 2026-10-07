import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { Keypair, PublicKey, TransactionInstruction, Transaction, ComputeBudgetProgram } from '@solana/web3.js';
import { ADDRESSES, derive, publicKey } from '../helpers/addresses.ts';
import { decodePool, discriminator, readU128 } from '../helpers/layouts.ts';
import { localConnection, testAta, testWallet } from '../helpers/localnet.ts';
import { rejectIncompleteReport } from '../helpers/report-gate.ts';
import { instruction, sendMeasured, u128 } from './client.ts';

const memo = 'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr';
const fixtures = JSON.parse(readFileSync(new URL('../../.localnet/raydium-fixtures.json', import.meta.url), 'utf8'));

for (const fixture of fixtures) {
  test(`Raydium vault lifecycle ${fixture.address}`, { timeout: 240_000 }, async () => {
    const connection = localConnection();
    const manager = testWallet();
    const mint = Keypair.generate();
    const pool = decodePool((await connection.getAccountInfo(publicKey(fixture.address)))!.data);
    const lower = Math.floor(pool.tickCurrent / pool.tickSpacing) * pool.tickSpacing - 10 * pool.tickSpacing;
    const upper = lower + 20 * pool.tickSpacing;
    function array(tick: number) {
      const start = Math.floor(tick / (pool.tickSpacing * 60)) * pool.tickSpacing * 60;
      const seed = Buffer.alloc(4);
      seed.writeInt32BE(start);
      return derive(ADDRESSES.raydium, Buffer.from('tick_array'), publicKey(fixture.address).toBuffer(), seed);
    }
    const personal = derive(ADDRESSES.raydium, Buffer.from('position'), mint.publicKey.toBuffer());
    const record = derive(ADDRESSES.spoke, Buffer.from('position'), publicKey(fixture.fund).toBuffer(), publicKey(personal).toBuffer());
    const nft = derive(ADDRESSES.ata, publicKey(fixture.vault).toBuffer(), publicKey(ADDRESSES.token2022).toBuffer(), mint.publicKey.toBuffer());
    const accounts: Record<string, string | PublicKey | null> = {
      authority: manager.publicKey, fund: fixture.fund, vault: fixture.vault, raydium_program: ADDRESSES.raydium,
      policy: fixture.policy, ledger: fixture.ledger, position_record: record, nft_mint: mint.publicKey, nft_account: nft,
      pool: fixture.address, protocol_position: ADDRESSES.raydium, tick_array_lower: array(lower), tick_array_upper: array(upper),
      personal_position: personal, token_account_0: testAta(pool.mint0, publicKey(fixture.vault)),
      token_account_1: testAta(pool.mint1, publicKey(fixture.vault)), token_vault_0: pool.vault0, token_vault_1: pool.vault1,
      token_program_2022: ADDRESSES.token2022, mint_0: pool.mint0, mint_1: pool.mint1, bitmap: fixture.bitmap,
      rent_payer: manager.publicKey,
    };
    for (let slot = 0; slot < 3; slot++) {
      accounts[`reward_vault_${slot}`] = fixture.rewards[slot]?.vault ?? null;
      accounts[`reward_quarantine_${slot}`] = fixture.rewards[slot]?.quarantine ?? null;
      accounts[`reward_mint_${slot}`] = fixture.rewards[slot]?.mint ?? null;
    }
    const ticks = Buffer.alloc(8);
    ticks.writeInt32LE(lower, 0); ticks.writeInt32LE(upper, 4);
    const liquidity = 10_000_000_000n;
    const max = Buffer.alloc(16);
    max.writeBigUInt64LE(1_000_000_000n, 0); max.writeBigUInt64LE(1_000_000_000n, 8);
    const payload = Buffer.concat([ticks, u128(liquidity), max, u128(liquidity)]);
    const open = instruction('raydium_open_position', accounts, payload);
    const activePositionsBefore = (await connection.getAccountInfo(publicKey(fixture.fund)))!.data.readUInt16LE(372);
    async function assertReportLatched() {
      await rejectIncompleteReport(connection, manager, publicKey(fixture.fund), publicKey(fixture.vault), 'AdapterNotIntegrated');
    }
    async function negative(changes: Record<string, string | PublicKey | null>, badPayload = payload) {
      const bad = instruction('raydium_open_position', { ...accounts, ...changes }, badPayload);
      const transaction = new Transaction({ feePayer: manager.publicKey, recentBlockhash: (await connection.getLatestBlockhash()).blockhash })
        .add(ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }), bad);
      transaction.sign(manager, mint);
      const result = await connection.simulateTransaction(transaction);
      assert.ok(result.value.err, 'negative must fail');
      assert.equal(await connection.getAccountInfo(publicKey(personal)), null);
    }
    await negative({ fund: fixtures.find((entry: any) => entry.fund !== fixture.fund).fund });
    await negative({ pool: fixtures.find((entry: any) => entry.address !== fixture.address).address });
    const empty = Buffer.from(payload); empty.fill(0, 8, 24);
    await negative({}, empty);
    await assert.rejects(sendMeasured(connection, testWallet('keeper'),
      instruction('raydium_open_position', { ...accounts, authority: testWallet('keeper').publicKey }, payload), [mint]),
      /Unauthorized|Manager is not authorized/);
    const overBudget = Buffer.from(payload);
    overBudget.writeBigUInt64LE(100_000_000_001n, 24);
    await negative({}, overBudget);
    assert.equal((await connection.getAccountInfo(publicKey(fixture.fund)))!.data.readUInt16LE(372), activePositionsBefore);
    const measuredOpen = await sendMeasured(connection, manager, open, [mint]);
    const activePositionsAfterOpen = (await connection.getAccountInfo(publicKey(fixture.fund)))!.data.readUInt16LE(372);
    assert.equal(activePositionsAfterOpen, activePositionsBefore + 1, 'successful open latches exactly one unretired position');
    assert.ok(activePositionsAfterOpen > 0);
    await assertReportLatched();
    assert.ok(measuredOpen.bytes <= 1232);
    assert.ok(measuredOpen.units! < 1_400_000);
    assert.equal(readU128((await connection.getAccountInfo(publicKey(personal)))!.data, 81), liquidity);
    assert.equal((await connection.getTokenAccountBalance(publicKey(nft))).value.amount, '1');
    const ledgerAfterOpen = (await connection.getAccountInfo(publicKey(fixture.ledger)))!.data;
    assert.ok(ledgerAfterOpen.readBigUInt64LE(72) < 100_000_000_000n || ledgerAfterOpen.readBigUInt64LE(80) < 100_000_000_000n);
    assert.equal(ledgerAfterOpen.readBigUInt64LE(88) + ledgerAfterOpen.readBigUInt64LE(96), 0n);
    for (const source of [accounts.token_account_0, accounts.token_account_1]) {
      const data = (await connection.getAccountInfo(source as PublicKey))!.data;
      assert.equal(data.readUInt32LE(72), 0, 'temporary Manager delegate revoked');
    }
    const beforeSwap = decodePool((await connection.getAccountInfo(publicKey(fixture.address)))!.data);
    const zeroForOne = pool.mint0 === ADDRESSES.usdc;
    const inputMint = zeroForOne ? pool.mint0 : pool.mint1;
    const outputMint = zeroForOne ? pool.mint1 : pool.mint0;
    const amount = Buffer.alloc(16); amount.writeBigUInt64LE(100_000_000n, 0); amount.writeBigUInt64LE(1n, 8);
    const limit = zeroForOne ? beforeSwap.sqrtPriceX64 * 999n / 1000n : beforeSwap.sqrtPriceX64 * 1001n / 1000n;
    const currentStart = Math.floor(beforeSwap.tickCurrent / (pool.tickSpacing * 60)) * pool.tickSpacing * 60;
    const arrays = fixture.arrays.map((address: string) => {
      const snapshot = JSON.parse(readFileSync(new URL(`../../.localnet/accounts/${address}.json`, import.meta.url), 'utf8'));
      return { address, start: Buffer.from(snapshot.account.data[0], 'base64').readInt32LE(40) };
    }).filter((entry: any) => zeroForOne ? entry.start <= currentStart : entry.start >= currentStart)
      .sort((left: any, right: any) => zeroForOne ? right.start - left.start : left.start - right.start);
    const swap = new TransactionInstruction({ programId: publicKey(ADDRESSES.raydium), keys: [
      { pubkey: manager.publicKey, isWritable: false, isSigner: true },
      ...[pool.config, fixture.address, testAta(inputMint, manager.publicKey), testAta(outputMint, manager.publicKey),
        zeroForOne ? pool.vault0 : pool.vault1, zeroForOne ? pool.vault1 : pool.vault0, pool.observation,
        ADDRESSES.token, ADDRESSES.token2022, memo, inputMint, outputMint, fixture.bitmap, ...arrays.map((entry: any) => entry.address)]
        .map((address, index) => ({ pubkey: typeof address === 'string' ? publicKey(address) : address,
          isSigner: false, isWritable: [1, 2, 3, 4, 5, 6].includes(index) || index >= 12 })),
    ], data: Buffer.concat([discriminator('global', 'swap_v2'), amount, u128(limit), Buffer.from([1])]) });
    await sendMeasured(connection, manager, swap);
    assert.notEqual(decodePool((await connection.getAccountInfo(publicKey(fixture.address)))!.data).sqrtPriceX64, beforeSwap.sqrtPriceX64);
    await sendMeasured(connection, manager, instruction('raydium_collect_fees', accounts, Buffer.alloc(0)));
    const recordData = (await connection.getAccountInfo(publicKey(record)))!.data;
    assert.ok(recordData.readBigUInt64LE(192) + recordData.readBigUInt64LE(200) > 0n, 'trading fees realized after direct pool swap');
    const ledgerAfterCollect = (await connection.getAccountInfo(publicKey(fixture.ledger)))!.data;
    assert.equal(ledgerAfterCollect.readBigUInt64LE(88), recordData.readBigUInt64LE(192));
    assert.equal(ledgerAfterCollect.readBigUInt64LE(96), recordData.readBigUInt64LE(200));
    for (const reward of fixture.rewards) {
      assert.equal((await connection.getTokenAccountBalance(publicKey(reward.quarantine))).value.amount, '0');
    }
    const vaultLamports = await connection.getBalance(publicKey(fixture.vault));
    await sendMeasured(connection, manager, instruction('raydium_close_position', accounts, Buffer.alloc(16)));
    assert.equal(await connection.getAccountInfo(publicKey(personal)), null);
    assert.equal(await connection.getAccountInfo(publicKey(nft)), null);
    assert.equal(await connection.getAccountInfo(mint.publicKey), null);
    assert.equal(await connection.getBalance(publicKey(fixture.vault)), vaultLamports, 'rent never remains in Fund');
    const closed = (await connection.getAccountInfo(publicKey(record)))!.data;
    assert.equal(readU128(closed, 176), 0n);
    assert.equal(closed[208], 1);
    assert.equal((await connection.getAccountInfo(publicKey(fixture.fund)))!.data.readUInt16LE(372), activePositionsAfterOpen,
      'close retains the integration latch until canonical ledger/report retirement');
    await assertReportLatched();
  });
}
