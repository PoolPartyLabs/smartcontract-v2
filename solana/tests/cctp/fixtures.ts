import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { secp256k1 } from '@noble/curves/secp256k1';
import { keccak_256 } from '@noble/hashes/sha3';
import { PublicKey } from '@solana/web3.js';
import { completeFundState } from '../helpers/fund-state.ts';
import { createHash } from 'node:crypto';
import { ADDRESSES, derive, publicKey } from '../helpers/addresses.ts';
import { discriminator } from '../helpers/layouts.ts';
import { testAta, testWallet } from '../helpers/localnet.ts';

export const HUB = Buffer.alloc(20, 9);
export const CONNECTOR = Buffer.alloc(20, 10);
export const FUND_ID = Buffer.alloc(32, 7);
export const CHAIN = 1n;
export const MANDATE = Buffer.alloc(32, 11);
export const fund = derive(ADDRESSES.spoke, Buffer.from('fund'), HUB, Buffer.from([0, 0]), MANDATE);
export const vault = derive(ADDRESSES.spoke, Buffer.from('vault'), publicKey(fund).toBuffer());
export const route = derive(ADDRESSES.spoke, Buffer.from('cctp_route'), publicKey(fund).toBuffer());
export const ledger = derive(ADDRESSES.spoke, Buffer.from('cctp_ledger'), publicKey(fund).toBuffer());
export const recipient = testAta(ADDRESSES.usdc, publicKey(vault));
const root = fileURLToPath(new URL('../../.localnet/', import.meta.url));

export function uint64(value: bigint): Buffer {
  const data = Buffer.alloc(8);
  data.writeBigUInt64LE(value);
  return data;
}

export function word(value: bigint): Buffer {
  const data = Buffer.alloc(32);
  data.writeBigUInt64BE(value, 24);
  return data;
}

export function evm(hex: string | Buffer): Buffer {
  return Buffer.concat([Buffer.alloc(12), typeof hex === 'string' ? Buffer.from(hex, 'hex') : hex]);
}

export function hook(id: Buffer, chain = 42161n): Buffer {
  return Buffer.concat([word(1n), FUND_ID, word(chain), id, word(0n)]);
}

export function arrival(id: Buffer, nonce: Buffer, amount = 1_000_000n, fee = 100n): Buffer {
  const message = Buffer.alloc(536);
  for (const [offset, value] of [[0, 1], [4, 3], [8, 5], [140, 1000], [144, 1000], [148, 1]]) message.writeUInt32BE(value, offset);
  nonce.copy(message, 12);
  evm('28b5a0e9c621a5badaa536219b3a228c8168cf5d').copy(message, 44);
  publicKey(ADDRESSES.cctpMessenger).toBuffer().copy(message, 76);
  publicKey(vault).toBuffer().copy(message, 108);
  evm('af88d065e77c8cc2239327c5edb3a432268e5831').copy(message, 152);
  recipient.toBuffer().copy(message, 184);
  word(amount).copy(message, 216);
  evm(HUB).copy(message, 248);
  word(200n).copy(message, 280);
  word(fee).copy(message, 312);
  hook(id).copy(message, 376);
  return message;
}

function localAttester(): Buffer {
  const scalar = Buffer.alloc(32);
  scalar[31] = 1;
  return scalar;
}

export function attest(message: Buffer): Buffer {
  const signature = secp256k1.sign(keccak_256(message), localAttester(), { lowS: true });
  return Buffer.concat([Buffer.from(signature.toCompactRawBytes()), Buffer.from([signature.recovery + 27])]);
}

function snapshot(address: string, overrides = false): any {
  return JSON.parse(readFileSync(`${root}/${overrides ? 'overrides' : 'accounts'}/${address}.json`, 'utf8'));
}

function write(address: string, data: Buffer, owner: string = ADDRESSES.spoke, lamports = 10_000_000): void {
  writeFileSync(`${root}/overrides/${address}.json`, JSON.stringify({ pubkey: address, account: {
    data: [data.toString('base64'), 'base64'], owner, lamports, executable: false, rentEpoch: 0,
  } }));
}

export function prepareCctpFixtures(): void {
  const transmitter = derive(ADDRESSES.cctpTransmitter, Buffer.from('message_transmitter'));
  const backup = `${root}/cctp-original-transmitter.json`;
  const current = snapshot(transmitter);
  const manifest = JSON.parse(readFileSync(`${root}/manifest.json`, 'utf8'));
  const sourceHash = manifest.accounts.find((account: { address: string }) => account.address === transmitter)?.sha256;
  const hash = (account: any) => createHash('sha256').update(Buffer.from(account.account.data[0], 'base64')).digest('hex');
  const cloned = hash(current) === sourceHash ? current : existsSync(backup) ? JSON.parse(readFileSync(backup, 'utf8')) : null;
  if (!cloned || hash(cloned) !== sourceHash) throw new Error('Original Circle snapshot does not match current clone manifest; re-prepare first');
  writeFileSync(backup, JSON.stringify(cloned));
  const original = Buffer.from(cloned.account.data[0], 'base64');
  if (cloned.account.owner !== ADDRESSES.cctpTransmitter || !original.subarray(0, 8).equals(discriminator('account', 'MessageTransmitter'))
      || original[136] !== 0 || original.readUInt32LE(137) !== 5 || original.readUInt32LE(141) !== 1) throw new Error('Unexpected cloned Circle transmitter layout');
  const count = original.readUInt32LE(149);
  if (count === 0 || 153 + count * 32 + 8 > original.length) throw new Error('Unexpected cloned attester vector');
  const enabled = evm(Buffer.from(keccak_256(secp256k1.getPublicKey(localAttester(), false).subarray(1))).subarray(12));
  const overridden = Buffer.concat([original.subarray(0, 145), Buffer.from([1, 0, 0, 0, 1, 0, 0, 0]), enabled,
    original.subarray(153 + count * 32, 161 + count * 32)]);
  const allocation = Buffer.alloc(original.length);
  overridden.copy(allocation);
  write(transmitter, allocation, ADDRESSES.cctpTransmitter, cloned.account.lamports);
  writeFileSync(`${root}/accounts/${transmitter}.json`, readFileSync(`${root}/overrides/${transmitter}.json`));
  const manager = testWallet();
  const fundBump = publicKey(ADDRESSES.spoke);
  const find = (seeds: Buffer[]) => PublicKey.findProgramAddressSync(seeds, fundBump)[1];
  write(fund, completeFundState(Buffer.concat([discriminator('account', 'FundState'), HUB, Buffer.alloc(2), FUND_ID, MANDATE, Buffer.alloc(20, 12),
    manager.publicKey.toBuffer(), uint64(0n), uint64(0n), Buffer.from([0, find([Buffer.from('fund'), HUB, Buffer.alloc(2), MANDATE]), find([Buffer.from('vault'), publicKey(fund).toBuffer()])])])));
  write(route, Buffer.concat([discriminator('account', 'CctpRoute'), publicKey(fund).toBuffer(), MANDATE, CONNECTOR, uint64(CHAIN), uint64(50_000n), Buffer.from([1])]));
  write(ledger, Buffer.concat([discriminator('account', 'CctpLedger'), publicKey(fund).toBuffer(), uint64(10_000_000n), Buffer.alloc(40)]));
  const [tokenLedger, tokenBump] = PublicKey.findProgramAddressSync([Buffer.from('ledger'), publicKey(fund).toBuffer(), publicKey(ADDRESSES.usdc).toBuffer()], publicKey(ADDRESSES.spoke));
  write(tokenLedger.toBase58(), Buffer.concat([discriminator('account', 'TokenLedger'), publicKey(fund).toBuffer(), publicKey(ADDRESSES.usdc).toBuffer(), uint64(10_000_000n), Buffer.alloc(24), Buffer.from([tokenBump])]));
  const token = snapshot(testAta(ADDRESSES.usdc, manager.publicKey).toBase58(), true);
  const tokenData = Buffer.from(token.account.data[0], 'base64');
  publicKey(vault).toBuffer().copy(tokenData, 32);
  tokenData.writeBigUInt64LE(10_000_000n, 64);
  write(recipient.toBase58(), tokenData, ADDRESSES.token, token.account.lamports);
  writeFileSync(`${root}/cctp-fixture.json`, JSON.stringify({ localOnly: true, fund, vault, route, ledger,
    recipient: recipient.toBase58(), attester: new PublicKey(enabled).toBase58(), overriddenAccounts: [transmitter, fund, route, ledger, recipient.toBase58()],
    notes: 'Synthetic verified Fund/route/ledger genesis replaces unavailable T1 init; only attesters/threshold modified in Circle state; no mainnet transactions.' }, null, 2));
  console.log('Prepared local-only CCTP attester, sealed Fund route and funded vault fixtures.');
}

if (process.argv[1] === fileURLToPath(import.meta.url)) prepareCctpFixtures();
