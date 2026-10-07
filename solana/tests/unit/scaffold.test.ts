import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import test from 'node:test';
import { ADDRESSES, fundAddresses, publicKey } from '../helpers/addresses.ts';
import { decodePool, decodeReserve, discriminator, readKey, spotRatio } from '../helpers/layouts.ts';
import { requireLoopback, testAta } from '../helpers/localnet.ts';
import { completeFundState } from '../helpers/fund-state.ts';

test('all mainnet constants are valid and match Rust pins', () => {
  const rust = readFileSync(new URL('../../programs/pp_spoke/src/constants.rs', import.meta.url), 'utf8');
  for (const [name, address] of Object.entries(ADDRESSES)) {
    assert.equal(publicKey(address).toBuffer().length, 32);
    if (!['spoke', 'scopePrices', 'loader'].includes(name)) assert.ok(rust.includes(address), name);
  }
});

test('Fund PDA isolation and token-program-qualified ATA derivation', () => {
  const first = fundAddresses(Buffer.alloc(20, 1), 0);
  const second = fundAddresses(Buffer.alloc(20, 1), 1);
  const third = fundAddresses(Buffer.alloc(20, 2), 0);
  assert.notEqual(first.fund, second.fund);
  assert.notEqual(first.fund, third.fund);
  assert.notEqual(first.vault, first.emitter);
  const owner = publicKey(ADDRESSES.usdc);
  assert.notEqual(testAta(ADDRESSES.usdc, owner).toBase58(), testAta(ADDRESSES.tslax, owner).toBase58());
  assert.throws(() => fundAddresses(Buffer.alloc(32), 0));
  assert.throws(() => fundAddresses(Buffer.alloc(20), 65536));
});

test('legacy local fixtures serialize the complete sealed Fund state layout', () => {
  const prefix = Buffer.alloc(165);
  const encoded = completeFundState(prefix);
  assert.equal(encoded.length, 4690);
  assert.equal(encoded.readBigUInt64LE(166), 42161n);
  assert.equal(encoded.readBigUInt64LE(194), 1n);
  assert.equal(encoded.readUInt16LE(338), 23);
  assert.equal(encoded.readUInt16LE(372), 0);
  assert.equal(encoded.readUInt16LE(374), 0);
  assert.equal(encoded.readUInt32LE(378), 0);
  assert.equal(encoded.readUInt32LE(382), 0);
  assert.throws(() => completeFundState(prefix.subarray(1)));
});

test('transaction guard rejects non-local and credentialed endpoints', () => {
  assert.equal(requireLoopback('http://127.0.0.1:8899'), 'http://127.0.0.1:8899');
  for (const endpoint of ['https://api.mainnet-beta.solana.com', 'http://example.com',
    'http://127.0.0.1@example.com', 'http://secret@localhost:8899', 'http://localhost:8899/?key=secret']) {
    assert.throws(() => requireLoopback(endpoint));
  }
});

test('Raydium decoder validates discriminator, offsets and negative ticks', () => {
  const data = Buffer.alloc(1544);
  discriminator('account', 'PoolState').copy(data);
  publicKey(ADDRESSES.usdc).toBuffer().copy(data, 73);
  publicKey(ADDRESSES.wsol).toBuffer().copy(data, 105);
  data[233] = 6;
  data[234] = 9;
  data.writeUInt16LE(10, 235);
  data.writeBigUInt64LE(1n, 261);
  data.writeInt32LE(-1, 269);
  const pool = decodePool(data);
  assert.equal(pool.mint0, ADDRESSES.usdc);
  assert.equal(pool.sqrtPriceX64, 1n << 64n);
  assert.equal(pool.tickCurrent, -1);
  assert.equal(spotRatio(pool), 0.001);
  assert.equal(Math.floor(pool.tickCurrent / (60 * pool.tickSpacing)), -1);
  assert.throws(() => decodePool(Buffer.alloc(1544)));
  assert.throws(() => readKey(data, data.length - 31));
});

test('Kamino decoder validates source-pinned reserve offsets', () => {
  const data = Buffer.alloc(8624);
  discriminator('account', 'Reserve').copy(data);
  publicKey(ADDRESSES.market).toBuffer().copy(data, 32);
  publicKey(ADDRESSES.usdc).toBuffer().copy(data, 128);
  data.writeBigUInt64LE(123n, 224);
  const reserve = decodeReserve(data);
  assert.equal(reserve.market, ADDRESSES.market);
  assert.equal(reserve.mint, ADDRESSES.usdc);
  assert.equal(reserve.available, 123n);
  assert.throws(() => decodeReserve(data.subarray(0, 8623)));
});

test('every declared instruction keeps an Accounts struct in its track module', () => {
  // Tracks replace the scaffold's fail-closed handlers with real ones and add helper files,
  // so this checks structure only: the 28 entry points stay declared and each module defines Accounts.
  const root = new URL('../../programs/pp_spoke/src/', import.meta.url);
  const lib = readFileSync(new URL('lib.rs', root), 'utf8');
  assert.equal((lib.match(/^\s*pub fn \w+\s*(<[^>]*>)?\s*\(/gm) ?? []).length, 28);
  for (const module of ['core', 'cctp', 'report', 'kamino', 'raydium', 'swap']) {
    const dir = new URL(`instructions/${module}/`, root);
    const sources = readdirSync(dir).filter(name => name.endsWith('.rs')).map(name => readFileSync(new URL(name, dir), 'utf8'));
    assert.ok(sources.some(source => /#\[derive\(Accounts\)\]/.test(source)), `${module} defines no Accounts struct`);
  }
});
