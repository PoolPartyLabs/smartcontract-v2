import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
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
