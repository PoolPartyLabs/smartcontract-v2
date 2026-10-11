import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, mkdtempSync, rmSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { R8_AUTHORITY, checkedEndpoint, assertGenesis, keypairFromParameter, keypairFromFile, requireOwnerOnly,
  sanitize, scrubbedEnv, stepLogger, cliFailureDetail } from './ops-common.mjs';
import { LOADER_V3, classifyProgramAccount, parseBuffer, preflight, recoverPrefundedProgram } from './loader-v3.mjs';

const require = createRequire(import.meta.url);
const { Connection, PublicKey } = require('@solana/web3.js');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const fail = message => { throw new Error(message); };
const log = stepLogger('deploy-mainnet');
const MODES = ['--preflight', '--verify', '--broadcast', '--recover-prefunded'];
const loadManifest = () => JSON.parse(readFileSync(resolve(process.env.PP_DEPLOY_APPROVAL_FILE ?? 'script/solana-mainnet-approval.json')));

async function connect() {
  const endpoint = checkedEndpoint('mainnet', process.env.SOLANA_MAINNET_RPC);
  const connection = new Connection(endpoint, 'finalized');
  return { endpoint, connection };
}

// CR-10 / SP-C11: read-only and NOT approval-gated. No key material is required; signer files are only
// read to derive public keys. Exit 2 means at least one NO-GO row.
async function runPreflight() {
  const manifest = loadManifest();
  const rows = [];
  const programId = new PublicKey(manifest.programId).toBase58();
  rows.push({ name: 'authorityPin', ok: manifest.authority === R8_AUTHORITY, detail: 'deployer/initial upgrade authority equals R8' });
  if (process.env.PP_DEPLOY_PROGRAM_KEYPAIR) {
    const signer = keypairFromFile(process.env.PP_DEPLOY_PROGRAM_KEYPAIR, 'Program signer file').publicKey.toBase58();
    rows.push({ name: 'programSigner', ok: signer === programId, detail: signer === programId ? 'program signer file matches the manifest id' : 'program signer file differs from the manifest id' });
  }
  let bufferAddress = process.env.PP_DEPLOY_BUFFER_ADDRESS;
  if (process.env.PP_DEPLOY_BUFFER_KEYPAIR) bufferAddress = keypairFromFile(process.env.PP_DEPLOY_BUFFER_KEYPAIR, 'Buffer signer file').publicKey.toBase58();
  if (bufferAddress) bufferAddress = new PublicKey(bufferAddress).toBase58();
  const binaryPath = resolve(root, 'target/deploy/pp_spoke.so');
  let binaryBytes = Number.isSafeInteger(manifest.maxLen) ? manifest.maxLen : undefined;
  if (existsSync(binaryPath)) {
    const binary = readFileSync(binaryPath);
    binaryBytes ??= binary.length;
    const release = existsSync(resolve(root, 'target/deploy/pp_spoke.release.json'))
      ? JSON.parse(readFileSync(resolve(root, 'target/deploy/pp_spoke.release.json'))) : {};
    const sha = createHash('sha256').update(binary).digest('hex');
    rows.push({ name: 'localRelease', ok: release.binarySha256 === sha && release.programId === programId
      && (!manifest.binarySha256 || manifest.binarySha256 === sha),
    detail: `local ELF ${binary.length} bytes sha256 ${sha}; release.json ${release.binarySha256 === sha ? 'matches' : 'differs'}` });
  }
  const { connection } = await connect();
  log('preflight', 'start', `programId=${programId}`);
  const result = await preflight({ connection, cluster: 'mainnet', programId, bufferAddress, deployer: manifest.authority,
    minimumLamports: manifest.walletMinimumLamports, binaryBytes });
  const checks = [...rows, ...result.checks].map(check => ({ ...check, detail: sanitize(check.detail) }));
  const ok = checks.every(check => check.ok);
  console.log(JSON.stringify({ preflightAt: new Date().toISOString(), readOnly: true, approvalStatus: manifest.status,
    programId, deployer: manifest.authority, buffer: bufferAddress ?? null, ok, checks }, null, 2));
  log('preflight', ok ? 'ok' : 'nogo', ok ? '' : checks.filter(check => !check.ok).map(check => check.name).join(','));
  if (!ok) process.exitCode = 2;
}

function requireApproval(manifest) {
  if (manifest.status !== 'FOUNDER_APPROVED' || !manifest.approvedBy || !manifest.approvedAt
      || !Number.isFinite(Date.parse(manifest.approvedAt)) || !manifest.sourceCommit?.match(/^[a-f0-9]{40}$/)) {
    fail('Founder approval and exact source commit are required; no transaction submitted');
  }
  if (manifest.authority !== '6VTveiPVZVM7H9BWEsUsu4ivsrPjKw9ePrLQqHaFgJaA') {
    fail('Upgrade authority must equal the R8 founder key; no transaction submitted');
  }
  const git = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' });
  const clean = spawnSync('git', ['status', '--porcelain', '--untracked-files=no'], { cwd: root, encoding: 'utf8' });
  if (git.status !== 0 || git.stdout.trim() !== manifest.sourceCommit || clean.status !== 0 || clean.stdout.trim()) {
    fail('Approval source does not match a clean checkout');
  }
  const release = JSON.parse(readFileSync(resolve(root, 'target/deploy/pp_spoke.release.json')));
  const binaryPath = resolve(root, 'target/deploy/pp_spoke.so');
  const binary = readFileSync(binaryPath);
  const sha256 = createHash('sha256').update(binary).digest('hex');
  if (release.sourceCommit !== manifest.sourceCommit || sha256 !== manifest.binarySha256 || sha256 !== release.binarySha256
      || release.idlSha256 !== manifest.idlSha256 || release.programId !== manifest.programId
      || release.features.join(',') !== 'no-idl,no-log-ix-name' || manifest.maxLen !== binary.length
      || release.programId === 'Fg6PaFpoGXkYsidMpWxTWqkZ7FEfcYkgMQHGfVNLusVw') {
    fail('Reviewed production ELF/IDL, non-scaffold identity and exactly 1x capacity required');
  }
  if (createHash('sha256').update(readFileSync(resolve(root, 'target/idl/pp_spoke.json'))).digest('hex') !== release.idlSha256) {
    fail('IDL bytes differ from the reviewed release');
  }
  return { binary, binaryPath, sha256 };
}

async function main() {
  if (!MODES.includes(process.argv[2]) || process.argv.length !== 3) {
    fail('Usage: deploy-mainnet.mjs --preflight|--verify|--broadcast|--recover-prefunded; no implicit transaction submission');
  }
  const mode = process.argv[2];
  if (mode === '--preflight') return runPreflight();
  const manifest = loadManifest();
  const { binary, binaryPath, sha256 } = requireApproval(manifest);
  log('approval', 'ok', `mode=${mode} sourceCommit=${manifest.sourceCommit}`);
  const { endpoint, connection } = await connect();
  await assertGenesis(connection, 'mainnet');
  log('genesis', 'ok', 'mainnet');
  const programId = new PublicKey(manifest.programId);
  const authority = new PublicKey(manifest.authority);
  async function verify() {
    const program = await connection.getAccountInfo(programId);
    if (!program?.executable || !program.owner.equals(LOADER_V3)
        || program.data.length !== 36 || program.data.readUInt32LE(0) !== 2) fail('Program owner/executable/layout mismatch');
    const dataId = new PublicKey(program.data.subarray(4));
    const data = await connection.getAccountInfo(dataId);
    if (!data || !data.owner.equals(program.owner) || data.data.length !== 45 + binary.length
        || data.data.readUInt32LE(0) !== 3 || data.data[12] !== 1
        || !data.data.subarray(13, 45).equals(authority.toBuffer())
        || !data.data.subarray(45).equals(binary)) fail('On-chain ELF/capacity/authority mismatch');
    console.log(JSON.stringify({ verifiedAt: new Date().toISOString(), programId: manifest.programId,
      programData: dataId.toBase58(), binarySha256: sha256, authority: manifest.authority,
      programRentLamports: program.lamports, programDataRentLamports: data.lamports,
      onChainIdlCreatedByThisPackage: false }, null, 2));
    log('verify', 'ok', `programData=${dataId.toBase58()}`);
  }
  if (mode === '--verify') { await verify(); return; }
  const recovery = mode === '--recover-prefunded';
  const programState = classifyProgramAccount(await connection.getAccountInfo(programId));
  log('program-id', 'inspected', `state=${programState.state}`);
  if (!recovery && programState.state !== 'absent') {
    fail(['prefunded', 'recovery-prepared'].includes(programState.state)
      ? 'Program id is pre-funded by a third party; run --preflight, then the reviewed --recover-prefunded mode'
      : 'Initial-deploy package refuses existing programs; run --verify');
  }
  if (recovery && !['prefunded', 'recovery-prepared'].includes(programState.state)) {
    fail(`Recovery applies only to a pre-funded program id; found ${programState.state}`);
  }
  if (!process.env.PP_DEPLOY_PROGRAM_KEYPAIR || !process.env.PP_DEPLOY_BUFFER_KEYPAIR) fail('Persistent program and buffer signer paths required');
  for (const signerPath of [process.env.PP_DEPLOY_PROGRAM_KEYPAIR, process.env.PP_DEPLOY_BUFFER_KEYPAIR]) requireOwnerOnly(signerPath);
  const payer = keypairFromParameter(process.env.SOLANA_DEPLOYER_PRIVATE_KEY, 'deployer key');
  if (!payer.publicKey.equals(authority)) fail('Deployer must equal the approved upgrade authority');
  const priority = manifest.priorityMicroLamportsPerCU;
  if (!Number.isSafeInteger(priority) || priority < 1 || priority > 1000000) fail('Reviewed positive priority fee required');
  const programKeypair = keypairFromFile(process.env.PP_DEPLOY_PROGRAM_KEYPAIR, 'Program signer file');
  if (!programKeypair.publicKey.equals(programId)) fail('Program signer differs from reviewed program id');
  const bufferAddress = keypairFromFile(process.env.PP_DEPLOY_BUFFER_KEYPAIR, 'Buffer signer file').publicKey;
  const bufferInfo = await connection.getAccountInfo(bufferAddress);
  // A recovery may resume from the fully written buffer left by a failed broadcast; an initial deploy never reuses one.
  const resumeBuffer = recovery && !!bufferInfo;
  if (bufferInfo && !recovery) fail('Buffer already exists; review/resume it explicitly, never overwrite implicitly');
  if (resumeBuffer) {
    const buffer = parseBuffer(bufferInfo);
    if (!buffer || buffer.authority !== payer.publicKey.toBase58() || buffer.capacity !== binary.length || !buffer.data.equals(binary)) {
      fail('Existing buffer is not a complete reviewed-ELF buffer owned by the deployer; close it and use a fresh buffer signer');
    }
    log('buffer', 'resume', `buffer=${bufferAddress.toBase58()} complete`);
  } else if (!Number.isSafeInteger(manifest.walletMinimumLamports) || manifest.walletMinimumLamports < 1
      || await connection.getBalance(authority) < manifest.walletMinimumLamports) {
    fail('Approved combined-wallet funding minimum not met');
  }
  const directory = mkdtempSync(resolve(tmpdir(), 'pp-approved-deploy-'));
  const payerPath = resolve(directory, 'payer.json');
  const childEnv = scrubbedEnv();
  function cli(step, args) {
    log(step, 'start');
    const started = Date.now();
    const result = spawnSync('solana', args, { env: childEnv, encoding: 'utf8', timeout: 900000, maxBuffer: 16 * 1024 * 1024 });
    if (result.status !== 0) {
      log(step, 'fail', cliFailureDetail(result));
      fail(`Solana CLI step ${step} failed; persistent buffer ${bufferAddress.toBase58()} retained for recovery`);
    }
    log(step, 'ok', `elapsedMs=${Date.now() - started}`);
    return result.stdout.trim();
  }
  try {
    writeFileSync(payerPath, JSON.stringify(Array.from(payer.secretKey)), { mode: 0o600 });
    if (!resumeBuffer) {
      cli('write-buffer', ['--url', endpoint, '--keypair', payerPath, '--commitment', 'finalized', 'program', 'write-buffer', binaryPath,
        '--buffer', process.env.PP_DEPLOY_BUFFER_KEYPAIR, '--buffer-authority', payerPath,
        '--max-len', String(binary.length), '--with-compute-unit-price', String(priority), '--use-rpc']);
    }
    if (recovery) {
      await recoverPrefundedProgram({ connection, payer, programKeypair, bufferAddress, binary, maxLen: binary.length,
        priorityMicroLamports: priority, commitment: 'finalized', log });
    } else {
      cli('deploy', ['--url', endpoint, '--keypair', payerPath, '--commitment', 'finalized', 'program', 'deploy',
        '--buffer', process.env.PP_DEPLOY_BUFFER_KEYPAIR, '--program-id', process.env.PP_DEPLOY_PROGRAM_KEYPAIR,
        '--upgrade-authority', payerPath, '--max-len', String(binary.length), '--no-auto-extend',
        '--with-compute-unit-price', String(priority), '--use-rpc']);
    }
    await verify();
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
main().catch(error => {
  // Diagnostics are sanitized (no endpoint, key bytes or secret-bearing env values), never suppressed wholesale.
  console.error(`deploy-mainnet: ${sanitize(error?.message ?? 'unknown failure')}`);
  process.exitCode = 1;
});
