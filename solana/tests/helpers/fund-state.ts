import { PublicKey } from '@solana/web3.js';
import { ADDRESSES, publicKey } from './addresses.ts';

export function completeFundState(prefix: Buffer, venues: Buffer[] = [], positions: string[] = [], transits: string[] = []): Buffer {
  if (prefix.length !== 165) throw new Error('Unexpected legacy FundState fixture prefix');
  const fund = PublicKey.findProgramAddressSync([Buffer.from('fund'), prefix.subarray(8, 28), prefix.subarray(28, 30), prefix.subarray(62, 94)], publicKey(ADDRESSES.spoke))[0];
  const extension = Buffer.alloc(221);
  extension[0] = PublicKey.findProgramAddressSync([Buffer.from('emitter'), fund.toBuffer()], publicKey(ADDRESSES.spoke))[1];
  extension.writeBigUInt64LE(42161n, 1);
  extension.writeBigUInt64LE(1n, 29);
  extension.writeUInt16LE(23, 173);
  const venueCount = Buffer.alloc(4); venueCount.writeUInt32LE(venues.length);
  const positionCount = Buffer.alloc(4); positionCount.writeUInt32LE(positions.length);
  const transitCount = Buffer.alloc(4); transitCount.writeUInt32LE(transits.length);
  extension.writeUInt16LE(transits.length, 209);
  return Buffer.concat([prefix, extension.subarray(0, 217), venueCount, ...venues, Buffer.alloc(200),
    positionCount, ...positions.map(position => publicKey(position).toBuffer()),
    transitCount, ...transits.map(transit => publicKey(transit).toBuffer()), Buffer.alloc(4096)]);
}
