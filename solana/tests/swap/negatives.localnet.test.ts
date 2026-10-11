// GO-2 negative sweep (from the 2026-10-09 e2e sweep, adopted by fix-sp / POO-2263).
// Runs on a fresh signed-production genesis (production.prepare.ts + production.start.sh), not the default gate:
// it waits until the cloned Pyth SOL/USD is older than the sealed 300 s to prove Stale.
// Each negative must reject with the exact named Anchor error and leave state unchanged.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import test from 'node:test';
import { Keypair, PublicKey, SystemProgram, TransactionInstruction, SYSVAR_RENT_PUBKEY,
  ComputeBudgetProgram, TransactionMessage, VersionedTransaction, AddressLookupTableProgram } from '@solana/web3.js';
import { ADDRESSES, publicKey, derive } from '../helpers/addresses.ts';
import { positionRegistry } from '../helpers/fund-state.ts';
import { decodePool, discriminator } from '../helpers/layouts.ts';
import { localConnection, requireLoopback, testWallet, testAta, sendLocal } from '../helpers/localnet.ts';
import { instruction, sendMeasured, u128 } from '../raydium/client.ts';
import { integer, word, fundId, addressWord } from '../core/fixtures.ts';
import { attest, evm } from '../cctp/fixtures.ts';
import { creation, productionApiKey, stageSwapPolicy, signedSwap, NVDA, SOL_PRICE } from '../swap/production-client.ts';

type Result = { case: string; expected: string; actual: string; number?: number; units?: number; stateUnchanged?: boolean };
const results: Result[] = [];
const failures: string[] = [];
const out = new URL('../../.localnet/e2e-negatives.json', import.meta.url);

test('e2e negative sweep on signed-production genesis', { timeout: 1_500_000 }, async () => {
  const connection = localConnection(); requireLoopback(connection.rpcEndpoint);
  const manager = testWallet(); const keeper = testWallet('keeper');
  const core = Buffer.alloc(20, 0xc8); const apiKey = productionApiKey();
  const pool = decodePool((await connection.getAccountInfo(publicKey(ADDRESSES.solPool)))!.data);
  const { payload, policyHash, target } = creation(manager.publicKey, core, 18, pool, apiKey, true);
  const fund = publicKey(target.fund); const vault = publicKey(target.vault);
  const ledger = (mint: string) => derive(ADDRESSES.spoke, Buffer.from('ledger'), fund.toBuffer(), publicKey(mint).toBuffer());
  const pda = (...seeds: Buffer[]) => derive(ADDRESSES.spoke, ...seeds);
  const foreign = (program: string, ...seeds: Buffer[]) => derive(program, ...seeds);
  const config = pda(Buffer.from('swap_config'), fund.toBuffer());
  const common = { authority: manager.publicKey, fund, vault, system_program: SystemProgram.programId };
  const asKeeper = { ...common, authority: keeper.publicKey };
  const key = (address: string | PublicKey, writable = false, signer = false) => ({ pubkey: typeof address === 'string' ? publicKey(address) : address, isWritable: writable, isSigner: signer });

  // One shared lookup table so most negatives can be simulated quickly in a single v0 packet.
  let table: any;
  async function lookup(addresses: PublicKey[]) {
    const slot = await connection.getSlot('finalized');
    const [create, address] = AddressLookupTableProgram.createLookupTable({ authority: manager.publicKey, payer: manager.publicKey, recentSlot: slot });
    await sendLocal(connection, manager, [create]);
    const unique = [...new Map(addresses.map(item => [item.toBase58(), item])).values()];
    for (let offset = 0; offset < unique.length; offset += 20) {
      await sendLocal(connection, manager, [AddressLookupTableProgram.extendLookupTable({ lookupTable: address, authority: manager.publicKey, payer: manager.publicKey, addresses: unique.slice(offset, offset + 20) })]);
    }
    const last = await connection.getSlot('confirmed');
    while (await connection.getSlot('confirmed') <= last + 1) await new Promise(resolve => setTimeout(resolve, 100));
    return (await connection.getAddressLookupTable(address)).value!;
  }
  async function snapshot(addresses: PublicKey[]) {
    return (await connection.getMultipleAccountsInfo(addresses)).map(account => account ? Buffer.from(account.data).toString('hex') + ':' + account.lamports : 'absent');
  }
  async function expectError(name: string, operation: TransactionInstruction, payer: Keypair, expected: string, watch: PublicKey[] = [fund], signers: Keypair[] = []) {
    const before = await snapshot(watch);
    const blockhash = await connection.getLatestBlockhash('confirmed');
    const tables = table ? [table] : [];
    const transaction = new VersionedTransaction(new TransactionMessage({ payerKey: payer.publicKey, recentBlockhash: blockhash.blockhash,
      instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units: 900_000 }), operation] }).compileToV0Message(tables));
    transaction.sign([payer, ...signers]);
    const simulation = await connection.simulateTransaction(transaction, { sigVerify: true, commitment: 'confirmed' });
    const line = simulation.value.logs?.find(log => log.includes('Error Code:')) ?? '';
    const match = /Error Code: (\w+)\. Error Number: (\d+)/.exec(line);
    const actual = simulation.value.err === null ? 'SUCCEEDED' : match?.[1] ?? JSON.stringify(simulation.value.err);
    const stateUnchanged = JSON.stringify(await snapshot(watch)) === JSON.stringify(before);
    results.push({ case: name, expected, actual, number: match ? Number(match[2]) : undefined, units: simulation.value.unitsConsumed, stateUnchanged });
    writeFileSync(out, JSON.stringify(results, null, 2));
    console.log(`NEGATIVE ${name}: expected ${expected}; actual ${actual}${match ? ` (${match[2]})` : ''}; CU ${simulation.value.unitsConsumed}`);
    if (actual !== expected || !stateUnchanged) failures.push(`${name}: expected ${expected}, actual ${actual}, stateUnchanged ${stateUnchanged}; ${simulation.value.logs?.slice(-4).join(' | ')}`);
  }

  // Bootstrap exactly as the production gate does.
  const { stage, instructions: stageInstructions } = stageSwapPolicy(manager.publicKey, fund, policyHash, payload);
  for (const operation of stageInstructions) await sendMeasured(connection, manager, operation);
  const init = instruction('initialize_fund', { ...common, usdc_mint: ADDRESSES.usdc, tslax_mint: ADDRESSES.tslax, wsol_mint: ADDRESSES.wsol,
    usdc_ata: testAta(ADDRESSES.usdc, vault), tslax_ata: testAta(ADDRESSES.tslax, vault), wsol_ata: testAta(ADDRESSES.wsol, vault),
    usdc_ledger: ledger(ADDRESSES.usdc), tslax_ledger: ledger(ADDRESSES.tslax), wsol_ledger: ledger(ADDRESSES.wsol),
    cctp_route: pda(Buffer.from('cctp_route'), fund.toBuffer()), cctp_ledger: pda(Buffer.from('cctp_ledger'), fund.toBuffer()),
    token_program: ADDRESSES.token, token_2022_program: ADDRESSES.token2022, ata_program: ADDRESSES.ata }, Buffer.from([2]));
  init.keys.push(key(config, true), key(stage, true), key(NVDA), key(testAta(NVDA, vault), true), key(ledger(NVDA), true));
  await sendMeasured(connection, manager, init);
  // Replay of initialization after the stage closed.
  await assert.rejects(sendMeasured(connection, manager, init));
  results.push({ case: 'initialize_fund replay after seal', expected: 'reject', actual: 'rejected (stage closed / Fund exists)' });

  // CCTP arrival negatives (production receive_and_credit entry).
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
  const transit = pda(Buffer.from('transit_in'), fund.toBuffer(), inbound);
  function receive(message: Buffer, signer = keeper.publicKey) {
    const attestation = attest(message);
    const operation = instruction('receive_and_credit', { ...common, authority: signer,
      route: pda(Buffer.from('cctp_route'), fund.toBuffer()), ledger: pda(Buffer.from('cctp_ledger'), fund.toBuffer()),
      transit, usdc_ata: usdc, token_ledger: ledger(ADDRESSES.usdc) },
      Buffer.concat([inbound, integer(message.length, 4), message, integer(attestation.length, 4), attestation]));
    operation.keys.push(key(signer, true, true), key(vault),
      key(foreign(ADDRESSES.cctpTransmitter, Buffer.from('message_transmitter_authority'), publicKey(ADDRESSES.cctpMessenger).toBuffer())),
      key(transmitter), key(foreign(ADDRESSES.cctpTransmitter, Buffer.from('used_nonce'), nonce), true), key(ADDRESSES.cctpMessenger), key(SystemProgram.programId),
      key(foreign(ADDRESSES.cctpTransmitter, Buffer.from('__event_authority'))), key(ADDRESSES.cctpTransmitter), key(messenger),
      key(foreign(ADDRESSES.cctpMessenger, Buffer.from('remote_token_messenger'), Buffer.from('3'))), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('token_minter'))),
      key(foreign(ADDRESSES.cctpMessenger, Buffer.from('local_token'), publicKey(ADDRESSES.usdc).toBuffer()), true),
      key(foreign(ADDRESSES.cctpMessenger, Buffer.from('token_pair'), Buffer.from('3'), evm('af88d065e77c8cc2239327c5edb3a432268e5831'))),
      key(feeAta, true), key(usdc, true), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('custody'), publicKey(ADDRESSES.usdc).toBuffer()), true),
      key(ADDRESSES.token), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('__event_authority'))), key(ADDRESSES.cctpMessenger), key(ADDRESSES.cctpTransmitter));
    return operation;
  }
  const valid = receive(arrival);
  table = await lookup(valid.keys.filter(meta => !meta.isSigner).map(meta => meta.pubkey));
  const cctpWatch = [fund, publicKey(ledger(ADDRESSES.usdc)), usdc, publicKey(transit)];
  const mutate = (offset: number, apply: (message: Buffer) => void) => { const message = Buffer.from(arrival); apply(message); return message; };
  await expectError('CCTP wrong Circle message sender (TokenMessenger)', receive(mutate(0, message => { message[60] ^= 1; })), keeper, 'WrongSender', cctpWatch);
  await expectError('CCTP wrong Hub core sender (messageSender)', receive(mutate(0, message => { message[260] ^= 1; })), keeper, 'WrongSender', cctpWatch);
  await expectError('CCTP wrong remote source domain (2 instead of Arbitrum 3)', receive(mutate(0, message => { message.writeUInt32BE(2, 4); })), keeper, 'InvalidMessage', cctpWatch);
  await expectError('CCTP wrong destination caller', receive(mutate(0, message => { message[120] ^= 1; })), keeper, 'WrongCaller', cctpWatch);
  await expectError('CCTP wrong burn token', receive(mutate(0, message => { message[170] ^= 1; })), keeper, 'WrongMint', cctpWatch);
  await expectError('CCTP maxFee above 5 bps ceiling', receive(mutate(0, message => { word(15_001).copy(message, 280); })), keeper, 'FeeCapExceeded', cctpWatch);
  await expectError('CCTP hook for another transit id', receive(mutate(0, message => { message[376 + 96 + 31] ^= 1; })), keeper, 'InvalidHook', cctpWatch);
  await sendMeasured(connection, keeper, valid);
  await assert.rejects(sendMeasured(connection, keeper, valid));
  results.push({ case: 'CCTP receive replay (same nonce/transit)', expected: 'reject', actual: 'rejected' });

  // Signed V2 swap negatives with the exact named error per case.
  const recorded = JSON.parse(readFileSync(new URL('../swap/fixtures/v2/wsol.json', import.meta.url), 'utf8'));
  const routeArrays = JSON.parse(readFileSync(new URL('../../.localnet/swap-production-route-arrays.json', import.meta.url), 'utf8'));
  routeArrays.slots.forEach((slot: number, index: number) => { recorded.build.swapInstruction.accounts[slot].pubkey = routeArrays.arrays[index]; });
  const swapWatch = [fund, publicKey(config), publicKey(ledger(ADDRESSES.usdc)), publicKey(ledger(ADDRESSES.wsol)), usdc, testAta(ADDRESSES.wsol, vault)];
  const probeSwap = signedSwap(recorded, common, core, apiKey, config, ledger);
  table = await lookup(probeSwap.keys.filter(meta => !meta.isSigner).map(meta => meta.pubkey));
  await expectError('API quote signed by wrong signer', signedSwap(recorded, common, core, apiKey, config, ledger, { forged: true }), manager, 'InvalidSignature', swapWatch);
  await expectError('API quote expired deadline', signedSwap(recorded, common, core, apiKey, config, ledger, { deadline: 1n }), manager, 'Expired', swapWatch);
  await expectError('API quote wrong nonce (1 before 0)', signedSwap(recorded, common, core, apiKey, config, ledger, { nonce: 1n }), manager, 'Replay', swapWatch);
  await expectError('price impact above Manager bound (1 bps, quote 1% under route)', signedSwap(recorded, common, core, apiKey, config, ledger, { impact: 1, outputBps: 9_900n }), manager, 'Impact', swapWatch);
  const stock = JSON.parse(readFileSync(new URL('../swap/fixtures/v2/nvdax.json', import.meta.url), 'utf8'));
  const stockSwap = signedSwap(stock, common, core, apiKey, config, ledger);
  table = await lookup(stockSwap.keys.filter(meta => !meta.isSigner).map(meta => meta.pubkey));
  await expectError('stock swap USDC->NVDAx with Scope OFF', stockSwap, manager, 'StockDisabled', swapWatch);
  table = await lookup(probeSwap.keys.filter(meta => !meta.isSigner).map(meta => meta.pubkey));
  await expectError('unbound signer: swap_to_ratio by keeper', signedSwap(recorded, asKeeper, core, apiKey, config, ledger), keeper, 'Unauthorized', swapWatch);

  // Raydium admission and position instructions with the keeper as signer.
  const lpPolicy = pda(Buffer.from('raydium_policy'), fund.toBuffer(), publicKey(ADDRESSES.solPool).toBuffer());
  const lpLedger = pda(Buffer.from('raydium_ledger'), fund.toBuffer(), publicKey(ADDRESSES.solPool).toBuffer());
  const adapter = (accounts: any) => instruction('initialize_adapter', { ...accounts, venue_program: ADDRESSES.raydium, venue: ADDRESSES.solPool,
    position_or_policy: lpPolicy, collateral_or_ledger: lpLedger, collateral_mint: ADDRESSES.usdc, token_program: ADDRESSES.token, ata_program: ADDRESSES.ata }, Buffer.alloc(0));
  table = undefined;
  await expectError('unbound signer: initialize_adapter by keeper', adapter(asKeeper), keeper, 'UnauthorizedManager', [fund, publicKey(lpPolicy)]);
  await sendMeasured(connection, manager, adapter(common));
  const mint = Keypair.generate(); const personal = foreign(ADDRESSES.raydium, Buffer.from('position'), mint.publicKey.toBuffer());
  const record = pda(Buffer.from('position'), fund.toBuffer(), publicKey(personal).toBuffer());
  const lower = Math.floor(pool.tickCurrent / pool.tickSpacing) * pool.tickSpacing - 10 * pool.tickSpacing;
  const upper = lower + 20 * pool.tickSpacing;
  const array = (tick: number) => { const start = Buffer.alloc(4); start.writeInt32BE(Math.floor(tick / (60 * pool.tickSpacing)) * 60 * pool.tickSpacing); return foreign(ADDRESSES.raydium, Buffer.from('tick_array'), publicKey(ADDRESSES.solPool).toBuffer(), start); };
  const bitmap = foreign(ADDRESSES.raydium, Buffer.from('pool_tick_array_bitmap_extension'), publicKey(ADDRESSES.solPool).toBuffer());
  const lp = (accounts: any, payer: PublicKey) => ({ ...accounts, raydium_program: ADDRESSES.raydium, policy: lpPolicy, ledger: lpLedger, position_record: record,
    nft_mint: mint.publicKey, nft_account: foreign(ADDRESSES.ata, vault.toBuffer(), publicKey(ADDRESSES.token2022).toBuffer(), mint.publicKey.toBuffer()),
    personal_position: personal, pool: ADDRESSES.solPool, protocol_position: ADDRESSES.raydium, tick_array_lower: array(lower), tick_array_upper: array(upper),
    token_account_0: testAta(pool.mint0, vault), token_account_1: testAta(pool.mint1, vault), token_vault_0: pool.vault0, token_vault_1: pool.vault1,
    rent: SYSVAR_RENT_PUBKEY, token_program: ADDRESSES.token, associated_token_program: ADDRESSES.ata, token_program_2022: ADDRESSES.token2022,
    mint_0: pool.mint0, mint_1: pool.mint1, bitmap, memo_program: 'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr', rent_payer: payer });
  const lpAccounts = lp(common, manager.publicKey); const keeperLp = lp(asKeeper, keeper.publicKey);
  const rewards = JSON.parse(readFileSync(new URL('../../.localnet/swap-production-rewards.json', import.meta.url), 'utf8'));
  for (const [index, reward] of rewards.entries()) for (const target of [lpAccounts, keeperLp]) Object.assign(target, {
    [`reward_vault_${index}`]: reward.vault, [`reward_quarantine_${index}`]: reward.quarantine, [`reward_mint_${index}`]: reward.mint });
  const ticks = Buffer.alloc(8); ticks.writeInt32LE(lower); ticks.writeInt32LE(upper, 4);
  const liquidity = 5_000_000_000n;
  const openPayload = Buffer.concat([ticks, u128(liquidity), integer(8_000_000, 8), integer(10_000_000, 8), u128(liquidity)]);
  const lpWatch = [fund, publicKey(lpLedger), publicKey(ledger(ADDRESSES.usdc)), publicKey(ledger(ADDRESSES.wsol)), usdc, testAta(ADDRESSES.wsol, vault)];
  table = await lookup(instruction('raydium_open_position', keeperLp, openPayload).keys.filter(meta => !meta.isSigner).map(meta => meta.pubkey));
  await expectError('unbound signer: raydium_open_position by keeper', instruction('raydium_open_position', keeperLp, openPayload), keeper, 'Unauthorized', lpWatch, [mint]);

  // Real signed swap + open (fresh oracle) so position-level negatives run against a live position.
  const swap = signedSwap(recorded, common, core, apiKey, config, ledger);
  const open = instruction('raydium_open_position', lpAccounts, openPayload);
  const both = await lookup([...swap.keys, ...open.keys].filter(meta => !meta.isSigner).map(meta => meta.pubkey));
  const blockhash = await connection.getLatestBlockhash();
  const transaction = new VersionedTransaction(new TransactionMessage({ payerKey: manager.publicKey, recentBlockhash: blockhash.blockhash,
    instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units: 900_000 }), swap, open] }).compileToV0Message([both]));
  transaction.sign([manager, mint]);
  const simulation = await connection.simulateTransaction(transaction, { sigVerify: true });
  assert.equal(simulation.value.err, null, simulation.value.logs?.join('\n'));
  const signature = await connection.sendRawTransaction(transaction.serialize());
  assert.equal((await connection.confirmTransaction({ signature, ...blockhash }, 'confirmed')).value.err, null);
  console.log(`E2E SWAP + OPEN: ${simulation.value.unitsConsumed} CU; ${transaction.serialize().length} bytes`);
  table = await lookup(instruction('raydium_collect_fees', keeperLp, Buffer.alloc(0)).keys.filter(meta => !meta.isSigner).map(meta => meta.pubkey));
  const positionWatch = [fund, publicKey(record), publicKey(personal), publicKey(lpLedger), usdc, testAta(ADDRESSES.wsol, vault)];
  await expectError('unbound signer: raydium_collect_fees by keeper', instruction('raydium_collect_fees', keeperLp, Buffer.alloc(0)), keeper, 'Unauthorized', positionWatch);
  await expectError('unbound signer: raydium_close_position by keeper (recorded rent payer)', instruction('raydium_close_position', { ...keeperLp, rent_payer: manager.publicKey }, Buffer.alloc(16)), keeper, 'Unauthorized', positionWatch);
  await expectError('raydium_decrease_position by keeper (fail-closed stub)', instruction('raydium_decrease_position', keeperLp, Buffer.alloc(0)), keeper, 'NotImplemented', positionWatch);
  await expectError('raydium_increase_position by keeper (fail-closed stub)', instruction('raydium_increase_position', keeperLp, Buffer.alloc(0)), keeper, 'NotImplemented', positionWatch);
  // CR-33: typed Fund, so the disabled entry fails closed with its own error instead of 3011.
  await expectError('swap_exact_in by keeper (fail-closed entry)', instruction('swap_exact_in', { ...asKeeper, swap_program: 'JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4' }, Buffer.alloc(0)), keeper, 'IntegrationPending', swapWatch);

  // CCTP send_to_hub with keeper as signer.
  const outbound = word(9802); const event = Keypair.generate();
  const route = pda(Buffer.from('cctp_route'), fund.toBuffer()); const transportLedger = pda(Buffer.from('cctp_ledger'), fund.toBuffer());
  const burn = instruction('send_to_hub', { ...asKeeper, route, ledger: transportLedger, transit: pda(Buffer.from('transit_out'), fund.toBuffer(), outbound), usdc_ata: usdc,
    token_ledger: ledger(ADDRESSES.usdc), event_account: event.publicKey }, Buffer.concat([outbound, integer(1_000_000, 8), integer(500, 8)]));
  burn.keys.push(...[key(vault), key(keeper.publicKey, true, true), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('sender_authority'))), key(usdc, true),
    key(foreign(ADDRESSES.cctpMessenger, Buffer.from('denylist_account'), vault.toBuffer())), key(transmitter, true), key(messenger), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('remote_token_messenger'), Buffer.from('3'))),
    key(foreign(ADDRESSES.cctpMessenger, Buffer.from('token_minter'))), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('local_token'), publicKey(ADDRESSES.usdc).toBuffer()), true), key(ADDRESSES.usdc, true), key(event.publicKey, true, true),
    key(ADDRESSES.cctpTransmitter), key(ADDRESSES.cctpMessenger), key(ADDRESSES.token), key(SystemProgram.programId), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('__event_authority'))), key(ADDRESSES.cctpMessenger), key(ADDRESSES.cctpMessenger)]);
  table = await lookup(burn.keys.filter(meta => !meta.isSigner).map(meta => meta.pubkey));
  await expectError('unbound signer: send_to_hub by keeper', burn, keeper, 'Unauthorized', [fund, publicKey(transportLedger), usdc, publicKey(ledger(ADDRESSES.usdc))], [event]);

  // Core Manager instructions (sweep/collect/refresh/prune) with keeper.
  table = undefined;
  for (const name of ['collect_income_all', 'refresh_income_results', 'sweep_excess']) {
    const operation = new TransactionInstruction({ programId: publicKey(ADDRESSES.spoke), keys: [key(keeper.publicKey, true, true), key(fund, true), key(vault, true), key(SystemProgram.programId)],
      data: Buffer.concat([discriminator('global', name), integer(0, 4)]) });
    await expectError(`unbound signer: ${name} by keeper`, operation, keeper, 'UnauthorizedManager', [fund]);
  }

  // CR-28: prune_registry is Manager-bound.
  const prune = (signer: PublicKey, extra: PublicKey[] = []) => new TransactionInstruction({ programId: publicKey(ADDRESSES.spoke),
    keys: [key(signer, false, true), key(fund, true), ...extra.map(item => key(item))], data: Buffer.concat([discriminator('global', 'prune_registry'), integer(0, 4)]) });
  await expectError('unbound signer: prune_registry by keeper, no entries', prune(keeper.publicKey), keeper, 'UnauthorizedManager', [fund]);
  await sendMeasured(connection, manager, instruction('raydium_close_position', lpAccounts, Buffer.alloc(16)));
  table = undefined;
  await expectError('unbound signer: prune_registry by keeper of a closed Raydium record', prune(keeper.publicKey, [publicKey(record)]), keeper, 'UnauthorizedManager', [fund]);
  assert.ok(positionRegistry((await connection.getAccountInfo(fund))!.data).includes(record));
  await sendLocal(connection, manager, [prune(manager.publicKey, [publicKey(record)])]);
  assert.ok(!positionRegistry((await connection.getAccountInfo(fund))!.data).includes(record));
  results.push({ case: 'prune_registry by Manager detaches the closed record', expected: 'SUCCEEDED', actual: 'SUCCEEDED' });

  // Stale primary oracle: wait until Pyth SOL publish_time is older than the sealed 300 s maximum.
  const pyth = (await connection.getAccountInfo(publicKey(SOL_PRICE)))!.data;
  const published = Number(pyth.readBigInt64LE(93));
  for (;;) {
    const now = await connection.getBlockTime(await connection.getSlot('confirmed'));
    if (now !== null && now - published > 305) break;
    await new Promise(resolve => setTimeout(resolve, 5000));
  }
  table = await lookup(probeSwap.keys.filter(meta => !meta.isSigner).map(meta => meta.pubkey));
  await expectError('stale Pyth SOL/USD (> sealed 300 s) on swap_to_ratio', signedSwap(recorded, common, core, apiKey, config, ledger, { nonce: 1n }), manager, 'Stale', swapWatch);
  writeFileSync(out, JSON.stringify({ results, failures }, null, 2));
  assert.deepEqual(failures, []);
});
