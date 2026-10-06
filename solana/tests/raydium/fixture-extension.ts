import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { PublicKey } from '@solana/web3.js';
import { ADDRESSES, derive, fundAddresses, publicKey } from '../helpers/addresses.ts';
import { discriminator, readKey } from '../helpers/layouts.ts';
import { testAta, testWallet } from '../helpers/localnet.ts';

const root = fileURLToPath(new URL('../../.localnet/', import.meta.url));
const memo = 'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr';
type Snapshot = { pubkey: string; account: { data: [string, string]; owner: string; executable: boolean; lamports: number; rentEpoch: number } };

function load(address: string): Snapshot {
  return JSON.parse(readFileSync(`${root}accounts/${address}.json`, 'utf8'));
}

function override(address: string, owner: string, data: Buffer, lamports = 20_000_000) {
  writeFileSync(`${root}overrides/${address}.json`, JSON.stringify({ pubkey: address, account: {
    data: [data.toString('base64'), 'base64'], owner, executable: false, lamports, rentEpoch: 0,
  } }));
}

async function clone(address: string) {
  if (existsSync(`${root}accounts/${address}.json`)) return;
  const endpoint = process.env.SOLANA_MAINNET_RPC ?? 'https://api.mainnet-beta.solana.com';
  const response = await fetch(endpoint, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'getAccountInfo', params: [address, { encoding: 'base64', commitment: 'finalized' }] }),
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error('Read-only fixture extension failed; endpoint suppressed');
  const result = await response.json() as any;
  if (!result.result?.value) throw new Error(`Required public fixture absent: ${address}`);
  const snapshot: Snapshot = { pubkey: address, account: { ...result.result.value, rentEpoch: 0 } };
  writeFileSync(`${root}accounts/${address}.json`, JSON.stringify(snapshot));
  if (snapshot.account.executable && snapshot.account.owner === ADDRESSES.loader) {
    await clone(readKey(Buffer.from(snapshot.account.data[0], 'base64'), 4));
  }
}

// DEC-190/193: only local T1 state is synthesized; cloned venue/mint state is untouched.
export async function extendFixtures() {
  mkdirSync(`${root}overrides`, { recursive: true });
  const manager = testWallet();
  const manifest = JSON.parse(readFileSync(`${root}manifest.json`, 'utf8'));
  await clone(memo);
  const fixtures = [];
  for (const [index, pool] of manifest.pools.entries()) {
    const hub = Buffer.alloc(20, index + 1);
    const addresses = fundAddresses(hub, 1);
    const fund = publicKey(addresses.fund);
    const vault = publicKey(addresses.vault);
    const fundBump = PublicKey.findProgramAddressSync([Buffer.from('fund'), hub, Buffer.from([1, 0])], publicKey(ADDRESSES.spoke))[1];
    const vaultBump = PublicKey.findProgramAddressSync([Buffer.from('vault'), fund.toBuffer()], publicKey(ADDRESSES.spoke))[1];
    const mandateHash = createHash('sha256').update(`local-raydium-mandate-${index}`).digest();
    const fundData = Buffer.concat([discriminator('account', 'FundState'), hub, Buffer.from([1, 0]),
      Buffer.alloc(32, index + 1), mandateHash, Buffer.alloc(20, 3), manager.publicKey.toBuffer(),
      Buffer.alloc(16), Buffer.from([0, fundBump, vaultBump])]);
    override(addresses.fund, ADDRESSES.spoke, fundData);
    override(addresses.vault, '11111111111111111111111111111111', Buffer.alloc(0), 0);
    const policy = derive(ADDRESSES.spoke, Buffer.from('raydium_policy'), fund.toBuffer(), publicKey(pool.address).toBuffer());
    const tickBounds = Buffer.alloc(8);
    tickBounds.writeInt32LE(-443636, 0);
    tickBounds.writeInt32LE(443636, 4);
    override(policy, ADDRESSES.spoke, Buffer.concat([discriminator('account', 'RaydiumPolicy'), fund.toBuffer(),
      mandateHash, publicKey(pool.address).toBuffer(), tickBounds, Buffer.from([1])]));
    const ledger = derive(ADDRESSES.spoke, Buffer.from('raydium_ledger'), fund.toBuffer(), publicKey(pool.address).toBuffer());
    const buckets = Buffer.alloc(32);
    buckets.writeBigUInt64LE(100_000_000_000n, 0);
    buckets.writeBigUInt64LE(100_000_000_000n, 8);
    override(ledger, ADDRESSES.spoke, Buffer.concat([discriminator('account', 'RaydiumLedger'), fund.toBuffer(), publicKey(pool.address).toBuffer(), buckets]));
    for (const [mint, tokenVault] of [[pool.mint0, pool.vault0], [pool.mint1, pool.vault1]]) {
      const template = load(tokenVault);
      const data = Buffer.from(template.account.data[0], 'base64');
      vault.toBuffer().copy(data, 32);
      data.writeBigUInt64LE(mint === ADDRESSES.tslax ? 100_000_000_000n : 1_000_000_000_000n, 64);
      data.fill(0, 72, 108);
      data[108] = 1;
      data.fill(0, 129, 165);
      override(testAta(mint, vault).toBase58(), template.account.owner, data);
      if (mint === ADDRESSES.wsol) {
        const managerData = Buffer.from(data);
        manager.publicKey.toBuffer().copy(managerData, 32);
        managerData.writeBigUInt64LE(0n, 64);
        override(testAta(mint, manager.publicKey).toBase58(), template.account.owner, managerData);
      }
    }
    const poolData = Buffer.from(load(pool.address).account.data[0], 'base64');
    const rewards = [];
    for (let slot = 0; slot < 3; slot++) {
      const offset = 397 + slot * 169;
      const mint = readKey(poolData, offset + 57);
      if (mint === '11111111111111111111111111111111') continue;
      const rewardVault = readKey(poolData, offset + 89);
      await clone(mint);
      await clone(rewardVault);
      const quarantine = derive(ADDRESSES.spoke, Buffer.from('raydium_reward'), fund.toBuffer(), publicKey(mint).toBuffer());
      const template = load(rewardVault);
      const data = Buffer.from(template.account.data[0], 'base64');
      vault.toBuffer().copy(data, 32);
      data.writeBigUInt64LE(0n, 64);
      data.fill(0, 72, 165);
      data[108] = 1;
      override(quarantine, template.account.owner, data);
      rewards.push({ mint, vault: rewardVault, quarantine });
    }
    fixtures.push({ ...pool, ...addresses, policy, ledger, rewards });
  }
  writeFileSync(`${root}raydium-fixtures.json`, JSON.stringify(fixtures, null, 2));
  console.log(`Raydium extension: ${fixtures.length} local Funds/policies; memo and reward accounts cloned read-only.`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  extendFixtures().catch(() => { console.error('Raydium fixture preparation failed; endpoint details suppressed.'); process.exitCode = 1; });
}
