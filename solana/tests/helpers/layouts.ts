import { createHash } from 'node:crypto';
import { PublicKey } from '@solana/web3.js';

export function discriminator(namespace: string, name: string): Buffer {
  return createHash('sha256').update(`${namespace}:${name}`).digest().subarray(0, 8);
}

export function readKey(data: Buffer, offset: number): string {
  if (offset < 0 || offset + 32 > data.length) throw new Error('Pubkey outside account data');
  return new PublicKey(data.subarray(offset, offset + 32)).toBase58();
}

function requireLayout(data: Buffer, name: string, minimum: number) {
  if (data.length < minimum || !data.subarray(0, 8).equals(discriminator('account', name))) {
    throw new Error(`Unexpected ${name} layout; refresh the pinned decoder before cloning`);
  }
}

export function readU128(data: Buffer, offset: number): bigint {
  return data.readBigUInt64LE(offset) | (data.readBigUInt64LE(offset + 8) << 64n);
}

export function decodePool(data: Buffer) {
  requireLayout(data, 'PoolState', 273);
  const tickSpacing = data.readUInt16LE(235);
  if (tickSpacing === 0) throw new Error('Invalid pool tick spacing');
  return {
    config: readKey(data, 9),
    mint0: readKey(data, 73),
    mint1: readKey(data, 105),
    vault0: readKey(data, 137),
    vault1: readKey(data, 169),
    observation: readKey(data, 201),
    decimals0: data[233],
    decimals1: data[234],
    tickSpacing,
    liquidity: readU128(data, 237),
    sqrtPriceX64: readU128(data, 253),
    tickCurrent: data.readInt32LE(269),
  };
}

export function decodeReserve(data: Buffer) {
  requireLayout(data, 'Reserve', 8624);
  return {
    version: data.readBigUInt64LE(8),
    lastUpdateSlot: data.readBigUInt64LE(16),
    market: readKey(data, 32),
    mint: readKey(data, 128),
    liquidityVault: readKey(data, 160),
    feeVault: readKey(data, 192),
    available: data.readBigUInt64LE(224),
    collateralMint: readKey(data, 2560),
    collateralVault: readKey(data, 2600),
  };
}

export function spotRatio(pool: ReturnType<typeof decodePool>): number {
  const sqrt = Number(pool.sqrtPriceX64) / 2 ** 64;
  return sqrt * sqrt * 10 ** (pool.decimals0 - pool.decimals1);
}
