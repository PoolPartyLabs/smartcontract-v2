import { readFileSync } from 'node:fs';
import { Connection, Keypair, PublicKey, TransactionInstruction, ComputeBudgetProgram,
  AddressLookupTableProgram, TransactionMessage, VersionedTransaction } from '@solana/web3.js';
import type { AccountMeta } from '@solana/web3.js';
import { ADDRESSES, publicKey } from '../helpers/addresses.ts';
import { discriminator } from '../helpers/layouts.ts';
import { requireLoopback, sendLocal } from '../helpers/localnet.ts';

export function u128(value: bigint) {
  const data = Buffer.alloc(16);
  data.writeBigUInt64LE(value & ((1n << 64n) - 1n), 0);
  data.writeBigUInt64LE(value >> 64n, 8);
  return data;
}

type IdlAccount = { name: string; writable?: boolean; signer?: boolean; optional?: boolean; address?: string; accounts?: IdlAccount[] };
export function instruction(name: string, accounts: Record<string, string | PublicKey | null>, payload: Buffer) {
  const idl = JSON.parse(readFileSync(new URL('../../target/idl/pp_spoke.json', import.meta.url), 'utf8'));
  const definition = idl.instructions.find((entry: any) => entry.name === name);
  function flatten(entries: IdlAccount[]): AccountMeta[] {
    return entries.flatMap(entry => {
      if (entry.accounts) return flatten(entry.accounts);
      const address = accounts[entry.name] ?? entry.address ?? (entry.optional ? ADDRESSES.spoke : undefined);
      if (!address) throw new Error(`Missing ${name} account ${entry.name}`);
      const omitted = entry.optional && address === ADDRESSES.spoke;
      return [{ pubkey: typeof address === 'string' ? publicKey(address) : address,
        isWritable: !omitted && !!entry.writable, isSigner: !omitted && !!entry.signer }];
    });
  }
  const length = Buffer.alloc(4);
  length.writeUInt32LE(payload.length);
  return new TransactionInstruction({ programId: publicKey(ADDRESSES.spoke), keys: flatten(definition.accounts),
    data: Buffer.concat([discriminator('global', name), length, payload]) });
}

export async function sendMeasured(connection: Connection, payer: Keypair, operation: TransactionInstruction, extraSigners: Keypair[] = []) {
  requireLoopback(connection.rpcEndpoint);
  const slot = await connection.getSlot('finalized');
  const [create, address] = AddressLookupTableProgram.createLookupTable({ authority: payer.publicKey, payer: payer.publicKey, recentSlot: slot });
  await sendLocal(connection, payer, [create]);
  const addresses = [...new Map(operation.keys.filter(meta => !meta.isSigner).map(meta => [meta.pubkey.toBase58(), meta.pubkey])).values()];
  for (let offset = 0; offset < addresses.length; offset += 20) {
    await sendLocal(connection, payer, [AddressLookupTableProgram.extendLookupTable({ lookupTable: address,
      authority: payer.publicKey, payer: payer.publicKey, addresses: addresses.slice(offset, offset + 20) })]);
  }
  const last = await connection.getSlot('confirmed');
  while (await connection.getSlot('confirmed') <= last) await new Promise(resolve => setTimeout(resolve, 100));
  const table = (await connection.getAddressLookupTable(address)).value!;
  const blockhash = await connection.getLatestBlockhash('confirmed');
  const message = new TransactionMessage({ payerKey: payer.publicKey, recentBlockhash: blockhash.blockhash,
    instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }), operation] }).compileToV0Message([table]);
  const transaction = new VersionedTransaction(message);
  transaction.sign([payer, ...extraSigners]);
  const serialized = transaction.serialize();
  const simulation = await connection.simulateTransaction(transaction, { commitment: 'confirmed', sigVerify: true });
  if (simulation.value.err) throw new Error(`Local simulation failed: ${JSON.stringify(simulation.value.err)}\n${simulation.value.logs?.join('\n')}`);
  const signature = await connection.sendRawTransaction(serialized, { preflightCommitment: 'confirmed' });
  const result = await connection.confirmTransaction({ signature, ...blockhash }, 'confirmed');
  if (result.value.err) throw new Error(`Local transaction failed: ${JSON.stringify(result.value.err)}`);
  console.log(`${operation.data.subarray(0, 8).toString('hex')}: ${simulation.value.unitsConsumed} CU; ${serialized.length} bytes; ${signature}`);
  return { signature, units: simulation.value.unitsConsumed, bytes: serialized.length };
}
