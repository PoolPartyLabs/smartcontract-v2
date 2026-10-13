import assert from 'node:assert/strict';
import { SystemProgram, Transaction, TransactionInstruction } from '@solana/web3.js';
import type { Connection, Keypair, PublicKey } from '@solana/web3.js';
import { ADDRESSES, publicKey } from './addresses.ts';
import { discriminator } from './layouts.ts';
import { requireLoopback } from './localnet.ts';

export async function rejectIncompleteReport(connection: Connection, payer: Keypair, fund: PublicKey, vault: PublicKey, error: string) {
  requireLoopback(connection.rpcEndpoint);
  const instruction = new TransactionInstruction({ programId: publicKey(ADDRESSES.spoke), keys: [
    { pubkey: payer.publicKey, isSigner: true, isWritable: true },
    { pubkey: fund, isSigner: false, isWritable: true },
    { pubkey: vault, isSigner: false, isWritable: true },
    { pubkey: publicKey(ADDRESSES.wormhole), isSigner: false, isWritable: false },
    { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
  ], data: Buffer.concat([discriminator('global', 'build_report'), Buffer.alloc(4)]) });
  const transaction = new Transaction({ feePayer: payer.publicKey, recentBlockhash: (await connection.getLatestBlockhash()).blockhash }).add(instruction);
  transaction.sign(payer);
  const result = await connection.simulateTransaction(transaction);
  assert.ok(result.value.err);
  assert.ok(result.value.logs?.some(line => line.includes(error)), result.value.logs?.join('\n'));
}
