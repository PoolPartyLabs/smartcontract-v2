import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { PublicKey } from '@solana/web3.js';
import { ADDRESSES } from '../helpers/addresses.ts';
import { testAta, testWallet } from '../helpers/localnet.ts';
import { decodePool } from '../helpers/layouts.ts';
import { creation, productionApiKey, NVDA, NVDA_POOL, SOL_PRICE, USDC_PRICE, CROSS_CHECK } from './production-client.ts';
import { prepareCctpFixtures } from '../cctp/fixtures.ts';

const root = new URL('../../.localnet/', import.meta.url);
const endpoint = process.env.SOLANA_MAINNET_RPC ?? 'https://api.mainnet-beta.solana.com';
const evidence: { address: string; slot: number; sha256: string }[] = [];
async function clone(address: string) {
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      const response = await fetch(endpoint, { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'getAccountInfo', params: [address, { commitment: 'finalized', encoding: 'base64' }] }),
        signal: AbortSignal.timeout(30_000) });
      const body = await response.json() as any;
      if (!response.ok || body.error || !body.result?.value) throw new Error('clone unavailable');
      const snapshot = { pubkey: address, account: { ...body.result.value, rentEpoch: 0 } };
      const data = Buffer.from(snapshot.account.data[0], 'base64');
      evidence.push({ address, slot: body.result.context.slot, sha256: createHash('sha256').update(data).digest('hex') });
      writeFileSync(new URL(`accounts/${address}.json`, root), JSON.stringify(snapshot));
      return snapshot;
    } catch {
      if (attempt === 4) throw new Error('Read-only production fixture clone failed; endpoint suppressed');
      await new Promise(resolve => setTimeout(resolve, 500 * 2 ** attempt));
    }
  }
  throw new Error('Read-only clone unavailable');
}

const snapshot = await clone(NVDA_POOL);
const pool = decodePool(Buffer.from(snapshot.account.data[0], 'base64'));
for (const address of [NVDA, pool.config, pool.vault0, pool.vault1, pool.observation, SOL_PRICE, USDC_PRICE, CROSS_CHECK]) await clone(address);
const span = pool.tickSpacing * 60;
const start = Math.floor(pool.tickCurrent / span) * span;
const arraySeed = Buffer.alloc(4); arraySeed.writeInt32BE(start);
const currentArray = PublicKey.findProgramAddressSync([Buffer.from('tick_array'), new PublicKey(NVDA_POOL).toBuffer(), arraySeed], new PublicKey(ADDRESSES.raydium))[0].toBase58();
await clone(currentArray);
const recorded = JSON.parse(readFileSync(new URL('./fixtures/v2/wsol.json', import.meta.url), 'utf8'));
const routePoolAddress = recorded.build.swapInstruction.accounts[13].pubkey;
const routePool = decodePool(Buffer.from((await clone(routePoolAddress)).account.data[0], 'base64'));
const routeSpan = routePool.tickSpacing * 60;
const routeStart = Math.floor(routePool.tickCurrent / routeSpan) * routeSpan;
const routeArrays: string[] = [];
for (let distance = 0; distance < 3; distance++) {
  const seed = Buffer.alloc(4); seed.writeInt32BE(routeStart + distance * routeSpan);
  const address = PublicKey.findProgramAddressSync([Buffer.from('tick_array'), new PublicKey(routePoolAddress).toBuffer(), seed], new PublicKey(ADDRESSES.raydium))[0].toBase58();
  await clone(address); routeArrays.push(address);
}
writeFileSync(new URL('swap-production-route-arrays.json', root), JSON.stringify(routeArrays));
const manager = testWallet();
const manifest = JSON.parse(readFileSync(new URL('manifest.json', root), 'utf8'));
const solPool = manifest.pools.find((entry: any) => entry.address === ADDRESSES.solPool);
const solPoolData = Buffer.from(JSON.parse(readFileSync(new URL(`accounts/${ADDRESSES.solPool}.json`, root), 'utf8')).account.data[0], 'base64');
const { target: fund } = creation(manager.publicKey, Buffer.alloc(20, 0xc8), 18, decodePool(solPoolData), productionApiKey(true), true);
const rewards: { mint: string; vault: string; quarantine: string }[] = [];
for (let index = 0; index < 3; index++) {
  const offset = 397 + index * 169;
  const mint = new PublicKey(solPoolData.subarray(offset + 57, offset + 89)).toBase58();
  if (mint === '11111111111111111111111111111111') continue;
  const rewardVault = new PublicKey(solPoolData.subarray(offset + 89, offset + 121)).toBase58();
  await clone(mint);
  const reward = await clone(rewardVault);
  const data = Buffer.from(reward.account.data[0], 'base64');
  new PublicKey(fund.vault).toBuffer().copy(data, 32); data.writeBigUInt64LE(0n, 64);
  data.fill(0, 72, 108); data[108] = 1; data.fill(0, 109, 165);
  const quarantine = PublicKey.findProgramAddressSync([Buffer.from('raydium_reward'), new PublicKey(fund.fund).toBuffer(), new PublicKey(mint).toBuffer()], new PublicKey(ADDRESSES.spoke))[0].toBase58();
  writeFileSync(new URL(`overrides/${quarantine}.json`, root), JSON.stringify({ pubkey: quarantine,
    account: { ...reward.account, data: [data.toString('base64'), 'base64'], lamports: 10_000_000 } }));
  rewards.push({ mint, vault: rewardVault, quarantine });
}
writeFileSync(new URL('swap-production-rewards.json', root), JSON.stringify(rewards));
const token = JSON.parse(readFileSync(new URL(`accounts/${solPool.vault0}.json`, root), 'utf8'));
const data = Buffer.from(token.account.data[0], 'base64');
manager.publicKey.toBuffer().copy(data, 32); data.writeBigUInt64LE(0n, 64);
data.fill(0, 72, 108); data[108] = 1; data.fill(0, 129, 165);
writeFileSync(new URL(`overrides/${testAta(ADDRESSES.wsol, manager.publicKey)}.json`, root), JSON.stringify({
  pubkey: testAta(ADDRESSES.wsol, manager.publicKey).toBase58(), account: { ...token.account, data: [data.toString('base64'), 'base64'] },
}));
manifest.warpSlot = Math.max(manifest.warpSlot, ...evidence.map(item => item.slot));
writeFileSync(new URL('manifest.json', root), JSON.stringify(manifest, null, 2));
writeFileSync(new URL('swap-production-clones.json', root), JSON.stringify(evidence, null, 2));
console.log(`Production extension: ${evidence.length} finalized read-only clones; local Manager WSOL and reward quarantine fixtures.`);
prepareCctpFixtures();
