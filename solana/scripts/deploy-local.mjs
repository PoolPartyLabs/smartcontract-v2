import { createRequire } from 'node:module';
import { mkdtempSync, writeFileSync, rmSync, statSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { Keypair, Connection, PublicKey } from '@solana/web3.js';

const require = createRequire(import.meta.url);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const endpoint = process.env.PP_DEPLOY_LOCAL_RPC ?? 'http://127.0.0.1:8995';
const url = new URL(endpoint);
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
  const secret = encoded.startsWith('[') ? Uint8Array.from(JSON.parse(encoded)) : require('bs58').decode(encoded);
  deployer = Keypair.fromSecretKey(secret);
} catch {
  throw new Error('Invalid deployer parameter; expected a 64-byte JSON array or base58 keypair');
}
const binary = resolve(root, 'target/deploy/pp_spoke.so');
const size = statSync(binary).size;
const multiplier = Number(process.env.PP_DEPLOY_MAX_LEN_MULTIPLIER ?? '1');
if (![1, 2].includes(multiplier)) throw new Error('Max length multiplier must be 1 or 2');
const connection = new Connection(endpoint, 'confirmed');
const directory = mkdtempSync(resolve(tmpdir(), 'pp-deploy-local-'));
const payer = resolve(directory, 'payer.json');
const buffer = resolve(directory, 'buffer.json');
const program = resolve(directory, 'program.json');
const programKey = Keypair.generate();
for (const [path, key] of [[payer, deployer], [buffer, Keypair.generate()], [program, programKey]]) {
  writeFileSync(path, JSON.stringify(Array.from(key.secretKey)), { mode: 0o600 });
}
const childEnv = { ...process.env };
delete childEnv.SOLANA_DEPLOYER_PRIVATE_KEY;
function command(args) {
  const result = spawnSync('solana', ['--url', endpoint, '--keypair', payer, ...args],
    { encoding: 'utf8', env: childEnv, timeout: 600_000 });
  if (result.status !== 0) throw new Error('Local Solana CLI step failed; output suppressed for key safety');
}
try {
  if (process.env.PP_DEPLOY_LOCAL_AIRDROP === '1') {
    const signature = await connection.requestAirdrop(deployer.publicKey, 100_000_000_000);
    await connection.confirmTransaction(signature, 'confirmed');
  }
  const balanceBefore = await connection.getBalance(deployer.publicKey);
  command(['program', 'write-buffer', binary, '--buffer', buffer, '--buffer-authority', payer,
    '--max-len', String(size * multiplier)]);
  const afterBuffer = await connection.getBalance(deployer.publicKey);
  command(['program', 'deploy', '--buffer', buffer, '--program-id', program, '--upgrade-authority', payer,
    '--max-len', String(size * multiplier)]);
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
    maxLen: size * multiplier, programId: programKey.publicKey.toBase58(),
    programRentLamports: info.lamports, programDataRentLamports: programData.lamports,
    bufferStageDebitLamports: balanceBefore - afterBuffer,
    totalDebitLamports: balanceBefore - await connection.getBalance(deployer.publicKey) }));
} finally {
  rmSync(directory, { recursive: true, force: true });
}
