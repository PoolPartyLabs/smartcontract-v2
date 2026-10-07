import { readFileSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Keypair, PublicKey, SystemProgram, Transaction, TransactionInstruction, ComputeBudgetProgram } from '@solana/web3.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const path = resolve(root, 'target/deploy/pp_spoke.so');
const size = statSync(path).size;
const endpoint = process.env.SOLANA_MAINNET_RPC ?? 'https://api.mainnet-beta.solana.com';
const methods = new Set(['getGenesisHash', 'getMinimumBalanceForRentExemption', 'getRecentPrioritizationFees', 'getLatestBlockhash', 'getFeeForMessage', 'getSlot']);
async function rpc(method, params = []) {
  if (!methods.has(method)) throw new Error('Read-only method required');
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      const response = await fetch(endpoint, { method: 'POST', signal: AbortSignal.timeout(30000),
        headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
      const body = await response.json();
      if (response.ok && !body.error && body.result != null) return body.result;
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 1000 * 2 ** attempt));
  }
  throw new Error('Read-only budget RPC failed; endpoint/response suppressed');
}
async function main() {
  if (await rpc('getGenesisHash') !== '5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d') throw new Error('Mainnet required');
  const samples = await rpc('getRecentPrioritizationFees');
  const ordered = samples.map(entry => entry.prioritizationFee).sort((left, right) => left - right);
  const percentile75 = ordered[Math.floor((ordered.length - 1) * 0.75)] ?? 0;
  const priority = Number(process.env.PP_BUDGET_PRIORITY_MICROLAMPORTS ?? Math.max(10000, percentile75));
  if (!Number.isSafeInteger(priority) || priority < 1 || priority > 1000000) throw new Error('Invalid priority price');
  const programRent = await rpc('getMinimumBalanceForRentExemption', [36, { commitment: 'finalized' }]);
  const programDataRent = await rpc('getMinimumBalanceForRentExemption', [45 + size, { commitment: 'finalized' }]);
  const payer = Keypair.generate().publicKey;
  const buffer = Keypair.generate().publicKey;
  const program = Keypair.generate().publicKey;
  const loader = new PublicKey('BPFLoaderUpgradeab1e11111111111111111111111');
  const key = (pubkey, isWritable = false, isSigner = false) => ({ pubkey, isWritable, isSigner });
  const encoded = (opcode, length, bytes = Buffer.alloc(0)) => {
    const data = Buffer.alloc(4 + length); data.writeUInt32LE(opcode); bytes.copy(data, 4); return data;
  };
  const blockhash = (await rpc('getLatestBlockhash', [{ commitment: 'finalized' }])).value.blockhash;
  async function messageFee(instructions, units) {
    const transaction = new Transaction({ feePayer: payer, recentBlockhash: blockhash }).add(
      ...instructions, ComputeBudgetProgram.setComputeUnitPrice({ microLamports: priority }),
      ComputeBudgetProgram.setComputeUnitLimit({ units }));
    const result = await rpc('getFeeForMessage', [transaction.compileMessage().serialize().toString('base64'), { commitment: 'finalized' }]);
    if (!Number.isSafeInteger(result.value) || result.value < 0) throw new Error('Fee message unavailable; rerun with fresh blockhash');
    return { lamports: result.value, contextSlot: result.context.slot, requestedCU: units,
      signatures: transaction.compileMessage().header.numRequiredSignatures };
  }
  const create = await messageFee([
    SystemProgram.createAccount({ fromPubkey: payer, newAccountPubkey: buffer, lamports: programDataRent, space: size + 37, programId: loader }),
    new TransactionInstruction({ programId: loader, keys: [key(buffer, true), key(payer)], data: encoded(0, 0) }),
  ], 2847);
  const chunkBytes = 960;
  const writes = Math.ceil(size / chunkBytes);
  const payload = Buffer.alloc(12 + Math.min(chunkBytes, size));
  payload.writeBigUInt64LE(BigInt(Math.min(chunkBytes, size)), 4);
  const write = await messageFee([new TransactionInstruction({ programId: loader,
    keys: [key(buffer, true), key(payer, false, true)], data: encoded(1, payload.length, payload) })], 2670);
  const deploy = await messageFee([
    SystemProgram.createAccount({ fromPubkey: payer, newAccountPubkey: program, lamports: programRent, space: 36, programId: loader }),
    new TransactionInstruction({ programId: loader, keys: [key(Keypair.generate().publicKey, true), key(program, true), key(buffer, true),
      key(payer, true), key(new PublicKey('SysvarRent111111111111111111111111111111111')),
      key(new PublicKey('SysvarC1ock11111111111111111111111111111111')), key(SystemProgram.programId), key(payer, false, true)],
      data: encoded(2, 8, (() => { const data = Buffer.alloc(8); data.writeBigUInt64LE(BigInt(size)); return data; })()) }),
  ], 2970);
  const fees = create.lamports + writes * write.lamports + deploy.lamports;
  const walletRoles = ['keeper', 'testManager'].map(role => ({ role, status: 'ACTION_COUNTS_NOT_APPROVED',
    principle: 'DEC-195: signer pays fees/rent; zero Fund SOL',
    one900kSingleSignatureTransactionLamports: 5000 + Math.ceil(900000 * priority / 1000000) }));
  console.log(JSON.stringify({ measuredAt: new Date().toISOString(), finalizedSlot: await rpc('getSlot', [{ commitment: 'finalized' }]),
    scope: 'Read-only mainnet rent and fee-message model; not deployment or exact future expenditure',
    binaryBytes: size, binarySha256: createHash('sha256').update(readFileSync(path)).digest('hex'),
    multiplier: 1, priorityMicroLamportsPerCU: priority, recentFeeSamples: samples.length, percentile75MicroLamports: percentile75,
    feeModel: 'Agave 2.3.0 shared payer/authority, 960-byte chunks; CU limits from measured loader sequence; resimulate if CLI changes',
    programRentLamports: programRent, programDataRentLamports: programDataRent,
    bufferFundedLamports: programDataRent, bufferFundingReusedAtDeploy: true,
    successfulDeployLamports: programRent + programDataRent + fees,
    peakBeforeFinalDeployLamports: programRent + programDataRent + fees,
    transactionCount: writes + 2, feeLamports: fees, groups: { create, write: { ...write, count: writes }, deploy }, walletRoles,
    combinedKey: '6VTveiPVZVM7H9BWEsUsu4ivsrPjKw9ePrLQqHaFgJaA',
    combinedWalletMinimum: 'TODO(decision): approve keeper/Manager counts, adapter rents, retries and funding margin' }, null, 2));
}
main().catch(() => { console.error('Read-only budget failed; endpoint suppressed'); process.exitCode = 1; });
