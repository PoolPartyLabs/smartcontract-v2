import { mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { PublicKey } from '@solana/web3.js';
import { ADDRESSES } from '../helpers/addresses.ts';

const root = new URL('../../.localnet/', import.meta.url);
const endpoint = process.env.SOLANA_MAINNET_RPC ?? 'https://api.mainnet-beta.solana.com';
const addresses = new Set<string>([
  '7AviUf9nL62mcxNbQGKm4nKDQnPjswo6c5MX4D57HmyE', '6HAuqASbHEh4w4REJEUUUCginTLfj1kwCh215ZLtMkrT',
  'CH31Xns5z3M1cTAbKW34jcxPPciazARpijcHj9rxtemt', 'Gt9S41PtjR58CbG9JhJ3J6vxesqrNAswbWYbLNTMZA3c',
  'HJR45sRiFdGncL69HVzRK4HLS2SXcVW3KeTPkp2aFmWC',
]);
const fixtures = readdirSync(new URL('./fixtures/v2/', import.meta.url)).filter(name => /^(wsol|tslax|nvdax).*\.json$/.test(name))
  .map(name => JSON.parse(readFileSync(new URL(`./fixtures/v2/${name}`, import.meta.url), 'utf8')));
for (const fixture of fixtures) {
  for (const account of fixture.build.swapInstruction.accounts) addresses.add(account.pubkey);
  for (const address of fixture.build.addressLookupTableAddresses) addresses.add(address);
}
const snapshots = new Map<string, any>();
let latestSlot = 0;
mkdirSync(new URL('accounts/', root), { recursive: true });
mkdirSync(new URL('overrides/', root), { recursive: true });
async function clone(address: string) {
  if (snapshots.has(address)) return;
  for (let attempt = 0; attempt < 5; attempt++) {
    await new Promise(resolve => setTimeout(resolve, 450 * 2 ** attempt));
    let response: Response;
    try { response = await fetch(endpoint, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'getAccountInfo', params: [address, { encoding: 'base64', commitment: 'finalized' }] }), signal: AbortSignal.timeout(30000) });
    } catch { throw new Error('Read-only clone failed; endpoint suppressed'); }
    if (response.status === 429 && attempt < 4) continue;
    if (!response.ok) throw new Error(`Read-only clone HTTP ${response.status}`);
    const result = await response.json();
    if (result.error) throw new Error(`Read-only clone RPC ${result.error.code}`);
    latestSlot = Math.max(latestSlot, result.result.context.slot);
    const account = result.result.value;
    const snapshot = account ? { pubkey: address, account: { ...account, rentEpoch: 0 } } : null;
    snapshots.set(address, snapshot);
    if (snapshot) {
      writeFileSync(new URL(`accounts/${address}.json`, root), JSON.stringify(snapshot));
      if (account.executable && account.owner === ADDRESSES.loader) {
        const data = Buffer.from(account.data[0], 'base64');
        if (data.length !== 36 || data.readUInt32LE(0) !== 2) throw new Error('Unsupported loader state');
        await clone(new PublicKey(data.subarray(4)).toBase58());
      }
    }
    return;
  }
  throw new Error('Read-only clone exhausted retry limit');
}
for (const address of addresses) await clone(address);
for (const fixture of fixtures) {
  const accounts = fixture.build.swapInstruction.accounts;
  for (const index of [1, 2]) {
    const mint = accounts[index + 2].pubkey;
    const program = mint === ADDRESSES.usdc || mint === ADDRESSES.wsol ? ADDRESSES.token : ADDRESSES.token2022;
    const template = [...snapshots.values()].find(snapshot => snapshot && snapshot.account.owner === program
      && Buffer.from(snapshot.account.data[0], 'base64').length >= 165
      && new PublicKey(Buffer.from(snapshot.account.data[0], 'base64').subarray(0, 32)).toBase58() === mint);
    if (!template) throw new Error(`Missing cloned token template for ${mint}`);
    const data = Buffer.from(template.account.data[0], 'base64');
    new PublicKey(fixture.vault).toBuffer().copy(data, 32);
    data.writeBigUInt64LE(1_000_000_000n, 64);
    data.fill(0, 72, 108); data[108] = 1; data.fill(0, 109, 165);
    let lamports = 10_000_000;
    if (mint === ADDRESSES.wsol) { data.writeUInt32LE(1, 109); data.writeBigUInt64LE(10_000_000n, 113); lamports += 1_000_000_000; }
    const expected = PublicKey.findProgramAddressSync([new PublicKey(fixture.vault).toBuffer(), new PublicKey(program).toBuffer(), new PublicKey(mint).toBuffer()], new PublicKey(ADDRESSES.ata))[0];
    if (expected.toBase58() !== accounts[index].pubkey) throw new Error('V2 ATA mismatch');
    writeFileSync(new URL(`overrides/${expected.toBase58()}.json`, root), JSON.stringify({ pubkey: expected.toBase58(), account: { ...template.account, data: [data.toString('base64'), 'base64'], lamports } }));
  }
}
const accounts = [...snapshots.entries()].filter(([, snapshot]) => snapshot).map(([address, snapshot]) => ({
  address, owner: snapshot.account.owner, executable: snapshot.account.executable,
  sha256: createHash('sha256').update(Buffer.from(snapshot.account.data[0], 'base64')).digest('hex'),
}));
writeFileSync(new URL('./fixtures/v2/clone-extension.json', import.meta.url), JSON.stringify({ latestSlot, accounts, absent: [...snapshots.entries()].filter(([, value]) => !value).map(([key]) => key) }, null, 2) + '\n');
console.log(`V2 explicit extension: ${accounts.length} finalized clones, slot ${latestSlot}; synthetic vault balances only`);
