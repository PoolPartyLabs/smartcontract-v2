import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PublicKey, SystemProgram, Transaction, TransactionInstruction } from '@solana/web3.js';
import { localConnection, testWallet, sendLocal, testAta } from '../helpers/localnet.ts';
import { ADDRESSES, derive } from '../helpers/addresses.ts';
import { decodePool } from '../helpers/layouts.ts';
import { instruction as spokeInstruction, sendMeasured } from '../raydium/client.ts';
import { creation, stageSwapPolicy } from './production-client.ts';

const connection = localConnection();
const manager = testWallet();
const probe = new PublicKey(new Uint8Array(32).fill(77));
const fixture = JSON.parse(readFileSync(new URL('../../.localnet/scope-evidence.json', import.meta.url), 'utf8'));
const extension = JSON.parse(readFileSync(new URL('./fixtures/scope-clone-extension.json', import.meta.url), 'utf8'));
type Entry = { name: string; index: number; value: string; exponent: number; timestamp: number; mint: string };

function instruction(entry: Entry, enabled = true, negative = 0, apiMinimum = 1n, impact = 100, wrong = false) {
  const data = Buffer.alloc(21);
  data[0] = 3; data[1] = Number(enabled); data[2] = negative;
  data.writeBigInt64LE(BigInt(entry.timestamp), 3);
  data.writeBigUInt64LE(apiMinimum, 11); data.writeUInt16LE(impact, 19);
  return new TransactionInstruction({ programId: probe, data, keys: [
    { pubkey: new PublicKey(wrong ? extension.accounts[1] : extension.accounts[0]), isSigner: false, isWritable: false },
    { pubkey: new PublicKey(extension.accounts[1]), isSigner: false, isWritable: false },
    { pubkey: new PublicKey(entry.mint), isSigner: false, isWritable: false },
  ] });
}

async function simulate(entry: Entry, enabled = true, negative = 0, apiMinimum = 1n, impact = 100, wrong = false) {
  const transaction = new Transaction({ feePayer: manager.publicKey,
    recentBlockhash: (await connection.getLatestBlockhash()).blockhash })
    .add(instruction(entry, enabled, negative, apiMinimum, impact, wrong));
  transaction.sign(manager);
  const result = (await connection.simulateTransaction(transaction)).value;
  assert.ok(result.logs?.some(log => log.includes(probe.toBase58())), 'probe must execute');
  return result;
}

function liveMultiplier(bytes: Buffer, now: number): [bigint, bigint] {
  let cursor = 166;
  while (cursor + 4 <= bytes.length) {
    const type = bytes.readUInt16LE(cursor); const length = bytes.readUInt16LE(cursor + 2); cursor += 4;
    if (type === 25) {
      const activation = Number(bytes.readBigInt64LE(cursor + 40));
      const bits = bytes.readBigUInt64LE(cursor + (now >= activation ? 48 : 32));
      const significand = (bits & ((1n << 52n) - 1n)) | (1n << 52n);
      const exponent = Number((bits >> 52n) & 0x7ffn) - 1023 - 52;
      return exponent < 0 ? [significand, 1n << BigInt(-exponent)] : [significand << BigInt(exponent), 1n];
    }
    cursor += length;
  }
  throw new Error('Cloned mint lacks multiplier');
}

test('Scope clone evidence pins owners, feeds, units and executable program', async () => {
  for (const entry of fixture.evidence) {
    const account = await connection.getAccountInfo(new PublicKey(entry.address));
    assert.ok(account); assert.equal(account.owner.toBase58(), entry.owner); assert.equal(account.data.length, entry.size);
  }
  const program = await connection.getAccountInfo(new PublicKey(extension.program));
  assert.equal(program?.executable, true);
});

test('production creation seals OFF by default and Scope ON only with signed consent', async () => {
  const poolAccount = await connection.getAccountInfo(new PublicKey(ADDRESSES.solPool)); assert.ok(poolAccount);
  const pool = decodePool(poolAccount.data);
  for (const enabled of [false, true]) {
    const fixture = creation(manager.publicKey, Buffer.alloc(20, enabled ? 0xcc : 0xcb), 27,
      pool, new Uint8Array(32).fill(42), false, enabled);
    const fund = new PublicKey(fixture.target.fund); const vault = new PublicKey(fixture.target.vault);
    const config = derive(ADDRESSES.spoke, Buffer.from('swap_config'), fund.toBuffer());
    const ledger = (mint: string) => derive(ADDRESSES.spoke, Buffer.from('ledger'), fund.toBuffer(), new PublicKey(mint).toBuffer());
    const { stage, instructions } = stageSwapPolicy(manager.publicKey, fund, fixture.policyHash, fixture.payload);
    for (const operation of instructions) await sendMeasured(connection, manager, operation);
    const operation = spokeInstruction('initialize_fund', { authority: manager.publicKey, fund, vault,
      system_program: SystemProgram.programId, usdc_mint: ADDRESSES.usdc, tslax_mint: ADDRESSES.tslax, wsol_mint: ADDRESSES.wsol,
      usdc_ata: testAta(ADDRESSES.usdc, vault), tslax_ata: testAta(ADDRESSES.tslax, vault), wsol_ata: testAta(ADDRESSES.wsol, vault),
      usdc_ledger: ledger(ADDRESSES.usdc), tslax_ledger: ledger(ADDRESSES.tslax), wsol_ledger: ledger(ADDRESSES.wsol),
      cctp_route: derive(ADDRESSES.spoke, Buffer.from('cctp_route'), fund.toBuffer()),
      cctp_ledger: derive(ADDRESSES.spoke, Buffer.from('cctp_ledger'), fund.toBuffer()),
      token_program: ADDRESSES.token, token_2022_program: ADDRESSES.token2022, ata_program: ADDRESSES.ata }, Buffer.from([2]));
    operation.keys.push({ pubkey: new PublicKey(config), isWritable: true, isSigner: false },
      { pubkey: stage, isWritable: true, isSigner: false });
    await sendMeasured(connection, manager, operation);
    const account = await connection.getAccountInfo(new PublicKey(config)); assert.ok(account);
    assert.equal(account.owner.toBase58(), ADDRESSES.spoke);
    assert.deepEqual(account.data.subarray(72, 72 + fixture.policy.length), fixture.policy);
    assert.deepEqual(account.data.subarray(72 + fixture.policy.length - 2, 72 + fixture.policy.length),
      Buffer.from([Number(enabled), Number(enabled)]));
    const before = Buffer.from(account.data);
    await assert.rejects(sendLocal(connection, manager, [instructions.at(-1)!]));
    assert.deepEqual((await connection.getAccountInfo(new PublicKey(config)))?.data, before);
    console.log(`Production Fund creation: Scope ${enabled ? 'ON' : 'OFF'} sealed; ${fund.toBase58()}.`);
  }
});

test('enabled fresh in-session cloned prices apply the live mint multiplier exactly once', async () => {
  for (const entry of fixture.entries as Entry[]) {
    const result = await simulate(entry);
    assert.equal(result.err, null, JSON.stringify(result.logs));
    const mint = await connection.getAccountInfo(new PublicKey(entry.mint)); assert.ok(mint);
    const [numerator, denominator] = liveMultiplier(mint.data, entry.timestamp);
    const effective = BigInt(entry.value) * numerator / denominator;
    const minimumNumerator = 25_000_000n * 100_000_000n * 9_900n * 10n ** 9n;
    const minimumDenominator = effective * 10_000n;
    const minimum = (minimumNumerator + minimumDenominator - 1n) / minimumDenominator;
    assert.ok(result.logs?.some(log => log.includes(`value ${effective} exponent -15 minimum ${minimum}`)), JSON.stringify(result.logs));
    const signature = await sendLocal(connection, manager, [instruction(entry)]);
    console.log(`${entry.name}: local signature ${signature}; cloned source ${entry.timestamp}; replayed in-session Clock; CU ${result.unitsConsumed}; minimum ${minimum}`);
    if (entry.name === 'NVDAx') assert.ok(effective > BigInt(entry.value));
  }
});

test('DEC-203 keeps the stricter API minimum and optional Manager-bound semantics', async () => {
  const entry = fixture.entries[0];
  for (const impact of [100, 0, 10_000]) {
    const result = await simulate(entry, true, 0, 999_999_999n, impact);
    assert.equal(result.err, null, JSON.stringify(result.logs));
    assert.ok(result.logs?.some(log => log.includes('minimum 999999999')));
  }
});

for (const [name, enabled, negative, wrong, error] of [
  ['disabled switch is unavailable', false, 0, false, 'StockDisabled'],
  ['closed market never reuses a cached price', true, 1, false, 'MarketClosed'],
  ['stale source is rejected', true, 2, false, 'Stale'],
  ['future source is rejected', true, 3, false, 'Stale'],
  ['wrong pinned account is rejected', true, 0, true, 'InvalidAccount'],
] as const) {
  test(name, async () => {
    for (const entry of fixture.entries) {
      const result = await simulate(entry, enabled, negative, 1n, 100, wrong);
      assert.notEqual(result.err, null);
      assert.ok(result.logs?.some(log => log.includes(`Error Code: ${error}`)), JSON.stringify(result.logs));
    }
  });
}
