import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { PublicKey } from '@solana/web3.js';
import { ADDRESSES, publicKey } from '../helpers/addresses.ts';

mkdirSync(new URL('../../.localnet/overrides/', import.meta.url), { recursive: true });
for (const pair of ['tslax', 'nvdax', 'wsol']) {
  const fixture = JSON.parse(readFileSync(new URL(`./fixtures/${pair}.json`, import.meta.url), 'utf8'));
  const accounts = fixture.instructions.swapInstruction.accounts;
  const templates = [accounts[15].pubkey, accounts[16].pubkey];
  for (let index = 0; index < 2; index++) {
    const mint = index === 0 ? ADDRESSES.usdc : fixture.quote.outputMint;
    const tokenProgram = index === 0 || pair === 'wsol' ? ADDRESSES.token : ADDRESSES.token2022;
    const snapshots = templates.map(address => JSON.parse(readFileSync(new URL(`../../.localnet/accounts/${address}.json`, import.meta.url), 'utf8')));
    const template = snapshots.find(snapshot => new PublicKey(Buffer.from(snapshot.account.data[0], 'base64').subarray(0, 32)).toBase58() === mint);
    if (!template) throw new Error('Route token vault template missing');
    const data = Buffer.from(template.account.data[0], 'base64');
    publicKey(fixture.vault).toBuffer().copy(data, 32);
    data.writeBigUInt64LE(index === 0 ? 100_000_000n : 0n, 64);
    data.fill(0, 72, 108);
    data[108] = 1;
    data.fill(0, 109, 165);
    const ata = accounts[index + 2].pubkey;
    const expected = PublicKey.findProgramAddressSync([publicKey(fixture.vault).toBuffer(), publicKey(tokenProgram).toBuffer(), publicKey(mint).toBuffer()], publicKey(ADDRESSES.ata))[0];
    if (expected.toBase58() !== ata) throw new Error('Unexpected route ATA');
    const lamports = 10_000_000;
    if (pair === 'wsol' && index === 1) { data.writeUInt32LE(1, 109); data.writeBigUInt64LE(BigInt(lamports), 113); }
    writeFileSync(new URL(`../../.localnet/overrides/${ata}.json`, import.meta.url), JSON.stringify({ pubkey: ata,
      account: { ...template.account, data: [data.toString('base64'), 'base64'], lamports, rentEpoch: 0 } }));
  }
}
console.log('Prepared synthetic vault balances from cloned token vault layouts; no Fund SOL');
