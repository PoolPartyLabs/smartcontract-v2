import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import test from 'node:test';
import { secp256k1 } from '@noble/curves/secp256k1';
import { Keypair, PublicKey, SystemProgram, TransactionInstruction, SYSVAR_CLOCK_PUBKEY, SYSVAR_RENT_PUBKEY,
  ComputeBudgetProgram, TransactionMessage, VersionedTransaction, AddressLookupTableProgram } from '@solana/web3.js';
import { ADDRESSES, publicKey, derive } from '../helpers/addresses.ts';
import { decodePool, discriminator } from '../helpers/layouts.ts';
import { localConnection, requireLoopback, testWallet, testAta, sendLocal } from '../helpers/localnet.ts';
import { instruction, sendMeasured, u128 } from '../raydium/client.ts';
import { integer, word, fundId, addressWord } from '../core/fixtures.ts';
import { attest, evm } from '../cctp/fixtures.ts';
import { creation, signedSwap, NVDA, NVDA_POOL, SOL_PRICE, USDC_PRICE, CROSS_CHECK } from './production-client.ts';

test('production signed swap plus open, real countertrade fees and NVDAx report', { timeout: 900_000 }, async () => {
  const connection = localConnection(); requireLoopback(connection.rpcEndpoint);
  const manager = testWallet(); const keeper = testWallet('keeper');
  const core = Buffer.alloc(20, 0xc8); const apiKey = secp256k1.utils.randomPrivateKey();
  const pool = decodePool((await connection.getAccountInfo(publicKey(ADDRESSES.solPool)))!.data);
  const { bootstrapPayload, stagedPayload, bindingDigest, policy, target } = creation(manager.publicKey, core, 18, pool, apiKey, true);
  const fund = publicKey(target.fund); const vault = publicKey(target.vault);
  const ledger = (mint: string) => derive(ADDRESSES.spoke, Buffer.from('ledger'), fund.toBuffer(), publicKey(mint).toBuffer());
  const pda = (...seeds: Buffer[]) => derive(ADDRESSES.spoke, ...seeds);
  const foreign = (program: string, ...seeds: Buffer[]) => derive(program, ...seeds);
  const config = pda(Buffer.from('swap_config'), fund.toBuffer());
  const common = { authority: manager.publicKey, fund, vault, system_program: SystemProgram.programId };
  const key = (address: string | PublicKey, writable = false, signer = false) => ({ pubkey: typeof address === 'string' ? publicKey(address) : address, isWritable: writable, isSigner: signer });
  const stage = Keypair.generate();
  const stageInstruction = instruction('swap_exact_in', { ...common, swap_program: 'JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4' }, stagedPayload);
  stageInstruction.keys.push(key(stage.publicKey, true, true));
  await sendMeasured(connection, manager, stageInstruction, [stage]);
  const init = instruction('initialize_fund', { ...common, usdc_mint: ADDRESSES.usdc, tslax_mint: ADDRESSES.tslax, wsol_mint: ADDRESSES.wsol,
    usdc_ata: testAta(ADDRESSES.usdc, vault), tslax_ata: testAta(ADDRESSES.tslax, vault), wsol_ata: testAta(ADDRESSES.wsol, vault),
    usdc_ledger: ledger(ADDRESSES.usdc), tslax_ledger: ledger(ADDRESSES.tslax), wsol_ledger: ledger(ADDRESSES.wsol),
    cctp_route: pda(Buffer.from('cctp_route'), fund.toBuffer()), cctp_ledger: pda(Buffer.from('cctp_ledger'), fund.toBuffer()),
    token_program: ADDRESSES.token, token_2022_program: ADDRESSES.token2022, ata_program: ADDRESSES.ata }, bootstrapPayload);
  init.keys.push(key(config, true), key(stage.publicKey, true), key(NVDA), key(testAta(NVDA, vault), true), key(ledger(NVDA), true));
  const tampered = new TransactionInstruction({ programId: init.programId, keys: init.keys, data: Buffer.from(init.data) });
  tampered.data[12 + 230] ^= 1;
  await assert.rejects(sendMeasured(connection, manager, tampered), /InvalidBinding|InvalidConfiguration/);
  assert.equal(await connection.getAccountInfo(fund), null);
  await sendMeasured(connection, manager, init);
  assert.equal(await connection.getAccountInfo(stage.publicKey), null);
  const sealed = (await connection.getAccountInfo(publicKey(config)))!.data;
  assert.deepEqual(sealed.subarray(40, 72), bindingDigest);
  assert.deepEqual(sealed.subarray(72, 72 + policy.length), policy);
  assert.equal((await connection.getAccountInfo(testAta(NVDA, vault)))!.owner.toBase58(), ADDRESSES.token2022);
  assert.equal((await connection.getAccountInfo(publicKey(ledger(NVDA))))!.data.readBigUInt64LE(72), 0n);

  const inbound = word(2801); const nonce = word(3801);
  const messenger = foreign(ADDRESSES.cctpMessenger, Buffer.from('token_messenger'));
  const transmitter = foreign(ADDRESSES.cctpTransmitter, Buffer.from('message_transmitter'));
  const messengerData = (await connection.getAccountInfo(publicKey(messenger)))!.data;
  const feeAta = testAta(ADDRESSES.usdc, new PublicKey(messengerData.subarray(109, 141)));
  const usdc = testAta(ADDRESSES.usdc, vault);
  const arrival = Buffer.alloc(536);
  for (const [offset, value] of [[0, 1], [4, 3], [8, 5], [140, 1000], [144, 1000], [148, 1]]) arrival.writeUInt32BE(value, offset);
  nonce.copy(arrival, 12); evm('28b5a0e9c621a5badaa536219b3a228c8168cf5d').copy(arrival, 44);
  publicKey(ADDRESSES.cctpMessenger).toBuffer().copy(arrival, 76); vault.toBuffer().copy(arrival, 108);
  evm('af88d065e77c8cc2239327c5edb3a432268e5831').copy(arrival, 152); usdc.toBuffer().copy(arrival, 184);
  word(30_000_000).copy(arrival, 216); addressWord(core).copy(arrival, 248); word(10_000).copy(arrival, 280); word(100).copy(arrival, 312);
  Buffer.concat([word(1), fundId, word(42161), inbound, word(0)]).copy(arrival, 376);
  const attestation = attest(arrival);
  const transit = pda(Buffer.from('transit'), fund.toBuffer(), inbound);
  const receive = instruction('receive_and_credit', { ...common, authority: keeper.publicKey,
    route: pda(Buffer.from('cctp_route'), fund.toBuffer()), ledger: pda(Buffer.from('cctp_ledger'), fund.toBuffer()),
    transit, usdc_ata: usdc, token_ledger: ledger(ADDRESSES.usdc) },
    Buffer.concat([inbound, integer(arrival.length, 4), arrival, integer(attestation.length, 4), attestation]));
  receive.keys.push(key(keeper.publicKey, true, true), key(vault),
    key(foreign(ADDRESSES.cctpTransmitter, Buffer.from('message_transmitter_authority'), publicKey(ADDRESSES.cctpMessenger).toBuffer())),
    key(transmitter), key(foreign(ADDRESSES.cctpTransmitter, Buffer.from('used_nonce'), nonce), true), key(ADDRESSES.cctpMessenger), key(SystemProgram.programId),
    key(foreign(ADDRESSES.cctpTransmitter, Buffer.from('__event_authority'))), key(ADDRESSES.cctpTransmitter), key(messenger),
    key(foreign(ADDRESSES.cctpMessenger, Buffer.from('remote_token_messenger'), Buffer.from('3'))), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('token_minter'))),
    key(foreign(ADDRESSES.cctpMessenger, Buffer.from('local_token'), publicKey(ADDRESSES.usdc).toBuffer()), true),
    key(foreign(ADDRESSES.cctpMessenger, Buffer.from('token_pair'), Buffer.from('3'), evm('af88d065e77c8cc2239327c5edb3a432268e5831'))),
    key(feeAta, true), key(usdc, true), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('custody'), publicKey(ADDRESSES.usdc).toBuffer()), true),
    key(ADDRESSES.token), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('__event_authority'))), key(ADDRESSES.cctpMessenger), key(ADDRESSES.cctpTransmitter));
  await sendMeasured(connection, keeper, receive);
  const recorded = JSON.parse(readFileSync(new URL('./fixtures/v2/wsol.json', import.meta.url), 'utf8'));
  const routeArrays = JSON.parse(readFileSync(new URL('../../.localnet/swap-production-route-arrays.json', import.meta.url), 'utf8'));
  for (let index = 0; index < 3; index++) recorded.build.swapInstruction.accounts[20 + index].pubkey = routeArrays[index];
  const before = await connection.getMultipleAccountsInfo([fund, publicKey(config), publicKey(ledger(ADDRESSES.usdc)), publicKey(ledger(ADDRESSES.wsol))]);
  for (const options of [{ forged: true }, { deadline: 1n }, { impact: 1 }, { nonce: 1n }]) {
    await assert.rejects(sendMeasured(connection, manager, signedSwap(recorded, common, core, apiKey, config, ledger, options)), /InvalidSignature|Expired|Impact|Replay/);
    const after = await connection.getMultipleAccountsInfo([fund, publicKey(config), publicKey(ledger(ADDRESSES.usdc)), publicKey(ledger(ADDRESSES.wsol))]);
    assert.deepEqual(after.map(account => account!.data), before.map(account => account!.data));
  }
  const stock = JSON.parse(readFileSync(new URL('./fixtures/v2/nvdax.json', import.meta.url), 'utf8'));
  await assert.rejects(sendMeasured(connection, manager, signedSwap(stock, common, core, apiKey, config, ledger)), /StockDisabled/);

  const lpPolicy = pda(Buffer.from('raydium_policy'), fund.toBuffer(), publicKey(ADDRESSES.solPool).toBuffer());
  const lpLedger = pda(Buffer.from('raydium_ledger'), fund.toBuffer(), publicKey(ADDRESSES.solPool).toBuffer());
  await sendMeasured(connection, manager, instruction('initialize_adapter', { ...common, venue_program: ADDRESSES.raydium, venue: ADDRESSES.solPool,
    position_or_policy: lpPolicy, collateral_or_ledger: lpLedger, collateral_mint: ADDRESSES.usdc, token_program: ADDRESSES.token, ata_program: ADDRESSES.ata }, Buffer.alloc(0)));
  const mint = Keypair.generate(); const personal = foreign(ADDRESSES.raydium, Buffer.from('position'), mint.publicKey.toBuffer());
  const record = pda(Buffer.from('position'), fund.toBuffer(), publicKey(personal).toBuffer());
  const lower = Math.floor(pool.tickCurrent / pool.tickSpacing) * pool.tickSpacing - 10 * pool.tickSpacing;
  const upper = lower + 20 * pool.tickSpacing;
  const array = (tick: number) => { const start = Buffer.alloc(4); start.writeInt32BE(Math.floor(tick / (60 * pool.tickSpacing)) * 60 * pool.tickSpacing); return foreign(ADDRESSES.raydium, Buffer.from('tick_array'), publicKey(ADDRESSES.solPool).toBuffer(), start); };
  const bitmap = foreign(ADDRESSES.raydium, Buffer.from('pool_tick_array_bitmap_extension'), publicKey(ADDRESSES.solPool).toBuffer());
  const lpAccounts = { ...common, raydium_program: ADDRESSES.raydium, policy: lpPolicy, ledger: lpLedger, position_record: record,
    nft_mint: mint.publicKey, nft_account: foreign(ADDRESSES.ata, vault.toBuffer(), publicKey(ADDRESSES.token2022).toBuffer(), mint.publicKey.toBuffer()),
    personal_position: personal, pool: ADDRESSES.solPool, protocol_position: ADDRESSES.raydium, tick_array_lower: array(lower), tick_array_upper: array(upper),
    token_account_0: testAta(pool.mint0, vault), token_account_1: testAta(pool.mint1, vault), token_vault_0: pool.vault0, token_vault_1: pool.vault1,
    rent: SYSVAR_RENT_PUBKEY, token_program: ADDRESSES.token, associated_token_program: ADDRESSES.ata, token_program_2022: ADDRESSES.token2022,
    mint_0: pool.mint0, mint_1: pool.mint1, bitmap, memo_program: 'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr', rent_payer: manager.publicKey };
  const ticks = Buffer.alloc(8); ticks.writeInt32LE(lower); ticks.writeInt32LE(upper, 4);
  const rewards = JSON.parse(readFileSync(new URL('../../.localnet/swap-production-rewards.json', import.meta.url), 'utf8'));
  for (const [index, reward] of rewards.entries()) Object.assign(lpAccounts, {
    [`reward_vault_${index}`]: reward.vault, [`reward_quarantine_${index}`]: reward.quarantine, [`reward_mint_${index}`]: reward.mint,
  });
  const liquidity = 5_000_000_000n;
  const open = instruction('raydium_open_position', lpAccounts, Buffer.concat([ticks, u128(liquidity), integer(8_000_000, 8), integer(10_000_000, 8), u128(liquidity)]));
  const swap = signedSwap(recorded, common, core, apiKey, config, ledger);
  const slot = await connection.getSlot('finalized');
  const [createTable, tableAddress] = AddressLookupTableProgram.createLookupTable({ authority: manager.publicKey, payer: manager.publicKey, recentSlot: slot });
  await sendLocal(connection, manager, [createTable]);
  const addresses = [...new Map([...swap.keys, ...open.keys].filter(meta => !meta.isSigner).map(meta => [meta.pubkey.toBase58(), meta.pubkey])).values()];
  for (let offset = 0; offset < addresses.length; offset += 20) await sendLocal(connection, manager, [AddressLookupTableProgram.extendLookupTable({ lookupTable: tableAddress, authority: manager.publicKey, payer: manager.publicKey, addresses: addresses.slice(offset, offset + 20) })]);
  await new Promise(resolve => setTimeout(resolve, 1000));
  const table = (await connection.getAddressLookupTable(tableAddress)).value!;
  const blockhash = await connection.getLatestBlockhash();
  const transaction = new VersionedTransaction(new TransactionMessage({ payerKey: manager.publicKey, recentBlockhash: blockhash.blockhash,
    instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }), swap, open] }).compileToV0Message([table]));
  transaction.sign([manager, mint]);
  assert.ok(transaction.serialize().length <= 1232);
  const badOpen = new TransactionInstruction({ programId: open.programId, keys: open.keys, data: Buffer.from(open.data) });
  badOpen.data.writeBigUInt64LE((1n << 64n) - 1n, 36);
  const failedAtomic = new VersionedTransaction(new TransactionMessage({ payerKey: manager.publicKey, recentBlockhash: blockhash.blockhash,
    instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }), swap, badOpen] }).compileToV0Message([table]));
  failedAtomic.sign([manager, mint]);
  const atomicBefore = await connection.getMultipleAccountsInfo([publicKey(config), publicKey(ledger(ADDRESSES.usdc)), publicKey(ledger(ADDRESSES.wsol)), usdc, testAta(ADDRESSES.wsol, vault)]);
  const failedSimulation = await connection.simulateTransaction(failedAtomic, { sigVerify: true });
  assert.ok(failedSimulation.value.err);
  assert.ok(failedSimulation.value.logs?.some(log => log.includes('Instruction: RouteV2')));
  assert.ok(failedSimulation.value.logs?.some(log => log.includes('Error Code: Slippage.')));
  const failedSignature = await connection.sendRawTransaction(failedAtomic.serialize(), { skipPreflight: true });
  assert.ok((await connection.confirmTransaction({ signature: failedSignature, ...blockhash }, 'confirmed')).value.err);
  const atomicAfter = await connection.getMultipleAccountsInfo([publicKey(config), publicKey(ledger(ADDRESSES.usdc)), publicKey(ledger(ADDRESSES.wsol)), usdc, testAta(ADDRESSES.wsol, vault)]);
  assert.deepEqual(atomicAfter.map(account => account!.data), atomicBefore.map(account => account!.data));
  const simulation = await connection.simulateTransaction(transaction, { sigVerify: true });
  assert.equal(simulation.value.err, null, simulation.value.logs?.join('\n'));
  const signature = await connection.sendRawTransaction(transaction.serialize());
  assert.equal((await connection.confirmTransaction({ signature, ...blockhash }, 'confirmed')).value.err, null);
  const metrics = { units: simulation.value.unitsConsumed, bytes: transaction.serialize().length, signature };
  console.log(`SIGNED SWAP + OPEN: ${JSON.stringify(metrics)}`);
  writeFileSync(new URL('../../.localnet/swap-production-metrics.json', import.meta.url), JSON.stringify(metrics, null, 2));
  assert.equal((await connection.getAccountInfo(publicKey(config)))!.data.readBigUInt64LE(72 + policy.length), 1n);
  await assert.rejects(sendMeasured(connection, manager, swap), /Replay/);

  const manifest = JSON.parse(readFileSync(new URL('../../.localnet/manifest.json', import.meta.url), 'utf8'));
  const fixture = manifest.pools.find((entry: any) => entry.address === ADDRESSES.solPool);
  const beforeTrade = decodePool((await connection.getAccountInfo(publicKey(ADDRESSES.solPool)))!.data);
  const start = Math.floor(beforeTrade.tickCurrent / (60 * pool.tickSpacing)) * 60 * pool.tickSpacing;
  const arrays = fixture.arrays.map((address: string) => ({ address, start: Buffer.from(JSON.parse(readFileSync(new URL(`../../.localnet/accounts/${address}.json`, import.meta.url), 'utf8')).account.data[0], 'base64').readInt32LE(40) }))
    .filter((entry: any) => entry.start >= start).sort((left: any, right: any) => left.start - right.start);
  const countertrade = new TransactionInstruction({ programId: publicKey(ADDRESSES.raydium), keys: [key(manager.publicKey, false, true), key(pool.config), key(ADDRESSES.solPool, true),
    key(testAta(ADDRESSES.usdc, manager.publicKey), true), key(testAta(ADDRESSES.wsol, manager.publicKey), true), key(pool.vault1, true), key(pool.vault0, true), key(pool.observation, true),
    key(ADDRESSES.token), key(ADDRESSES.token2022), key(lpAccounts.memo_program), key(ADDRESSES.usdc), key(ADDRESSES.wsol), key(bitmap, true), ...arrays.map((entry: any) => key(entry.address, true))],
    data: Buffer.concat([discriminator('global', 'swap_v2'), integer(1_000_000_000, 8), integer(1, 8), u128(beforeTrade.sqrtPriceX64 * 1001n / 1000n), Buffer.from([1])]) });
  await sendMeasured(connection, manager, countertrade);
  const prior = await connection.getMultipleAccountsInfo([publicKey(ledger(pool.mint0)), publicKey(ledger(pool.mint1))]);
  await sendMeasured(connection, manager, instruction('raydium_collect_fees', lpAccounts, Buffer.alloc(0)));
  const after = await connection.getMultipleAccountsInfo([publicKey(ledger(pool.mint0)), publicKey(ledger(pool.mint1))]);
  const fees = after.map((account, index) => {
    assert.equal(account!.data.readBigUInt64LE(72), prior[index]!.data.readBigUInt64LE(72), 'fees never increase principal');
    return account!.data.readBigUInt64LE(80) - prior[index]!.data.readBigUInt64LE(80);
  });
  assert.ok(fees[0] + fees[1] > 0n);
  for (const reward of rewards) assert.equal((await connection.getAccountInfo(publicKey(reward.quarantine)))!.data.readBigUInt64LE(64), 0n);
  console.log(`REAL FEES: ${fees.map(amount => amount.toString()).join(',')}; principal unchanged`);
  const message = Keypair.generate();
  const publish = instruction('publish_report', { ...common, authority: keeper.publicKey, wormhole_program: ADDRESSES.wormhole, emitter: target.emitter,
    bridge: foreign(ADDRESSES.wormhole, Buffer.from('Bridge')), sequence: foreign(ADDRESSES.wormhole, Buffer.from('Sequence'), publicKey(target.emitter).toBuffer()),
    fee_collector: foreign(ADDRESSES.wormhole, Buffer.from('fee_collector')), message: message.publicKey, clock: SYSVAR_CLOCK_PUBKEY, rent: SYSVAR_RENT_PUBKEY }, Buffer.alloc(0));
  publish.keys.push(...[ADDRESSES.usdc, ADDRESSES.wsol, NVDA].flatMap(mint => [key(ledger(mint)), key(testAta(mint, vault))]), key(NVDA),
    key(record), key(ADDRESSES.solPool), key(personal), key(array(lower)), key(array(upper)), key(pool.vault0), key(pool.vault1), key(transit));
  await sendMeasured(connection, keeper, publish, [message]);
  const posted = (await connection.getAccountInfo(message.publicKey))!.data;
  assert.equal(posted[4], 32);
  const report = posted.subarray(95);
  const readWord = (offset: number) => report.readBigUInt64BE(offset + 24);
  const collected = 64 + Number(readWord(64 + 10 * 32));
  assert.ok(readWord(collected) > 0n);
  const sum = Array.from({ length: Number(readWord(collected)) }, (_, index) => readWord(collected + 32 + index * 64 + 32)).reduce((total, amount) => total + amount, 0n);
  assert.equal(sum, fees[0] + fees[1]);
  const states = 64 + Number(readWord(64 + 17 * 32));
  assert.equal(readWord(states), 1n);
  assert.equal(readWord(states + 32 + 64), 0x3ff006f7d589fea9n);
  writeFileSync(new URL('../../.localnet/swap-production-report.hex', import.meta.url), `0x${report.toString('hex')}\n`);
  console.log(`REPORT: ${report.length} bytes; collected income=${sum}; NVDAx effective multiplier witness included`);
  assert.equal((await connection.getAccountInfo(vault))?.lamports ?? 0, 0);
  await sendMeasured(connection, manager, instruction('raydium_close_position', lpAccounts, Buffer.alloc(16)));
  assert.equal(await connection.getAccountInfo(publicKey(personal)), null);
  assert.equal((await connection.getAccountInfo(vault))?.lamports ?? 0, 0);
});
