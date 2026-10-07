import assert from 'node:assert/strict';
import test from 'node:test';
import { TransactionInstruction, SystemProgram, Keypair } from '@solana/web3.js';
import { ADDRESSES, fundAddresses, publicKey, derive } from '../helpers/addresses.ts';
import { discriminator } from '../helpers/layouts.ts';
import { localConnection, testWallet, testAta } from '../helpers/localnet.ts';
import { addresses, bindingPayload, integer, sendSignedLocal, mandateHash } from './fixtures.ts';

export function init(signer = testWallet('manager').publicKey, core = Buffer.alloc(20, 0x81), index = 2, payload = bindingPayload(signer, core, index)) {
  const target = fundAddresses(core, index, mandateHash);
  const vault = publicKey(target.vault);
  const fund = publicKey(target.fund);
  const keys = [
    { pubkey: signer, isSigner: true, isWritable: true },
    { pubkey: fund, isSigner: false, isWritable: true },
    { pubkey: vault, isSigner: false, isWritable: false },
    ...[ADDRESSES.usdc, ADDRESSES.tslax, ADDRESSES.wsol].map(mint => ({ pubkey: publicKey(mint), isSigner: false, isWritable: false })),
    ...[ADDRESSES.usdc, ADDRESSES.tslax, ADDRESSES.wsol].map(mint => ({ pubkey: testAta(mint, vault), isSigner: false, isWritable: true })),
    ...[ADDRESSES.usdc, ADDRESSES.tslax, ADDRESSES.wsol].map(mint => ({ pubkey: publicKey(derive(ADDRESSES.spoke, Buffer.from('ledger'), fund.toBuffer(), publicKey(mint).toBuffer())), isSigner: false, isWritable: true })),
    ...[ADDRESSES.token, ADDRESSES.token2022, ADDRESSES.ata].map(program => ({ pubkey: publicKey(program), isSigner: false, isWritable: false })),
    { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
  ];
  return new TransactionInstruction({ programId: publicKey(ADDRESSES.spoke), keys,
    data: Buffer.concat([discriminator('global', 'initialize_fund'), integer(payload.length, 4), payload]) });
}

test('valid dual-binding initializes mandate-qualified Fund without a Hub message', async () => {
  const connection = localConnection();
  const manager = testWallet('manager');
  const instruction = init();
  await sendSignedLocal(connection, manager, [instruction]);
  assert.equal((await connection.getAccountInfo(instruction.keys[1].pubkey))?.owner.toBase58(), ADDRESSES.spoke);
  await assert.rejects(sendSignedLocal(connection, manager, [instruction]), /InvalidConfiguration/);
});

test('wrong Solana signer, expired binding and claimed contract Manager fail', async () => {
  const connection = localConnection();
  const manager = testWallet('manager');
  const core = Buffer.alloc(20, 0x82);
  const wrong = bindingPayload(Keypair.generate().publicKey, core, 2);
  await assert.rejects(sendSignedLocal(connection, manager, [init(manager.publicKey, core, 2, wrong)]), /InvalidConfiguration|InvalidBinding/);
  const expired = bindingPayload(manager.publicKey, core, 2, 1n);
  await assert.rejects(sendSignedLocal(connection, manager, [init(manager.publicKey, core, 2, expired)]), /BindingExpired/);
  const contract = bindingPayload(manager.publicKey, core, 2);
  contract.fill(0xaa, 86, 106);
  await assert.rejects(sendSignedLocal(connection, manager, [init(manager.publicKey, core, 2, contract)]), /InvalidBinding/);
});

test('existing per-Fund PDA prevents initialization replay', async () => {
  const connection = localConnection();
  const manager = testWallet('manager');
  const core = Buffer.alloc(20, 0x71);
  const before = await connection.getAccountInfo(publicKey(addresses.fund));
  await assert.rejects(sendSignedLocal(connection, manager, [init(manager.publicKey, core, 1)]), /InvalidConfiguration/);
  assert.deepEqual((await connection.getAccountInfo(publicKey(addresses.fund)))?.data, before?.data);
});

test('sealed transport rejects substituted Circle targets, caller, custody and fee ceiling', async () => {
  const connection = localConnection();
  const manager = testWallet('manager');
  const core = Buffer.alloc(20, 0x83);
  const valid = bindingPayload(manager.publicKey, core, 2);
  for (const offset of [0, 20, 40, 60, 64, 96, 128, 160, 192]) {
    const changed = Buffer.from(valid);
    changed[changed.length - 200 + offset] ^= 1;
    await assert.rejects(sendSignedLocal(connection, manager, [init(manager.publicKey, core, 2, changed)]), /InvalidConfiguration/);
  }
  assert.equal(await connection.getAccountInfo(publicKey(fundAddresses(core, 2, mandateHash).fund)), null);
});

test('keeper cannot execute Manager instructions; Manager cannot choose excess recipient', async () => {
  const connection = localConnection();
  for (const name of ['collect_income_all', 'refresh_income_results', 'sweep_excess']) {
    function instruction(signer = testWallet('keeper').publicKey) {
      return new TransactionInstruction({ programId: publicKey(ADDRESSES.spoke), keys: [
        { pubkey: signer, isSigner: true, isWritable: true },
        { pubkey: publicKey(addresses.fund), isSigner: false, isWritable: true },
        { pubkey: publicKey(addresses.vault), isSigner: false, isWritable: true },
        { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
      ], data: Buffer.concat([discriminator('global', name), integer(0, 4)]) });
    }
    await assert.rejects(sendSignedLocal(connection, testWallet('keeper'), [instruction()]), /UnauthorizedManager/);
    await assert.rejects(sendSignedLocal(connection, testWallet('manager'), [instruction(testWallet('manager').publicKey)]),
      name === 'sweep_excess' ? /ExcessRecipientNotConfigured/ : /AdapterNotIntegrated/);
  }
});
