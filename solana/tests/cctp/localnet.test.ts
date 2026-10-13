import assert from 'node:assert/strict';
import { rejectIncompleteReport } from '../helpers/report-gate.ts';
import test from 'node:test';
import { AddressLookupTableProgram, ComputeBudgetProgram, Keypair, SystemProgram, TransactionInstruction, TransactionMessage, VersionedTransaction } from '@solana/web3.js';
import type { AccountMeta, Connection } from '@solana/web3.js';
import { ADDRESSES, derive, publicKey } from '../helpers/addresses.ts';
import { discriminator } from '../helpers/layouts.ts';
import { localConnection, requireLoopback, sendLocal, testWallet } from '../helpers/localnet.ts';
import { arrival, attest, CONNECTOR, evm, fund, FUND_ID, hook, ledger, recipient, route, uint64, vault, CHAIN } from './fixtures.ts';

const pda = (program: string, ...seeds: Buffer[]) => derive(program, ...seeds);
const key = (address: string, writable = false, signer = false): AccountMeta => ({ pubkey: publicKey(address), isWritable: writable, isSigner: signer });
const messenger = pda(ADDRESSES.cctpMessenger, Buffer.from('token_messenger'));
const transmitter = pda(ADDRESSES.cctpTransmitter, Buffer.from('message_transmitter'));
const remote = pda(ADDRESSES.cctpMessenger, Buffer.from('remote_token_messenger'), Buffer.from('3'));
const minter = pda(ADDRESSES.cctpMessenger, Buffer.from('token_minter'));
const localToken = pda(ADDRESSES.cctpMessenger, Buffer.from('local_token'), publicKey(ADDRESSES.usdc).toBuffer());
const eventAuthority = pda(ADDRESSES.cctpMessenger, Buffer.from('__event_authority'));
const transit = (id: Buffer) => pda(ADDRESSES.spoke, Buffer.from('transit'), publicKey(fund).toBuffer(), id);

function base(payer: Keypair, id: Buffer): AccountMeta[] {
  return [key(payer.publicKey.toBase58(), true, true), key(fund, true), key(vault), key(route), key(ledger, true), key(transit(id), true), key(recipient.toBase58(), true), key(derive(ADDRESSES.spoke, Buffer.from('ledger'), publicKey(fund).toBuffer(), publicKey(ADDRESSES.usdc).toBuffer()), true)];
}

function receive(payer: Keypair, id: Buffer, nonce: Buffer, message: Buffer, feeAta: string): TransactionInstruction {
  const circle = [key(payer.publicKey.toBase58(), true, true), key(vault),
    key(pda(ADDRESSES.cctpTransmitter, Buffer.from('message_transmitter_authority'), publicKey(ADDRESSES.cctpMessenger).toBuffer())),
    key(transmitter), key(pda(ADDRESSES.cctpTransmitter, Buffer.from('used_nonce'), nonce), true), key(ADDRESSES.cctpMessenger),
    key(SystemProgram.programId.toBase58()), key(pda(ADDRESSES.cctpTransmitter, Buffer.from('__event_authority'))), key(ADDRESSES.cctpTransmitter),
    key(messenger), key(remote), key(minter), key(localToken, true),
    key(pda(ADDRESSES.cctpMessenger, Buffer.from('token_pair'), Buffer.from('3'), evm('af88d065e77c8cc2239327c5edb3a432268e5831'))),
    key(feeAta, true), key(recipient.toBase58(), true), key(pda(ADDRESSES.cctpMessenger, Buffer.from('custody'), publicKey(ADDRESSES.usdc).toBuffer()), true),
    key(ADDRESSES.token), key(eventAuthority), key(ADDRESSES.cctpMessenger), key(ADDRESSES.cctpTransmitter)];
  const signature = attest(message);
  const messageLen = Buffer.alloc(4); messageLen.writeUInt32LE(message.length);
  const signatureLen = Buffer.alloc(4); signatureLen.writeUInt32LE(signature.length);
  const payload = Buffer.concat([id, messageLen, message, signatureLen, signature]);
  const length = Buffer.alloc(4); length.writeUInt32LE(payload.length);
  return new TransactionInstruction({ programId: publicKey(ADDRESSES.spoke), keys: [...base(payer, id), key(SystemProgram.programId.toBase58()), ...circle],
    data: Buffer.concat([discriminator('global', 'receive_and_credit'), length, payload]) });
}

function burn(payer: Keypair, id: Buffer, event: Keypair): TransactionInstruction {
  const circle = [key(vault), key(payer.publicKey.toBase58(), true, true), key(pda(ADDRESSES.cctpMessenger, Buffer.from('sender_authority'))),
    key(recipient.toBase58(), true), key(pda(ADDRESSES.cctpMessenger, Buffer.from('denylist_account'), publicKey(vault).toBuffer())),
    key(transmitter, true), key(messenger), key(remote), key(minter), key(localToken, true), key(ADDRESSES.usdc, true), key(event.publicKey.toBase58(), true, true),
    key(ADDRESSES.cctpTransmitter), key(ADDRESSES.cctpMessenger), key(ADDRESSES.token), key(SystemProgram.programId.toBase58()), key(eventAuthority), key(ADDRESSES.cctpMessenger), key(ADDRESSES.cctpMessenger)];
  const payload = Buffer.concat([id, uint64(1_000_000n), uint64(200n)]);
  const length = Buffer.alloc(4); length.writeUInt32LE(payload.length);
  return new TransactionInstruction({ programId: publicKey(ADDRESSES.spoke), keys: [...base(payer, id), key(event.publicKey.toBase58(), true, true), key(SystemProgram.programId.toBase58()), ...circle],
    data: Buffer.concat([discriminator('global', 'send_to_hub'), length, payload]) });
}

async function table(connection: Connection, payer: Keypair, instructions: TransactionInstruction[]) {
  requireLoopback(connection.rpcEndpoint);
  const slot = await connection.getSlot('finalized');
  const [create, address] = AddressLookupTableProgram.createLookupTable({ authority: payer.publicKey, payer: payer.publicKey, recentSlot: slot });
  await sendLocal(connection, payer, [create]);
  const addresses = [...new Map(instructions.flatMap(instruction => instruction.keys).filter(meta => !meta.isSigner).map(meta => [meta.pubkey.toBase58(), meta.pubkey])).values()];
  for (let offset = 0; offset < addresses.length; offset += 20) await sendLocal(connection, payer, [AddressLookupTableProgram.extendLookupTable({ lookupTable: address, authority: payer.publicKey, payer: payer.publicKey, addresses: addresses.slice(offset, offset + 20) })]);
  await new Promise(resolve => setTimeout(resolve, 1500));
  return (await connection.getAddressLookupTable(address)).value!;
}

test('real cloned Circle V2 burn and signed receive are atomic and replay-safe', { timeout: 240_000 }, async () => {
  const connection = localConnection();
  const manager = testWallet();
  const keeper = testWallet('keeper');
  const id = Buffer.alloc(32, 21);
  const nonce = Buffer.alloc(32, 22);
  const message = arrival(id, nonce);
  const messengerData = (await connection.getAccountInfo(publicKey(messenger)))!.data;
  const feeOwner = messengerData.subarray(109, 141);
  const feeAta = pda(ADDRESSES.ata, feeOwner, publicKey(ADDRESSES.token).toBuffer(), publicKey(ADDRESSES.usdc).toBuffer());
  const valid = receive(keeper, id, nonce, message, feeAta);
  const outboundId = Buffer.alloc(32, 23);
  const event = Keypair.generate();
  const outbound = burn(manager, outboundId, event);
  const badCaller = Buffer.from(message); badCaller.fill(33, 108, 140);
  const badRecipient = Buffer.from(message); badRecipient.fill(34, 184, 216);
  const badAttestation = receive(keeper, id, nonce, message, feeAta); badAttestation.data[badAttestation.data.length - 10] ^= 1;
  const unauthorized = burn(keeper, Buffer.alloc(32, 24), event);
  const lookup = await table(connection, manager, [valid, outbound, unauthorized]);
  const execute = async (payer: Keypair, instruction: TransactionInstruction, extra: Keypair[] = [], expect?: string) => {
    requireLoopback(connection.rpcEndpoint);
    const latest = await connection.getLatestBlockhash('confirmed');
    const transaction = new VersionedTransaction(new TransactionMessage({ payerKey: payer.publicKey, recentBlockhash: latest.blockhash,
      instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units: 800_000 }), instruction] }).compileToV0Message([lookup]));
    transaction.sign([payer, ...extra]);
    const simulation = await connection.simulateTransaction(transaction, { sigVerify: true, commitment: 'confirmed' });
    if (expect) {
      assert.ok(simulation.value.err);
      assert.ok(simulation.value.logs?.some(line => line.includes(expect)), simulation.value.logs?.join('\n'));
      return;
    }
    assert.equal(simulation.value.err, null, simulation.value.logs?.join('\n'));
    const signature = await connection.sendRawTransaction(transaction.serialize(), { preflightCommitment: 'confirmed' });
    assert.equal((await connection.confirmTransaction({ signature, ...latest }, 'confirmed')).value.err, null);
    console.log(`${instruction.data.subarray(0, 8).equals(discriminator('global', 'send_to_hub')) ? 'Burn' : 'Receive'} executed: ${simulation.value.unitsConsumed} CU; local transaction confirmed.`);
  };
  const before = BigInt((await connection.getTokenAccountBalance(recipient)).value.amount);
  const wrongAccounts = receive(keeper, id, nonce, message, feeAta);
  wrongAccounts.keys[19] = key(minter);
  await execute(keeper, wrongAccounts, [], 'InvalidAccount');
  const expired = Buffer.from(message);
  const expiry = Buffer.alloc(32); expiry.writeBigUInt64BE(1n, 24); expiry.copy(expired, 344);
  await execute(keeper, receive(keeper, id, nonce, expired, feeAta), [], 'MessageExpired');
  await execute(keeper, receive(keeper, id, nonce, badCaller, feeAta), [], 'WrongCaller');
  await execute(keeper, receive(keeper, id, nonce, badRecipient, feeAta), [], 'WrongRecipient');
  await execute(keeper, badAttestation, [], 'Error');
  await execute(keeper, unauthorized, [event], 'Unauthorized');
  assert.equal(BigInt((await connection.getTokenAccountBalance(recipient)).value.amount), before);
  assert.equal(await connection.getAccountInfo(publicKey(transit(id))), null);
  assert.equal(await connection.getAccountInfo(publicKey(pda(ADDRESSES.cctpTransmitter, Buffer.from('used_nonce'), nonce))), null);
  await execute(keeper, valid);
  assert.equal((await connection.getAccountInfo(publicKey(fund)))!.data.readUInt16LE(374), 1);
  await rejectIncompleteReport(connection, keeper, publicKey(fund), publicKey(vault), 'TransitNotIntegrated');
  assert.equal(BigInt((await connection.getTokenAccountBalance(recipient)).value.amount), before + 999_900n);
  const ledgerData = (await connection.getAccountInfo(publicKey(ledger)))!.data;
  assert.equal(ledgerData.readBigUInt64LE(40), 10_999_900n);
  assert.equal(ledgerData.readBigUInt64LE(72), 100n);
  await execute(keeper, valid, [], 'already in use');
  const freshNonceReplay = receive(keeper, id, Buffer.alloc(32, 25), arrival(id, Buffer.alloc(32, 25)), feeAta);
  await execute(keeper, freshNonceReplay, [], 'already in use');
  assert.equal(BigInt((await connection.getTokenAccountBalance(recipient)).value.amount), before + 999_900n);
  await execute(manager, outbound, [event]);
  assert.equal((await connection.getAccountInfo(publicKey(fund)))!.data.readUInt16LE(374), 2);
  assert.equal(BigInt((await connection.getTokenAccountBalance(recipient)).value.amount), before - 100n);
  const afterLedger = (await connection.getAccountInfo(publicKey(ledger)))!.data;
  assert.equal(afterLedger.readBigUInt64LE(48), 1_000_000n);
  assert.equal(afterLedger.readBigUInt64LE(56), 999_800n);
  const eventData = (await connection.getAccountInfo(event.publicKey))!.data;
  assert.ok(eventData.subarray(8, 40).equals(manager.publicKey.toBuffer()));
  assert.ok(eventData.includes(evm(CONNECTOR)));
  assert.ok(eventData.includes(hook(outboundId, CHAIN)));
  assert.ok(eventData.includes(FUND_ID));
  const sourceMessage = Buffer.from(eventData.subarray(52));
  sourceMessage.fill(26, 12, 44);
  sourceMessage.writeUInt32BE(1000, 144);
  const reclaimAttestation = attest(sourceMessage);
  const attestationLength = Buffer.alloc(4); attestationLength.writeUInt32LE(reclaimAttestation.length);
  const destinationLength = Buffer.alloc(4); destinationLength.writeUInt32LE(sourceMessage.length);
  const reclaim = new TransactionInstruction({ programId: publicKey(ADDRESSES.cctpTransmitter), keys: [key(manager.publicKey.toBase58(), true, true), key(transmitter, true), key(event.publicKey.toBase58(), true)],
    data: Buffer.concat([discriminator('global', 'reclaim_event_account'), attestationLength, reclaimAttestation, destinationLength, sourceMessage]) });
  await execute(manager, reclaim, [], 'EventAccountWindowNotExpired');
  assert.ok(await connection.getAccountInfo(event.publicKey));
  assert.equal((await connection.getAccountInfo(publicKey(vault)))?.lamports ?? 0, 0);
  console.log('Wrong caller/recipient/signature/Manager/CPI accounts, expired attestation rollback/manual retry, exact deltas, business replay with new nonce, fee surplus, persistent burn, early rent-reclaim rejection and no Fund SOL verified.');
});
