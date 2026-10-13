import type { AccountMeta, PublicKey } from "@solana/web3.js";
import { ADDRESSES, derive, publicKey } from "../tests/helpers/addresses.ts";
import { testAta } from "../tests/helpers/localnet.ts";
import { NVDA } from "../tests/swap/production-client.ts";

// DF-1: the sealed native asset set is an explicit reviewed input (PP_CREATION_ASSETS), recorded in builder-input.json
// and in the Manager approval copy (creation.assets). Default USDC+WSOL, the founder-ruled demo Fund; a stock only when
// requested. The builder's venues (Kamino USDC, Raydium SOL/USDC) need USDC and WSOL, and initialize_fund admits at most
// 3 assets, so the only sets are usdc,wsol and usdc,wsol + one of nvdax|tslax.
export const ASSET_MINTS: Readonly<Record<string, string>> = { usdc: ADDRESSES.usdc, wsol: ADDRESSES.wsol, nvdax: NVDA, tslax: ADDRESSES.tslax };
const STOCKS = ["nvdax", "tslax"];
const hexOf = (mint: string) => "0x" + publicKey(mint).toBuffer().toString("hex");

export function parseAssetSet(raw = "usdc,wsol"): string[] {
  const names = raw.split(",").map(name => name.trim().toLowerCase());
  if (names[0] !== "usdc" || names[1] !== "wsol" || names.length > 3 || (names.length === 3 && !STOCKS.includes(names[2]))) {
    throw new Error("PP_CREATION_ASSETS must be usdc,wsol, optionally followed by exactly one of nvdax|tslax");
  }
  return names;
}

export const isStock = (name: string) => STOCKS.includes(name);

/** Names of the sealed assets (bytes32 mint hex, as in the plan calldata); refuses a mint outside ASSET_MINTS. */
export function assetNames(sealedMints: string[]): string[] {
  return sealedMints.map(mint => {
    const name = Object.keys(ASSET_MINTS).find(key => hexOf(ASSET_MINTS[key]) === mint.toLowerCase());
    if (!name) throw new Error("Plan seals an asset outside the reviewed set");
    return name;
  });
}

/** initialize_fund.rs:97 — the NVDAx mint/ATA/ledger triple is a remaining account only when NVDAx is sealed. */
export function nvdaxRemainingAccounts(sealedMints: string[], fund: PublicKey, vault: PublicKey): AccountMeta[] {
  if (!sealedMints.some(mint => mint.toLowerCase() === hexOf(NVDA))) return [];
  return [
    { pubkey: publicKey(NVDA), isWritable: false, isSigner: false },
    { pubkey: testAta(NVDA, vault), isWritable: true, isSigner: false },
    { pubkey: publicKey(derive(ADDRESSES.spoke, Buffer.from("ledger"), fund.toBuffer(), publicKey(NVDA).toBuffer())), isWritable: true, isSigner: false },
  ];
}
