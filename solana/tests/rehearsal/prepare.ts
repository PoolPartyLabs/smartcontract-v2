import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { PublicKey } from '@solana/web3.js';
import { ADDRESSES, fundAddresses, publicKey, derive } from '../helpers/addresses.ts';
import { mandateHash, fundId, word, addressWord, hash, integer } from '../core/fixtures.ts';
import { prepareCctpFixtures } from '../cctp/fixtures.ts';

const root = new URL('../../.localnet/', import.meta.url);
const route = JSON.parse(readFileSync(new URL('../swap/fixtures/tslax.json', import.meta.url), 'utf8'));
const endpoint = process.env.SOLANA_MAINNET_RPC ?? 'https://api.mainnet-beta.solana.com';
const visited = new Set<string>();
const evidence: { address: string; slot: number; sha256: string }[] = [];

async function clone(address: string) {
  if (visited.has(address) || address === '11111111111111111111111111111111' || address.startsWith('Sysvar')) return;
  visited.add(address);
  for (let attempt = 0; attempt < 5; attempt++) {
    await new Promise(resolve => setTimeout(resolve, 400 * 2 ** attempt));
    const response = await fetch(endpoint, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'getAccountInfo', params: [address, { encoding: 'base64', commitment: 'finalized' }] }) });
    if (!response.ok) { if (attempt < 4) continue; throw new Error('Read-only clone failed; endpoint suppressed'); }
    const result = await response.json() as any;
    if (result.error) { if (attempt < 4) continue; throw new Error('Read-only clone RPC failed; endpoint suppressed'); }
    if (!result.result.value) return;
    const account = { ...result.result.value, rentEpoch: 0 };
    const bytes = Buffer.from(account.data[0], 'base64');
    writeFileSync(new URL(`accounts/${address}.json`, root), JSON.stringify({ pubkey: address, account }));
    evidence.push({ address, slot: result.result.context.slot, sha256: createHash('sha256').update(bytes).digest('hex') });
    if (account.executable && account.owner === ADDRESSES.loader) await clone(new PublicKey(bytes.subarray(4, 36)).toBase58());
    return;
  }
}

try {
  for (const account of route.instructions.swapInstruction.accounts) {
    if ([route.vault, route.instructions.swapInstruction.accounts[2].pubkey, route.instructions.swapInstruction.accounts[3].pubkey].includes(account.pubkey)) continue;
    await clone(account.pubkey);
  }
  await clone(route.instructions.swapInstruction.programId);
  await clone('MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr');
  prepareCctpFixtures();
  const core = Buffer.alloc(20, 0xa8);
  const acknowledgements: Record<string, string> = {};
  for (const variant of ['valid', 'wrongEmitter']) {
    const emitter = variant === 'valid' ? addressWord(core) : Buffer.alloc(32, 0xff);
    const payload = Buffer.concat([word(1), word(4), fundId, word(802), word(0), word(2_000_000_000), word(1), word(2), word(0), word(0), word(0)]);
    const timestamp = 1_791_286_864;
    const encodedTimestamp = Buffer.alloc(4); encodedTimestamp.writeUInt32BE(timestamp);
    const encodedSequence = Buffer.alloc(8); encodedSequence.writeBigUInt64BE(2n);
    const encodedChain = Buffer.alloc(2); encodedChain.writeUInt16BE(23);
    const body = Buffer.concat([encodedTimestamp, Buffer.alloc(4), encodedChain, emitter, encodedSequence, Buffer.from([200]), payload]);
    const address = derive(ADDRESSES.wormhole, Buffer.from('PostedVAA'), hash(body));
    const data = Buffer.concat([Buffer.from('vaa'), Buffer.from([1, 200]), integer(timestamp, 4), Buffer.alloc(32, 1), integer(timestamp, 4),
      Buffer.alloc(4), integer(2, 8), integer(23, 2), emitter, integer(payload.length, 4), payload]);
    writeFileSync(new URL(`overrides/${address}.json`, root), JSON.stringify({ pubkey: address,
      account: { owner: ADDRESSES.wormhole, data: [data.toString('base64'), 'base64'], lamports: 10_000_000, executable: false, rentEpoch: 0 } }));
    acknowledgements[variant] = address;
  }
  writeFileSync(new URL('rehearsal-acks.json', root), JSON.stringify(acknowledgements));
  writeFileSync(new URL('rehearsal-clones.json', root), JSON.stringify(evidence, null, 2));
  const manifest = JSON.parse(readFileSync(new URL('manifest.json', root), 'utf8'));
  manifest.warpSlot = Math.max(manifest.warpSlot, ...evidence.map(item => item.slot)) + 32;
  writeFileSync(new URL('manifest.json', root), JSON.stringify(manifest, null, 2));
  console.log(`Rehearsal: ${evidence.length} extra read-only clones; local attester override only.`);
} catch {
  console.error('Rehearsal preparation failed; RPC and credentials suppressed.');
  process.exitCode = 1;
}
