import { createRequire } from 'node:module';
import { appendFileSync } from 'node:fs';

const require = createRequire(import.meta.url);
const { ComputeBudgetProgram, Connection } = require('@solana/web3.js');
const ceiling = Number(process.env.PP_REHEARSAL_CU_LIMIT ?? '900000');
if (!Number.isSafeInteger(ceiling) || ceiling < 600000 || ceiling > 1000000) {
  throw new Error('Rehearsal CU ceiling must be between 600000 and 1000000');
}
const buildLimit = ComputeBudgetProgram.setComputeUnitLimit;
ComputeBudgetProgram.setComputeUnitLimit = function (parameters) {
  return buildLimit.call(this, { units: Math.min(parameters.units, ceiling) });
};
const simulate = Connection.prototype.simulateTransaction;
Connection.prototype.simulateTransaction = async function (...parameters) {
  let result;
  for (let attempt = 0; attempt < 20; attempt++) {
    try {
      result = await simulate.apply(this, parameters);
      break;
    } catch (error) {
      if (!error.message?.includes('Transaction address table lookup uses an invalid index') || attempt === 19) throw error;
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
  }
  if (process.env.PP_REHEARSAL_METRICS) {
    appendFileSync(process.env.PP_REHEARSAL_METRICS, JSON.stringify({
      measuredAt: new Date().toISOString(), units: result.value.unitsConsumed,
      success: result.value.err === null, ceiling,
      eventDataLogs: result.value.logs?.filter(line => line.startsWith('Program data:')).length ?? 0,
      instructionNameLogs: result.value.logs?.filter(line => line.includes('Instruction:')).length ?? 0,
    }) + '\n');
  }
  if (result.value.err === null && result.value.unitsConsumed >= ceiling) {
    throw new Error('Successful rehearsal exhausted its compute reserve');
  }
  return result;
};
const confirm = Connection.prototype.confirmTransaction;
Connection.prototype.confirmTransaction = async function (...parameters) {
  const result = await confirm.apply(this, parameters);
  if (process.env.PP_REHEARSAL_METRICS && result.value.err === null) {
    const signature = typeof parameters[0] === 'string' ? parameters[0] : parameters[0].signature;
    const transaction = await this.getTransaction(signature, { commitment: 'confirmed', maxSupportedTransactionVersion: 0 });
    if (transaction?.meta && !transaction.meta.err) {
      const message = transaction.transaction.message;
      const payer = (message.staticAccountKeys ?? message.accountKeys)[0].toBase58();
      appendFileSync(process.env.PP_REHEARSAL_METRICS, JSON.stringify({ kind: 'confirmed', payer,
        units: transaction.meta.computeUnitsConsumed, feeLamports: transaction.meta.fee,
        payerDebitLamports: transaction.meta.preBalances[0] - transaction.meta.postBalances[0],
        signatures: message.header.numRequiredSignatures, ceiling }) + '\n');
    }
  }
  return result;
};
