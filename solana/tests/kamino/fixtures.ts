import { readFileSync, writeFileSync } from 'node:fs';
import { PublicKey } from '@solana/web3.js';
import { ADDRESSES, fundAddresses, publicKey, derive } from '../helpers/addresses.ts';
import { discriminator } from '../helpers/layouts.ts';
import { testWallet, testAta } from '../helpers/localnet.ts';

export const COLLATERAL = 'B8V6WVjPxW1UGwVDfxH2d2r8SyT4cqn7dQRK6XneVa7D';
export const MARKET_AUTHORITY = derive(ADDRESSES.kamino, Buffer.from('lma'), publicKey(ADDRESSES.market).toBuffer());
export const CREDIT = 100_000_000n;
export const DONATION = 1_000_000n;
export const COLLATERAL_DONATION = 17n;

export function fixture(identity: number) {
  const hub = Buffer.alloc(20, identity);
  const addresses = fundAddresses(hub, 2);
  return { ...addresses, hub,
    position: derive(ADDRESSES.spoke, Buffer.from('position'), publicKey(addresses.fund).toBuffer(), publicKey(ADDRESSES.reserve).toBuffer()),
    usdc: testAta(ADDRESSES.usdc, publicKey(addresses.vault)).toBase58(),
    collateral: testAta(COLLATERAL, publicKey(addresses.vault)).toBase58(),
  };
}

const root = new URL('../../.localnet/', import.meta.url);

function snapshot(address: string, owner: string, data: Buffer) {
  writeFileSync(new URL(`overrides/${address}.json`, root), JSON.stringify({ pubkey: address, account: {
    lamports: (data.length + 128) * 6960, data: [data.toString('base64'), 'base64'], owner, executable: false, rentEpoch: 0,
  } }));
}

function token(mint: string, owner: string, amount: bigint): Buffer {
  const data = Buffer.alloc(165);
  publicKey(mint).toBuffer().copy(data, 0);
  publicKey(owner).toBuffer().copy(data, 32);
  data.writeBigUInt64LE(amount, 64);
  data[108] = 1;
  return data;
}

export function prepareKaminoFixtures() {
  const manager = testWallet().publicKey;
  const reserve = Buffer.from(JSON.parse(readFileSync(new URL(`accounts/${ADDRESSES.reserve}.json`, root), 'utf8')).account.data[0], 'base64');
  for (const identity of [31, 32, 33, 34]) {
    const addresses = fixture(identity);
    const fund = Buffer.alloc(184);
    discriminator('account', 'FundState').copy(fund);
    let offset = 8;
    addresses.hub.copy(fund, offset); offset += 20;
    fund.writeUInt16LE(2, offset); offset += 2;
    Buffer.alloc(32, identity).copy(fund, offset); offset += 32;
    Buffer.alloc(32, 99).copy(fund, offset); offset += 32;
    Buffer.alloc(20, 88).copy(fund, offset); offset += 20;
    manager.toBuffer().copy(fund, offset); offset += 32;
    offset += 16;
    fund[offset++] = 0;
    fund[offset++] = PublicKey.findProgramAddressSync([Buffer.from('fund'), addresses.hub, Buffer.from([2, 0])], publicKey(ADDRESSES.spoke))[1];
    fund[offset++] = PublicKey.findProgramAddressSync([Buffer.from('vault'), publicKey(addresses.fund).toBuffer()], publicKey(ADDRESSES.spoke))[1];
    snapshot(addresses.fund, ADDRESSES.spoke, fund.subarray(0, offset));
    const position = Buffer.alloc(8 + 64 + 1 + 11 * 8);
    discriminator('account', 'KaminoPosition').copy(position);
    publicKey(addresses.fund).toBuffer().copy(position, 8);
    publicKey(ADDRESSES.reserve).toBuffer().copy(position, 40);
    position[72] = identity === 33 ? 0 : 1;
    const units = identity === 32 ? reserve.readBigUInt64LE(2592) / 2n : identity === 34 ? 1_000_000n : 0n;
    position.writeBigUInt64LE(units, 73);
    if (identity === 32) position.writeBigUInt64LE(reserve.readBigUInt64LE(224) * 10n, 81);
    if (identity === 34) position.writeBigUInt64LE(500_000n, 81);
    position.writeBigUInt64LE(CREDIT, 89);
    snapshot(addresses.position, ADDRESSES.spoke, position);
    snapshot(addresses.usdc, ADDRESSES.token, token(ADDRESSES.usdc, addresses.vault, CREDIT + DONATION));
    snapshot(addresses.collateral, ADDRESSES.token, token(COLLATERAL, addresses.vault, units + COLLATERAL_DONATION));
  }
  console.log('Prepared 4 local-only Kamino fixtures; no protocol state or mint overrides.');
}
