import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { AddressLookupTableAccount, PublicKey } from '@solana/web3.js';
import type { Connection } from '@solana/web3.js';
import { buildSwapToRatio } from '../../clients/swap/build.ts';
import type { JupiterClient, Quote, SwapInstructions } from '../../clients/swap/jupiter.ts';
import { Q64 } from '../../clients/swap/ratio.ts';
import { ADDRESSES } from '../helpers/addresses.ts';

for (const pair of ['tslax', 'nvdax', 'wsol']) {
  test(`builder returns an unsigned custody-bound ${pair} v0 transaction from fixture`, async () => {
    const fixture = JSON.parse(readFileSync(new URL(`./fixtures/${pair}.json`, import.meta.url), 'utf8')) as {
      quote: Quote; instructions: SwapInstructions; vault: string; probe: string; fund: string;
    };
    const quote = fixture.quote;
    const vault = new PublicKey(fixture.vault);
    const mockRpc = {
      getMultipleAccountsInfo: async () => [{}, {}],
      getLatestBlockhash: async () => ({ blockhash: ADDRESSES.usdc, lastValidBlockHeight: 10 }),
      getAddressLookupTable: async (key: PublicKey) => ({ value: new AddressLookupTableAccount({ key,
        state: { deactivationSlot: (1n << 64n) - 1n, lastExtendedSlot: 0, lastExtendedSlotStartIndex: 0,
          addresses: fixture.instructions.swapInstruction.accounts.map(account => new PublicKey(account.pubkey))
            .filter(key => !key.equals(vault)) } }) }),
    } as unknown as Connection;
    const client = { quote: async () => structuredClone(quote), instructions: async () => structuredClone(fixture.instructions) } as unknown as JupiterClient;
    const args = { connection: mockRpc, client, program: new PublicKey(fixture.probe), manager: new PublicKey(Buffer.alloc(32, 45)),
      fund: new PublicKey(fixture.fund), vault, mint0: new PublicKey(quote.inputMint), mint1: new PublicKey(quote.outputMint),
      tokenProgram0: new PublicKey(ADDRESSES.token), tokenProgram1: new PublicKey(pair === 'wsol' ? ADDRESSES.token : ADDRESSES.token2022),
      inventory: { balance0: BigInt(quote.inAmount), balance1: 0n, sqrtPriceX64: 2n * Q64, sqrtLowerX64: Q64 / 2n, sqrtUpperX64: Q64 },
      slippageBps: 200, sealedMaxSlippageBps: 200, sealedMints: [new PublicKey(quote.inputMint), new PublicKey(quote.outputMint)] };
    const built = await buildSwapToRatio(args);
    assert.ok(built);
    assert.equal(built.inputAmount, BigInt(quote.inAmount));
    assert.ok(built.transaction.signatures.every(signature => signature.every(byte => byte === 0)));
    assert.ok(built.transactionBytes <= 1232);
    console.log(`production-shaped ${pair} unsigned tx bytes=${built.transactionBytes}`);
    await assert.rejects(buildSwapToRatio({ ...args, sealedMints: [] }), /sealed/);
    await assert.rejects(buildSwapToRatio({ ...args, slippageBps: 201 }), /sealed/);
    await assert.rejects(buildSwapToRatio({ ...args, vault: args.manager }), /vault/);
  });
}
