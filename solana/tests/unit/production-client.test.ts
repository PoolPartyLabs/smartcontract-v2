import assert from 'node:assert/strict';
import test from 'node:test';
import { AddressLookupTableAccount, ComputeBudgetProgram, Keypair, PublicKey, SystemProgram, Transaction, TransactionInstruction, TransactionMessage, VersionedTransaction } from '@solana/web3.js';
import { secp256k1 } from '@noble/curves/secp256k1';
import { ADDRESSES, derive, publicKey } from '../helpers/addresses.ts';
import { discriminator } from '../helpers/layouts.ts';
import { testAta } from '../helpers/localnet.ts';
import { addressWord, bindingPayload, factory, fundId, hash, hubPolicyHash, initializationPlan, integer, mandateHash, policyAddresses, stageSwapPolicy, word } from '../core/fixtures.ts';
import { creation, policyBytes, policyDigest } from '../swap/production-client.ts';

const manager = Keypair.fromSeed(Buffer.alloc(32, 8));
const apiKey = Buffer.alloc(32, 1);
const core = Buffer.alloc(20, 0xc8);
const pool = { mint0: ADDRESSES.usdc, mint1: ADDRESSES.wsol };

function initializer(payload: Buffer, fund: PublicKey, vault: PublicKey, remaining: PublicKey[] = []) {
  const mints = [ADDRESSES.usdc, ADDRESSES.tslax, ADDRESSES.wsol];
  const keys = [
    { pubkey: manager.publicKey, isSigner: true, isWritable: true },
    { pubkey: fund, isSigner: false, isWritable: true },
    { pubkey: vault, isSigner: false, isWritable: false },
    ...mints.map(mint => ({ pubkey: publicKey(mint), isSigner: false, isWritable: false })),
    ...mints.map(mint => ({ pubkey: testAta(mint, vault), isSigner: false, isWritable: true })),
    ...mints.map(mint => ({ pubkey: publicKey(derive(ADDRESSES.spoke, Buffer.from('ledger'), fund.toBuffer(), publicKey(mint).toBuffer())), isSigner: false, isWritable: true })),
    ...['cctp_route', 'cctp_ledger'].map(seed => ({ pubkey: publicKey(derive(ADDRESSES.spoke, Buffer.from(seed), fund.toBuffer())), isSigner: false, isWritable: true })),
    ...[ADDRESSES.token, ADDRESSES.token2022, ADDRESSES.ata, SystemProgram.programId.toBase58()].map(address => ({ pubkey: publicKey(address), isSigner: false, isWritable: false })),
    ...remaining.map(pubkey => ({ pubkey, isSigner: false, isWritable: true })),
  ];
  return new TransactionInstruction({ programId: publicKey(ADDRESSES.spoke), keys,
    data: Buffer.concat([discriminator('global', 'initialize_fund'), integer(payload.length, 4), payload]) });
}

function packetBytes(operation: TransactionInstruction) {
  const addresses = [...new Map(operation.keys.filter(account => !account.isSigner).map(account => [account.pubkey.toBase58(), account.pubkey])).values()];
  const table = new AddressLookupTableAccount({ key: PublicKey.default, state: {
    deactivationSlot: (1n << 64n) - 1n, lastExtendedSlot: 0, lastExtendedSlotStartIndex: 0, addresses,
  } });
  return new VersionedTransaction(new TransactionMessage({ payerKey: manager.publicKey, recentBlockhash: PublicKey.default.toBase58(),
    instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units: 600_000 }), operation] }).compileToV0Message([table])).serialize().length;
}

function request(operation: TransactionInstruction) {
  assert.deepEqual(operation.data.subarray(0, 8), discriminator('global', 'stage_swap_policy'));
  const bytes = operation.data.subarray(12);
  assert.equal(operation.data.readUInt32LE(8), bytes.length);
  const size = bytes.readUInt32LE(36);
  assert.equal(bytes.length, 41 + size);
  return { policyHash: bytes.subarray(0, 32), total: bytes.readUInt16LE(32), offset: bytes.readUInt16LE(34),
    chunk: bytes.subarray(40, 40 + size), seal: bytes[40 + size] === 1 };
}

function replay(policyHash: Buffer, total: number) {
  let payload = Buffer.alloc(0);
  let sealed = false;
  return {
    append(operation: TransactionInstruction) {
      const decoded = request(operation);
      if (sealed || !decoded.policyHash.equals(policyHash) || decoded.total !== total || decoded.offset !== payload.length
        || decoded.chunk.length === 0 || decoded.chunk.length > 600 || payload.length + decoded.chunk.length > total
        || (decoded.seal && payload.length + decoded.chunk.length !== total)) throw new Error('Rejected stage request');
      payload = Buffer.concat([payload, decoded.chunk]);
      sealed = decoded.seal;
    },
    snapshot: () => ({ payload: Buffer.from(payload), sealed }),
  };
}

test('production hashes include exact Borsh swap policy and identity-free native ABI', () => {
  const result = creation(manager.publicKey, core, 18, pool, apiKey);
  const payload = result.payload;
  let offset = 279;
  const count = payload.readUInt32LE(offset); offset += 4;
  const assets: Buffer[] = [];
  for (let index = 0; index < count; index++) {
    assets.push(payload.subarray(offset, offset + 32), addressWord(payload.subarray(offset + 32, offset + 52)), word(payload[offset + 52]));
    offset += 53;
  }
  const venueCount = payload.readUInt32LE(offset); offset += 4;
  const venues = payload.subarray(offset, offset + venueCount * 160); offset += venues.length;
  const transport = payload.subarray(offset, offset + 200);
  const abi = Buffer.concat([word(6), word(64), publicKey(ADDRESSES.spoke).toBuffer(), Buffer.alloc(32),
    publicKey(ADDRESSES.usdc).toBuffer(), manager.publicKey.toBuffer(), word(1), word(544), word(544 + 32 + count * 96),
    ...[0, 20, 40].map(start => addressWord(transport.subarray(start, start + 20))), word(5), Buffer.alloc(64),
    transport.subarray(128, 160), Buffer.alloc(32), word(50_000), hash(policyBytes(apiKey)), word(count), ...assets, word(venueCount), venues]);
  assert.deepEqual(hash(abi), result.nativePolicyHash);
  assert.deepEqual(hash(Buffer.concat([hash(Buffer.from('PoolParty/SolanaPolicy/v6')), hubPolicyHash, hash(abi)])), result.policyHash);
  const vault = publicKey(result.target.vault);
  publicKey(result.target.emitter).toBuffer().copy(abi, 96);
  testAta(ADDRESSES.usdc, vault).toBuffer().copy(abi, 416);
  vault.toBuffer().copy(abi, 448); vault.toBuffer().copy(abi, 512);
  assert.deepEqual(hash(abi), result.nativeHash);
  assert.deepEqual(payload.subarray(offset + 200, offset + 296), Buffer.concat([hubPolicyHash, result.policyHash, hash(result.policy)]));
});

test('bootstrap policy member and policy consent recover the same Manager', () => {
  const result = creation(manager.publicKey, core, 18, pool, apiKey);
  const fund = publicKey(result.target.fund); const vault = publicKey(result.target.vault);
  const domain = hash(Buffer.concat([hash(Buffer.from('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
    hash(Buffer.from('PoolParty Solana Fund')), hash(Buffer.from('6')), word(42161), addressWord(factory)]));
  const type = 'SolanaBootstrap(uint256 hubChain,address core,bytes32 mandateHash,bytes32 policyHash,uint16 spokeIndex,bytes32 program,bytes32 fundPda,bytes32 solanaKey,bytes32 usdcAta,bytes32 tslaxAta,bytes32 nvdaxAta,bytes32 wsolAta,bytes32 nativeMandateHash,bytes32 fundId,uint256 nonce,uint256 expiry)';
  const message = hash(Buffer.concat([hash(Buffer.from(type)), word(42161), addressWord(core), mandateHash, result.policyHash, word(18),
    publicKey(ADDRESSES.spoke).toBuffer(), fund.toBuffer(), manager.publicKey.toBuffer(),
    ...[ADDRESSES.usdc, ADDRESSES.tslax, 'Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh', ADDRESSES.wsol].map(mint => testAta(mint, vault).toBuffer()),
    result.nativeHash, fundId, word(9), word(2_000_000_000n)]));
  assert.deepEqual(hash(Buffer.concat([Buffer.from([25, 1]), domain, message])), result.bindingDigest);
  const recover = (bytes: Buffer, digest: Buffer) => hash(secp256k1.Signature.fromCompact(bytes.subarray(0, 64))
    .addRecoveryBit(bytes[64] - 27).recoverPublicKey(digest).toRawBytes(false).subarray(1)).subarray(12);
  assert.deepEqual(recover(result.payload.subarray(214, 279), result.bindingDigest), result.payload.subarray(86, 106));
  assert.deepEqual(recover(result.payload.subarray(-65), policyDigest(result.policy, result.bindingDigest, fund, core)), result.payload.subarray(86, 106));
});

test('API policy changes Fund PDA but repeated local fixture input does not', () => {
  const result = creation(manager.publicKey, core, 18, pool, apiKey);
  assert.equal(creation(manager.publicKey, core, 18, pool, apiKey).target.fund, result.target.fund);
  assert.notEqual(creation(manager.publicKey, core, 18, pool, Buffer.alloc(32, 2)).target.fund, result.target.fund);
  assert.equal(result.target.fund, PublicKey.findProgramAddressSync([Buffer.from('fund'), integer(42161, 8), core, integer(18, 2), result.policyHash], publicKey(ADDRESSES.spoke))[0].toBase58());
});

test('production chunks replay exact payload with final-only sealing and bounded packets', () => {
  const result = creation(manager.publicKey, core, 18, pool, apiKey);
  const { stage, instructions } = stageSwapPolicy(manager.publicKey, publicKey(result.target.fund), result.policyHash, result.payload);
  const state = replay(result.policyHash, result.payload.length);
  for (const [index, operation] of instructions.entries()) {
    state.append(operation);
    assert.equal(state.snapshot().sealed, index === instructions.length - 1);
    assert.deepEqual(operation.keys.map(account => [account.isWritable, account.isSigner]), [[true, true], [false, false], [true, false], [false, false]]);
    assert.ok(new Transaction({ feePayer: manager.publicKey, recentBlockhash: PublicKey.default.toBase58() }).add(operation)
      .serialize({ requireAllSignatures: false, verifySignatures: false }).length <= 1232);
  }
  assert.deepEqual(state.snapshot().payload, result.payload);
  assert.equal(stage.toBase58(), PublicKey.findProgramAddressSync([Buffer.from('swap_policy_stage'), publicKey(result.target.fund).toBuffer(), manager.publicKey.toBuffer()], publicKey(ADDRESSES.spoke))[0].toBase58());
  assert.throws(() => state.append(instructions[0]));
});

test('replay model rejects reordered, repeated, wrong-hash and premature-seal chunks without mutation', () => {
  const result = creation(manager.publicKey, core, 18, pool, apiKey);
  const { instructions } = stageSwapPolicy(manager.publicKey, publicKey(result.target.fund), result.policyHash, result.payload);
  const state = replay(result.policyHash, result.payload.length);
  assert.throws(() => state.append(instructions[1]));
  for (const mutate of [(bytes: Buffer) => { bytes[12] ^= 1; }, (bytes: Buffer) => { bytes.writeUInt16LE(result.payload.length + 1, 44); },
    (bytes: Buffer) => { bytes[bytes.length - 1] = 1; }]) {
    const forged = new TransactionInstruction({ ...instructions[0], data: Buffer.from(instructions[0].data) });
    mutate(forged.data);
    assert.throws(() => state.append(forged));
    assert.deepEqual(state.snapshot(), { payload: Buffer.alloc(0), sealed: false });
  }
  state.append(instructions[0]);
  const before = state.snapshot();
  assert.throws(() => state.append(instructions[0]));
  assert.deepEqual(state.snapshot(), before);
});

test('stage builder rejects zero hash and invalid capacity or chunk sizes', () => {
  const fund = PublicKey.default; const policyHash = Buffer.alloc(32, 1);
  for (const size of [0, 601, 1.5]) assert.throws(() => stageSwapPolicy(manager.publicKey, fund, policyHash, Buffer.alloc(1), size));
  for (const bytes of [Buffer.alloc(31), Buffer.alloc(32)]) assert.throws(() => stageSwapPolicy(manager.publicKey, fund, bytes, Buffer.alloc(1)));
  for (const bytes of [Buffer.alloc(0), Buffer.alloc(4097)]) assert.throws(() => stageSwapPolicy(manager.publicKey, fund, policyHash, bytes));
});

test('LP full and compact initialization stage without swap configuration when packets overflow', () => {
  const target = policyAddresses(manager.publicKey, core, 1, pool);
  const full = bindingPayload(manager.publicKey, core, 1, 2_000_000_000n, pool);
  const compact = Buffer.concat([Buffer.from([1]), full.subarray(0, 134), full.subarray(174)]);
  for (const payload of [full, compact]) {
    const operation = initializer(payload, publicKey(target.fund), publicKey(target.vault));
    const planned = initializationPlan(operation, manager.publicKey);
    assert.ok(planned.packetBytes > 1232);
    assert.ok(planned.stage);
    assert.equal(planned.operation.keys.length, 19);
    assert.deepEqual(planned.operation.data.subarray(12), Buffer.from([2]));
    assert.ok(planned.operation.keys[18].pubkey.equals(planned.stage));
    assert.ok(packetBytes(planned.operation) <= 1232);
    assert.deepEqual(Buffer.concat(planned.instructions.map(chunk => request(chunk).chunk)), payload);
    assert.deepEqual(request(planned.instructions[0]).policyHash, target.policyHash);
  }
});

test('small generic initializer stays inline and production remaining accounts retain order', () => {
  const target = policyAddresses(manager.publicKey, core);
  const payload = bindingPayload(manager.publicKey, core);
  const small = initializer(payload, publicKey(target.fund), publicKey(target.vault));
  assert.equal(initializationPlan(small, manager.publicKey).operation, small);
  assert.equal(initializationPlan(small, manager.publicKey).packetBytes, packetBytes(small));
  const result = creation(manager.publicKey, core, 18, pool, apiKey);
  const remaining = [PublicKey.unique(), PublicKey.unique(), PublicKey.unique(), PublicKey.unique()];
  const planned = initializationPlan(initializer(result.payload, publicKey(result.target.fund), publicKey(result.target.vault), remaining), manager.publicKey);
  assert.ok(planned.stage);
  assert.deepEqual(planned.operation.keys.slice(18).map(account => account.pubkey), [remaining[0], planned.stage, ...remaining.slice(1)]);
});
