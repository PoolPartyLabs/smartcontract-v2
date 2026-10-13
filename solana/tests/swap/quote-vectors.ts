import { writeFileSync } from 'node:fs';
import { PublicKey } from '@solana/web3.js';
import { secp256k1 } from '@noble/curves/secp256k1';
import { keccak_256 } from '@noble/hashes/sha3';
import { quoteDigest, encodeQuote } from '../../clients/swap/quote.ts';

const domain = { chainId: 42161n, verifyingContract: Buffer.alloc(20, 5), program: new PublicKey(Buffer.alloc(32, 77)) };
const quote = { fund: new PublicKey(Buffer.alloc(32, 78)), tokenIn: new PublicKey(Buffer.alloc(32, 1)),
  tokenOut: new PublicKey(Buffer.alloc(32, 2)), legsHash: Buffer.alloc(32, 3), quotedAmountIn: 100n,
  minAmountOut: 198n, deadline: 2000n, nonce: 0n, signature: Buffer.alloc(65) };
const localTestScalar = Buffer.alloc(32, 42);
const digest = quoteDigest(quote, domain);
const signature = secp256k1.sign(digest, localTestScalar);
quote.signature = Buffer.concat([Buffer.from(signature.toCompactRawBytes()), Buffer.from([27 + signature.recovery])]);
const signer = Buffer.from(keccak_256(secp256k1.getPublicKey(localTestScalar, false).subarray(1))).subarray(12);
writeFileSync(new URL('./fixtures/v2/api-quote.bin', import.meta.url), encodeQuote(quote));
writeFileSync(new URL('./fixtures/v2/api-quote-vector.json', import.meta.url), JSON.stringify({
  testOnly: true, domain: { chainId: '42161', verifyingContract: domain.verifyingContract.toString('hex'), program: domain.program.toBase58() },
  signer: signer.toString('hex'), digest: digest.toString('hex'),
}, null, 2) + '\n');
