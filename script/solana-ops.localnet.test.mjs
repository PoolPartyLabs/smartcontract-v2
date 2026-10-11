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

function writeBuffer(bufferKeypair, binaryPath = join(directory, 'elf.so')) {
  const payerPath = writeKeypair(join(directory, `payer-${Date.now()}.json`), payer);
  const bufferPath = writeKeypair(join(directory, `buffer-${bufferKeypair.publicKey.toBase58()}.json`), bufferKeypair);
  const result = solana(['--keypair', payerPath, '--commitment', 'confirmed', 'program', 'write-buffer', binaryPath,
    '--buffer', bufferPath, '--buffer-authority', payerPath, '--max-len', String(elf.length), '--use-rpc']);
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
