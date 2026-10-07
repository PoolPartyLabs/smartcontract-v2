import { writeFileSync, mkdirSync } from 'node:fs';
import { PublicKey, SystemProgram, TransactionInstruction, Transaction, SendTransactionError, AddressLookupTableAccount, AddressLookupTableProgram, TransactionMessage, VersionedTransaction, ComputeBudgetProgram } from '@solana/web3.js';
import type { Connection, Keypair } from '@solana/web3.js';
import { secp256k1 } from '@noble/curves/secp256k1';
import { keccak_256 } from '@noble/hashes/sha3';
import { ADDRESSES, fundAddresses, derive, publicKey } from '../helpers/addresses.ts';
import { discriminator } from '../helpers/layouts.ts';
import { requireLoopback, testAta, testWallet } from '../helpers/localnet.ts';

export const hubCore = Buffer.alloc(20, 0x71);
export const factory = Buffer.alloc(20, 0x72);
export const fundId = Buffer.alloc(32, 0x73);
export const mandateHash = Buffer.alloc(32, 0x74);
export const addresses = fundAddresses(hubCore, 1, mandateHash);
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

export function nativeConfig(manager: PublicKey, emitter: PublicKey, fund = publicKey(addresses.fund), lp?: { mint0: string; mint1: string }, swapPolicyHash = Buffer.alloc(32)) {
  const mint = publicKey(ADDRESSES.usdc).toBuffer();
  const namespace = Buffer.from('PoolParty/SolanaAsset/v6');
  const paddedNamespace = Buffer.concat([namespace, Buffer.alloc(32 - namespace.length)]);
  const alias = hash(Buffer.concat([word(96), word(1), mint, word(namespace.length), paddedNamespace])).subarray(12);
  const asset = Buffer.concat([mint, alias, integer(0, 1)]);
  const venue = Buffer.concat([publicKey(ADDRESSES.kamino).toBuffer(), Buffer.alloc(32), publicKey(ADDRESSES.reserve).toBuffer(), mint, Buffer.alloc(32)]);
  const stockMint = publicKey(ADDRESSES.tslax).toBuffer();
  const stockAlias = hash(Buffer.concat([word(96), word(1), stockMint, word(namespace.length), paddedNamespace])).subarray(12);
  const stockAsset = Buffer.concat([stockMint, stockAlias, integer(1, 1)]);
  const lpVenue = lp ? Buffer.concat([publicKey(ADDRESSES.raydium).toBuffer(), publicKey(ADDRESSES.tslaxPool).toBuffer(), Buffer.alloc(32), publicKey(lp.mint0).toBuffer(), publicKey(lp.mint1).toBuffer()]) : Buffer.alloc(0);
  const hubUsdc = Buffer.from('af88d065e77c8cc2239327c5edb3a432268e5831', 'hex');
  const messenger = Buffer.from('28b5a0e9c621a5badaa536219b3a228c8168cf5d', 'hex');
  const transmitter = Buffer.from('81d40f21f12a8f0e3252bccb954d722d4c464b64', 'hex');
  const vault = PublicKey.findProgramAddressSync([Buffer.from('vault'), fund.toBuffer()], publicKey(ADDRESSES.spoke))[0];
  const recipient = testAta(ADDRESSES.usdc, vault).toBuffer();
  const remoteMessenger = publicKey(ADDRESSES.cctpMessenger).toBuffer();
  const transport = Buffer.concat([hubUsdc, messenger, transmitter, integer(5, 4), recipient, vault.toBuffer(), remoteMessenger, vault.toBuffer(), integer(50_000, 8)]);
  const abi = Buffer.concat([word(6), word(64), publicKey(ADDRESSES.spoke).toBuffer(), emitter.toBuffer(), mint, manager.toBuffer(),
    word(1), word(544), word(lp ? 768 : 672), addressWord(hubUsdc), addressWord(messenger), addressWord(transmitter), word(5), recipient,
    vault.toBuffer(), remoteMessenger, vault.toBuffer(), word(50_000), swapPolicyHash, word(lp ? 2 : 1), mint, addressWord(alias), word(0),
    ...(lp ? [stockMint, addressWord(stockAlias), word(1)] : []), word(lp ? 2 : 1), venue, lpVenue]);
  const policy = Buffer.from(abi);
  policy.fill(0, 96, 128);
  policy.fill(0, 416, 480);
  policy.fill(0, 512, 544);
  return { nativeHash: hash(abi), nativePolicyHash: hash(policy), assets: Buffer.concat([integer(lp ? 2 : 1, 4), asset, ...(lp ? [stockAsset] : [])]), venues: Buffer.concat([integer(lp ? 2 : 1, 4), venue, lpVenue]), transport };
}

export const hubPolicyHash = Buffer.alloc(32, 0x11);
export function policyAddresses(manager: PublicKey, core = hubCore, index = 1, lp?: { mint0: string; mint1: string }) {
  const config = nativeConfig(manager, PublicKey.default, PublicKey.default, lp);
  const policyHash = hash(Buffer.concat([hash(Buffer.from('PoolParty/SolanaPolicy/v6')), hubPolicyHash, config.nativePolicyHash]));
  return { ...fundAddresses(core, index, policyHash), policyHash };
}

export function bindingPayload(manager: PublicKey, core = hubCore, index = 1, expiry = 2_000_000_000n, lp?: { mint0: string; mint1: string }) {
  const target = policyAddresses(manager, core, index, lp);
  const emitter = publicKey(target.emitter);
  const config = nativeConfig(manager, emitter, publicKey(target.fund), lp);
  const nonce = word(9);
  const type = 'ManagerSolanaBinding(bytes32 solanaKey,address fund,bytes32 spoke,uint256 spokeChainId,bytes32 nativeMandateHash,uint256 nonce,uint256 expiry)';
  const domain = hash(Buffer.concat([hash(Buffer.from('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
    hash(Buffer.from('PoolParty Solana Fund')), hash(Buffer.from('6')), word(42161), addressWord(factory)]));
  const struct = hash(Buffer.concat([hash(Buffer.from(type)), manager.toBuffer(), addressWord(core), emitter.toBuffer(), word(1), config.nativeHash, nonce, word(expiry)]));
  const digest = hash(Buffer.concat([Buffer.from([25, 1]), domain, struct]));
  const ephemeralKey = secp256k1.utils.randomPrivateKey();
  const managerEvm = hash(Buffer.from(secp256k1.getPublicKey(ephemeralKey, false)).subarray(1)).subarray(12);
  const vault = publicKey(target.vault);
  const nvdax = 'Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh';
  const bootstrapType = 'SolanaBootstrap(uint256 hubChain,address core,bytes32 mandateHash,bytes32 policyHash,uint16 spokeIndex,bytes32 program,bytes32 fundPda,bytes32 solanaKey,bytes32 usdcAta,bytes32 tslaxAta,bytes32 nvdaxAta,bytes32 wsolAta,bytes32 nativeMandateHash,bytes32 fundId,uint256 nonce,uint256 expiry)';
  const bootstrapStruct = hash(Buffer.concat([hash(Buffer.from(bootstrapType)), word(42161), addressWord(core), mandateHash,
    target.policyHash, word(index), publicKey(ADDRESSES.spoke).toBuffer(), publicKey(target.fund).toBuffer(), manager.toBuffer(),
    ...[ADDRESSES.usdc, ADDRESSES.tslax, nvdax, ADDRESSES.wsol].map(mint => testAta(mint, vault).toBuffer()), config.nativeHash, fundId, nonce, word(expiry)]));
  const bootstrap = secp256k1.sign(hash(Buffer.concat([Buffer.from([25, 1]), domain, bootstrapStruct])), ephemeralKey);
  return Buffer.concat([core, integer(index, 2), fundId, mandateHash, managerEvm, factory, integer(42161, 8), integer(1, 8),
    config.nativeHash, nonce, integer(expiry, 8),
    Buffer.from(bootstrap.toCompactRawBytes()), integer(bootstrap.recovery + 27, 1), config.assets, config.venues, config.transport, hubPolicyHash, target.policyHash, Buffer.alloc(32)]);
}

export function fixtureFund(manager: PublicKey) {
  const fund = publicKey(addresses.fund);
  const program = publicKey(ADDRESSES.spoke);
  const index = integer(1, 2);
  const bump = PublicKey.findProgramAddressSync([Buffer.from('fund'), integer(42161, 8), hubCore, index, mandateHash], program)[1];
  const vaultBump = PublicKey.findProgramAddressSync([Buffer.from('vault'), fund.toBuffer()], program)[1];
  const emitterBump = PublicKey.findProgramAddressSync([Buffer.from('emitter'), fund.toBuffer()], program)[1];
  const config = nativeConfig(manager, publicKey(addresses.emitter));
  return Buffer.concat([discriminator('account', 'FundState'), hubCore, index, fundId, mandateHash, Buffer.alloc(20, 1), manager.toBuffer(),
    integer(0, 8), integer(0, 8), integer(0, 1), integer(bump, 1), integer(vaultBump, 1), integer(emitterBump, 1),
    integer(42161, 8), factory, integer(1, 8), config.nativeHash, word(9), Buffer.alloc(32, 1), integer(2_000_000_000, 8),
    addressWord(hubCore), integer(23, 2), integer(0, 16), integer(0, 16), integer(0, 2), integer(0, 2), integer(0, 2), config.assets, config.venues, config.transport, Buffer.alloc(8), mandateHash, hubPolicyHash, Buffer.alloc(37)]);
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

export function stageSwapPolicy(manager: PublicKey, fund: PublicKey, policyHash: Buffer, payload: Buffer, chunkSize = 600) {
  if (policyHash.length !== 32 || policyHash.equals(Buffer.alloc(32)) || payload.length === 0 || payload.length > 4096
    || !Number.isInteger(chunkSize) || chunkSize < 1 || chunkSize > 600) throw new Error('Invalid staged policy payload');
  const programId = publicKey(ADDRESSES.spoke);
  const stage = PublicKey.findProgramAddressSync([Buffer.from('swap_policy_stage'), fund.toBuffer(), manager.toBuffer()], programId)[0];
  const instructions: TransactionInstruction[] = [];
  for (let offset = 0; offset < payload.length; offset += chunkSize) {
    const chunk = payload.subarray(offset, offset + chunkSize);
    const request = Buffer.concat([policyHash, integer(payload.length, 2), integer(offset, 2), integer(chunk.length, 4), chunk,
      Buffer.from([Number(offset + chunk.length === payload.length)])]);
    instructions.push(new TransactionInstruction({ programId, keys: [
      { pubkey: manager, isSigner: true, isWritable: true },
      { pubkey: fund, isSigner: false, isWritable: false },
      { pubkey: stage, isSigner: false, isWritable: true },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ], data: Buffer.concat([discriminator('global', 'stage_swap_policy'), integer(request.length, 4), request]) }));
  }
  return { stage, instructions };
}

export function initializationPlan(operation: TransactionInstruction, payer: PublicKey) {
  const accounts = [...new Map(operation.keys.filter(account => !account.isSigner).map(account => [account.pubkey.toBase58(), account.pubkey])).values()];
  const table = new AddressLookupTableAccount({ key: PublicKey.default, state: {
    deactivationSlot: (1n << 64n) - 1n, lastExtendedSlot: 0, lastExtendedSlotStartIndex: 0, addresses: accounts,
  } });
  const message = new TransactionMessage({ payerKey: payer, recentBlockhash: PublicKey.default.toBase58(),
    instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units: 600_000 }), operation] }).compileToV0Message([table]);
  const shortLength = (value: number) => value < 128 ? 1 : value < 16384 ? 2 : 3;
  const packetBytes = shortLength(message.header.numRequiredSignatures) + message.header.numRequiredSignatures * 64
    + 1 + 3 + shortLength(message.staticAccountKeys.length) + message.staticAccountKeys.length * 32 + 32
    + shortLength(message.compiledInstructions.length)
    + message.compiledInstructions.reduce((size, entry) => size + 1 + shortLength(entry.accountKeyIndexes.length)
      + entry.accountKeyIndexes.length + shortLength(entry.data.length) + entry.data.length, 0)
    + shortLength(message.addressTableLookups.length)
    + message.addressTableLookups.reduce((size, entry) => size + 32 + shortLength(entry.writableIndexes.length)
      + entry.writableIndexes.length + shortLength(entry.readonlyIndexes.length) + entry.readonlyIndexes.length, 0);
  if (packetBytes <= 1232) return { operation, instructions: [] as TransactionInstruction[], packetBytes, stage: undefined };
  if (!operation.programId.equals(publicKey(ADDRESSES.spoke))
    || !operation.data.subarray(0, 8).equals(discriminator('global', 'initialize_fund'))
    || operation.data.readUInt32LE(8) !== operation.data.length - 12) throw new Error('Invalid initialization instruction');
  const payload = operation.data.subarray(12);
  let offset = payload[0] === 1 ? 240 : 279;
  const assets = payload.readUInt32LE(offset); offset += 4 + assets * 53;
  const venues = payload.readUInt32LE(offset); offset += 4 + venues * 160 + 200;
  if (offset + 96 > payload.length) throw new Error('Invalid initialization policy hashes');
  const policyHash = payload.subarray(offset + 32, offset + 64);
  const hasSwap = !payload.subarray(offset + 64, offset + 96).equals(Buffer.alloc(32));
  const staged = stageSwapPolicy(operation.keys[0].pubkey, operation.keys[1].pubkey, policyHash, payload);
  const remaining = operation.keys.slice(18);
  if (hasSwap && remaining.length === 0) throw new Error('Swap configuration account missing');
  const stageAccount = { pubkey: staged.stage, isSigner: false, isWritable: true };
  const keys = [...operation.keys.slice(0, 18), ...(hasSwap ? [remaining[0], stageAccount, ...remaining.slice(1)] : [stageAccount, ...remaining])];
  return { operation: new TransactionInstruction({ programId: operation.programId, keys,
    data: Buffer.concat([discriminator('global', 'initialize_fund'), integer(1, 4), Buffer.from([2])]) }),
    instructions: staged.instructions, stage: staged.stage, packetBytes };
}

export async function sendSignedLocal(connection: Connection, payer: Keypair, instructions: TransactionInstruction[], additional: Keypair[] = []) {
  requireLoopback(connection.rpcEndpoint);
  let table: AddressLookupTableAccount | undefined;
  if (instructions.some(instruction => instruction.data.subarray(0, 8).equals(discriminator('global', 'initialize_fund')))) {
    const planned: TransactionInstruction[] = [];
    for (const operation of instructions) {
      if (operation.data.subarray(0, 8).equals(discriminator('global', 'initialize_fund'))) {
        const plan = initializationPlan(operation, payer.publicKey);
        for (const chunk of plan.instructions) await sendSignedLocal(connection, payer, [chunk], additional);
        planned.push(plan.operation);
      } else planned.push(operation);
    }
    instructions = planned;
    instructions = [ComputeBudgetProgram.setComputeUnitLimit({ units: 600_000 }), ...instructions];
    const slot = await connection.getSlot('finalized');
    const [create, address] = AddressLookupTableProgram.createLookupTable({ authority: payer.publicKey, payer: payer.publicKey, recentSlot: slot });
    await sendSignedLocal(connection, payer, [create]);
    const keys = [...new Map(instructions.flatMap(instruction => instruction.keys).filter(meta => !meta.isSigner).map(meta => [meta.pubkey.toBase58(), meta.pubkey])).values()];
    for (let offset = 0; offset < keys.length; offset += 20) {
      await sendSignedLocal(connection, payer, [AddressLookupTableProgram.extendLookupTable({ lookupTable: address,
        authority: payer.publicKey, payer: payer.publicKey, addresses: keys.slice(offset, offset + 20) })]);
    }
    const extendedAt = await connection.getSlot('confirmed');
    while (await connection.getSlot('confirmed') <= extendedAt) await new Promise(resolve => setTimeout(resolve, 100));
    table = (await connection.getAddressLookupTable(address)).value ?? undefined;
    if (!table) throw new Error('Local init lookup table is unavailable');
  }
  for (let attempt = 0; attempt < 20; attempt++) {
    const blockhash = await connection.getLatestBlockhash('confirmed');
    const transaction = table
      ? new VersionedTransaction(new TransactionMessage({ payerKey: payer.publicKey, recentBlockhash: blockhash.blockhash, instructions }).compileToV0Message([table]))
      : new Transaction({ feePayer: payer.publicKey, recentBlockhash: blockhash.blockhash }).add(...instructions);
    if (transaction instanceof VersionedTransaction) transaction.sign([payer, ...additional]);
    else transaction.sign(payer, ...additional);
    const serialized = transaction.serialize();
    if (serialized.length > 1232) throw new Error(`Local transaction exceeds packet limit: ${serialized.length}`);
    if (table) console.log(`Versioned initialization transaction: ${serialized.length} bytes.`);
    let signature: string;
    try { signature = await connection.sendRawTransaction(serialized, { preflightCommitment: 'confirmed' }); }
    catch (error) {
      if (!(error instanceof SendTransactionError) || !error.message.startsWith('Simulation failed.')
          || !error.transactionError.message.includes('Program cache hit max limit') || attempt === 19) throw error;
      await new Promise(resolve => setTimeout(resolve, 1000 * Math.min(attempt + 1, 5)));
      continue;
    }
    const result = await connection.confirmTransaction({ signature, ...blockhash }, 'confirmed');
    if (result.value.err) throw new Error(`Submitted local transaction failed: ${JSON.stringify(result.value.err)}`);
    return signature;
  }
  throw new Error('Local validator program cache did not become ready');
}
