import assert from 'node:assert/strict';
import test from 'node:test';
import { Keypair, TransactionInstruction, SystemProgram, SYSVAR_CLOCK_PUBKEY, SYSVAR_RENT_PUBKEY } from '@solana/web3.js';
import { ADDRESSES, derive, publicKey } from '../helpers/addresses.ts';
import { discriminator } from '../helpers/layouts.ts';
import { localConnection, testWallet, testAta } from '../helpers/localnet.ts';
import { addresses, integer, sendSignedLocal } from '../core/fixtures.ts';

test('build_report returns complete bytes and rejects missing ledger witnesses', async () => {
  const connection = localConnection();
  const keeper = testWallet('keeper');
  const ledger = publicKey(derive(ADDRESSES.spoke, Buffer.from('ledger'), publicKey(addresses.fund).toBuffer(), publicKey(ADDRESSES.usdc).toBuffer()));
  const vaultAta = testAta(ADDRESSES.usdc, publicKey(addresses.vault));
  const keys = [
    { pubkey: keeper.publicKey, isSigner: true, isWritable: true },
    { pubkey: publicKey(addresses.fund), isSigner: false, isWritable: true },
    { pubkey: publicKey(addresses.vault), isSigner: false, isWritable: true },
    { pubkey: publicKey(ADDRESSES.wormhole), isSigner: false, isWritable: false },
    { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    { pubkey: ledger, isSigner: false, isWritable: false },
    { pubkey: vaultAta, isSigner: false, isWritable: false },
  ];
  const data = Buffer.concat([discriminator('global', 'build_report'), integer(0, 4)]);
  const instruction = new TransactionInstruction({ programId: publicKey(ADDRESSES.spoke), keys, data });
  const signature = await sendSignedLocal(connection, keeper, [instruction]);
  const transaction = await connection.getTransaction(signature, { commitment: 'confirmed', maxSupportedTransactionVersion: 0 });
  const returned = transaction?.meta?.returnData;
  assert.equal(returned?.programId, ADDRESSES.spoke);
  assert.equal(Buffer.from(returned!.data[0], 'base64').length, 992);
  const withoutWitnesses = new TransactionInstruction({ programId: instruction.programId, keys: keys.slice(0, 5), data });
  const before = (await connection.getAccountInfo(publicKey(addresses.fund)))!.data;
  await assert.rejects(sendSignedLocal(connection, keeper, [withoutWitnesses]), /InvalidAccounts/);
  assert.deepEqual((await connection.getAccountInfo(publicKey(addresses.fund)))!.data, before);
});

test('spoke CPI posts two canonical v6 reports on cloned Wormhole with Finalized=32', async () => {
  const connection = localConnection();
  const keeper = testWallet('keeper');
  const sequence = publicKey(derive(ADDRESSES.wormhole, Buffer.from('Sequence'), publicKey(addresses.emitter).toBuffer()));
  const bridge = publicKey(derive(ADDRESSES.wormhole, Buffer.from('Bridge')));
  const collector = publicKey(derive(ADDRESSES.wormhole, Buffer.from('fee_collector')));
  const ledger = publicKey(derive(ADDRESSES.spoke, Buffer.from('ledger'), publicKey(addresses.fund).toBuffer(), publicKey(ADDRESSES.usdc).toBuffer()));
  const vaultAta = testAta(ADDRESSES.usdc, publicKey(addresses.vault));
  const custodyBefore = await connection.getAccountInfo(vaultAta);
  const bridgeData = (await connection.getAccountInfo(bridge))!.data;
  assert.equal(bridgeData.readBigUInt64LE(16), 100n);
  const fundBefore = (await connection.getAccountInfo(publicKey(addresses.fund)))!.data;
  const initialReport = fundBefore.readBigUInt64LE(146);
  const sequenceBefore = await connection.getAccountInfo(sequence);
  const initialSequence = sequenceBefore ? sequenceBefore.data.readBigUInt64LE(0) : 0n;
  for (let index = 0; index < 2; index++) {
    const message = Keypair.generate();
    const keys = [
      { pubkey: keeper.publicKey, isSigner: true, isWritable: true },
      { pubkey: publicKey(addresses.fund), isSigner: false, isWritable: true },
      { pubkey: publicKey(addresses.vault), isSigner: false, isWritable: true },
      { pubkey: publicKey(ADDRESSES.wormhole), isSigner: false, isWritable: false },
      { pubkey: publicKey(addresses.emitter), isSigner: false, isWritable: false },
      { pubkey: bridge, isSigner: false, isWritable: true },
      { pubkey: sequence, isSigner: false, isWritable: true },
      { pubkey: collector, isSigner: false, isWritable: true },
      { pubkey: message.publicKey, isSigner: true, isWritable: true },
      { pubkey: SYSVAR_CLOCK_PUBKEY, isSigner: false, isWritable: false },
      { pubkey: SYSVAR_RENT_PUBKEY, isSigner: false, isWritable: false },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
      { pubkey: ledger, isSigner: false, isWritable: false },
      { pubkey: vaultAta, isSigner: false, isWritable: false },
    ];
    const instruction = new TransactionInstruction({ programId: publicKey(ADDRESSES.spoke), keys,
      data: Buffer.concat([discriminator('global', 'publish_report'), integer(0, 4)]) });
    const collectorBefore = await connection.getBalance(collector);
    const signature = await sendSignedLocal(connection, keeper, [instruction], [message]);
    const posted = (await connection.getAccountInfo(message.publicKey))!;
    assert.equal(posted.owner.toBase58(), ADDRESSES.wormhole);
    assert.equal(posted.data.subarray(0, 3).toString(), 'msg');
    assert.equal(posted.data[4], 32);
    assert.equal(posted.data.readBigUInt64LE(49), initialSequence + BigInt(index));
    assert.deepEqual(posted.data.subarray(59, 91), publicKey(addresses.emitter).toBuffer());
    const payload = posted.data.subarray(95);
    assert.equal(payload.length, posted.data.readUInt32LE(91));
    assert.equal(payload.readBigUInt64BE(24), 6n);
    assert.equal(payload.readBigUInt64BE(56), 64n);
    assert.equal(payload.readBigUInt64BE(64 + 3 * 32 + 24), initialReport + BigInt(index) + 1n);
    const offset = Number(payload.readBigUInt64BE(64 + 7 * 32 + 24));
    assert.equal(payload.readBigUInt64BE(64 + offset + 24), 1n);
    assert.deepEqual(payload.subarray(64 + offset + 32, 64 + offset + 64), publicKey(ADDRESSES.usdc).toBuffer());
    assert.equal(payload.readBigUInt64BE(64 + offset + 64 + 24), 50_000_000n);
    assert.equal(await connection.getBalance(collector), collectorBefore + 100);
    const transaction = await connection.getTransaction(signature, { commitment: 'confirmed', maxSupportedTransactionVersion: 0 });
    assert.ok(transaction?.meta?.logMessages?.some(log => log.includes(`Program ${ADDRESSES.wormhole} success`)));
    assert.ok(transaction?.meta?.logMessages?.some(log => log.includes(`Program ${ADDRESSES.spoke} success`)));
    console.log(`Report ${initialReport + BigInt(index) + 1n}: ${payload.length} bytes; Wormhole sequence ${initialSequence + BigInt(index)}; ${transaction?.meta?.computeUnitsConsumed} CU; fee 100 lamports; Finalized 32.`);
  }
  assert.deepEqual((await connection.getAccountInfo(vaultAta))?.data, custodyBefore?.data);
  assert.equal((await connection.getAccountInfo(sequence))!.data.readBigUInt64LE(0), initialSequence + 2n);
});
