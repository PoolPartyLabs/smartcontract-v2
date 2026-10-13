import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Connection, PublicKey, Transaction, TransactionInstruction } from '@solana/web3.js';
import { testWallet } from '../tests/helpers/localnet.ts';

const port = process.env.PP_LOCALNET_RPC_PORT ?? '8983';
if (!/^\d+$/.test(port) || Number(port) > 65535) throw new Error('Invalid local port');
const connection = new Connection(`http://127.0.0.1:${port}`, 'confirmed');
const idl = JSON.parse(readFileSync(new URL('../target/idl/pp_spoke.json', import.meta.url)));
const program = new PublicKey(idl.address);
const base = PublicKey.findProgramAddressSync([], program)[0];
const idlAccount = await PublicKey.createWithSeed(base, 'anchor:idl', program);
assert.equal(await connection.getAccountInfo(idlAccount), null, 'No on-chain IDL account permitted');
const tag = Buffer.alloc(8);
tag.writeBigUInt64LE(0x0a69e9a778bcf440n);
const transaction = new Transaction({ feePayer: testWallet().publicKey,
  recentBlockhash: (await connection.getLatestBlockhash()).blockhash }).add(
  new TransactionInstruction({ programId: program, keys: [], data: tag }));
const result = await connection.simulateTransaction(transaction);
assert.ok(result.value.err);
assert.ok(result.value.logs?.some(line => line.includes('IdlInstructionStub')));
console.log('Off-chain IDL contains instructions/events; on-chain IDL absent; IDL dispatch rejects with IdlInstructionStub.');
