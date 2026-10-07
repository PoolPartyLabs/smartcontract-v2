import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, mkdtempSync, rmSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const require = createRequire(import.meta.url);
const { Keypair, Connection, PublicKey } = require('@solana/web3.js');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const fail = message => { throw new Error(message); };
async function main() {
  if (!['--verify', '--broadcast'].includes(process.argv[2]) || process.argv.length !== 3) {
    fail('Usage: deploy-mainnet.mjs --verify|--broadcast; no implicit transaction submission');
  }
  const broadcast = process.argv[2] === '--broadcast';
  const manifest = JSON.parse(readFileSync(resolve(process.env.PP_DEPLOY_APPROVAL_FILE ?? 'script/solana-mainnet-approval.json')));
  if (manifest.status !== 'FOUNDER_APPROVED' || !manifest.approvedBy || !manifest.approvedAt
      || !Number.isFinite(Date.parse(manifest.approvedAt)) || !manifest.sourceCommit?.match(/^[a-f0-9]{40}$/)) {
    fail('Founder approval and exact source commit are required; no transaction submitted');
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
  if (sha256 !== manifest.binarySha256 || sha256 !== release.binarySha256
      || release.idlSha256 !== manifest.idlSha256 || release.programId !== manifest.programId
      || release.features.join(',') !== 'no-idl,no-log-ix-name' || manifest.maxLen !== binary.length
      || release.programId === 'Fg6PaFpoGXkYsidMpWxTWqkZ7FEfcYkgMQHGfVNLusVw') {
    fail('Reviewed production ELF/IDL, non-scaffold identity and exactly 1x capacity required');
  }
  if (createHash('sha256').update(readFileSync(resolve(root, 'target/idl/pp_spoke.json'))).digest('hex') !== release.idlSha256) {
    fail('IDL bytes differ from the reviewed release');
  }
  const endpoint = process.env.SOLANA_MAINNET_RPC;
  let parsed;
  try { parsed = new URL(endpoint); } catch { fail('Explicit mainnet endpoint required; value suppressed'); }
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password) fail('HTTPS mainnet endpoint required; value suppressed');
  const connection = new Connection(endpoint, 'finalized');
  if (await connection.getGenesisHash() !== '5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp') fail('Endpoint is not Solana mainnet');
  const programId = new PublicKey(manifest.programId);
  const authority = new PublicKey(manifest.authority);
  async function verify() {
    const program = await connection.getAccountInfo(programId);
    if (!program?.executable || !program.owner.equals(new PublicKey('BPFLoaderUpgradeab1e11111111111111111111111'))
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
  }
  if (!broadcast) { await verify(); return; }
  if (await connection.getAccountInfo(programId)) fail('Initial-deploy package refuses existing programs; use reviewed upgrade recovery');
  if (!process.env.PP_DEPLOY_PROGRAM_KEYPAIR || !process.env.PP_DEPLOY_BUFFER_KEYPAIR) fail('Persistent program and buffer signer paths required');
  for (const signerPath of [process.env.PP_DEPLOY_PROGRAM_KEYPAIR, process.env.PP_DEPLOY_BUFFER_KEYPAIR]) {
    if (!statSync(signerPath).isFile() || (statSync(signerPath).mode & 0o077) !== 0) fail('Signer files require owner-only permissions');
  }
  const key = process.env.SOLANA_DEPLOYER_PRIVATE_KEY?.trim();
  let payer;
  try {
    const values = key?.startsWith('[') ? JSON.parse(key) : require('bs58').decode(key ?? '');
    if (values.length !== 64 || !Array.from(values).every(value => Number.isInteger(value) && value >= 0 && value <= 255)) throw new Error();
    payer = Keypair.fromSecretKey(Uint8Array.from(values));
  } catch { fail('Valid deployer key parameter required; value suppressed'); }
  if (!payer.publicKey.equals(authority)) fail('Deployer must equal the approved upgrade authority');
  const priority = manifest.priorityMicroLamportsPerCU;
  if (!Number.isSafeInteger(priority) || priority < 1 || priority > 1000000) fail('Reviewed positive priority fee required');
  if (!Number.isSafeInteger(manifest.walletMinimumLamports) || manifest.walletMinimumLamports < 1
      || await connection.getBalance(authority) < manifest.walletMinimumLamports) fail('Approved combined-wallet funding minimum not met');
  const directory = mkdtempSync(resolve(tmpdir(), 'pp-approved-deploy-'));
  const payerPath = resolve(directory, 'payer.json');
  const childEnv = { ...process.env };
  for (const name of Object.keys(childEnv)) if (/PRIVATE_KEY|SECRET|RPC|API_KEY/.test(name)) delete childEnv[name];
  function cli(args) {
    const result = spawnSync('solana', args, { env: childEnv, encoding: 'utf8', timeout: 900000, maxBuffer: 16 * 1024 * 1024 });
    if (result.status !== 0) fail('Solana CLI step failed; output suppressed; retain persistent buffer for recovery');
    return result.stdout.trim();
  }
  try {
    writeFileSync(payerPath, JSON.stringify(Array.from(payer.secretKey)), { mode: 0o600 });
    if (cli(['address', '--keypair', process.env.PP_DEPLOY_PROGRAM_KEYPAIR]) !== manifest.programId) fail('Program signer differs from reviewed program id');
    const bufferAddress = cli(['address', '--keypair', process.env.PP_DEPLOY_BUFFER_KEYPAIR]);
    if (await connection.getAccountInfo(new PublicKey(bufferAddress))) fail('Buffer already exists; review/resume it explicitly, never overwrite implicitly');
    cli(['--url', endpoint, '--keypair', payerPath, '--commitment', 'finalized', 'program', 'write-buffer', binaryPath,
      '--buffer', process.env.PP_DEPLOY_BUFFER_KEYPAIR, '--buffer-authority', payerPath,
      '--max-len', String(binary.length), '--with-compute-unit-price', String(priority), '--use-rpc']);
    cli(['--url', endpoint, '--keypair', payerPath, '--commitment', 'finalized', 'program', 'deploy',
      '--buffer', process.env.PP_DEPLOY_BUFFER_KEYPAIR, '--program-id', process.env.PP_DEPLOY_PROGRAM_KEYPAIR,
      '--upgrade-authority', payerPath, '--max-len', String(binary.length), '--no-auto-extend',
      '--with-compute-unit-price', String(priority), '--use-rpc']);
    await verify();
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
main().catch(error => {
  const safe = error?.message?.startsWith('Usage:') || error?.message?.includes('Founder approval');
  console.error(safe ? error.message : 'Deploy/verification failed; secrets and endpoint suppressed; consult the runbook');
  process.exitCode = 1;
});
