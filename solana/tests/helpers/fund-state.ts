import { PublicKey } from '@solana/web3.js';
import { ADDRESSES, publicKey } from './addresses.ts';

export function completeFundState(prefix: Buffer): Buffer {
  if (prefix.length !== 165) throw new Error('Unexpected legacy FundState fixture prefix');
  const fund = PublicKey.findProgramAddressSync([Buffer.from('fund'), prefix.subarray(8, 28), prefix.subarray(28, 30), prefix.subarray(62, 94)], publicKey(ADDRESSES.spoke))[0];
  const extension = Buffer.alloc(221);
  extension[0] = PublicKey.findProgramAddressSync([Buffer.from('emitter'), fund.toBuffer()], publicKey(ADDRESSES.spoke))[1];
  extension.writeBigUInt64LE(42161n, 1);
  extension.writeBigUInt64LE(1n, 29);
  extension.writeUInt16LE(23, 173);
  return Buffer.concat([prefix, extension, Buffer.alloc(200)]);
}
