// HTTP-only send and confirmation for the operations scripts. No websocket subscriptions: public and
// keyed mainnet RPCs are often HTTP-only, and a dangling subscription keeps a process alive forever.
// A transaction is proven dropped only when the FINALIZED block height passed its lastValidBlockHeight
// and the signature is still unknown with full history search.
import { createRequire } from 'node:module';
import { existsSync, readFileSync, mkdirSync, openSync, writeSync, fsyncSync, closeSync, rmSync } from 'node:fs';
import { dirname } from 'node:path';

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
    if (status && ORDER[status.confirmationStatus] >= ORDER[commitment]) {
      return status.err ? { state: 'failed', err: status.err, slot: status.slot }
        : { state: 'landed', slot: status.slot, confirmationStatus: status.confirmationStatus };
    }
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

// ---- Journaled guarded send (CR-07): persist the signature BEFORE sending; never re-sign an uncertain one.

export function readJournal(path) {
  if (!existsSync(path)) return [];
  return readFileSync(path, 'utf8').split('\n').filter(Boolean).map(line => JSON.parse(line));
}

export function appendJournal(path, record) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const fd = openSync(path, 'a', 0o600);
  try {
    writeSync(fd, JSON.stringify({ ...record, at: new Date().toISOString() }) + '\n');
    fsyncSync(fd);
  } finally { closeSync(fd); }
}

export const latestRecord = (path, key) => readJournal(path).filter(record => record.key === key).at(-1);

// One signer process per journal: a second concurrent run could sign the same intent twice.
export function lockJournal(path) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const lock = `${path}.lock`;
  try { closeSync(openSync(lock, 'wx', 0o600)); } catch {
    throw new Error(`Journal is locked by another signer run (${lock}); remove it only after confirming no signer is running`);
  }
  return () => rmSync(lock, { force: true });
}

// Brings a prior non-terminal record to a terminal state by polling (bounded by its lastValidBlockHeight).
async function reconcile(connection, journalPath, prior, commitment) {
  if (['landed', 'failed', 'expired'].includes(prior.status)) return prior;
  const result = await waitForSignature(connection, { signature: prior.signature, lastValidBlockHeight: prior.lastValidBlockHeight, commitment });
  const record = { ...prior, status: result.state, slot: result.slot, err: result.err };
  appendJournal(journalPath, record);
  return record;
}

// build(blockhash) must return { transaction, meta? } with every signature applied. key identifies the
// business step (creation step or API intent hash). Returns { signature, status, skipped, meta }.
export async function guardedSend({ connection, journalPath, key, build, commitment = 'confirmed', retryExpired = false,
  retryFailed = false, log = () => {} }) {
  const prior = latestRecord(journalPath, key);
  if (prior) {
    log(key, 'reconcile', `priorSignature=${prior.signature} priorStatus=${prior.status}`);
    const settled = await reconcile(connection, journalPath, prior, commitment);
    if (settled.status === 'landed') return { signature: settled.signature, status: 'landed', skipped: true, meta: settled.meta };
    if (settled.status === 'failed' && !retryFailed) {
      throw new Error(`${key}: prior signature ${settled.signature} FAILED on-chain ${JSON.stringify(settled.err)}; review, then rerun with --retry-failed`);
    }
    if (settled.status === 'expired' && !retryExpired) {
      throw new Error(`${key}: prior signature ${settled.signature} provably expired without landing; rerun with --retry-expired to sign again`);
    }
  }
  const block = await connection.getLatestBlockhash('confirmed');
  const { transaction, meta } = await build(block.blockhash);
  // VersionedTransaction only: legacy simulateTransaction would silently replace the signed blockhash.
  if (!(transaction instanceof VersionedTransaction)) throw new Error(`${key}: builder must return a signed VersionedTransaction`);
  const signature = signatureOf(transaction);
  const simulation = await connection.simulateTransaction(transaction, { sigVerify: true, commitment: 'confirmed' });
  if (simulation.value.err) {
    throw new Error(`${key}: simulation failed, nothing sent: ${JSON.stringify(simulation.value.err)} ${(simulation.value.logs ?? []).slice(-6).join(' | ')}`);
  }
  appendJournal(journalPath, { key, status: 'sent', signature, blockhash: block.blockhash, lastValidBlockHeight: block.lastValidBlockHeight,
    unitsConsumed: simulation.value.unitsConsumed, meta });
  log(key, 'sent', `signature=${signature} lastValidBlockHeight=${block.lastValidBlockHeight}`);
  const raw = transaction.serialize();
  try {
    await connection.sendRawTransaction(raw, { skipPreflight: true, maxRetries: 0 });
  } catch (error) {
    // Unknown delivery: the journal already holds the signature, so a rerun reconciles instead of re-signing.
    log(key, 'send-error', error?.message ?? 'unknown');
  }
  const result = await waitForSignature(connection, { signature, lastValidBlockHeight: block.lastValidBlockHeight, raw, commitment });
  appendJournal(journalPath, { key, status: result.state, signature, blockhash: block.blockhash, lastValidBlockHeight: block.lastValidBlockHeight,
    slot: result.slot, err: result.err, meta });
  log(key, result.state, `signature=${signature}`);
  if (result.state !== 'landed') throw new Error(`${key}: signature ${signature} ${result.state}${result.err ? ` ${JSON.stringify(result.err)}` : ''}`);
  return { signature, status: 'landed', skipped: false, meta };
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
