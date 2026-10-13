import { keccak_256 } from '@noble/hashes/sha3';
import { PublicKey } from '@solana/web3.js';
import type { ApiInstruction } from './jupiter.ts';

const hash = (bytes: Uint8Array | string) => Buffer.from(keccak_256(typeof bytes === 'string' ? Buffer.from(bytes) : bytes));
const word = (value: bigint) => {
  if (value < 0n || value >= 1n << 64n) throw new Error('Quote integer outside u64');
  const bytes = Buffer.alloc(32);
  bytes.writeBigUInt64BE(value, 24);
  return bytes;
};
export type ApiQuote = {
  fund: PublicKey; tokenIn: PublicKey; tokenOut: PublicKey; legsHash: Buffer;
  quotedAmountIn: bigint; minAmountOut: bigint; deadline: bigint; nonce: bigint; signature: Buffer;
};
export type QuoteDomain = { chainId: bigint; verifyingContract: Buffer; program: PublicKey };

export function quoteDigest(quote: ApiQuote, domain: QuoteDomain): Buffer {
  if (domain.verifyingContract.length !== 20 || quote.legsHash.length !== 32) throw new Error('Invalid quote domain/hash');
  const separator = hash(Buffer.concat([
    hash('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)'),
    hash('Pool Party Swap Adapter'), hash('2'), word(domain.chainId), Buffer.concat([Buffer.alloc(12), domain.verifyingContract]), domain.program.toBuffer(),
  ]));
  const struct = hash(Buffer.concat([
    hash('SolanaSwapRoute(bytes32 fund,bytes32 tokenIn,bytes32 tokenOut,bytes32 legsHash,uint256 quotedAmountIn,uint256 minAmountOut,uint256 deadline,uint256 nonce)'),
    quote.fund.toBuffer(), quote.tokenIn.toBuffer(), quote.tokenOut.toBuffer(), quote.legsHash,
    word(quote.quotedAmountIn), word(quote.minAmountOut), word(quote.deadline), word(quote.nonce),
  ]));
  return hash(Buffer.concat([Buffer.from([25, 1]), separator, struct]));
}

export function routeHash(instruction: ApiInstruction, vault: PublicKey): Buffer {
  const data = Buffer.from(instruction.data, 'base64');
  const length = Buffer.alloc(4); length.writeUInt32LE(data.length);
  const count = Buffer.alloc(4); count.writeUInt32LE(instruction.accounts.length);
  return hash(Buffer.concat([length, data, count, ...instruction.accounts.map(account => Buffer.concat([
    new PublicKey(account.pubkey).toBuffer(), Buffer.from([Number(account.pubkey === vault.toBase58()), Number(account.isWritable)]),
  ]))]));
}

export function encodeQuote(quote: ApiQuote): Buffer {
  if (quote.signature.length !== 65 || quote.legsHash.length !== 32) throw new Error('Invalid signed API quote');
  const numbers = Buffer.alloc(32);
  [quote.quotedAmountIn, quote.minAmountOut, quote.deadline, quote.nonce].forEach((value, index) => numbers.writeBigUInt64LE(value, index * 8));
  return Buffer.concat([quote.fund.toBuffer(), quote.tokenIn.toBuffer(), quote.tokenOut.toBuffer(), quote.legsHash, numbers, quote.signature]);
}
