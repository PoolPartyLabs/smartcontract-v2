import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../solana/package.json', import.meta.url));
const { ComputeBudgetProgram } = require('@solana/web3.js');

test('DEC-189: mainnet deployment requires an explicit command before network/key use', () => {
  const result = spawnSync(process.execPath, ['solana/scripts/deploy-mainnet.mjs'], {
    encoding: 'utf8', env: { ...process.env, SOLANA_MAINNET_RPC: 'SECRET_ENDPOINT', SOLANA_DEPLOYER_PRIVATE_KEY: 'SECRET_KEY' },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /no implicit transaction submission/);
  assert.doesNotMatch(result.stdout + result.stderr, /SECRET_ENDPOINT|SECRET_KEY/);
});

test('DEC-189: even explicit mainnet broadcast refuses the unapproved manifest', () => {
  const result = spawnSync(process.execPath, ['solana/scripts/deploy-mainnet.mjs', '--broadcast'], { encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Founder approval/);
});

test('DEC-188/189: committed approval keeps identity, hash and budget unresolved', () => {
  const approval = JSON.parse(readFileSync('script/solana-mainnet-approval.json'));
  assert.equal(approval.status, 'NOT_APPROVED');
  assert.equal(approval.programId, '7PptZ653uyn5eoAFKqs4DXR1ijxH6sf49f2YAGMLTfCx');
  for (const field of ['binarySha256', 'idlSha256', 'maxLen', 'walletMinimumLamports']) assert.equal(approval[field], null);
});

test('DEC-189: EVM wrapper refuses broadcast without approval before RPC/key use', () => {
  const result = spawnSync('bash', ['script/solana-evm-deploy.sh', 'arbitrum', 'factory-v6', '--broadcast'], {
    encoding: 'utf8', env: { ...process.env, PP_EVM_FOUNDER_APPROVED: '', ARBITRUM_RPC_URL: 'SECRET_ENDPOINT', PRIVATE_KEY: 'SECRET_KEY' },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /no transaction submitted/);
  assert.doesNotMatch(result.stdout + result.stderr, /SECRET_ENDPOINT|SECRET_KEY/);
});

test('DEC-195: rehearsal builder emits explicit 900k limit, preserving lower limits', async () => {
  await import('../solana/scripts/deploy-compute-budget.mjs');
  assert.equal(ComputeBudgetProgram.setComputeUnitLimit({ units: 1400000 }).data.readUInt32LE(1), 900000);
  assert.equal(ComputeBudgetProgram.setComputeUnitLimit({ units: 600000 }).data.readUInt32LE(1), 600000);
});

test('R8: an approved manifest cannot substitute the upgrade authority', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pp-authority-test-'));
  try {
    const approval = JSON.parse(readFileSync('script/solana-mainnet-approval.json'));
    const filename = join(directory, 'approval.json');
    writeFileSync(filename, JSON.stringify({ ...approval, status: 'FOUNDER_APPROVED',
      approvedBy: 'test', approvedAt: new Date().toISOString(), sourceCommit: 'a'.repeat(40),
      authority: '11111111111111111111111111111111' }));
    const result = spawnSync(process.execPath, ['solana/scripts/deploy-mainnet.mjs', '--broadcast'], {
      encoding: 'utf8', env: { ...process.env, PP_DEPLOY_APPROVAL_FILE: filename,
        SOLANA_MAINNET_RPC: 'SECRET_ENDPOINT', SOLANA_DEPLOYER_PRIVATE_KEY: 'SECRET_KEY' },
    });
    assert.notEqual(result.status, 0);
    assert.doesNotMatch(result.stdout + result.stderr, /SECRET_ENDPOINT|SECRET_KEY/);
    assert.match(readFileSync('solana/scripts/deploy-mainnet.mjs', 'utf8'), /manifest\.authority !== '6VTveiPVZVM7H9BWEsUsu4ivsrPjKw9ePrLQqHaFgJaA'/);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('deployment shell wrappers disable inherited tracing before parameter access', () => {
  for (const filename of ['script/solana-evm-deploy.sh', 'script/solana-three-chain-creation.sh']) {
    const args = filename.includes('evm-deploy') ? ['arbitrum', 'factory-v6', '--broadcast'] : ['--broadcast'];
    const result = spawnSync('bash', ['-x', filename, ...args], { encoding: 'utf8',
      env: { ...process.env, PP_EVM_FOUNDER_APPROVED: '', PRIVATE_KEY: 'SECRET_KEY',
        DEPLOYER_PRIVATE_KEY: 'SECRET_KEY', ARBITRUM_RPC_URL: 'SECRET_ENDPOINT' } });
    assert.notEqual(result.status, 0);
    assert.doesNotMatch(result.stdout + result.stderr, /SECRET_KEY|SECRET_ENDPOINT/);
    assert.match(readFileSync(filename, 'utf8'), /^#![^\n]+\nset \+x\n/);
  }
});

test('persistent program keys remain excluded in every clone', () => {
  assert.match(readFileSync('.gitignore', 'utf8'), /^\/\.keys\/$/m);
  const result = spawnSync('git', ['check-ignore', '--no-index', '.keys/pp_spoke-program-keypair.json'], { encoding: 'utf8' });
  assert.equal(result.status, 0);
});

test('release build generates off-chain IDL and excludes all rehearsal/debug features', () => {
  const script = readFileSync('solana/scripts/deploy-build.sh', 'utf8');
  assert.match(script, /anchor build -- --features no-idl,no-log-ix-name\n/);
  assert.match(script, /idl\.events\?\.length/);
  assert.doesNotMatch(script, /anchor idl (init|upgrade)|rehearsal-v1-swap|anchor-debug/);
});

test('budget only permits read-only mainnet methods and models buffer rent reuse', () => {
  const script = readFileSync('solana/scripts/deploy-mainnet-budget.mjs', 'utf8');
  assert.doesNotMatch(script, /sendTransaction|sendRawTransaction|requestAirdrop/);
  assert.match(script, /bufferFundingReusedAtDeploy: true/);
  assert.match(script, /TODO\(decision\)/);
});

test('all release shell commands parse without executing a transaction', () => {
  for (const path of ['script/solana-release-rehearsal.sh', 'script/solana-evm-deploy.sh',
    'script/solana-evm-rehearsal-all.sh', 'solana/scripts/deploy-build.sh']) {
    const result = spawnSync('bash', ['-n', path], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
  }
});

test('EVM fee collector locates Foundry dry-run directory artifacts', () => {
  const source = readFileSync('script/solana-evm-budget.mjs', 'utf8');
  assert.match(source, /path\.includes\('\/dry-run\/'\)/);
  assert.match(source, /gasEstimateL1Component/);
  assert.doesNotMatch(source, /getL1Fee/);
});
