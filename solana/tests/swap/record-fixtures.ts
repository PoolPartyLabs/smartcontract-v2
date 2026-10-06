import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { PublicKey } from '@solana/web3.js';
import { JupiterClient } from '../../clients/swap/jupiter.ts';
import { ADDRESSES, publicKey } from '../helpers/addresses.ts';

const rpcEndpoint = process.env.SOLANA_MAINNET_RPC ?? 'https://api.mainnet-beta.solana.com';
const client = new JupiterClient(process.env.JUPITER_API_KEY);
export const PROBE = new PublicKey(Buffer.alloc(32, 77));
export const FUND = new PublicKey(Buffer.alloc(32, 78));
export const VAULT = PublicKey.findProgramAddressSync([Buffer.from('vault'), FUND.toBuffer()], PROBE)[0];
const outputMints = { tslax: ADDRESSES.tslax, nvdax: 'Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh', wsol: ADDRESSES.wsol };
const snapshots = new Map<string, any>();
let latestSlot = 0;

async function clone(address: string): Promise<void> {
  if (snapshots.has(address)) return;
  for (let attempt = 0; attempt < 4; attempt++) {
    await new Promise(resolve => setTimeout(resolve, 450 * 2 ** attempt));
    let response: Response;
    try {
      response = await fetch(rpcEndpoint, { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'getAccountInfo', params: [address, { encoding: 'base64', commitment: 'finalized' }] }) });
    } catch { throw new Error('Read-only clone request failed'); }
    if (response.status === 429 && attempt < 3) continue;
    if (!response.ok) throw new Error(`Read-only clone HTTP ${response.status}`);
    const result = await response.json();
    if (result.error) throw new Error(`Read-only clone RPC error ${result.error.code}`);
    latestSlot = Math.max(latestSlot, result.result.context.slot);
    const account = result.result.value;
    snapshots.set(address, account ? { pubkey: address, account: { ...account, rentEpoch: 0 } } : null);
    if (account?.executable && account.owner === ADDRESSES.loader) {
      const data = Buffer.from(account.data[0], 'base64');
      if (data.length !== 36 || data.readUInt32LE(0) !== 2) throw new Error('Unexpected upgradeable program');
      await clone(new PublicKey(data.subarray(4)).toBase58());
    }
    return;
  }
}

async function main() {
  mkdirSync(new URL('./fixtures/', import.meta.url), { recursive: true });
  const allAccounts = new Set<string>();
  for (const [pair, mint] of Object.entries(outputMints)) {
    const tokenProgram = pair === 'wsol' ? ADDRESSES.token : ADDRESSES.token2022;
    const outputAta = PublicKey.findProgramAddressSync([VAULT.toBuffer(), publicKey(tokenProgram).toBuffer(), publicKey(mint).toBuffer()], publicKey(ADDRESSES.ata))[0];
    const recorded = process.argv.includes('--replay')
      ? JSON.parse(readFileSync(new URL(`./fixtures/${pair}.json`, import.meta.url), 'utf8')) : null;
    const quote = recorded?.quote ?? await client.quote(ADDRESSES.usdc, mint, 15_000_000n, 200);
    const instructions = recorded?.instructions ?? await client.instructions(quote, VAULT.toBase58(), outputAta.toBase58());
    for (const account of instructions.swapInstruction.accounts) allAccounts.add(account.pubkey);
    for (const address of instructions.addressLookupTableAddresses) allAccounts.add(address);
    allAccounts.add(mint);
    writeFileSync(new URL(`./fixtures/${pair}.json`, import.meta.url), JSON.stringify({ pair, probe: PROBE.toBase58(), fund: FUND.toBase58(), vault: VAULT.toBase58(), quote, instructions }, null, 2) + '\n');
    console.log(`${recorded ? 'Replayed' : 'Recorded real'} ${pair} quote/instruction: ${instructions.swapInstruction.accounts.length} route accounts`);
  }
  allAccounts.add(ADDRESSES.usdc);
  for (const address of allAccounts) await clone(address);
  mkdirSync(new URL('../../.localnet/accounts/', import.meta.url), { recursive: true });
  const accounts: { address: string; owner: string; executable: boolean; sha256: string }[] = [];
  const absent: string[] = [];
  for (const [address, snapshot] of snapshots) {
    if (!snapshot) { absent.push(address); continue; }
    writeFileSync(new URL(`../../.localnet/accounts/${address}.json`, import.meta.url), JSON.stringify(snapshot));
    accounts.push({ address, owner: snapshot.account.owner, executable: snapshot.account.executable,
      sha256: createHash('sha256').update(Buffer.from(snapshot.account.data[0], 'base64')).digest('hex') });
  }
  writeFileSync(new URL('./fixtures/clone-extension.json', import.meta.url), JSON.stringify({ latestSlot, accounts, absent }, null, 2) + '\n');
  console.log(`Read-only extension: ${accounts.length} accounts, ${absent.length} absent user/optional accounts, finalized slot ${latestSlot}`);
}

await main();
