import { createRequire } from 'node:module';
import { mkdtempSync, writeFileSync, rmSync, statSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { Keypair, Connection, PublicKey } from '@solana/web3.js';

const require = createRequire(import.meta.url);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
if (process.argv.length !== 3 || process.argv[2] !== '--broadcast') {
  throw new Error('Local deployment requires the explicit --broadcast flag; no transaction submitted');
}
const endpoint = process.env.PP_DEPLOY_LOCAL_RPC ?? 'http://127.0.0.1:8970';
let url;
try { url = new URL(endpoint); } catch { throw new Error('Invalid local validator endpoint; value suppressed'); }
if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)
    || url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
  throw new Error('Deployment is restricted to an explicit loopback HTTP validator');
}
if (!process.env.SOLANA_DEPLOYER_PRIVATE_KEY?.trim()) {
  throw new Error('SOLANA_DEPLOYER_PRIVATE_KEY is required; no default authority');
}
const encoded = process.env.SOLANA_DEPLOYER_PRIVATE_KEY.trim();
let deployer;
try {
  const values = encoded.startsWith('[') ? JSON.parse(encoded) : require('bs58').decode(encoded);
  if (values.length !== 64 || !Array.from(values).every(value => Number.isInteger(value) && value >= 0 && value <= 255))
    throw new Error('Invalid key bytes');
  const secret = Uint8Array.from(values);
  deployer = Keypair.fromSecretKey(secret);
} catch {
  throw new Error('Invalid deployer parameter; expected a 64-byte JSON array or base58 keypair');
}
async function main() {
const binary = resolve(root, 'target/deploy/pp_spoke.so');
const size = statSync(binary).size;
const multiplier = Number(process.env.PP_DEPLOY_MAX_LEN_MULTIPLIER ?? '1');
if (![1, 2].includes(multiplier)) throw new Error('Max length multiplier must be 1 or 2');
const priority = Number(process.env.PP_BUDGET_PRIORITY_MICROLAMPORTS ?? '10000');
if (!Number.isSafeInteger(priority) || priority < 1 || priority > 1000000) throw new Error('Invalid priority fee');
const connection = new Connection(endpoint, 'confirmed');
const directory = mkdtempSync(resolve(tmpdir(), 'pp-deploy-local-'));
const payer = resolve(directory, 'payer.json');
const buffer = resolve(directory, 'buffer.json');
const program = resolve(directory, 'program.json');
const programKey = Keypair.generate();
const bufferKey = Keypair.generate();
const childEnv = { ...process.env };
delete childEnv.SOLANA_DEPLOYER_PRIVATE_KEY;
function command(args) {
  const result = spawnSync('solana', ['--url', endpoint, '--keypair', payer, ...args],
    { encoding: 'utf8', env: childEnv, timeout: 600_000 });
  if (result.status !== 0) throw new Error('Local Solana CLI step failed; output suppressed for key safety');
}
try {
  for (const [path, key] of [[payer, deployer], [buffer, bufferKey], [program, programKey]]) {
    writeFileSync(path, JSON.stringify(Array.from(key.secretKey)), { mode: 0o600 });
  }
  if (process.env.PP_DEPLOY_LOCAL_AIRDROP === '1') {
    const signature = await connection.requestAirdrop(deployer.publicKey, 100_000_000_000);
    await connection.confirmTransaction(signature, 'confirmed');
  }
  const balanceBefore = await connection.getBalance(deployer.publicKey);
  command(['program', 'write-buffer', binary, '--buffer', buffer, '--buffer-authority', payer,
    '--max-len', String(size * multiplier), '--with-compute-unit-price', String(priority), '--use-rpc']);
  const afterBuffer = await connection.getBalance(deployer.publicKey);
  const bufferInfo = await connection.getAccountInfo(bufferKey.publicKey);
  if (!bufferInfo) throw new Error('Local buffer is absent');
  command(['program', 'deploy', '--buffer', buffer, '--program-id', program, '--upgrade-authority', payer,
    '--max-len', String(size * multiplier), '--with-compute-unit-price', String(priority), '--use-rpc', '--no-auto-extend']);
  const info = await connection.getAccountInfo(programKey.publicKey);
  if (!info?.executable || !info.owner.equals(new PublicKey('BPFLoaderUpgradeab1e11111111111111111111111')))
    throw new Error('Local program is not loader-v3 executable');
  const dataAddress = new PublicKey(info.data.subarray(4, 36));
  const programData = await connection.getAccountInfo(dataAddress);
  if (!programData || programData.data[12] !== 1
      || !programData.data.subarray(13, 45).equals(deployer.publicKey.toBuffer()))
    throw new Error('Upgrade authority differs from the supplied deployer');
  if (!programData.data.subarray(45, 45 + size).equals(readFileSync(binary)))
    throw new Error('Deployed ELF bytes differ');
  console.log(JSON.stringify({ scope: 'local-validator-only', binaryBytes: size, maxLenMultiplier: multiplier,
    priorityMicroLamportsPerCU: priority,
    maxLen: size * multiplier, programId: programKey.publicKey.toBase58(),
    programRentLamports: info.lamports, programDataRentLamports: programData.lamports,
    bufferRentLamports: bufferInfo.lamports, bufferAccountBytes: bufferInfo.data.length,
    bufferStageDebitLamports: balanceBefore - afterBuffer,
    totalDebitLamports: balanceBefore - await connection.getBalance(deployer.publicKey) }));
} finally {
  rmSync(directory, { recursive: true, force: true });
}
}
main().catch(() => {
  console.error('Local deployment failed; diagnostic output suppressed for key and endpoint safety');
  process.exitCode = 1;
});
