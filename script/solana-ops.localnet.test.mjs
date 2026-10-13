// Loopback regression tests for the Solana operations tooling (CR-10 preflight/recovery, CR-07 Manager
// signer, CR-22 ProgramData watcher). One owned solana-test-validator on loopback; never mainnet.
// Ports default to the fix-ops block (8940/9940/14000/14001-14060) and refuse an occupied RPC port.
// Run: node --test --test-concurrency=1 script/solana-ops.localnet.test.mjs
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { preflight, recoverPrefundedProgram, readDeployedProgram, classifyProgramAccount, LOADER_V3 }
  from '../solana/scripts/loader-v3.mjs';
import { sendInstructions } from '../solana/scripts/guarded-send.mjs';
import { solanaCliConfig } from '../solana/scripts/ops-common.mjs';

const require = createRequire(new URL('../solana/package.json', import.meta.url));
const { Connection, Keypair, SystemProgram } = require('@solana/web3.js');

const RPC_PORT = process.env.PP_LOCALNET_RPC_PORT ?? '8940';
const FAUCET_PORT = process.env.PP_LOCALNET_FAUCET_PORT ?? '9940';
const GOSSIP_PORT = process.env.PP_LOCALNET_GOSSIP_PORT ?? '14000';
const DYNAMIC_PORTS = process.env.PP_LOCALNET_DYNAMIC_PORTS ?? '14001-14060';
const endpoint = `http://127.0.0.1:${RPC_PORT}`;
const MEMO = 'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let validator;
let directory;
let connection;
let elf;
let payer;

export function writeKeypair(path, keypair) {
  writeFileSync(path, JSON.stringify(Array.from(keypair.secretKey)), { mode: 0o600 });
  return path;
}

// HTTP polling only: a websocket subscription would outlive the validator and hang the runner.
async function airdrop(publicKey, sol) {
  const signature = await connection.requestAirdrop(publicKey, sol * 1_000_000_000);
  for (let attempt = 0; attempt < 120; attempt++) {
    const status = (await connection.getSignatureStatuses([signature])).value[0];
    if (status?.err) throw new Error('Local airdrop failed');
    if (status?.confirmationStatus === 'confirmed' || status?.confirmationStatus === 'finalized') return;
    await sleep(250);
  }
  throw new Error('Local airdrop did not confirm');
}

function solana(args) {
  return spawnSync('solana', ['--url', endpoint, ...args], { encoding: 'utf8', timeout: 300_000 });
}

// Same invocation shape as deploy-mainnet.mjs write-buffer: endpoint only inside a 0600 CLI config (CR-27).
function writeBuffer(bufferKeypair, binaryPath = join(directory, 'elf.so')) {
  const payerPath = writeKeypair(join(directory, `payer-${Date.now()}.json`), payer);
  const bufferPath = writeKeypair(join(directory, `buffer-${bufferKeypair.publicKey.toBase58()}.json`), bufferKeypair);
  const configPath = join(directory, `cli-config-${Date.now()}.yml`);
  writeFileSync(configPath, solanaCliConfig(endpoint, payerPath, 'confirmed'), { mode: 0o600 });
  const args = ['--config', configPath, '--keypair', payerPath, '--commitment', 'confirmed', 'program', 'write-buffer', binaryPath,
    '--buffer', bufferPath, '--buffer-authority', payerPath, '--max-len', String(elf.length), '--use-rpc'];
  assert.ok(!args.some(arg => arg.includes(String(RPC_PORT))), 'endpoint never on argv');
  const result = spawnSync('solana', args, { encoding: 'utf8', timeout: 300_000 });
  assert.equal(result.status, 0, result.stderr);
}

before(async () => {
  if (spawnSync('lsof', [`-iTCP:${RPC_PORT}`, '-sTCP:LISTEN'], { encoding: 'utf8' }).stdout.trim()) {
    throw new Error(`Port ${RPC_PORT} is occupied; this suite never kills another validator`);
  }
  directory = mkdtempSync(join(tmpdir(), 'pp-ops-localnet-'));
  validator = spawn('solana-test-validator', ['--reset', '--quiet', '--bind-address', '127.0.0.1', '--rpc-port', RPC_PORT,
    '--faucet-port', FAUCET_PORT, '--gossip-port', GOSSIP_PORT, '--dynamic-port-range', DYNAMIC_PORTS,
    '--ledger', join(directory, 'ledger')], { stdio: 'ignore' });
  connection = new Connection(endpoint, 'confirmed');
  for (let attempt = 0; ; attempt++) {
    try { if (await connection.getSlot('confirmed') > 2) break; } catch {}
    if (attempt > 120) throw new Error('Owned validator did not start');
    await sleep(500);
  }
  // A real loader-v3-deployable SBF ELF without depending on a local program build: the genesis Memo program.
  assert.equal(solana(['program', 'dump', MEMO, join(directory, 'elf.so')]).status, 0);
  elf = readFileSync(join(directory, 'elf.so'));
  payer = Keypair.generate();
  await airdrop(payer.publicKey, 200);
});

after(() => {
  validator?.kill('SIGTERM');
  if (directory) rmSync(directory, { recursive: true, force: true });
});

test('CR-10: preflight passes on an unused id and flags genesis, funding and buffer reuse', async () => {
  const programId = Keypair.generate().publicKey.toBase58();
  const bufferKeypair = Keypair.generate();
  const base = { connection, cluster: 'localnet', programId, bufferAddress: bufferKeypair.publicKey.toBase58(),
    deployer: payer.publicKey.toBase58(), minimumLamports: null, binaryBytes: elf.length, commitment: 'confirmed' };
  const clean = await preflight(base);
  assert.equal(clean.ok, true, JSON.stringify(clean.checks));
  assert.deepEqual(clean.checks.map(check => check.name), ['genesis', 'programId', 'buffer', 'deployerBalance']);
  const poor = await preflight({ ...base, deployer: Keypair.generate().publicKey.toBase58() });
  assert.equal(poor.ok, false);
  assert.equal(poor.checks.find(check => check.name === 'deployerBalance').ok, false);
  const approvedMinimum = await preflight({ ...base, minimumLamports: 1_000_000_000_000 });
  assert.match(approvedMinimum.checks.find(check => check.name === 'deployerBalance').detail, /approved walletMinimumLamports/);
  assert.equal(approvedMinimum.ok, false);
  const wrongCluster = await preflight({ ...base, cluster: 'mainnet' });
  assert.equal(wrongCluster.ok, false);
  assert.deepEqual(wrongCluster.checks.map(check => [check.name, check.ok]), [['genesis', false]]);
  writeBuffer(bufferKeypair);
  const reused = await preflight(base);
  assert.equal(reused.checks.find(check => check.name === 'buffer').ok, false);
  assert.match(reused.checks.find(check => check.name === 'buffer').detail, /buffer exists/);
});

test('CR-10: a pre-funded program id blocks the CLI deploy; the reviewed recovery deploys it exactly', async () => {
  const programKeypair = Keypair.generate();
  const programId = programKeypair.publicKey;
  const griefer = Keypair.generate();
  await airdrop(griefer.publicKey, 1);
  await sendInstructions(connection, [SystemProgram.transfer({ fromPubkey: griefer.publicKey, toPubkey: programId, lamports: 1_000_000 })],
    [griefer]);
  assert.equal(classifyProgramAccount(await connection.getAccountInfo(programId)).state, 'prefunded');
  const griefed = await preflight({ connection, cluster: 'localnet', programId: programId.toBase58(), bufferAddress: Keypair.generate().publicKey.toBase58(),
    deployer: payer.publicKey.toBase58(), minimumLamports: null, binaryBytes: elf.length, commitment: 'confirmed' });
  assert.equal(griefed.checks.find(check => check.name === 'programId').ok, false);
  assert.match(griefed.checks.find(check => check.name === 'programId').detail, /pre-funded by a third party.*--recover-prefunded/);
  const blocked = solana(['--keypair', writeKeypair(join(directory, 'blocked-payer.json'), payer), 'program', 'deploy', join(directory, 'elf.so'),
    '--program-id', writeKeypair(join(directory, 'blocked-program.json'), programKeypair), '--use-rpc']);
  assert.notEqual(blocked.status, 0, 'griefing must block the plain CLI deploy (the failure this recovery exists for)');
  const bufferKeypair = Keypair.generate();
  writeBuffer(bufferKeypair);
  const signatures = await recoverPrefundedProgram({ connection, payer, programKeypair, bufferAddress: bufferKeypair.publicKey,
    binary: elf, maxLen: elf.length, priorityMicroLamports: 10_000, commitment: 'confirmed' });
  assert.ok(signatures.prepare && signatures.deploy);
  const { program, programData } = await readDeployedProgram(connection, programId, 'confirmed');
  assert.equal(program.state, 'deployed');
  assert.equal(program.owner, LOADER_V3.toBase58());
  assert.equal(programData.authority, payer.publicKey.toBase58());
  assert.equal(programData.capacity, elf.length);
  assert.ok(programData.data.equals(elf));
  assert.equal(await connection.getAccountInfo(bufferKeypair.publicKey), null, 'buffer is consumed by the deploy');
  await assert.rejects(recoverPrefundedProgram({ connection, payer, programKeypair, bufferAddress: bufferKeypair.publicKey,
    binary: elf, maxLen: elf.length, priorityMicroLamports: 10_000, commitment: 'confirmed' }), /found deployed/);
});

test('CR-10: recovery resumes from an allocated id and refuses a buffer that is not the reviewed ELF', async () => {
  const programKeypair = Keypair.generate();
  const programId = programKeypair.publicKey;
  const rent = await connection.getMinimumBalanceForRentExemption(36);
  // Simulates a prepare transaction that landed before the operator lost the session.
  await sendInstructions(connection, [SystemProgram.transfer({ fromPubkey: payer.publicKey, toPubkey: programId, lamports: rent }),
    SystemProgram.allocate({ accountPubkey: programId, space: 36 }),
    SystemProgram.assign({ accountPubkey: programId, programId: LOADER_V3 })], [payer, programKeypair]);
  assert.equal(classifyProgramAccount(await connection.getAccountInfo(programId)).state, 'recovery-prepared');
  const bufferKeypair = Keypair.generate();
  writeBuffer(bufferKeypair);
  const tampered = Buffer.from(elf);
  tampered[tampered.length - 1] ^= 1;
  await assert.rejects(recoverPrefundedProgram({ connection, payer, programKeypair, bufferAddress: bufferKeypair.publicKey,
    binary: tampered, maxLen: elf.length, priorityMicroLamports: 10_000, commitment: 'confirmed' }), /fully written loader buffer/);
  const stranger = Keypair.generate();
  await airdrop(stranger.publicKey, 1);
  await assert.rejects(recoverPrefundedProgram({ connection, payer: stranger, programKeypair, bufferAddress: bufferKeypair.publicKey,
    binary: elf, maxLen: elf.length, priorityMicroLamports: 10_000, commitment: 'confirmed' }), /deployer as authority/);
  const signatures = await recoverPrefundedProgram({ connection, payer, programKeypair, bufferAddress: bufferKeypair.publicKey,
    binary: elf, maxLen: elf.length, priorityMicroLamports: 10_000, commitment: 'confirmed' });
  assert.equal(signatures.prepare, undefined, 'already-prepared id skips allocate/assign');
  const { programData } = await readDeployedProgram(connection, programId, 'confirmed');
  assert.ok(programData.data.equals(elf));
});

// ---- CR-07: guarded Manager CLI signer. The genesis Memo program stands in for the spoke: a test IDL
// maps the memo prefix "pp-probe" to an instruction name, so the full decode/allowlist path runs.
const { TransactionInstruction, TransactionMessage, VersionedTransaction, ComputeBudgetProgram, PublicKey } = require('@solana/web3.js');
const PROBE = Buffer.from('pp-probe');

function signerEnv(manager, extra = {}) {
  const approval = join(directory, 'manager-approval.json');
  writeFileSync(approval, JSON.stringify({ schema: 1, status: 'NOT_APPROVED', programId: MEMO, managerSolanaKey: manager.publicKey.toBase58(),
    allowedPrograms: [MEMO, 'ComputeBudget111111111111111111111111111111'], maxPriorityFeeLamports: 100000 }));
  const idl = join(directory, 'probe-idl.json');
  writeFileSync(idl, JSON.stringify({ instructions: [{ name: 'memo_probe', discriminator: Array.from(PROBE) }] }));
  return { ...process.env, PP_MANAGER_APPROVAL_FILE: approval, PP_SPOKE_IDL: idl, PP_LOCALNET_RPC: endpoint,
    SOLANA_MANAGER_PRIVATE_KEY: JSON.stringify(Array.from(manager.secretKey)), ...extra };
}

async function apiTransaction(payerKey, { memo = `pp-probe:${Math.random()}`, signers = [], extraInstructions = [], price } = {}) {
  const block = await connection.getLatestBlockhash('finalized');
  const instructions = [ComputeBudgetProgram.setComputeUnitLimit({ units: 200_000 })];
  if (price) instructions.push(ComputeBudgetProgram.setComputeUnitPrice({ microLamports: price }));
  instructions.push(...extraInstructions, new TransactionInstruction({ programId: new PublicKey(MEMO), data: Buffer.from(memo),
    keys: signers.map(pubkey => ({ pubkey, isSigner: true, isWritable: false })) }));
  const transaction = new VersionedTransaction(new TransactionMessage({ payerKey, recentBlockhash: block.blockhash, instructions }).compileToV0Message());
  const path = join(directory, `api-${Math.random().toString(16).slice(2)}.json`);
  writeFileSync(path, JSON.stringify({ protocolVersion: 'v2', transaction: Buffer.from(transaction.serialize()).toString('base64') }));
  return path;
}

function managerSign(args, env) {
  const result = spawnSync(process.execPath, ['solana/scripts/manager-sign.mjs', ...args], { encoding: 'utf8', env, timeout: 300_000 });
  return { ...result, json: (() => { try { return JSON.parse(result.stdout); } catch { return null; } })() };
}

test('CR-07: signer journals the signature before send, lands once and never re-signs a landed intent', async () => {
  const manager = Keypair.generate();
  await airdrop(manager.publicKey, 2);
  const env = signerEnv(manager);
  const tx = await apiTransaction(manager.publicKey);
  const inspected = managerSign(['inspect', '--tx', tx], { ...env, SOLANA_MANAGER_PRIVATE_KEY: '' });
  assert.equal(inspected.status, 0, inspected.stderr);
  assert.match(inspected.json.intentSha256, /^[0-9a-f]{64}$/);
  assert.deepEqual(inspected.json.instructions.map(entry => entry.name), ['SetComputeUnitLimit', 'memo_probe']);
  const journal = join(directory, 'journal-landed.jsonl');
  const args = ['send', '--tx', tx, '--cluster', 'localnet', '--journal', journal, '--expect-intent', inspected.json.intentSha256, '--expect-instruction', 'memo_probe'];
  const sent = managerSign(args, env);
  assert.equal(sent.status, 0, sent.stderr);
  assert.equal(sent.json.status, 'landed');
  assert.equal(sent.json.alreadyLanded, false);
  const records = readFileSync(journal, 'utf8').trim().split('\n').map(line => JSON.parse(line));
  assert.deepEqual(records.map(record => record.status), ['sent', 'landed']);
  assert.equal(records[0].signature, sent.json.signature);
  assert.ok(records[0].lastValidBlockHeight > 0);
  assert.ok((await connection.getSignatureStatuses([sent.json.signature])).value[0]);
  const again = managerSign(args, env);
  assert.equal(again.status, 0, again.stderr);
  assert.equal(again.json.alreadyLanded, true);
  assert.equal(again.json.signature, sent.json.signature);
  assert.equal(readFileSync(journal, 'utf8').trim().split('\n').length, 2, 'no new signature for a landed intent');
  assert.doesNotMatch(sent.stdout + sent.stderr + again.stderr, /\[\s*\d+\s*,\s*\d+/);
});

test('CR-07: an uncertain prior signature is reconciled to expiry and re-signed only with --retry-expired', async () => {
  const manager = Keypair.generate();
  await airdrop(manager.publicKey, 2);
  const env = signerEnv(manager);
  const tx = await apiTransaction(manager.publicKey);
  const intent = managerSign(['inspect', '--tx', tx], env).json.intentSha256;
  const journal = join(directory, 'journal-uncertain.jsonl');
  // A crash after journaling but before delivery: the signature never reached the cluster.
  const bs58 = require('bs58');
  const ghost = (bs58.default ?? bs58).encode(Keypair.generate().secretKey);
  const height = await connection.getBlockHeight('finalized');
  writeFileSync(journal, JSON.stringify({ key: intent, status: 'sent', signature: ghost, lastValidBlockHeight: height + 3 }) + '\n');
  const args = ['send', '--tx', tx, '--cluster', 'localnet', '--journal', journal, '--expect-intent', intent];
  const refused = managerSign(args, env);
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /provably expired without landing; rerun with --retry-expired/);
  assert.deepEqual(readFileSync(journal, 'utf8').trim().split('\n').map(line => JSON.parse(line).status), ['sent', 'expired']);
  const retried = managerSign([...args, '--retry-expired'], env);
  assert.equal(retried.status, 0, retried.stderr);
  assert.equal(retried.json.status, 'landed');
  assert.notEqual(retried.json.signature, ghost);
});

test('CR-07: signer refuses foreign payers, unpinned keys, non-allowlisted programs, fee drains and reused signers', async () => {
  const manager = Keypair.generate();
  const stranger = Keypair.generate();
  await airdrop(manager.publicKey, 2);
  await airdrop(stranger.publicKey, 1);
  const env = signerEnv(manager);
  const send = async (tx, extraArgs = [], overrides = {}) => {
    const intent = managerSign(['inspect', '--tx', tx], env).json?.intentSha256 ?? 'none';
    return managerSign(['send', '--tx', tx, '--cluster', 'localnet', '--journal', join(directory, 'journal-refusals.jsonl'),
      '--expect-intent', intent, ...extraArgs], { ...env, ...overrides });
  };
  assert.match((await send(await apiTransaction(stranger.publicKey))).stderr, /Fee payer is not the pinned Manager/);
  assert.match((await send(await apiTransaction(manager.publicKey), [], { SOLANA_MANAGER_PRIVATE_KEY: JSON.stringify(Array.from(stranger.secretKey)) })).stderr,
    /differs from the pinned managerSolanaKey/);
  const drain = SystemProgram.transfer({ fromPubkey: manager.publicKey, toPubkey: stranger.publicKey, lamports: 1_000_000 });
  assert.match(managerSign(['inspect', '--tx', await apiTransaction(manager.publicKey, { extraInstructions: [drain] })], env).stderr, /not in the approved allowlist/);
  assert.match(managerSign(['inspect', '--tx', await apiTransaction(manager.publicKey, { price: 1_000_000_000 })], env).stderr, /exceeds the approved cap/);
  const tx = await apiTransaction(manager.publicKey);
  const wrongIntent = managerSign(['send', '--tx', tx, '--cluster', 'localnet', '--expect-intent', '0'.repeat(64)], env);
  assert.match(wrongIntent.stderr, /--expect-intent must equal the reviewed intentSha256/);
  assert.match((await send(tx, ['--expect-instruction', 'kamino_supply'])).stderr, /not the expected kamino_supply/);
  assert.match((await send(tx, [], { PP_LOCALNET_RPC: 'https://example.invalid/' })).stderr, /restricted to an uncredentialed loopback/);
  assert.match(managerSign(['send', '--tx', tx, '--cluster', 'mainnet', '--expect-intent', '0'.repeat(64)], env).stderr, /Founder-approved Manager signing file required/);
  // Fresh one-shot signers only: an account that already exists (here: funded) is refused before signing.
  const reusedPath = writeKeypair(join(directory, 'reused-signer.json'), stranger);
  assert.match((await send(await apiTransaction(manager.publicKey, { signers: [stranger.publicKey] }), ['--extra-signer', reusedPath])).stderr,
    /already exists on-chain/);
  assert.match((await send(await apiTransaction(manager.publicKey, { signers: [stranger.publicKey] }))).stderr,
    /Required signers must be exactly the Manager plus the supplied fresh signers/);
  const fresh = managerSign(['new-signer', '--out', join(directory, 'fresh-signer.json')], env);
  assert.equal(fresh.status, 0, fresh.stderr);
  const freshKey = new PublicKey(fresh.json.publicKey);
  const landed = await send(await apiTransaction(manager.publicKey, { signers: [freshKey] }), ['--extra-signer', join(directory, 'fresh-signer.json')]);
  assert.equal(landed.status, 0, landed.stderr);
  assert.equal(landed.json.status, 'landed');
  assert.notEqual(managerSign(['new-signer', '--out', join(directory, 'fresh-signer.json')], env).status, 0, 'never overwrites a signer file');
});

// ---- CR-22: ProgramData watcher (slot / authority / SHA-256 vs release.json).
test('CR-22: watcher alerts on upgrade, authority change, ELF drift and program closure', async () => {
  const { createHash } = await import('node:crypto');
  const programKeypair = Keypair.generate();
  const programId = programKeypair.publicKey.toBase58();
  const payerPath = writeKeypair(join(directory, 'watch-payer.json'), payer);
  const programPath = writeKeypair(join(directory, 'watch-program.json'), programKeypair);
  const cold = Keypair.generate();
  const coldPath = writeKeypair(join(directory, 'watch-cold.json'), cold);
  const deploy = () => solana(['--keypair', payerPath, '--commitment', 'confirmed', 'program', 'deploy', join(directory, 'elf.so'),
    '--program-id', programPath, '--upgrade-authority', payerPath, '--use-rpc']);
  assert.equal(deploy().status, 0);
  const release = join(directory, 'watch-release.json');
  writeFileSync(release, JSON.stringify({ programId, binarySha256: createHash('sha256').update(elf).digest('hex'), binaryBytes: elf.length }));
  const drifted = join(directory, 'watch-release-drift.json');
  writeFileSync(drifted, JSON.stringify({ programId, binarySha256: '0'.repeat(64), binaryBytes: elf.length }));
  const state = join(directory, 'watch-state.json');
  const watch = (authority = payer.publicKey.toBase58(), releasePath = release) => {
    const result = spawnSync(process.execPath, ['solana/scripts/programdata-watch.mjs', '--cluster', 'localnet', '--commitment', 'confirmed',
      '--release', releasePath, '--state', state, '--authority', authority], { encoding: 'utf8', env: { ...process.env, PP_LOCALNET_RPC: endpoint } });
    return { status: result.status, report: JSON.parse(result.stdout || 'null'), stderr: result.stderr };
  };
  const baseline = watch();
  assert.equal(baseline.status, 0, baseline.stderr);
  assert.equal(baseline.report.status, 'OK');
  assert.equal(baseline.report.authority, payer.publicKey.toBase58());
  assert.equal(watch().report.status, 'OK', 'stable program stays OK on the cached SHA');
  assert.equal(deploy().status, 0, 'same-ELF upgrade');
  const upgraded = watch();
  assert.equal(upgraded.status, 2);
  assert.match(upgraded.report.findings.join(' '), /program upgraded: deploy slot \d+ -> \d+/);
  assert.equal(watch().report.status, 'OK', 'an upgrade alerts once, then the new slot is the baseline');
  const drift = watch(payer.publicKey.toBase58(), drifted);
  assert.equal(drift.status, 2);
  assert.match(drift.report.findings.join(' '), /on-chain ELF [0-9a-f]{64} differs from release/);
  assert.equal(solana(['--keypair', payerPath, '--commitment', 'confirmed', 'program', 'set-upgrade-authority', programId,
    '--upgrade-authority', payerPath, '--new-upgrade-authority', coldPath]).status, 0);
  const moved = watch();
  assert.equal(moved.status, 2);
  assert.match(moved.report.findings.join(' '), new RegExp(`upgrade authority ${cold.publicKey.toBase58()} differs from expected`));
  assert.equal(watch(cold.publicKey.toBase58()).report.status, 'OK', 'a reviewed cold-key move verifies against the new expected authority');
  assert.equal(solana(['--keypair', payerPath, '--commitment', 'confirmed', 'program', 'close', programId, '--authority', coldPath,
    '--recipient', payer.publicKey.toBase58(), '--bypass-warning']).status, 0);
  const closed = watch(cold.publicKey.toBase58());
  assert.equal(closed.status, 2);
  assert.equal(closed.report.status, 'ALERT');
});
