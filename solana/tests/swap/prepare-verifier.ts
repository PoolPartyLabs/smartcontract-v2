import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { PublicKey } from '@solana/web3.js';
import { secp256k1 } from '@noble/curves/secp256k1';
import { keccak_256 } from '@noble/hashes/sha3';

const root = new URL('../../.localnet/', import.meta.url);
const verifier = new PublicKey('Gt9S41PtjR58CbG9JhJ3J6vxesqrNAswbWYbLNTMZA3c');
const state = PublicKey.findProgramAddressSync([Buffer.from('verifier')], verifier)[0];
const controller = new PublicKey(Buffer.alloc(32, 88));
const configDigest = Buffer.alloc(32, 11);
const config = PublicKey.findProgramAddressSync([configDigest], verifier)[0];
const original = JSON.parse(readFileSync(new URL(`accounts/${state.toBase58()}.json`, root), 'utf8'));
const data = Buffer.from(original.account.data[0], 'base64');
data.fill(0, 16); data.writeUInt16LE(1, 112);
const don = 120; data.writeUInt32LE(1, don); data[don + 28] = 1; data[don + 29] = 1;
for (const [index, scalar] of [42, 43].entries()) {
  const address = Buffer.from(keccak_256(secp256k1.getPublicKey(Buffer.alloc(32, scalar), false).subarray(1))).subarray(12);
  address.copy(data, don + 31 + index * 20);
}
data[don + 31 + 31 * 20] = 2;
function save(address: PublicKey, bytes: Buffer, owner: PublicKey) {
  writeFileSync(new URL(`overrides/${address.toBase58()}.json`, root), JSON.stringify({ pubkey: address.toBase58(), account: {
    data: [bytes.toString('base64'), 'base64'], owner: owner.toBase58(), executable: false, lamports: 2_000_000_000, rentEpoch: 0,
  } }));
}
save(state, data, verifier);
const access = Buffer.alloc(2120); createHash('sha256').update('account:AccessController').digest().subarray(0, 8).copy(access);
save(controller, access, new PublicKey('EjVftbXwfRZoZDzJ6eHArCqiBiPHBLq5zajRqMiHGH1A'));
save(config, Buffer.alloc(0), new PublicKey('11111111111111111111111111111111'));
save(new PublicKey(Buffer.alloc(32, 78)), Buffer.alloc(8), new PublicKey(Buffer.alloc(32, 77)));
writeFileSync(new URL('verifier-fixture.json', root), JSON.stringify({ verifier: verifier.toBase58(), state: state.toBase58(), controller: controller.toBase58(), config: config.toBase58(), configDigest: configDigest.toString('hex') }));
console.log('LOCAL ONLY: cloned verifier DON replaced with two test signers; no production oracle configuration');
