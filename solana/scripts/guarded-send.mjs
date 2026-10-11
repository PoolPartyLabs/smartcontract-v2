// HTTP-only send and confirmation for the operations scripts. No websocket subscriptions: public and
// keyed mainnet RPCs are often HTTP-only, and a dangling subscription keeps a process alive forever.
// A transaction is proven dropped only when the FINALIZED block height passed its lastValidBlockHeight
// and the signature is still unknown with full history search.
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { Transaction, VersionedTransaction, ComputeBudgetProgram } = require('@solana/web3.js');
const bs58 = require('bs58');
const encode = (bs58.default ?? bs58).encode;
const ORDER = { processed: 0, confirmed: 1, finalized: 2 };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

export function signatureOf(transaction) {
  const bytes = transaction instanceof VersionedTransaction ? transaction.signatures[0] : transaction.signature;
  if (!bytes || bytes.every(byte => byte === 0)) throw new Error('Transaction is not signed by its fee payer');
  return encode(bytes);
}

// Terminal states: landed | failed | expired. Re-broadcasts the SAME signed bytes while waiting; that is
// idempotent (one signature) and never a re-sign.
export async function waitForSignature(connection, { signature, lastValidBlockHeight, raw, commitment = 'confirmed', pollMs = 1000 }) {
  let seen = false;
  for (let round = 0; ; round++) {
    const status = (await connection.getSignatureStatuses([signature], { searchTransactionHistory: true })).value[0];
    if (status?.err) return { state: 'failed', err: status.err, slot: status.slot };
    if (status && ORDER[status.confirmationStatus] >= ORDER[commitment]) return { state: 'landed', slot: status.slot, confirmationStatus: status.confirmationStatus };
    seen ||= !!status;
    if (!status && await connection.getBlockHeight('finalized') > lastValidBlockHeight) {
      const recheck = (await connection.getSignatureStatuses([signature], { searchTransactionHistory: true })).value[0];
      if (!recheck) return { state: 'expired', seenBeforeExpiry: seen };
      continue;
    }
    if (raw && round % 2 === 1) {
      try { await connection.sendRawTransaction(raw, { skipPreflight: true, maxRetries: 0 }); } catch {}
    }
    await sleep(pollMs);
  }
}

// Unjournaled helper for idempotent-by-state flows (loader recovery): fresh blockhash, sign, simulate via
// preflight, send, poll. Throws on failure/expiry; the caller re-derives its stage from on-chain state.
export async function sendInstructions(connection, instructions, signers, { commitment = 'confirmed', computeUnitLimit, priorityMicroLamports } = {}) {
  const block = await connection.getLatestBlockhash('confirmed');
  const transaction = new Transaction({ feePayer: signers[0].publicKey, recentBlockhash: block.blockhash });
  if (computeUnitLimit) transaction.add(ComputeBudgetProgram.setComputeUnitLimit({ units: computeUnitLimit }));
  if (priorityMicroLamports) transaction.add(ComputeBudgetProgram.setComputeUnitPrice({ microLamports: priorityMicroLamports }));
  transaction.add(...instructions);
  transaction.sign(...signers);
  const raw = transaction.serialize();
  const signature = await connection.sendRawTransaction(raw, { preflightCommitment: 'confirmed' });
  const result = await waitForSignature(connection, { signature, lastValidBlockHeight: block.lastValidBlockHeight, raw, commitment });
  if (result.state !== 'landed') throw new Error(`Transaction ${signature} ${result.state}${result.err ? ` ${JSON.stringify(result.err)}` : ''}`);
  return signature;
}
