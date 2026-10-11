import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { Keypair, PublicKey, SystemProgram, SYSVAR_CLOCK_PUBKEY, SYSVAR_RENT_PUBKEY } from '@solana/web3.js';
import { ADDRESSES, publicKey, derive } from '../helpers/addresses.ts';
import { decodePool } from '../helpers/layouts.ts';
import { localConnection, requireLoopback, testWallet, testAta } from '../helpers/localnet.ts';
import { instruction, sendMeasured } from '../raydium/client.ts';
import { integer, word, fundId, addressWord } from '../core/fixtures.ts';
import { attest, evm } from '../cctp/fixtures.ts';
import { creation, productionApiKey, stageSwapPolicy } from '../swap/production-client.ts';
import { CLOSE_PENDING } from './close-pending.fixtures.ts';

// CR-28 / DEC-205: a Hub CLOSE cannot finalize, and the Fund cannot close, while USDC is in flight.
test('close is refused while an outbound CCTP transit is pending, then completes after the Hub ACK', { timeout: 600_000 }, async () => {
  const connection = localConnection(); requireLoopback(connection.rpcEndpoint);
  const manager = testWallet(); const keeper = testWallet('keeper');
  const vaas = JSON.parse(readFileSync(new URL('../../.localnet/close-pending-vaas.json', import.meta.url), 'utf8'));
  const { core, index } = CLOSE_PENDING;
  const pool = decodePool((await connection.getAccountInfo(publicKey(ADDRESSES.solPool)))!.data);
  const { payload, policyHash, target } = creation(manager.publicKey, core, index, pool, productionApiKey(), false);
  const fund = publicKey(target.fund); const vault = publicKey(target.vault);
  const pda = (...seeds: Buffer[]) => derive(ADDRESSES.spoke, ...seeds);
  const foreign = (program: string, ...seeds: Buffer[]) => derive(program, ...seeds);
  const ledger = (mint: string) => pda(Buffer.from('ledger'), fund.toBuffer(), publicKey(mint).toBuffer());
  const key = (address: string | PublicKey, writable = false, signer = false) => ({ pubkey: typeof address === 'string' ? publicKey(address) : address, isWritable: writable, isSigner: signer });
  const common = { authority: manager.publicKey, fund, vault, system_program: SystemProgram.programId };
  const route = pda(Buffer.from('cctp_route'), fund.toBuffer());
  const transportLedger = pda(Buffer.from('cctp_ledger'), fund.toBuffer());
  const usdc = testAta(ADDRESSES.usdc, vault);
  const fundState = async () => (await connection.getAccountInfo(fund))!.data;

  const { stage, instructions: stageInstructions } = stageSwapPolicy(manager.publicKey, fund, policyHash, payload);
  for (const chunk of stageInstructions) await sendMeasured(connection, manager, chunk);
  const init = instruction('initialize_fund', { ...common, usdc_mint: ADDRESSES.usdc, tslax_mint: ADDRESSES.tslax, wsol_mint: ADDRESSES.wsol,
    usdc_ata: usdc, tslax_ata: testAta(ADDRESSES.tslax, vault), wsol_ata: testAta(ADDRESSES.wsol, vault),
    usdc_ledger: ledger(ADDRESSES.usdc), tslax_ledger: ledger(ADDRESSES.tslax), wsol_ledger: ledger(ADDRESSES.wsol),
    cctp_route: route, cctp_ledger: transportLedger,
    token_program: ADDRESSES.token, token_2022_program: ADDRESSES.token2022, ata_program: ADDRESSES.ata }, Buffer.from([2]));
  init.keys.push(key(pda(Buffer.from('swap_config'), fund.toBuffer()), true), key(stage, true));
  await sendMeasured(connection, manager, init);
  // CR-28: prune_registry is Manager-bound; the keeper (or anyone else) cannot reshape the report registry.
  const prune = (signer: PublicKey) => instruction('prune_registry', { authority: signer, fund }, Buffer.alloc(0));
  const opened = await fundState();
  await assert.rejects(sendMeasured(connection, keeper, prune(keeper.publicKey)), /UnauthorizedManager/);
  assert.deepEqual(await fundState(), opened);
  await sendMeasured(connection, manager, prune(manager.publicKey));

  // Inbound CCTP Fast arrival (local attester fixture), credited to principal.
  const inbound = transitIn(CLOSE_PENDING.inbound);
  function transitIn(id: Buffer) { return pda(Buffer.from('transit_in'), fund.toBuffer(), id); }
  const transmitter = foreign(ADDRESSES.cctpTransmitter, Buffer.from('message_transmitter'));
  const messenger = foreign(ADDRESSES.cctpMessenger, Buffer.from('token_messenger'));
  const feeAta = testAta(ADDRESSES.usdc, new PublicKey((await connection.getAccountInfo(publicKey(messenger)))!.data.subarray(109, 141)));
  const arrival = Buffer.alloc(536);
  for (const [offset, value] of [[0, 1], [4, 3], [8, 5], [140, 1000], [144, 1000], [148, 1]]) arrival.writeUInt32BE(value, offset);
  CLOSE_PENDING.cctpNonce.copy(arrival, 12); evm('28b5a0e9c621a5badaa536219b3a228c8168cf5d').copy(arrival, 44);
  publicKey(ADDRESSES.cctpMessenger).toBuffer().copy(arrival, 76); vault.toBuffer().copy(arrival, 108);
  evm('af88d065e77c8cc2239327c5edb3a432268e5831').copy(arrival, 152); usdc.toBuffer().copy(arrival, 184);
  word(20_000_000).copy(arrival, 216); addressWord(core).copy(arrival, 248); word(10_000).copy(arrival, 280); word(100).copy(arrival, 312);
  Buffer.concat([word(1), fundId, word(42161), CLOSE_PENDING.inbound, word(0)]).copy(arrival, 376);
  const attestation = attest(arrival);
  const receive = instruction('receive_and_credit', { ...common, authority: keeper.publicKey, route, ledger: transportLedger,
    transit: inbound, usdc_ata: usdc, token_ledger: ledger(ADDRESSES.usdc) },
    Buffer.concat([CLOSE_PENDING.inbound, integer(arrival.length, 4), arrival, integer(attestation.length, 4), attestation]));
  receive.keys.push(key(keeper.publicKey, true, true), key(vault),
    key(foreign(ADDRESSES.cctpTransmitter, Buffer.from('message_transmitter_authority'), publicKey(ADDRESSES.cctpMessenger).toBuffer())),
    key(transmitter), key(foreign(ADDRESSES.cctpTransmitter, Buffer.from('used_nonce'), CLOSE_PENDING.cctpNonce), true), key(ADDRESSES.cctpMessenger), key(SystemProgram.programId),
    key(foreign(ADDRESSES.cctpTransmitter, Buffer.from('__event_authority'))), key(ADDRESSES.cctpTransmitter), key(messenger),
    key(foreign(ADDRESSES.cctpMessenger, Buffer.from('remote_token_messenger'), Buffer.from('3'))), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('token_minter'))),
    key(foreign(ADDRESSES.cctpMessenger, Buffer.from('local_token'), publicKey(ADDRESSES.usdc).toBuffer()), true),
    key(foreign(ADDRESSES.cctpMessenger, Buffer.from('token_pair'), Buffer.from('3'), evm('af88d065e77c8cc2239327c5edb3a432268e5831'))),
    key(feeAta, true), key(usdc, true), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('custody'), publicKey(ADDRESSES.usdc).toBuffer()), true),
    key(ADDRESSES.token), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('__event_authority'))), key(ADDRESSES.cctpMessenger), key(ADDRESSES.cctpTransmitter));
  await sendMeasured(connection, keeper, receive);
  const principal = (await connection.getAccountInfo(publicKey(ledger(ADDRESSES.usdc))))!.data.readBigUInt64LE(72);
  assert.equal(principal, 19_999_900n);

  // All principal home over CCTP: the outbound claim stays pending until the Hub ACK.
  const outbound = pda(Buffer.from('transit_out'), fund.toBuffer(), CLOSE_PENDING.outbound);
  const event = Keypair.generate();
  const burn = instruction('send_to_hub', { ...common, route, ledger: transportLedger, transit: outbound, usdc_ata: usdc,
    token_ledger: ledger(ADDRESSES.usdc), event_account: event.publicKey }, Buffer.concat([CLOSE_PENDING.outbound, integer(principal, 8), integer(1000, 8)]));
  burn.keys.push(...[key(vault), key(manager.publicKey, true, true), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('sender_authority'))), key(usdc, true),
    key(foreign(ADDRESSES.cctpMessenger, Buffer.from('denylist_account'), vault.toBuffer())), key(transmitter, true), key(messenger),
    key(foreign(ADDRESSES.cctpMessenger, Buffer.from('remote_token_messenger'), Buffer.from('3'))), key(foreign(ADDRESSES.cctpMessenger, Buffer.from('token_minter'))),
    key(foreign(ADDRESSES.cctpMessenger, Buffer.from('local_token'), publicKey(ADDRESSES.usdc).toBuffer()), true), key(ADDRESSES.usdc, true), key(event.publicKey, true, true),
    key(ADDRESSES.cctpTransmitter), key(ADDRESSES.cctpMessenger), key(ADDRESSES.token), key(SystemProgram.programId),
    key(foreign(ADDRESSES.cctpMessenger, Buffer.from('__event_authority'))), key(ADDRESSES.cctpMessenger), key(ADDRESSES.cctpMessenger)]);
  await sendMeasured(connection, manager, burn, [event]);
  assert.equal((await connection.getAccountInfo(publicKey(outbound)))!.data.at(-2), 0, 'outbound transit pending');

  // CR-16: the Fund's first Hub order is Wormhole sequence 0 and executes.
  const command = pda(Buffer.from('command'), fund.toBuffer(), Buffer.from(vaas.order, 'hex'));
  const close = instruction('execute_close_order', { ...common, authority: keeper.publicKey, wormhole_program: ADDRESSES.wormhole, posted_vaa: vaas.close }, Buffer.alloc(0));
  close.keys.push(key(command, true), key(ledger(ADDRESSES.usdc)));
  await sendMeasured(connection, keeper, close);
  assert.ok(await connection.getAccountInfo(publicKey(command)), 'CLOSE accepted at sequence 0');
  // Replay: verify_order runs before the command PDA is allocated, so sequence 0 < next (1) is the exact rejection.
  await assert.rejects(sendMeasured(connection, keeper, close), /Error Code: InvalidOrder\./);

  const reportAccounts = [ledger(ADDRESSES.usdc), usdc, ledger(ADDRESSES.wsol), testAta(ADDRESSES.wsol, vault)];
  const finalize = (transits: string[]) => {
    const operation = instruction('resume_command', { authority: manager.publicKey, fund, command, usdc_ledger: ledger(ADDRESSES.usdc), spoke_program: ADDRESSES.spoke }, Buffer.from([0]));
    // Exhaustive snapshot order: ledger/ATA pairs, registered transits, then registered commands.
    operation.keys.push(...[...reportAccounts, ...transits, command].map(address => key(address)));
    return operation;
  };
  const CLOSED = 162; // FundState.closed byte after discriminator and identity fields
  const beforeFinalize = await fundState();
  assert.equal(beforeFinalize[CLOSED], 0);
  await assert.rejects(sendMeasured(connection, manager, finalize([inbound, outbound])), /OrderExecutionNotIntegrated/);
  assert.deepEqual(await fundState(), beforeFinalize, 'refused close leaves the Fund unchanged');
  console.log('DEC-205: finalize refused with OrderExecutionNotIntegrated while the outbound transit is pending; Fund not closed');

  // Hub ACK at sequence 1 settles the claim; only then can the command complete and the final report close the Fund.
  const ack = instruction('execute_order', { ...common, authority: keeper.publicKey, wormhole_program: ADDRESSES.wormhole, posted_vaa: vaas.ack }, Buffer.alloc(0));
  ack.keys.push(key(outbound, true), key(transportLedger, true));
  await sendMeasured(connection, keeper, ack);
  assert.equal((await connection.getAccountInfo(publicKey(outbound)))!.data.at(-2), 1, 'outbound transit received');
  await sendMeasured(connection, manager, finalize([inbound]));
  const message = Keypair.generate();
  const publish = instruction('publish_report', { ...common, authority: keeper.publicKey, wormhole_program: ADDRESSES.wormhole, emitter: target.emitter,
    bridge: foreign(ADDRESSES.wormhole, Buffer.from('Bridge')), sequence: foreign(ADDRESSES.wormhole, Buffer.from('Sequence'), publicKey(target.emitter).toBuffer()),
    fee_collector: foreign(ADDRESSES.wormhole, Buffer.from('fee_collector')), message: message.publicKey, clock: SYSVAR_CLOCK_PUBKEY, rent: SYSVAR_RENT_PUBKEY }, Buffer.alloc(0));
  publish.keys.push(...[...reportAccounts, inbound, command].map(address => key(address)));
  await sendMeasured(connection, keeper, publish, [message]);
  const closed = await fundState();
  assert.equal(closed[CLOSED], 1, 'final report closed the Fund only after the transit settled');
  await assert.rejects(sendMeasured(connection, manager, prune(manager.publicKey)), /FundClosed/);
  assert.deepEqual(await fundState(), closed);
  console.log('DEC-205 positive control: ACK settled the transit, CLOSE finalized and the final report closed the Fund');
});
