import { writeFileSync } from 'node:fs';
import { ADDRESSES, derive } from '../helpers/addresses.ts';
import { fundId, word, addressWord, hash, integer } from '../core/fixtures.ts';

// CR-28 / DEC-205: local guardian fixture (genesis PostedVAA accounts), same technique as the rehearsal ACKs.
export const CLOSE_PENDING = {
  core: Buffer.alloc(20, 0xc9),
  index: 21,
  inbound: word(2901),
  cctpNonce: word(3901),
  outbound: word(902),
  request: word(9001),
};

function posted(root: URL, sequence: bigint, payload: Buffer, timestamp: number): string {
  const emitter = addressWord(CLOSE_PENDING.core);
  const encodedTimestamp = Buffer.alloc(4); encodedTimestamp.writeUInt32BE(timestamp);
  const encodedSequence = Buffer.alloc(8); encodedSequence.writeBigUInt64BE(sequence);
  const encodedChain = Buffer.alloc(2); encodedChain.writeUInt16BE(23);
  const body = Buffer.concat([encodedTimestamp, Buffer.alloc(4), encodedChain, emitter, encodedSequence, Buffer.from([200]), payload]);
  const address = derive(ADDRESSES.wormhole, Buffer.from('PostedVAA'), hash(body));
  const data = Buffer.concat([Buffer.from('vaa'), Buffer.from([1, 200]), integer(timestamp, 4), Buffer.alloc(32, 1), integer(timestamp, 4),
    Buffer.alloc(4), integer(sequence, 8), integer(23, 2), emitter, integer(payload.length, 4), payload]);
  writeFileSync(new URL(`overrides/${address}.json`, root), JSON.stringify({ pubkey: address,
    account: { owner: ADDRESSES.wormhole, data: [data.toString('base64'), 'base64'], lamports: 10_000_000, executable: false, rentEpoch: 0 } }));
  return address;
}

/** Hub CLOSE at Wormhole sequence 0 (CR-16) and the later arrival ACK at sequence 1 for the pending outbound transit. */
export function prepareClosePendingVaas(root: URL) {
  const now = Math.floor(Date.now() / 1000);
  const issued = now - 600;
  const deadline = BigInt(now + 7 * 86_400);
  const close = Buffer.concat([word(1), word(2), fundId, CLOSE_PENDING.request, word(0), word(deadline), word(1), word(1),
    word(0), word(0), word(issued)]);
  const transitId = hash(Buffer.concat([Buffer.from('PoolParty/CCTPTransit/v2'), fundId, word(5), word(3), CLOSE_PENDING.outbound]));
  const ack = Buffer.concat([word(1), word(4), fundId, transitId, word(0), word(deadline), word(1), word(2), word(0), word(0), word(0)]);
  const vaas = { close: posted(root, 0n, close, issued), ack: posted(root, 1n, ack, issued),
    order: hash(Buffer.concat([word(2), fundId, CLOSE_PENDING.request, word(0)])).toString('hex') };
  writeFileSync(new URL('close-pending-vaas.json', root), JSON.stringify(vaas, null, 2));
  return vaas;
}
