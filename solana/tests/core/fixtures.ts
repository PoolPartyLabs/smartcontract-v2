import { writeFileSync, mkdirSync } from 'node:fs';
import { PublicKey, Transaction, SendTransactionError } from '@solana/web3.js';
import type { Connection, Keypair, TransactionInstruction } from '@solana/web3.js';
import { secp256k1 } from '@noble/curves/secp256k1';
import { keccak_256 } from '@noble/hashes/sha3';
import { ADDRESSES, fundAddresses, derive, publicKey } from '../helpers/addresses.ts';
import { discriminator } from '../helpers/layouts.ts';
import { requireLoopback, testAta, testWallet } from '../helpers/localnet.ts';

export const hubCore = Buffer.alloc(20, 0x71);
export const factory = Buffer.alloc(20, 0x72);
export const fundId = Buffer.alloc(32, 0x73);
export const mandateHash = Buffer.alloc(32, 0x74);
export const addresses = fundAddresses(hubCore, 1);
export const word = (value: bigint | number) => Buffer.from(BigInt(value).toString(16).padStart(64, '0'), 'hex');
export const hash = (data: Uint8Array) => Buffer.from(keccak_256(data));
export const addressWord = (value: Buffer) => Buffer.concat([Buffer.alloc(12), value]);
export function integer(value: number | bigint, size: number): Buffer {
  const bytes = Buffer.alloc(size);
  if (size === 1) bytes.writeUInt8(Number(value));
  else if (size === 2) bytes.writeUInt16LE(Number(value));
  else if (size === 4) bytes.writeUInt32LE(Number(value));
  else if (size === 8) bytes.writeBigUInt64LE(BigInt(value));
  else if (size === 16) { bytes.writeBigUInt64LE(BigInt(value) & ((1n << 64n) - 1n)); bytes.writeBigUInt64LE(BigInt(value) >> 64n, 8); }
  else throw new Error('Unsupported fixture integer size');
  return bytes;
}

export function nativeConfig(manager: PublicKey, emitter: PublicKey) {
  const mint = publicKey(ADDRESSES.usdc).toBuffer();
  const namespace = Buffer.from('PoolParty/SolanaAsset/v6');
  const paddedNamespace = Buffer.concat([namespace, Buffer.alloc(32 - namespace.length)]);
  const alias = hash(Buffer.concat([word(96), word(1), mint, word(namespace.length), paddedNamespace])).subarray(12);
  const asset = Buffer.concat([mint, alias, integer(0, 1)]);
  const venue = Buffer.concat([publicKey(ADDRESSES.kamino).toBuffer(), Buffer.alloc(32), publicKey(ADDRESSES.reserve).toBuffer(), mint, Buffer.alloc(32)]);
  const abi = Buffer.concat([word(6), word(64), publicKey(ADDRESSES.spoke).toBuffer(), emitter.toBuffer(), mint, manager.toBuffer(),
    word(1), word(224), word(352), word(1), mint, addressWord(alias), word(0), word(1), venue]);
  return { nativeHash: hash(abi), assets: Buffer.concat([integer(1, 4), asset]), venues: Buffer.concat([integer(1, 4), venue]) };
}

export function bindingPayload(manager: PublicKey, core = hubCore, index = 1, expiry = 2_000_000_000n) {
  const target = fundAddresses(core, index);
  const emitter = publicKey(target.emitter);
  const config = nativeConfig(manager, emitter);
  const nonce = word(9);
  const type = 'ManagerSolanaBinding(bytes32 solanaKey,address fund,bytes32 spoke,uint256 spokeChainId,bytes32 nativeMandateHash,uint256 nonce,uint256 expiry)';
  const domain = hash(Buffer.concat([hash(Buffer.from('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
    hash(Buffer.from('PoolParty Solana Fund')), hash(Buffer.from('6')), word(42161), addressWord(factory)]));
  const struct = hash(Buffer.concat([hash(Buffer.from(type)), manager.toBuffer(), addressWord(core), emitter.toBuffer(), word(1), config.nativeHash, nonce, word(expiry)]));
  const digest = hash(Buffer.concat([Buffer.from([25, 1]), domain, struct]));
  const ephemeralKey = secp256k1.utils.randomPrivateKey();
  const signature = secp256k1.sign(digest, ephemeralKey);
  const managerEvm = hash(Buffer.from(secp256k1.getPublicKey(ephemeralKey, false)).subarray(1)).subarray(12);
  return Buffer.concat([core, integer(index, 2), fundId, mandateHash, managerEvm, factory, integer(42161, 8), integer(1, 8),
    config.nativeHash, nonce, integer(expiry, 8), Buffer.from(signature.toCompactRawBytes()), integer(signature.recovery + 27, 1), config.assets, config.venues]);
}

export function fixtureFund(manager: PublicKey) {
  const fund = publicKey(addresses.fund);
  const program = publicKey(ADDRESSES.spoke);
  const index = integer(1, 2);
  const bump = PublicKey.findProgramAddressSync([Buffer.from('fund'), hubCore, index], program)[1];
  const vaultBump = PublicKey.findProgramAddressSync([Buffer.from('vault'), fund.toBuffer()], program)[1];
  const emitterBump = PublicKey.findProgramAddressSync([Buffer.from('emitter'), fund.toBuffer()], program)[1];
  const config = nativeConfig(manager, publicKey(addresses.emitter));
  return Buffer.concat([discriminator('account', 'FundState'), hubCore, index, fundId, mandateHash, Buffer.alloc(20, 1), manager.toBuffer(),
    integer(0, 8), integer(0, 8), integer(0, 1), integer(bump, 1), integer(vaultBump, 1), integer(emitterBump, 1),
    integer(42161, 8), factory, integer(1, 8), config.nativeHash, word(9), Buffer.alloc(32, 1), integer(2_000_000_000, 8),
    addressWord(hubCore), integer(23, 2), integer(0, 16), integer(0, 16), integer(0, 2), integer(0, 2), integer(0, 2), config.assets, config.venues]);
}

export function fixtureLedger() {
  const fund = publicKey(addresses.fund);
  const mint = publicKey(ADDRESSES.usdc);
  const bump = PublicKey.findProgramAddressSync([Buffer.from('ledger'), fund.toBuffer(), mint.toBuffer()], publicKey(ADDRESSES.spoke))[1];
  return Buffer.concat([discriminator('account', 'TokenLedger'), fund.toBuffer(), mint.toBuffer(), integer(50_000_000, 8), integer(0, 8), integer(0, 16), integer(bump, 1)]);
}

export function prepareCoreFixtures() {
  const manager = testWallet('manager').publicKey;
  const output = new URL('../../.localnet/overrides/', import.meta.url);
  mkdirSync(output, { recursive: true });
  function write(address: string, data: Buffer, owner: string) {
    const fixture = { pubkey: address, account: { lamports: 20_000_000, data: [data.toString('base64'), 'base64'], owner, executable: false, rentEpoch: 0 } };
    writeFileSync(new URL(`${address}.json`, output), JSON.stringify(fixture));
  }
  write(addresses.fund, fixtureFund(manager), ADDRESSES.spoke);
  write(derive(ADDRESSES.spoke, Buffer.from('ledger'), publicKey(addresses.fund).toBuffer(), publicKey(ADDRESSES.usdc).toBuffer()), fixtureLedger(), ADDRESSES.spoke);
  const token = Buffer.alloc(165);
  publicKey(ADDRESSES.usdc).toBuffer().copy(token);
  publicKey(addresses.vault).toBuffer().copy(token, 32);
  token.writeBigUInt64LE(60_000_000n, 64);
  token[108] = 1;
  write(testAta(ADDRESSES.usdc, publicKey(addresses.vault)).toBase58(), token, ADDRESSES.token);
}

export async function sendSignedLocal(connection: Connection, payer: Keypair, instructions: TransactionInstruction[], additional: Keypair[] = []) {
  requireLoopback(connection.rpcEndpoint);
  for (let attempt = 0; attempt < 5; attempt++) {
    const blockhash = await connection.getLatestBlockhash('confirmed');
    const transaction = new Transaction({ feePayer: payer.publicKey, recentBlockhash: blockhash.blockhash }).add(...instructions);
    transaction.sign(payer, ...additional);
    let signature: string;
    try { signature = await connection.sendRawTransaction(transaction.serialize(), { preflightCommitment: 'confirmed' }); }
    catch (error) {
      if (!(error instanceof SendTransactionError) || !error.message.startsWith('Simulation failed.')
          || !error.transactionError.message.includes('Program cache hit max limit') || attempt === 4) throw error;
      await new Promise(resolve => setTimeout(resolve, 1000 * (attempt + 1)));
      continue;
    }
    const result = await connection.confirmTransaction({ signature, ...blockhash }, 'confirmed');
    if (result.value.err) throw new Error(`Submitted local transaction failed: ${JSON.stringify(result.value.err)}`);
    return signature;
  }
  throw new Error('Local validator program cache did not become ready');
}
