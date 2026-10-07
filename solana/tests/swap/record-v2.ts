import { mkdirSync, writeFileSync } from 'node:fs';
import { PublicKey } from '@solana/web3.js';
import { JupiterClient } from '../../clients/swap/jupiter.ts';
import { ADDRESSES } from '../helpers/addresses.ts';

const client = new JupiterClient(process.env.JUPITER_API_KEY);
const probe = new PublicKey(Buffer.alloc(32, 77));
const fund = new PublicKey(Buffer.alloc(32, 78));
const vault = PublicKey.findProgramAddressSync([Buffer.from('vault'), fund.toBuffer()], probe)[0];
const pairs = { wsol: ADDRESSES.wsol, tslax: ADDRESSES.tslax, nvdax: 'Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh' };
mkdirSync(new URL('./fixtures/v2/', import.meta.url), { recursive: true });
for (const [pair, mint] of Object.entries(pairs)) {
  for (const reverse of [false, true]) {
    if (process.argv.includes('--wsol') && pair !== 'wsol') continue;
    const input = reverse ? mint : ADDRESSES.usdc;
    const output = reverse ? ADDRESSES.usdc : mint;
    const program = output === ADDRESSES.usdc || output === ADDRESSES.wsol ? ADDRESSES.token : ADDRESSES.token2022;
    const ata = PublicKey.findProgramAddressSync([vault.toBuffer(), new PublicKey(program).toBuffer(), new PublicKey(output).toBuffer()], new PublicKey(ADDRESSES.ata))[0];
    const name = `${pair}${reverse ? '-reverse' : ''}`;
    try {
      const build = await client.build(input, output, reverse ? (pair === 'wsol' ? 10_000_000n : 10_000_000n) : (pair === 'wsol' ? 1_000_000n : 15_000_000n), 200, vault.toBase58(), ata.toBase58());
      writeFileSync(new URL(`./fixtures/v2/${name}.json`, import.meta.url), JSON.stringify({ recordedAt: new Date().toISOString(), apiVersion: 2, probe: probe.toBase58(), fund: fund.toBase58(), vault: vault.toBase58(), build }, null, 2) + '\n');
      console.log(`${name}: ${build.swapInstruction.accounts.length} accounts; wire ${Buffer.from(build.swapInstruction.data, 'base64').toString('hex')}`);
    } catch (error) {
      console.log(`${name}: ${error instanceof Error ? error.message : 'recording failed'}`);
      process.exitCode = 1;
    }
  }
}
