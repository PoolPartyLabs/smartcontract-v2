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
  const result = await simulate.apply(this, parameters);
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
