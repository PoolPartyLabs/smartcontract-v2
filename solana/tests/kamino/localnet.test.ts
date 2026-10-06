import assert from 'node:assert/strict';
import { rejectIncompleteReport } from '../helpers/report-gate.ts';
import test from 'node:test';
import { ComputeBudgetProgram, Transaction, TransactionInstruction } from '@solana/web3.js';
import { ADDRESSES, publicKey } from '../helpers/addresses.ts';
import { discriminator, readU128 } from '../helpers/layouts.ts';
import { localConnection, sendLocal, testWallet } from '../helpers/localnet.ts';
import { fixture, COLLATERAL, CREDIT, DONATION, COLLATERAL_DONATION, MARKET_AUTHORITY } from './fixtures.ts';

const connection = localConnection();
const manager = testWallet();
const budget = ComputeBudgetProgram.setComputeUnitLimit({ units: 500_000 });
const SCALE = 1n << 60n;

function uint64(amount: bigint): Buffer {
  const data = Buffer.alloc(8); data.writeBigUInt64LE(amount); return data;
}

function instruction(name: 'kamino_supply' | 'kamino_redeem' | 'kamino_refresh', identity: number, payload: Buffer = Buffer.alloc(0), signer = manager.publicKey) {
  const addresses = fixture(identity);
  const keys = [
    { pubkey: signer, isSigner: true, isWritable: false },
    { pubkey: publicKey(addresses.fund), isSigner: false, isWritable: name === 'kamino_supply' },
    { pubkey: publicKey(addresses.vault), isSigner: false, isWritable: false },
    { pubkey: publicKey(addresses.position), isSigner: false, isWritable: true },
  ];
  const venue: [string, boolean][] = name === 'kamino_refresh' ? [
    [addresses.collateral, false], [ADDRESSES.kamino, false], [ADDRESSES.market, false], [ADDRESSES.reserve, true],
  ] : [
    [ADDRESSES.kamino, false], [ADDRESSES.market, false], [ADDRESSES.reserve, true],
    [MARKET_AUTHORITY, false], [ADDRESSES.usdc, false], [COLLATERAL, true],
    ['Bgq7trRgVMeq33yt235zM2onQ4bRDBsY5EWiTetF4qw6', true],
    [addresses.usdc, true], [addresses.collateral, true], [ADDRESSES.token, false],
    ['Sysvar1nstructions1111111111111111111111111', false],
  ];
  for (const [address, writable] of venue) keys.push({ pubkey: publicKey(address), isSigner: false, isWritable: writable });
  const length = Buffer.alloc(4); length.writeUInt32LE(payload.length);
  return new TransactionInstruction({ programId: publicKey(ADDRESSES.spoke), keys,
    data: Buffer.concat([discriminator('global', name), length, payload]) });
}

async function position(identity: number) {
  const data = (await connection.getAccountInfo(publicKey(fixture(identity).position)))!.data;
  const values = Array.from({ length: 11 }, (_, index) => data.readBigUInt64LE(73 + index * 8));
  const [units, principal, idlePrincipal, idleIncome, cumulativeIncome, pendingUnits, pendingMin, value, principalNow, income, slot] = values;
  return { units, principal, idlePrincipal, idleIncome, cumulativeIncome, pendingUnits, pendingMin, value, principalNow, income, slot, data };
}

async function balance(address: string) {
  return BigInt((await connection.getTokenAccountBalance(publicKey(address))).value.amount);
}

async function execute(operation: TransactionInstruction, label: string) {
  const signature = await sendLocal(connection, manager, [budget, operation]);
  const result = await connection.getTransaction(signature, { commitment: 'confirmed', maxSupportedTransactionVersion: 0 });
  assert.equal(result?.meta?.err, null);
  assert.ok(result!.meta!.computeUnitsConsumed! < 500_000);
  console.log(`${label}: ${result!.meta!.computeUnitsConsumed} CU; local signature ${signature}`);
  return result!;
}

async function rejects(operation: TransactionInstruction, expected: string, payer = manager) {
  const addresses = operation.keys[3].pubkey;
  const before = (await connection.getAccountInfo(addresses))!.data;
  const transaction = new Transaction({ feePayer: payer.publicKey, recentBlockhash: (await connection.getLatestBlockhash()).blockhash }).add(budget, operation);
  transaction.sign(payer);
  const result = await connection.simulateTransaction(transaction);
  assert.ok(result.value.err, `expected ${expected}`);
  assert.ok(result.value.logs?.some(line => line.includes(expected)), result.value.logs?.join('\n'));
  assert.ok((await connection.getAccountInfo(addresses))!.data.equals(before));
}

async function exactSupplyAmount(identity: number, target: bigint): Promise<bigint> {
  const addresses = fixture(identity);
  const keys = [addresses.fund, addresses.position, addresses.usdc, addresses.collateral].map(publicKey);
  const before = await connection.getMultipleAccountsInfo(keys);
  const blockhash = (await connection.getLatestBlockhash()).blockhash;
  for (let index = 0; index < 33; index++) {
    const offset = BigInt(Math.ceil(index / 2)) * (index % 2 === 0 ? -1n : 1n);
    const amount = target + offset;
    const transaction = new Transaction({ feePayer: manager.publicKey, recentBlockhash: blockhash })
      .add(budget, instruction('kamino_supply', identity, uint64(amount)));
    transaction.sign(manager);
    const simulation = await connection.simulateTransaction(transaction, undefined, keys);
    const unchanged = await connection.getMultipleAccountsInfo(keys);
    unchanged.forEach((account, accountIndex) => assert.ok(account!.data.equals(before[accountIndex]!.data),
      'supply simulation does not change Fund, position or custody'));
    if (simulation.value.err) {
      assert.deepEqual(simulation.value.err, { InstructionError: [1, { Custom: 7311 }] });
      assert.ok(simulation.value.logs?.some(line => line.includes('UnexpectedDelta')));
      continue;
    }
    const after = simulation.value.accounts!.map(account => Buffer.from(account!.data[0], 'base64'));
    assert.equal(before[2]!.data.readBigUInt64LE(64) - after[2].readBigUInt64LE(64), amount);
    assert.ok(after[3].readBigUInt64LE(64) > before[3]!.data.readBigUInt64LE(64));
    assert.equal(after[1].readBigUInt64LE(81) - before[1]!.data.readBigUInt64LE(81), amount);
    assert.equal(before[1]!.data.readBigUInt64LE(89) - after[1].readBigUInt64LE(89), amount);
    assert.equal(after[0].readUInt16LE(372), before[0]!.data.readUInt16LE(372) + 1);
    console.log(`Exact-debit Kamino supply candidate: ${amount}; simulations=${index + 1}.`);
    return amount;
  }
  assert.fail('No exact-debit Kamino supply in the bounded 33-candidate fixture range');
}

test('cloned Kamino supply, partial/full exit, fresh value and authorization negatives', { timeout: 120_000 }, async () => {
  const addresses = fixture(31);
  assert.equal(await balance(addresses.usdc), CREDIT + DONATION);
  assert.equal(await balance(addresses.collateral), COLLATERAL_DONATION);
  await execute(instruction('kamino_refresh', 31), 'refresh with unrecorded cToken donation');
  assert.equal((await position(31)).value, 0n);
  await rejects(instruction('kamino_supply', 31, uint64(CREDIT + 1n)), 'InsufficientPrincipal');
  const keeper = testWallet('keeper');
  await rejects(instruction('kamino_supply', 31, uint64(1_000_000n), keeper.publicKey), 'Unauthorized', keeper);
  const wrong = instruction('kamino_supply', 31, uint64(1_000_000n));
  wrong.keys[6].pubkey = publicKey(ADDRESSES.market);
  await rejects(wrong, 'WrongReserve');
  const wrongProgram = instruction('kamino_supply', 31, uint64(1_000_000n));
  wrongProgram.keys[4].pubkey = publicKey(ADDRESSES.raydium);
  await rejects(wrongProgram, 'WrongProgram');
  const wrongVault = instruction('kamino_supply', 31, uint64(1_000_000n));
  wrongVault.keys[11].pubkey = publicKey(fixture(33).usdc);
  await rejects(wrongVault, 'InvalidTokenAccount');
  await rejects(instruction('kamino_supply', 31, uint64(0n)), 'InvalidAmount');
  await rejects(instruction('kamino_supply', 33, uint64(1_000_000n)), 'EntryDisabled');
  const supplied = await exactSupplyAmount(31, 10_000_000n);
  await execute(instruction('kamino_supply', 31, uint64(supplied)), 'supply exact-debit USDC');
  assert.equal((await connection.getAccountInfo(publicKey(addresses.fund)))!.data.readUInt16LE(372), 1);
  await rejectIncompleteReport(connection, manager, publicKey(addresses.fund), publicKey(addresses.vault), 'AdapterNotIntegrated');
  let tracked = await position(31);
  assert.equal(tracked.principal, supplied);
  assert.equal(tracked.idlePrincipal, CREDIT - supplied);
  assert.equal(await balance(addresses.collateral), tracked.units + COLLATERAL_DONATION);
  assert.equal(await balance(addresses.usdc), CREDIT + DONATION - supplied);
  const reserve = (await connection.getAccountInfo(publicKey(ADDRESSES.reserve)))!.data;
  const total = reserve.readBigUInt64LE(224) * SCALE + readU128(reserve, 232)
    - readU128(reserve, 344) - readU128(reserve, 360) - readU128(reserve, 376);
  assert.equal(tracked.value, (tracked.units * total / reserve.readBigUInt64LE(2592)) >> 60n);
  assert.equal(tracked.slot, reserve.readBigUInt64LE(16));
  assert.equal(reserve[24], 0);
  assert.equal(tracked.principalNow, tracked.principal < tracked.value ? tracked.principal : tracked.value);
  assert.equal(tracked.income, tracked.value - tracked.principalNow);
  const rate = new TransactionInstruction({ programId: publicKey(ADDRESSES.kamino), keys: [
    { pubkey: publicKey(ADDRESSES.reserve), isWritable: false, isSigner: false },
  ], data: discriminator('global', 'calculate_ctoken_exchange_rate') });
  const signature = await sendLocal(connection, manager, [budget, instruction('kamino_refresh', 31), rate]);
  const transaction = await connection.getTransaction(signature, { commitment: 'confirmed', maxSupportedTransactionVersion: 0 });
  const returned = (transaction?.meta as any)?.returnData;
  assert.equal(returned?.programId, ADDRESSES.kamino);
  const rateData = Buffer.from(returned.data[0], 'base64');
  assert.equal(rateData.length, 17);
  assert.equal(rateData[16], 6);
  tracked = await position(31);
  const fromRate = tracked.units * readU128(rateData, 0) / 1_000_000n / SCALE;
  assert.ok(tracked.value - fromRate >= 0n && tracked.value - fromRate <= 1n);
  console.log(`Kamino own math parity: direct ${tracked.value}, returned rate ${fromRate}, slot ${tracked.slot}.`);
  const partial = tracked.units / 3n;
  await execute(instruction('kamino_redeem', 31, Buffer.concat([uint64(partial), uint64(1n)])), 'partial withdraw');
  const afterPartial = await position(31);
  assert.equal(afterPartial.units, tracked.units - partial);
  assert.ok(afterPartial.principal < tracked.principal);
  await execute(instruction('kamino_redeem', 31, Buffer.concat([uint64((1n << 64n) - 1n), uint64(1n)])), 'full withdraw');
  const final = await position(31);
  assert.equal(final.units, 0n);
  assert.equal(final.principal, 0n);
  assert.equal(final.value, 0n);
  assert.equal(final.pendingUnits, 0n);
  assert.equal(await balance(addresses.collateral), COLLATERAL_DONATION);
  assert.equal(await balance(addresses.usdc), final.idlePrincipal + final.idleIncome + DONATION);
  assert.equal(final.idleIncome, final.cumulativeIncome);
});

test('liquidity shortfall stays pending without collateral burn or write-off', { timeout: 60_000 }, async () => {
  const addresses = fixture(32);
  const before = await position(32);
  const collateralBefore = await balance(addresses.collateral);
  const usdcBefore = await balance(addresses.usdc);
  const payload = Buffer.concat([uint64(before.units), uint64(1n)]);
  await execute(instruction('kamino_redeem', 32, payload), 'illiquid withdrawal records pending claim');
  const pending = await position(32);
  assert.equal(pending.units, before.units);
  assert.equal(pending.principal, before.principal);
  assert.equal(pending.pendingUnits, before.units);
  assert.equal(pending.pendingMin, 1n);
  assert.equal(await balance(addresses.collateral), collateralBefore);
  assert.equal(await balance(addresses.usdc), usdcBefore);
  await execute(instruction('kamino_redeem', 32, payload), 'retry unchanged pending withdrawal');
  await rejects(instruction('kamino_supply', 32, uint64(1n)), 'PendingWithdrawal');
  await rejects(instruction('kamino_redeem', 32, Buffer.concat([uint64(before.units / 2n), uint64(1n)])), 'PendingWithdrawal');
});

test('accrued interest is uncollected until redemption and realized separately', { timeout: 60_000 }, async () => {
  await execute(instruction('kamino_refresh', 34), 'value historical supply with accrued interest');
  const before = await position(34);
  assert.ok(before.income > 0n);
  assert.equal(before.principalNow, 500_000n);
  assert.equal(before.idleIncome, 0n);
  assert.equal(before.cumulativeIncome, 0n);
  await execute(instruction('kamino_redeem', 34, Buffer.concat([uint64(before.units), uint64(1n)])), 'redeem accrued interest separately from principal');
  const after = await position(34);
  assert.equal(after.units, 0n);
  assert.equal(after.principal, 0n);
  assert.equal(after.idlePrincipal, CREDIT + 500_000n);
  assert.ok(after.idleIncome >= before.income);
  assert.equal(after.idleIncome, after.cumulativeIncome);
  assert.equal(await balance(fixture(34).usdc), after.idlePrincipal + after.idleIncome + DONATION);
});
