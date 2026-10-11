// Guarded CLI signer for API-built unsigned Manager transactions (CR-07, risk-review R02/N2).
// The API returns base64 unsigned v0 transactions (POST .../solana/build/:action, bootstrap, route,
// build-receive). This tool signs ONLY with the pinned Manager Solana Key and fresh one-shot signers:
//
//   inspect    --tx <file>                       decode + intent hash; no key, no network
//   new-signer --out <file>                      fresh 0600 keypair for eventAccount/nftMint; prints pubkey
//   send       --tx <file> --expect-intent <sha256> [--extra-signer <file>]... [--expect-instruction <name>]
//              [--cluster mainnet|localnet] [--journal <file>] [--retry-expired] [--retry-failed]
//
// Guards: mainnet genesis (localnet: loopback + non-mainnet genesis); approval file pins the Manager
// pubkey; fee payer = Manager; every required signer is the Manager or a fresh (non-existent) account;
// top-level programs only from the approved allowlist; spoke instructions must decode against the IDL;
// priority fee capped; the operator must echo the reviewed intent hash (message with blockhash zeroed);
// the signature is journaled (fsync) BEFORE send; a prior uncertain signature is reconciled, never re-signed.
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { createHash } from 'node:crypto';
import { checkedEndpoint, assertGenesis, keypairFromParameter, keypairFromFile, sanitize, stepLogger } from './ops-common.mjs';
import { guardedSend, lockJournal } from './guarded-send.mjs';

const require = createRequire(import.meta.url);
const { Connection, Keypair, PublicKey, VersionedTransaction, VersionedMessage, ComputeBudgetProgram } = require('@solana/web3.js');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const log = stepLogger('manager-sign');
const COMPUTE_BUDGET = ComputeBudgetProgram.programId.toBase58();
const ZERO_BLOCKHASH = '11111111111111111111111111111111';
const DEFAULT_MAX_PRIORITY_FEE_LAMPORTS = 100_000;

function intentHash(message) {
  const copy = VersionedMessage.deserialize(message.serialize());
  copy.recentBlockhash = ZERO_BLOCKHASH;
  return createHash('sha256').update(copy.serialize()).digest('hex');
}

function loadIdl() {
  const path = process.env.PP_SPOKE_IDL ?? resolve(root, 'solana/target/idl/pp_spoke.json');
  if (!existsSync(path)) throw new Error('Spoke IDL required (solana/target/idl/pp_spoke.json or PP_SPOKE_IDL) to decode instructions');
  const idl = JSON.parse(readFileSync(path, 'utf8'));
  return new Map(idl.instructions.map(entry => [Buffer.from(entry.discriminator).toString('hex'), entry.name]));
}

function readTransaction(path) {
  if (!path) throw new Error('--tx <file> required (API base64 transaction or its JSON response)');
  const text = readFileSync(path, 'utf8').trim();
  const encoded = text.startsWith('{') ? JSON.parse(text).transaction : text;
  const transaction = VersionedTransaction.deserialize(Buffer.from(encoded, 'base64'));
  if (transaction.version !== 0) throw new Error('Only API-built v0 transactions are accepted');
  return transaction;
}

// Static review: no key and no network. Returns the summary printed by inspect and enforced by send.
function review(transaction, { programId, allowedPrograms, idl, maxPriorityFeeLamports = DEFAULT_MAX_PRIORITY_FEE_LAMPORTS }) {
  const message = transaction.message;
  const keys = message.staticAccountKeys.map(key => key.toBase58());
  const required = keys.slice(0, message.header.numRequiredSignatures);
  if (transaction.signatures.some(signature => signature.some(byte => byte !== 0))) throw new Error('Partially signed transactions are refused');
  let unitLimit = 200_000 * message.compiledInstructions.length;
  let unitPrice = 0;
  const instructions = message.compiledInstructions.map(instruction => {
    const program = keys[instruction.programIdIndex];
    const data = Buffer.from(instruction.data);
    if (!allowedPrograms.includes(program)) throw new Error(`Top-level program ${program} is not in the approved allowlist`);
    if (program === COMPUTE_BUDGET) {
      if (data[0] === 2 && data.length === 5) { unitLimit = data.readUInt32LE(1); return { program, name: 'SetComputeUnitLimit', units: unitLimit }; }
      if (data[0] === 3 && data.length === 9) { unitPrice = Number(data.readBigUInt64LE(1)); return { program, name: 'SetComputeUnitPrice', microLamports: unitPrice }; }
      throw new Error('Only SetComputeUnitLimit/SetComputeUnitPrice compute-budget instructions are accepted');
    }
    if (program === programId) {
      const name = idl.get(data.subarray(0, 8).toString('hex'));
      if (!name) throw new Error('Spoke instruction discriminator is not in the reviewed IDL');
      return { program, name, accounts: instruction.accountKeyIndexes.length };
    }
    return { program, name: 'allowlisted', dataBytes: data.length };
  });
  const priorityFeeLamports = Math.ceil(unitLimit * unitPrice / 1_000_000);
  if (priorityFeeLamports > maxPriorityFeeLamports) throw new Error(`Priority fee ${priorityFeeLamports} lamports exceeds the approved cap ${maxPriorityFeeLamports}`);
  return { intentSha256: intentHash(message), feePayer: keys[0], requiredSigners: required, instructions,
    lookupTables: message.addressTableLookups.map(lookup => lookup.accountKey.toBase58()), apiBlockhash: message.recentBlockhash,
    priorityFeeLamports, bytes: transaction.serialize().length };
}

function loadApproval(cluster) {
  const path = process.env.PP_MANAGER_APPROVAL_FILE ?? resolve(root, 'script/solana-manager-approval.json');
  const approval = JSON.parse(readFileSync(path, 'utf8'));
  if (cluster === 'mainnet' && (approval.status !== 'FOUNDER_APPROVED' || !approval.approvedBy || !Number.isFinite(Date.parse(approval.approvedAt)))) {
    throw new Error('Founder-approved Manager signing file required; no transaction signed');
  }
  let manager;
  try { manager = new PublicKey(approval.managerSolanaKey).toBase58(); } catch { throw new Error('Approval file must pin managerSolanaKey; no transaction signed'); }
  if (manager !== approval.managerSolanaKey) throw new Error('Approval file must pin a canonical managerSolanaKey');
  const programId = new PublicKey(approval.programId).toBase58();
  const allowedPrograms = approval.allowedPrograms ?? [programId, COMPUTE_BUDGET];
  return { manager, programId, allowedPrograms, maxPriorityFeeLamports: approval.maxPriorityFeeLamports ?? DEFAULT_MAX_PRIORITY_FEE_LAMPORTS };
}

function managerKeypair() {
  if (process.env.PP_MANAGER_KEYPAIR) return keypairFromFile(process.env.PP_MANAGER_KEYPAIR, 'Manager keypair file');
  return keypairFromParameter(process.env.SOLANA_MANAGER_PRIVATE_KEY, 'Manager key');
}

async function main() {
  const command = process.argv[2];
  const { values } = parseArgs({ args: process.argv.slice(3), strict: true, options: {
    tx: { type: 'string' }, out: { type: 'string' }, 'expect-intent': { type: 'string' }, 'expect-instruction': { type: 'string' },
    'extra-signer': { type: 'string', multiple: true, default: [] }, cluster: { type: 'string', default: 'mainnet' },
    journal: { type: 'string' }, 'retry-expired': { type: 'boolean', default: false }, 'retry-failed': { type: 'boolean', default: false } } });
  if (command === 'new-signer') {
    if (!values.out || existsSync(values.out)) throw new Error('--out <new file> required; existing files are never overwritten');
    const signer = Keypair.generate();
    writeFileSync(values.out, JSON.stringify(Array.from(signer.secretKey)), { mode: 0o600, flag: 'wx' });
    console.log(JSON.stringify({ publicKey: signer.publicKey.toBase58(), file: values.out, purpose: 'one-shot fresh signer (eventAccount/nftMint)' }));
    return;
  }
  if (!['inspect', 'send'].includes(command)) throw new Error('Usage: manager-sign.mjs inspect|new-signer|send (see header); no implicit signing');
  const cluster = values.cluster;
  if (!['mainnet', 'localnet'].includes(cluster)) throw new Error('Cluster must be mainnet or localnet');
  const approval = loadApproval(command === 'inspect' ? 'localnet' : cluster);
  const transaction = readTransaction(values.tx);
  const summary = review(transaction, { ...approval, idl: loadIdl() });
  if (command === 'inspect') { console.log(JSON.stringify(summary, null, 2)); return; }

  if (values['expect-intent'] !== summary.intentSha256) throw new Error('--expect-intent must equal the reviewed intentSha256 from inspect; no transaction signed');
  const spokeNames = summary.instructions.filter(entry => entry.program === approval.programId).map(entry => entry.name);
  if (values['expect-instruction'] && (spokeNames.length !== 1 || spokeNames[0] !== values['expect-instruction'])) {
    throw new Error(`Transaction carries [${spokeNames.join(',')}], not the expected ${values['expect-instruction']}`);
  }
  if (summary.feePayer !== approval.manager) throw new Error('Fee payer is not the pinned Manager Solana Key');
  const manager = managerKeypair();
  if (manager.publicKey.toBase58() !== approval.manager) throw new Error('Loaded Manager key differs from the pinned managerSolanaKey');
  const extras = values['extra-signer'].map(path => keypairFromFile(path, 'Extra signer file'));
  const signerSet = new Set([approval.manager, ...extras.map(extra => extra.publicKey.toBase58())]);
  if (signerSet.size !== extras.length + 1 || summary.requiredSigners.length !== signerSet.size
      || !summary.requiredSigners.every(key => signerSet.has(key))) {
    throw new Error('Required signers must be exactly the Manager plus the supplied fresh signers');
  }
  const endpoint = checkedEndpoint(cluster, cluster === 'mainnet' ? process.env.SOLANA_MAINNET_RPC : process.env.PP_LOCALNET_RPC);
  const connection = new Connection(endpoint, 'confirmed');
  await assertGenesis(connection, cluster);
  for (const extra of extras) {
    if (await connection.getAccountInfo(extra.publicKey, 'confirmed')) throw new Error(`Extra signer ${extra.publicKey.toBase58()} already exists on-chain; only fresh one-shot signers are accepted`);
  }
  const journalPath = resolve(values.journal ?? resolve(root, `cache/manager-sign/${cluster}-journal.jsonl`));
  const unlock = lockJournal(journalPath);
  try {
    log('intent', 'reviewed', `intent=${summary.intentSha256} instructions=${spokeNames.join(',')}`);
    const result = await guardedSend({ connection, journalPath, key: summary.intentSha256, log,
      retryExpired: values['retry-expired'], retryFailed: values['retry-failed'],
      build: async blockhash => {
        const message = VersionedMessage.deserialize(transaction.message.serialize());
        message.recentBlockhash = blockhash;
        const signed = new VersionedTransaction(message);
        signed.sign([manager, ...extras]);
        return { transaction: signed, meta: { intent: summary.intentSha256, instructions: spokeNames } };
      } });
    console.log(JSON.stringify({ cluster, intentSha256: summary.intentSha256, signature: result.signature, status: result.status,
      alreadyLanded: result.skipped, journal: journalPath }, null, 2));
  } finally { unlock(); }
}

main().catch(error => {
  console.error(`manager-sign: ${sanitize(error?.message ?? 'unknown failure')}`);
  process.exitCode = 1;
});
