import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { PublicKey } from '@solana/web3.js';

const root = new URL('../../.localnet/', import.meta.url);
const extension = JSON.parse(readFileSync(new URL('./fixtures/scope-clone-extension.json', import.meta.url), 'utf8'));
const endpoint = process.env.SOLANA_MAINNET_RPC ?? 'https://api.mainnet-beta.solana.com';
const evidence: { address: string; owner: string; slot: number; size: number; sha256: string }[] = [];
mkdirSync(new URL('accounts/', root), { recursive: true });

async function clone(address: string): Promise<Buffer> {
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      await new Promise(resolve => setTimeout(resolve, 400 * 2 ** attempt));
      const response = await fetch(endpoint, { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'getAccountInfo',
          params: [address, { encoding: 'base64', commitment: 'finalized' }] }), signal: AbortSignal.timeout(30_000) });
      if (!response.ok) throw new Error('Read failed');
      const result = (await response.json() as any).result;
      if (!result?.value) throw new Error('Missing account');
      const bytes = Buffer.from(result.value.data[0], 'base64');
      writeFileSync(new URL(`accounts/${address}.json`, root), JSON.stringify({ pubkey: address,
        account: { ...result.value, rentEpoch: 0 } }));
      evidence.push({ address, owner: result.value.owner, slot: result.context.slot, size: bytes.length,
        sha256: createHash('sha256').update(bytes).digest('hex') });
      return bytes;
    } catch {
      if (attempt === 4) throw new Error(`Read-only Scope clone failed for ${address}; endpoint suppressed`);
    }
  }
  throw new Error('Unreachable clone failure');
}

const program = await clone(extension.program);
if (program.length !== 36 || program.readUInt32LE(0) !== 2) throw new Error('Unexpected upgradeable program layout');
await clone(new PublicKey(program.subarray(4, 36)).toBase58());
for (const address of extension.accounts) await clone(address);
const prices = Buffer.from(JSON.parse(readFileSync(new URL(`accounts/${extension.accounts[0]}.json`, root), 'utf8')).account.data[0], 'base64');
const mappings = Buffer.from(JSON.parse(readFileSync(new URL(`accounts/${extension.accounts[1]}.json`, root), 'utf8')).account.data[0], 'base64');
if (prices.length !== 28_712 || mappings.length !== 29_704 || prices.subarray(0, 8).toString('hex') !== '598076dd0648b492'
    || mappings.subarray(0, 8).toString('hex') !== '28f46e50ffd6f3bc'
    || new PublicKey(prices.subarray(8, 40)).toBase58() !== extension.accounts[1]) throw new Error('Scope layout mismatch');
const feeds = ['00084edc844a6f88449c59c8cfcdb2225799a2330503472cb0bc4f9369a717fa',
  '0008adc184847ba8d17f0030c15e78f61b83eda2e190f30346c4ea3babed647d'];
const entries = Object.entries(extension.entries).map(([name, rawIndex], ordinal) => {
  const index = Number(rawIndex); const offset = 40 + index * 56;
  if (mappings.subarray(8 + index * 32, 40 + index * 32).toString('hex') !== feeds[ordinal]
      || mappings[16_392 + index] !== 34 || mappings[19_464 + 20 * index] !== 1
      || prices.readBigUInt64LE(offset + 8) !== 15n) throw new Error('Scope mapping/type/unit mismatch');
  return { name, index, value: prices.readBigUInt64LE(offset).toString(),
    exponent: 15, sourceSlot: Number(prices.readBigUInt64LE(offset + 16)),
    timestamp: Number(prices.readBigUInt64LE(offset + 24)), mint: extension.accounts[ordinal + 2] };
});
if (evidence.slice(2, 4).some(account => account.owner !== extension.program)) throw new Error('Scope owner mismatch');
const manifest = JSON.parse(readFileSync(new URL('manifest.json', root), 'utf8'));
manifest.warpSlot = Math.max(manifest.warpSlot, ...evidence.map(account => account.slot));
writeFileSync(new URL('manifest.json', root), JSON.stringify(manifest, null, 2));
writeFileSync(new URL('scope-evidence.json', root), JSON.stringify({ evidence, entries }, null, 2));
console.log(`Scope extension: ${evidence.length} finalized read-only clones; pinned Open feeds and exponent verified.`);
for (const entry of entries) console.log(`${entry.name}: source timestamp ${entry.timestamp}; slot ${entry.sourceSlot}; underlying mantissa ${entry.value}.`);
