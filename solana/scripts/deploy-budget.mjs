import { statSync, readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const binary = resolve(dirname(fileURLToPath(import.meta.url)), '../target/deploy/pp_spoke.so');
const size = statSync(binary).size;
const endpoint = process.env.PP_BUDGET_RPC ?? 'http://127.0.0.1:8970';
let url;
try { url = new URL(endpoint); } catch { throw new Error('Invalid local budget endpoint; value suppressed'); }
if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)
    || url.username || url.password || url.pathname !== '/' || url.search || url.hash)
  throw new Error('Budget measurement requires a local validator');
async function rent(bytes) {
  try {
    const response = await fetch(endpoint, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'getMinimumBalanceForRentExemption', params: [bytes] }) });
    const body = await response.json();
    if (!response.ok || !Number.isSafeInteger(body.result) || body.result < 0) throw new Error('Invalid rent');
    return body.result;
  } catch { throw new Error('Local rent query failed; endpoint and response suppressed'); }
}
const program = await rent(36);
const modes = [];
for (const multiplier of [1, 2]) {
  const programData = await rent(45 + size * multiplier);
  const buffer = await rent(45 + size * multiplier);
  const minimumLoaderBuffer = await rent(37 + size * multiplier);
  modes.push({ multiplier, maxLen: size * multiplier, programLamports: program,
    programDataLamports: programData, bufferLamports: buffer,
    minimumLoaderBufferLamports: minimumLoaderBuffer,
    conservativePeakRentLamports: program + programData + buffer });
}
console.log(JSON.stringify({ measuredAt: new Date().toISOString(), binaryBytes: size,
  binarySha256: createHash('sha256').update(readFileSync(binary)).digest('hex'), modes,
  walletBudget: 'UNVERIFIED: use measured payer deltas, message fees and configured action counts; no Fund SOL' }, null, 2));
