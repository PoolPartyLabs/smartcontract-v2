import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { Keypair } from '@solana/web3.js';
import { ADDRESSES, publicKey } from '../helpers/addresses.ts';
import { NVDA } from '../swap/production-client.ts';
import { ASSET_MINTS, parseAssetSet, isStock, assetNames, nvdaxRemainingAccounts } from '../../scripts/creation-assets.ts';

const sealed = (names: string[]) => names.map(name => '0x' + publicKey(ASSET_MINTS[name]).toBuffer().toString('hex'));

test('DF-1: the creation asset set defaults to USDC+WSOL and admits one requested stock', () => {
  assert.deepEqual(parseAssetSet(), ['usdc', 'wsol']);
  assert.deepEqual(parseAssetSet(undefined), ['usdc', 'wsol']);
  assert.deepEqual(parseAssetSet(' USDC , wsol '), ['usdc', 'wsol']);
  assert.deepEqual(parseAssetSet('usdc,wsol,nvdax'), ['usdc', 'wsol', 'nvdax']);
  assert.deepEqual(parseAssetSet('usdc,wsol,tslax'), ['usdc', 'wsol', 'tslax']);
  for (const refused of ['', 'usdc', 'wsol,usdc', 'usdc,nvdax', 'usdc,wsol,wsol', 'usdc,wsol,usdc', 'usdc,wsol,nvdax,tslax', 'usdc,wsol,bonk']) {
    assert.throws(() => parseAssetSet(refused), /PP_CREATION_ASSETS/, refused);
  }
  assert.equal(isStock('nvdax'), true);
  assert.equal(isStock('tslax'), true);
  assert.equal(isStock('wsol'), false);
  assert.equal(ASSET_MINTS.nvdax, NVDA);
  assert.equal(ASSET_MINTS.tslax, ADDRESSES.tslax);
});

test('DF-1: NVDAx remaining accounts exist only when NVDAx is sealed (initialize_fund.rs:97)', () => {
  const fund = Keypair.generate().publicKey;
  const vault = Keypair.generate().publicKey;
  assert.deepEqual(nvdaxRemainingAccounts(sealed(['usdc', 'wsol']), fund, vault), []);
  assert.deepEqual(nvdaxRemainingAccounts(sealed(['usdc', 'wsol', 'tslax']), fund, vault), []);
  const triple = nvdaxRemainingAccounts(sealed(['usdc', 'wsol', 'nvdax']).map(mint => '0x' + mint.slice(2).toUpperCase()), fund, vault);
  assert.equal(triple.length, 3);
  assert.equal(triple[0].pubkey.toBase58(), NVDA);
  assert.deepEqual(triple.map(meta => [meta.isWritable, meta.isSigner]), [[false, false], [true, false], [true, false]]);
  assert.deepEqual(assetNames(sealed(['usdc', 'wsol', 'nvdax'])), ['usdc', 'wsol', 'nvdax']);
  assert.throws(() => assetNames(['0x' + '11'.repeat(32)]), /outside the reviewed set/);
});

test('DF-1: the builder has no hard-coded stock and the broadcast gate checks the approved asset set', () => {
  const builder = readFileSync(new URL('../../scripts/three-chain-creation.ts', import.meta.url), 'utf8');
  assert.doesNotMatch(builder, /\[ADDRESSES\.usdc, ADDRESSES\.wsol, NVDA\]/);
  assert.match(builder, /parseAssetSet\(process\.env\.PP_CREATION_ASSETS\)/);
  assert.match(builder, /\.\.\.nvdaxRemainingAccounts\(native\.assets\.map/);
  assert.match(builder, /Plan sealed assets differ from the approved creation\.assets; no transaction signed/);
  // Element-wise, never a joined string (["usdc,wsol"] would equal "usdc,wsol").
  assert.match(builder, /creation\.assets\.length !== sealedNames\.length \|\| sealedNames\.some\(\(name, index\) => creation\.assets\[index\] !== name\)/);
  assert.doesNotMatch(builder, /creation\.assets\.join\(/);
  const template = JSON.parse(readFileSync(new URL('../../../script/solana-manager-approval.json', import.meta.url), 'utf8'));
  assert.equal(template.creation.assets, null);
});
