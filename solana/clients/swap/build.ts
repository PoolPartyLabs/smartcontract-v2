import { createHash } from 'node:crypto';
import { PublicKey, TransactionInstruction, TransactionMessage, VersionedTransaction, ComputeBudgetProgram, SystemProgram } from '@solana/web3.js';
import type { Connection } from '@solana/web3.js';
import { JupiterClient } from './jupiter.ts';
import { solveRatio } from './ratio.ts';
import type { RangeInventory } from './ratio.ts';
import { decodeRouteV2 } from './decoder.ts';
import { encodeQuote, routeHash } from './quote.ts';
import type { ApiQuote } from './quote.ts';

export const JUPITER = new PublicKey('JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4');
const TOKEN = new PublicKey('TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA');
const TOKEN_2022 = new PublicKey('TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb');
const ATA = new PublicKey('ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL');

function vaultAta(vault: PublicKey, mint: PublicKey, tokenProgram: PublicKey): PublicKey {
  if (!tokenProgram.equals(TOKEN) && !tokenProgram.equals(TOKEN_2022)) throw new Error('Unsupported token program');
  return PublicKey.findProgramAddressSync([vault.toBuffer(), tokenProgram.toBuffer(), mint.toBuffer()], ATA)[0];
}

export type BuildSwapArgs = {
  connection: Connection; client: JupiterClient; program: PublicKey; manager: PublicKey; fund: PublicKey;
  vault: PublicKey; mint0: PublicKey; mint1: PublicKey; tokenProgram0: PublicKey; tokenProgram1: PublicKey;
  inventory: RangeInventory; slippageBps: number; sealedMaxSlippageBps: number; sealedMints: PublicKey[];
  iterations?: number; computeUnits?: number;
  maxPriceImpactBps: number;
  oracleAccounts: PublicKey[];
  authorizeQuote: (route: { fund: PublicKey; inputMint: PublicKey; outputMint: PublicKey;
    amountIn: bigint; suggestedMinOut: bigint; routeHash: Buffer }) => Promise<ApiQuote>;
};

export async function buildSwapToRatio(args: BuildSwapArgs) {
  const { connection, client, program, manager, fund, vault, mint0, mint1 } = args;
  if (!Number.isInteger(args.maxPriceImpactBps) || args.maxPriceImpactBps < 0 || args.maxPriceImpactBps > 65535
      || args.oracleAccounts.length !== 3 || typeof args.authorizeQuote !== 'function') throw new Error('API authorization and pinned oracle accounts required');
  const pinnedOracles = ['7AviUf9nL62mcxNbQGKm4nKDQnPjswo6c5MX4D57HmyE', '6HAuqASbHEh4w4REJEUUUCginTLfj1kwCh215ZLtMkrT', 'CH31Xns5z3M1cTAbKW34jcxPPciazARpijcHj9rxtemt'];
  if (args.oracleAccounts.some((key, index) => key.toBase58() !== pinnedOracles[index])) throw new Error('Unpinned oracle account');
  if (!PublicKey.findProgramAddressSync([Buffer.from('vault'), fund.toBuffer()], program)[0].equals(vault)
      || !args.sealedMints.some(mint => mint.equals(mint0)) || !args.sealedMints.some(mint => mint.equals(mint1))
      || mint0.equals(mint1) || args.slippageBps > args.sealedMaxSlippageBps) throw new Error('Invalid sealed swap policy or vault');
  const units = args.computeUnits ?? 1_200_000;
  if (!Number.isInteger(units) || units < 1 || units > 1_400_000) throw new Error('Invalid compute budget');
  const result = await solveRatio(args.inventory, async (zeroForOne, amount) => {
    const quote = await client.quote((zeroForOne ? mint0 : mint1).toBase58(), (zeroForOne ? mint1 : mint0).toBase58(), amount, args.slippageBps);
    return BigInt(quote.outAmount);
  }, args.iterations);
  if (!result) return null;
  const inputMint = result.zeroForOne ? mint0 : mint1;
  const outputMint = result.zeroForOne ? mint1 : mint0;
  const inputAta = vaultAta(vault, inputMint, result.zeroForOne ? args.tokenProgram0 : args.tokenProgram1);
  const outputAta = vaultAta(vault, outputMint, result.zeroForOne ? args.tokenProgram1 : args.tokenProgram0);
  const quote = await client.quote(inputMint.toBase58(), outputMint.toBase58(), result.amount, args.slippageBps);
  const response = await client.instructions(quote, vault.toBase58(), outputAta.toBase58());
  const swap = response.swapInstruction;
  if (!swap || swap.programId !== JUPITER.toBase58() || swap.accounts.length > 48
      || swap.accounts[0]?.pubkey !== vault.toBase58() || swap.accounts[1]?.pubkey !== inputAta.toBase58()
      || swap.accounts[2]?.pubkey !== outputAta.toBase58()
      || swap.accounts.some(account => account.isSigner && account.pubkey !== vault.toBase58())) throw new Error('Jupiter custody mismatch');
  const endpoints = await connection.getMultipleAccountsInfo([inputAta, outputAta]);
  if (endpoints.some(account => !account)) throw new Error('Manager must create vault ATAs before swap; no setup/unwrap instructions are forwarded');
  const route = Buffer.from(swap.data, 'base64');
  const decoded = decodeRouteV2(route);
  if (decoded.amountIn !== result.amount || decoded.quotedOut !== BigInt(quote.outAmount)
      || decoded.slippageBps !== args.slippageBps) throw new Error('Jupiter V2 quote mismatch');
  const minOut = (BigInt(quote.outAmount) * BigInt(10_000 - args.slippageBps) + 9999n) / 10_000n;
  const hash = routeHash(swap, vault);
  const apiQuote = await args.authorizeQuote({ fund, inputMint, outputMint, amountIn: result.amount, suggestedMinOut: minOut, routeHash: hash });
  if (!apiQuote.fund.equals(fund) || !apiQuote.tokenIn.equals(inputMint) || !apiQuote.tokenOut.equals(outputMint)
      || apiQuote.quotedAmountIn !== result.amount || apiQuote.minAmountOut < minOut || !apiQuote.legsHash.equals(hash))
    throw new Error('API-signed quote does not bind the selected route');
  const trailer = Buffer.alloc(6); trailer.writeUInt16LE(args.maxPriceImpactBps); trailer.writeUInt32LE(route.length, 2);
  const payload = Buffer.concat([encodeQuote(apiQuote), trailer, route, Buffer.from([0])]);
  const length = Buffer.alloc(4);
  length.writeUInt32LE(payload.length);
  const instruction = new TransactionInstruction({ programId: program, keys: [
    { pubkey: manager, isSigner: true, isWritable: false },
    { pubkey: fund, isSigner: false, isWritable: true },
    { pubkey: vault, isSigner: false, isWritable: false },
    { pubkey: JUPITER, isSigner: false, isWritable: false },
    { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ...args.oracleAccounts.map(pubkey => ({ pubkey, isSigner: false, isWritable: false })),
    ...swap.accounts.map(account => ({ pubkey: new PublicKey(account.pubkey), isSigner: false, isWritable: account.isWritable })),
  ], data: Buffer.concat([createHash('sha256').update('global:swap_to_ratio').digest().subarray(0, 8), length, payload]) });
  const lookups = await Promise.all(response.addressLookupTableAddresses.map(async address => {
    const lookup = (await connection.getAddressLookupTable(new PublicKey(address))).value;
    if (!lookup || !lookup.isActive()) throw new Error('Route ALT is absent or inactive');
    return lookup;
  }));
  const blockhash = await connection.getLatestBlockhash();
  const transaction = new VersionedTransaction(new TransactionMessage({ payerKey: manager, recentBlockhash: blockhash.blockhash,
    instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units }), instruction],
  }).compileToV0Message(lookups));
  let transactionBytes: number;
  try { transactionBytes = transaction.serialize().length; } catch { throw new Error('Swap exceeds v0 packet size; reduce route accounts and rebuild manually'); }
  if (transactionBytes > 1232) throw new Error('Swap exceeds 1232-byte packet; rebuild with fewer accounts');
  return { transaction, transactionBytes, computeUnitLimit: units, quote, minOut,
    inputAmount: result.amount, inputMint, outputMint, blockhash };
}
