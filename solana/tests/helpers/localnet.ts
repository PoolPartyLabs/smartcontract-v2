import { readFileSync } from 'node:fs';
import { Connection, Keypair, PublicKey, Transaction, SendTransactionError, sendAndConfirmTransaction } from '@solana/web3.js';
import type { TransactionInstruction } from '@solana/web3.js';
import { ADDRESSES, derive, publicKey } from './addresses.ts';

export const LOCAL_RPC = 'http://127.0.0.1:8899';

export function requireLoopback(endpoint: string): string {
  const parsed = new URL(endpoint);
  if (parsed.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(parsed.hostname)
      || parsed.username || parsed.password || parsed.pathname !== '/' || parsed.search || parsed.hash) {
    throw new Error('Transactions are allowed only on an uncredentialed loopback HTTP RPC');
  }
  return endpoint;
}

export function localConnection(): Connection {
  return new Connection(requireLoopback(LOCAL_RPC), 'confirmed');
}

export function testWallet(role: 'manager' | 'keeper' = 'manager'): Keypair {
  return Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(new URL(`../../.localnet/${role}.json`, import.meta.url), 'utf8'))));
}

export function testAta(mint: string, owner: PublicKey): PublicKey {
  const token = mint === ADDRESSES.tslax ? ADDRESSES.token2022 : ADDRESSES.token;
  return publicKey(derive(ADDRESSES.ata, owner.toBuffer(), publicKey(token).toBuffer(), publicKey(mint).toBuffer()));
}

export async function fundSol(connection: Connection, wallet: PublicKey, sol = 10): Promise<void> {
  requireLoopback(connection.rpcEndpoint);
  const signature = await connection.requestAirdrop(wallet, sol * 1_000_000_000);
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    const status = (await connection.getSignatureStatuses([signature])).value[0];
    if (status?.err) throw new Error('Local airdrop failed');
    if (status?.confirmationStatus === 'confirmed' || status?.confirmationStatus === 'finalized') return;
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  throw new Error('Local airdrop did not confirm');
}

export async function sendLocal(connection: Connection, payer: Keypair, instructions: TransactionInstruction[]): Promise<string> {
  requireLoopback(connection.rpcEndpoint);
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      return await sendAndConfirmTransaction(connection, new Transaction().add(...instructions), [payer], { commitment: 'confirmed' });
    } catch (error) {
      if (!(error instanceof SendTransactionError) || error.signature !== ''
          || !error.transactionMessage.includes('Program cache hit max limit') || attempt === 4) throw error;
      await new Promise(resolve => setTimeout(resolve, 1000 * (attempt + 1)));
    }
  }
  throw new Error('Local validator program cache did not become ready');
}
