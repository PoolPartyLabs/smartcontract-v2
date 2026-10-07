import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { secp256k1 } from '@noble/curves/secp256k1';
import { PublicKey, SystemProgram, TransactionInstruction } from '@solana/web3.js';
import { ADDRESSES, fundAddresses, publicKey } from '../helpers/addresses.ts';
import { testAta } from '../helpers/localnet.ts';
import { factory, fundId, mandateHash, hubPolicyHash, integer, word, hash, addressWord } from '../core/fixtures.ts';
export { stageSwapPolicy } from '../core/fixtures.ts';
import { quoteDigest, encodeQuote, routeHash } from '../../clients/swap/quote.ts';
import { instruction } from '../raydium/client.ts';

export const NVDA = 'Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh';
export const NVDA_POOL = '49iMatQtoyabsYAQc8GafVq6aeBFVDxSRH44oiatyyw6';
export const SOL_PRICE = '7AviUf9nL62mcxNbQGKm4nKDQnPjswo6c5MX4D57HmyE';
export const USDC_PRICE = '6HAuqASbHEh4w4REJEUUUCginTLfj1kwCh215ZLtMkrT';
export const CROSS_CHECK = 'CH31Xns5z3M1cTAbKW34jcxPPciazARpijcHj9rxtemt';
export const SOL_FEED = Buffer.from('ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d', 'hex');
export const USDC_FEED = Buffer.from('eaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a', 'hex');

export function productionApiKey(create = false): Uint8Array {
  const root = new URL('../../.localnet/', import.meta.url);
  const path = new URL('production-api-key.json', root);
  if (create) {
    mkdirSync(root, { recursive: true });
    const fixtureKey = hash(Buffer.from('PoolParty/localnet/production-api/v1'));
    try {
      writeFileSync(path, JSON.stringify(Array.from(fixtureKey)), { flag: 'wx', mode: 0o600 });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw new Error('Unable to create local production API fixture');
    }
  }
  try {
    const value: unknown = JSON.parse(readFileSync(path, 'utf8'));
    if (!Array.isArray(value) || value.length !== 32 || !value.every(byte => Number.isInteger(byte) && byte >= 0 && byte <= 255)) {
      throw new Error('Invalid local fixture');
    }
    const key = Uint8Array.from(value);
    if (!secp256k1.utils.isValidPrivateKey(key)) throw new Error('Invalid local fixture');
    return key;
  } catch {
    throw new Error('Production API fixture missing or invalid; run local production preparation');
  }
}

export function policyBytes(apiKey: Uint8Array) {
  const signer = hash(secp256k1.getPublicKey(apiKey, false).subarray(1)).subarray(12);
  return Buffer.concat([signer, publicKey(SOL_PRICE).toBuffer(), publicKey(USDC_PRICE).toBuffer(), SOL_FEED,
    USDC_FEED, integer(300, 8), integer(100, 2), integer(50, 2), integer(200, 2), Buffer.from([0, 0])]);
}

export function policyDigest(policy: Buffer, bindingDigest: Buffer, fund: PublicKey, core: Buffer) {
  const domain = hash(Buffer.concat([hash(Buffer.from('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)')),
    hash(Buffer.from('Pool Party Swap Adapter')), hash(Buffer.from('2')), word(42161), addressWord(core), publicKey(ADDRESSES.spoke).toBuffer()]));
  const message = hash(Buffer.concat([hash(Buffer.from('SolanaSwapPolicy(bytes32 fund,bytes32 bindingDigest,bytes32 policyHash)')),
    fund.toBuffer(), bindingDigest, hash(policy)]));
  return hash(Buffer.concat([Buffer.from([25, 1]), domain, message]));
}

export function creation(manager: PublicKey, core: Buffer, index: number, pool: { mint0: string; mint1: string }, apiKey: Uint8Array, includeNvda = true) {
  const policy = policyBytes(apiKey);
  const swapPolicyHash = hash(policy);
  const mints = [ADDRESSES.usdc, ADDRESSES.wsol, ...(includeNvda ? [NVDA] : [])];
  const assetWords = mints.map(mint => {
    const namespace = Buffer.from('PoolParty/SolanaAsset/v6');
    const alias = hash(Buffer.concat([word(96), word(1), publicKey(mint).toBuffer(), word(namespace.length), namespace, Buffer.alloc(32 - namespace.length)])).subarray(12);
    return { mint, alias, stock: mint === NVDA };
  });
  const venues = [
    [ADDRESSES.raydium, ADDRESSES.solPool, SystemProgram.programId.toBase58(), pool.mint0, pool.mint1],
  ];
  const usdc = Buffer.from('af88d065e77c8cc2239327c5edb3a432268e5831', 'hex');
  const messenger = Buffer.from('28b5a0e9c621a5badaa536219b3a228c8168cf5d', 'hex');
  const transmitter = Buffer.from('81d40f21f12a8f0e3252bccb954d722d4c464b64', 'hex');
  const nativeAbi = (emitter: PublicKey, recipient: PublicKey, vault: PublicKey) => Buffer.concat([
    word(6), word(64), publicKey(ADDRESSES.spoke).toBuffer(), emitter.toBuffer(),
    publicKey(ADDRESSES.usdc).toBuffer(), manager.toBuffer(), word(1), word(544), word(544 + 32 + assetWords.length * 96),
    addressWord(usdc), addressWord(messenger), addressWord(transmitter), word(5), recipient.toBuffer(), vault.toBuffer(),
    publicKey(ADDRESSES.cctpMessenger).toBuffer(), vault.toBuffer(), word(50_000), swapPolicyHash, word(assetWords.length),
    ...assetWords.flatMap(asset => [publicKey(asset.mint).toBuffer(), addressWord(asset.alias), word(Number(asset.stock))]),
    word(venues.length), ...venues.flatMap(venue => venue.map(address => publicKey(address).toBuffer()))]);
  const nativePolicyHash = hash(nativeAbi(PublicKey.default, PublicKey.default, PublicKey.default));
  const policyHash = hash(Buffer.concat([hash(Buffer.from('PoolParty/SolanaPolicy/v6')), hubPolicyHash, nativePolicyHash]));
  const target = fundAddresses(core, index, policyHash);
  const fund = publicKey(target.fund); const vault = publicKey(target.vault);
  const transport = Buffer.concat([usdc, messenger, transmitter, integer(5, 4), testAta(ADDRESSES.usdc, vault).toBuffer(),
    vault.toBuffer(), publicKey(ADDRESSES.cctpMessenger).toBuffer(), vault.toBuffer(), integer(50_000, 8)]);
  const nativeHash = hash(nativeAbi(publicKey(target.emitter), testAta(ADDRESSES.usdc, vault), vault));
  const domain = hash(Buffer.concat([hash(Buffer.from('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
    hash(Buffer.from('PoolParty Solana Fund')), hash(Buffer.from('6')), word(42161), addressWord(factory)]));
  const nonce = word(9); const expiry = 2_000_000_000n;
  const message = hash(Buffer.concat([hash(Buffer.from('SolanaBootstrap(uint256 hubChain,address core,bytes32 mandateHash,bytes32 policyHash,uint16 spokeIndex,bytes32 program,bytes32 fundPda,bytes32 solanaKey,bytes32 usdcAta,bytes32 tslaxAta,bytes32 nvdaxAta,bytes32 wsolAta,bytes32 nativeMandateHash,bytes32 fundId,uint256 nonce,uint256 expiry)')),
    word(42161), addressWord(core), mandateHash, policyHash, word(index), publicKey(ADDRESSES.spoke).toBuffer(), fund.toBuffer(), manager.toBuffer(),
    ...[ADDRESSES.usdc, ADDRESSES.tslax, NVDA, ADDRESSES.wsol].map(mint => testAta(mint, vault).toBuffer()), nativeHash, fundId, nonce, word(expiry)]));
  const bindingDigest = hash(Buffer.concat([Buffer.from([25, 1]), domain, message]));
  const managerKey = secp256k1.utils.randomPrivateKey();
  const evm = hash(secp256k1.getPublicKey(managerKey, false).subarray(1)).subarray(12);
  const signature = secp256k1.sign(bindingDigest, managerKey);
  const consent = secp256k1.sign(policyDigest(policy, bindingDigest, fund, core), managerKey);
  const payload = Buffer.concat([core, integer(index, 2), fundId, mandateHash, evm, factory, integer(42161, 8), integer(1, 8), nativeHash, nonce, integer(expiry, 8),
    Buffer.from(signature.toCompactRawBytes()), Buffer.from([signature.recovery + 27]), integer(assetWords.length, 4),
    ...assetWords.map(asset => Buffer.concat([publicKey(asset.mint).toBuffer(), asset.alias, Buffer.from([Number(asset.stock)])])),
    integer(venues.length, 4), ...venues.map(venue => Buffer.concat(venue.map(address => publicKey(address).toBuffer()))), transport,
    hubPolicyHash, policyHash, swapPolicyHash,
    policy, Buffer.from(consent.toCompactRawBytes()), Buffer.from([consent.recovery + 27])]);
  return { payload, bindingDigest, policy, policyHash, swapPolicyHash, nativeHash, nativePolicyHash, target };
}

export function signedSwap(recorded: any, common: Record<string, any>, core: Buffer, apiKey: Uint8Array, config: string, ledger: (mint: string) => string,
  options: { nonce?: bigint; forged?: boolean; amount?: bigint; deadline?: bigint; impact?: number } = {}) {
  const route = structuredClone(recorded.build.swapInstruction);
  const vault = common.vault as PublicKey;
  const substitutions = new Map<string, string>([[recorded.vault, vault.toBase58()],
    [route.accounts[1].pubkey, testAta(recorded.build.inputMint, vault).toBase58()],
    [route.accounts[2].pubkey, testAta(recorded.build.outputMint, vault).toBase58()]]);
  route.accounts = route.accounts.map((account: any) => ({ ...account, pubkey: substitutions.get(account.pubkey) ?? account.pubkey }));
  const data = Buffer.from(route.data, 'base64');
  const amount = options.amount ?? BigInt(recorded.build.inAmount);
  const output = data.readBigUInt64LE(16) * amount / data.readBigUInt64LE(8);
  data.writeBigUInt64LE(amount, 8); data.writeBigUInt64LE(output, 16); route.data = data.toString('base64');
  const quote = { fund: common.fund as PublicKey, tokenIn: publicKey(recorded.build.inputMint), tokenOut: publicKey(recorded.build.outputMint),
    legsHash: routeHash(route, vault), quotedAmountIn: amount, minAmountOut: (output * 9800n + 9999n) / 10000n,
    deadline: options.deadline ?? BigInt(Math.floor(Date.now() / 1000)) + 120n, nonce: options.nonce ?? 0n, signature: Buffer.alloc(65) };
  const signature = secp256k1.sign(quoteDigest(quote, { chainId: 42161n, verifyingContract: core, program: publicKey(ADDRESSES.spoke) }),
    options.forged ? secp256k1.utils.randomPrivateKey() : apiKey);
  quote.signature = Buffer.concat([Buffer.from(signature.toCompactRawBytes()), Buffer.from([signature.recovery + 27])]);
  const operation = instruction('swap_to_ratio', { ...common, swap_program: route.programId },
    Buffer.concat([encodeQuote(quote), integer(options.impact ?? 500, 2), integer(data.length, 4), data, Buffer.from([0])]));
  operation.keys.push(...route.accounts.map((account: any) => ({ pubkey: publicKey(account.pubkey), isSigner: false, isWritable: account.isWritable })),
    ...[config, SOL_PRICE, USDC_PRICE, CROSS_CHECK, ledger(recorded.build.inputMint), ledger(recorded.build.outputMint)]
      .map((address, index) => ({ pubkey: publicKey(address), isSigner: false, isWritable: [0, 4, 5].includes(index) })));
  return operation;
}
