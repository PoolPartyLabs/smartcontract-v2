import test from 'node:test';
import assert from 'node:assert/strict';
import { PublicKey, SystemProgram, TransactionInstruction } from '@solana/web3.js';
import { secp256k1 } from '@noble/curves/secp256k1';
import { ADDRESSES, publicKey, derive } from '../helpers/addresses.ts';
import { localConnection, testWallet, testAta } from '../helpers/localnet.ts';
import { discriminator } from '../helpers/layouts.ts';
import { nativeConfig, hash, word, addressWord, integer, factory, fundId, mandateHash, sendSignedLocal } from './fixtures.ts';

const bootstrapType = 'SolanaBootstrap(uint256 hubChain,address core,bytes32 mandateHash,bytes32 policyHash,uint16 spokeIndex,bytes32 program,bytes32 fundPda,bytes32 solanaKey,bytes32 usdcAta,bytes32 tslaxAta,bytes32 nvdaxAta,bytes32 wsolAta,bytes32 nativeMandateHash,bytes32 fundId,uint256 nonce,uint256 expiry)';

function policyInit(manager: PublicKey, core: Buffer, changePolicy = false) {
  const program = publicKey(ADDRESSES.spoke);
  const hubPolicy = Buffer.alloc(32, 0x11);
  const empty = nativeConfig(manager, PublicKey.default, PublicKey.default);
  const nativePolicy = hash(Buffer.concat([word(6), word(64), program.toBuffer(), Buffer.alloc(32),
    publicKey(ADDRESSES.usdc).toBuffer(), manager.toBuffer(), word(1), word(512), word(640),
    ...[0, 20, 40].map(offset => addressWord(empty.transport.subarray(offset, offset + 20))), word(5),
    Buffer.alloc(64), publicKey(ADDRESSES.cctpMessenger).toBuffer(), Buffer.alloc(32), word(50_000), word(1),
    empty.assets.subarray(4, 36), addressWord(empty.assets.subarray(36, 56)), word(0), word(1), empty.venues.subarray(4)]));
  const policyHash = hash(Buffer.concat([hash(Buffer.from('PoolParty/SolanaPolicy/v6')), hubPolicy, nativePolicy]));
  const fund = PublicKey.findProgramAddressSync([Buffer.from('fund'), integer(42161, 8), core, integer(1, 2), policyHash], program)[0];
  const vault = PublicKey.findProgramAddressSync([Buffer.from('vault'), fund.toBuffer()], program)[0];
  const emitter = PublicKey.findProgramAddressSync([Buffer.from('emitter'), fund.toBuffer()], program)[0];
  const config = nativeConfig(manager, emitter, fund);
  const secret = secp256k1.utils.randomPrivateKey();
  const managerEvm = hash(Buffer.from(secp256k1.getPublicKey(secret, false)).subarray(1)).subarray(12);
  const domain = hash(Buffer.concat([hash(Buffer.from('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
    hash(Buffer.from('PoolParty Solana Fund')), hash(Buffer.from('6')), word(42161), addressWord(factory)]));
  const expiry = 2_000_000_000n;
  const message = hash(Buffer.concat([hash(Buffer.from(bootstrapType)), word(42161), addressWord(core), mandateHash,
    policyHash, word(1), program.toBuffer(), fund.toBuffer(), manager.toBuffer(),
    ...[ADDRESSES.usdc, ADDRESSES.tslax, 'Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh', ADDRESSES.wsol].map(mint => testAta(mint, vault).toBuffer()),
    config.nativeHash, fundId, word(9), word(expiry)]));
  const signature = secp256k1.sign(hash(Buffer.concat([Buffer.from([25, 1]), domain, message])), secret);
  const submittedPolicy = Buffer.from(policyHash);
  if (changePolicy) submittedPolicy[0] ^= 1;
  const payload = Buffer.concat([core, integer(1, 2), fundId, mandateHash, managerEvm, factory, integer(42161, 8), integer(1, 8),
    config.nativeHash, word(9), integer(expiry, 8), Buffer.from(signature.toCompactRawBytes()), integer(signature.recovery + 27, 1),
    config.assets, config.venues, config.transport, hubPolicy, submittedPolicy]);
  const keys = [
    { pubkey: manager, isSigner: true, isWritable: true }, { pubkey: fund, isSigner: false, isWritable: true },
    { pubkey: vault, isSigner: false, isWritable: false },
    ...[ADDRESSES.usdc, ADDRESSES.tslax, ADDRESSES.wsol].map(mint => ({ pubkey: publicKey(mint), isSigner: false, isWritable: false })),
    ...[ADDRESSES.usdc, ADDRESSES.tslax, ADDRESSES.wsol].map(mint => ({ pubkey: testAta(mint, vault), isSigner: false, isWritable: true })),
    ...[ADDRESSES.usdc, ADDRESSES.tslax, ADDRESSES.wsol].map(mint => ({ pubkey: publicKey(derive(ADDRESSES.spoke, Buffer.from('ledger'), fund.toBuffer(), publicKey(mint).toBuffer())), isSigner: false, isWritable: true })),
    ...['cctp_route', 'cctp_ledger'].map(seed => ({ pubkey: publicKey(derive(ADDRESSES.spoke, Buffer.from(seed), fund.toBuffer())), isSigner: false, isWritable: true })),
    ...[ADDRESSES.token, ADDRESSES.token2022, ADDRESSES.ata].map(address => ({ pubkey: publicKey(address), isSigner: false, isWritable: false })),
    { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
  ];
  return { fund, instruction: new TransactionInstruction({ programId: program, keys,
    data: Buffer.concat([discriminator('global', 'initialize_fund'), integer(payload.length, 4), payload]) }) };
}

test('policy bootstrap rejects mismatches and accepts only the signed derived PDA', async () => {
  const connection = localConnection();
  const manager = testWallet('manager');
  const bad = policyInit(manager.publicKey, Buffer.alloc(20, 0x91), true);
  await assert.rejects(sendSignedLocal(connection, manager, [bad.instruction]));
  assert.equal(await connection.getAccountInfo(bad.fund), null);
  const valid = policyInit(manager.publicKey, Buffer.alloc(20, 0x92));
  await sendSignedLocal(connection, manager, [SystemProgram.transfer({ fromPubkey: manager.publicKey, toPubkey: valid.fund, lamports: 1_000_000 })]);
  await sendSignedLocal(connection, manager, [valid.instruction]);
  const account = await connection.getAccountInfo(valid.fund);
  assert.equal(account?.owner.toBase58(), ADDRESSES.spoke);
  await assert.rejects(sendSignedLocal(connection, manager, [valid.instruction]));
});
