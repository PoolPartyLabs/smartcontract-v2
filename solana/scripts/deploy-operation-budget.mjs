import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Connection, Keypair } from '@solana/web3.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const port = process.env.PP_LOCALNET_RPC_PORT ?? '8983';
if (!/^\d+$/.test(port) || Number(port) > 65535) throw new Error('Invalid local validator port');
const connection = new Connection(`http://127.0.0.1:${port}`, 'confirmed');
const priority = Number(process.env.PP_BUDGET_PRIORITY_MICROLAMPORTS ?? '10000');
if (!Number.isSafeInteger(priority) || priority < 1 || priority > 1000000) throw new Error('Invalid modeled priority fee');
async function main() {
  const roles = [];
  for (const role of ['manager', 'keeper']) {
    const key = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(resolve(root, `.localnet/${role}.json`)))));
    const signatures = [];
    let before;
    for (;;) {
      const batch = await connection.getSignaturesForAddress(key.publicKey, { before, limit: 1000 }, 'confirmed');
      signatures.push(...batch);
      if (batch.length < 1000) break;
      before = batch.at(-1).signature;
    }
    const measurements = [];
    for (const signature of signatures.reverse()) {
      const transaction = await connection.getTransaction(signature.signature, { commitment: 'confirmed', maxSupportedTransactionVersion: 0 });
      if (!transaction?.meta) throw new Error('Missing local transaction evidence');
      const message = transaction.transaction.message;
      const keys = message.staticAccountKeys ?? message.accountKeys;
      if (!keys[0].equals(key.publicKey)) continue;
      const instructions = message.compiledInstructions ?? message.instructions;
      const instruction = instructions.find(entry => keys[entry.programIdIndex].toBase58() === 'ComputeBudget111111111111111111111111111111111'
        && entry.data instanceof Uint8Array && entry.data[0] === 2);
      const units = instruction ? Buffer.from(instruction.data).readUInt32LE(1) : Math.min(1400000, instructions.length * 200000);
      const fee = message.header.numRequiredSignatures * 5000 + Math.ceil(units * priority / 1000000);
      measurements.push({ slot: signature.slot, successful: transaction.meta.err === null,
        feeLamports: transaction.meta.fee, modeledPriorityFeeInclusiveLamports: fee,
        payerDebitLamports: transaction.meta.preBalances[0] - transaction.meta.postBalances[0],
        consumedCU: transaction.meta.computeUnitsConsumed, requestedCU: units });
    }
    const netDebit = measurements.reduce((sum, entry) => sum + entry.payerDebitLamports, 0);
    const fees = measurements.reduce((sum, entry) => sum + entry.feeLamports, 0);
    const modeledFees = measurements.reduce((sum, entry) => sum + entry.modeledPriorityFeeInclusiveLamports, 0);
    let runningDebit = 0;
    let peakDebit = 0;
    for (const entry of measurements) {
      runningDebit += entry.payerDebitLamports - entry.feeLamports + entry.modeledPriorityFeeInclusiveLamports;
      peakDebit = Math.max(peakDebit, runningDebit);
    }
    roles.push({ role, transactionCount: measurements.length, successfulTransactions: measurements.filter(entry => entry.successful).length,
      actualFeeLamports: fees, netNonFeeDebitLamports: netDebit - fees,
      modeledFeeLamports: modeledFees, modeledNetDebitLamports: netDebit - fees + modeledFees,
      modeledPeakDebitLamports: peakDebit, measurements });
  }
  console.log(JSON.stringify({ measuredAt: new Date().toISOString(), scope: 'Measured owned local validator session; fixture capital excluded',
    priorityMicroLamportsPerCU: priority, roles, noFundSol: 'Asserted by the lifecycle tests, not inferred from this budget',
    limitation: 'ALT setup/negative transactions included. Future action counts/retries and mainnet account rent changes require remeasurement. Same-slot signature order is not a total order; peak is a session estimate.' }, null, 2));
}
main().catch(() => { console.error('Local operation measurement failed; signer details suppressed'); process.exitCode = 1; });
