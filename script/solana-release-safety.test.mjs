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
  // CR-11: the dev-host keeper key lives beside it and is excluded the same way.
  assert.equal(spawnSync('git', ['check-ignore', '--no-index', '.keys/keeper.json'], { encoding: 'utf8' }).status, 0);
  assert.match(readFileSync('docs/DEPLOYMENT-SOLANA.md', 'utf8'), /## Key roles and the keeper split \(CR-11\)/);
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

test('CR-10: --preflight is read-only and not approval-gated; it still refuses a non-HTTPS endpoint', () => {
  const result = spawnSync(process.execPath, ['solana/scripts/deploy-mainnet.mjs', '--preflight'], {
    encoding: 'utf8', env: { ...process.env, SOLANA_MAINNET_RPC: 'http://127.0.0.1:1/', SOLANA_DEPLOYER_PRIVATE_KEY: 'SECRET_KEY' },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /HTTPS mainnet endpoint required/);
  assert.doesNotMatch(result.stderr, /Founder approval/);
  assert.doesNotMatch(result.stdout + result.stderr, /SECRET_KEY|127\.0\.0\.1/);
  const source = readFileSync('solana/scripts/deploy-mainnet.mjs', 'utf8');
  assert.match(source, /if \(mode === '--preflight'\) return runPreflight\(\);\n  const manifest = loadManifest\(\);\n  const \{ binary, binaryPath, sha256 \} = requireApproval\(manifest\);/);
  const loader = readFileSync('solana/scripts/loader-v3.mjs', 'utf8');
  const preflightBody = loader.slice(loader.indexOf('export async function preflight'), loader.indexOf('export function deployWithMaxDataLenInstruction'));
  assert.ok(preflightBody.length > 100);
  assert.doesNotMatch(preflightBody, /send|sign\(/i);
});

test('CR-10: the pre-funded recovery mode is approval-gated like the initial deploy', () => {
  const result = spawnSync(process.execPath, ['solana/scripts/deploy-mainnet.mjs', '--recover-prefunded'], {
    encoding: 'utf8', env: { ...process.env, SOLANA_MAINNET_RPC: 'SECRET_ENDPOINT', SOLANA_DEPLOYER_PRIVATE_KEY: 'SECRET_KEY' },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Founder approval/);
  assert.doesNotMatch(result.stdout + result.stderr, /SECRET_ENDPOINT|SECRET_KEY/);
});

test('CR-07: creation broadcast refuses an unapproved or unclean source before parsing any key', () => {
  const env = { ...process.env, DEPLOYER_PRIVATE_KEY: 'SECRET_KEY_EVM', SOLANA_DEPLOYER_PRIVATE_KEY: 'SECRET_KEY_SOL',
    SOLANA_MAINNET_RPC: 'SECRET_ENDPOINT', ARBITRUM_RPC_URL: 'SECRET_ENDPOINT' };
  const unapproved = spawnSync(process.execPath, ['solana/scripts/three-chain-creation.ts', 'broadcast'], { encoding: 'utf8', env });
  assert.notEqual(unapproved.status, 0);
  assert.match(unapproved.stderr, /Founder-approved Manager signing file/);
  assert.doesNotMatch(unapproved.stdout + unapproved.stderr, /SECRET_KEY|SECRET_ENDPOINT/);
  const directory = mkdtempSync(join(tmpdir(), 'pp-creation-gate-'));
  try {
    const approval = join(directory, 'approval.json');
    writeFileSync(approval, JSON.stringify({ ...JSON.parse(readFileSync('script/solana-manager-approval.json')), status: 'FOUNDER_APPROVED',
      approvedBy: 'test', approvedAt: new Date().toISOString(), sourceCommit: 'a'.repeat(40), managerSolanaKey: '6VTveiPVZVM7H9BWEsUsu4ivsrPjKw9ePrLQqHaFgJaA' }));
    const unclean = spawnSync(process.execPath, ['solana/scripts/three-chain-creation.ts', 'broadcast'], { encoding: 'utf8',
      env: { ...env, PP_MANAGER_APPROVAL_FILE: approval } });
    assert.notEqual(unclean.status, 0);
    assert.match(unclean.stderr, /Approval source does not match a clean checkout/);
  } finally { rmSync(directory, { recursive: true, force: true }); }
  const source = readFileSync('solana/scripts/three-chain-creation.ts', 'utf8');
  assert.match(source, /const gate = process\.argv\[2\] === "broadcast" \? await broadcastGate\(\) : null;\n  const \{ manager, solana \} = gate \? wallets\(gate\.approval\.managerSolanaKey\) : wallets\(\);/);
  assert.match(source, /the fork cache plan is never broadcast/);
  assert.match(source, /eth_getTransactionReceipt/);
});

test('CR-07: Manager CLI signer requires an explicit command and founder approval for mainnet', () => {
  const usage = spawnSync(process.execPath, ['solana/scripts/manager-sign.mjs'], { encoding: 'utf8' });
  assert.notEqual(usage.status, 0);
  assert.match(usage.stderr, /no implicit signing/);
  const mainnet = spawnSync(process.execPath, ['solana/scripts/manager-sign.mjs', 'send', '--expect-intent', '0'.repeat(64)], {
    encoding: 'utf8', env: { ...process.env, SOLANA_MANAGER_PRIVATE_KEY: 'SECRET_KEY', SOLANA_MAINNET_RPC: 'SECRET_ENDPOINT' } });
  assert.notEqual(mainnet.status, 0);
  assert.match(mainnet.stderr, /Founder-approved Manager signing file required/);
  assert.doesNotMatch(mainnet.stdout + mainnet.stderr, /SECRET_KEY|SECRET_ENDPOINT/);
  const template = JSON.parse(readFileSync('script/solana-manager-approval.json'));
  assert.equal(template.status, 'NOT_APPROVED');
  assert.equal(template.managerSolanaKey, null);
  assert.deepEqual(template.allowedPrograms, ['7PptZ653uyn5eoAFKqs4DXR1ijxH6sf49f2YAGMLTfCx', 'ComputeBudget111111111111111111111111111111']);
  const sender = readFileSync('solana/scripts/guarded-send.mjs', 'utf8');
  const guarded = sender.slice(sender.indexOf('export async function guardedSend'), sender.indexOf('export async function sendInstructions'));
  const journaled = guarded.indexOf("appendJournal(journalPath, { key, status: 'sent'");
  assert.ok(journaled > 0 && journaled < guarded.indexOf('sendRawTransaction'), 'signature is journaled before the first send');
  assert.doesNotMatch(sender, /onSignature|confirmTransaction\(/);
});

test('CR-22: deploy stays R8-pinned while --verify reads the expected authority from the approval manifest', () => {
  const source = readFileSync('solana/scripts/deploy-mainnet.mjs', 'utf8');
  assert.match(source, /const expected = manifest\.expectedAuthority \?\? manifest\.authority;/);
  assert.match(source, /if \(mode === '--verify'\) \{ await verify\(expectedAuthority\); return; \}/);
  assert.match(source, /    await verify\(authority\);\n  \} finally/);
  assert.equal(JSON.parse(readFileSync('script/solana-mainnet-approval.json')).expectedAuthority, null);
  const watcher = readFileSync('solana/scripts/programdata-watch.mjs', 'utf8');
  assert.doesNotMatch(watcher, /sendRawTransaction|sendTransaction|\.sign\(/);
  assert.match(watcher, /manifest\.expectedAuthority \?\? manifest\.authority/);
  const runbook = readFileSync('docs/DEPLOYMENT-SOLANA.md', 'utf8');
  assert.match(runbook, /Never run `solana program close` on the spoke\s+program while any Fund exists/);
  assert.match(runbook, /gpg --symmetric --cipher-algo AES256/);
});

test('CR-27: no raw key or endpoint on argv in the mainnet wrappers', () => {
  const evm = readFileSync('script/solana-evm-deploy.sh', 'utf8');
  assert.doesNotMatch(evm, /--private-key/);
  assert.doesNotMatch(evm, /--(fork-url|rpc-url) "\$RPC"/);
  assert.match(evm, /--fork-url "\$RPC_ALIAS"/);
  assert.match(evm, /--account "\$\{EVM_KEYSTORE_ACCOUNT:\?/);
  assert.match(readFileSync('foundry.toml', 'utf8'), /\[rpc_endpoints\]\narbitrum = "\$\{ARBITRUM_RPC_URL\}"\nrobinhood = "\$\{ROBINHOOD_RPC_URL\}"/);
  const solana = readFileSync('solana/scripts/deploy-mainnet.mjs', 'utf8');
  assert.doesNotMatch(solana, /'--url'/);
  assert.match(solana, /cli\('write-buffer', \['--config', configPath/);
  assert.match(solana, /cli\('deploy', \['--config', configPath/);
  // The plaintext temporary payer is removed on an interrupt too, not only in `finally`.
  assert.match(solana, /for \(const signal of \['SIGINT', 'SIGTERM', 'SIGHUP'\]\) \{\n    process\.once\(signal, \(\) => \{ rmSync\(directory/);
});

test('CR-27: broadcast resolves the RPC through the alias and fails closed without printing it or the key', () => {
  const result = spawnSync('bash', ['script/solana-evm-deploy.sh', 'arbitrum', 'factory-v6', '--broadcast'], { encoding: 'utf8',
    env: { ...process.env, PP_EVM_FOUNDER_APPROVED: 'YES', ARBITRUM_RPC_URL: 'https://SECRET_ENDPOINT.invalid', ARBITRUM_FORK_BLOCK: '1',
      PRIVATE_KEY: 'SECRET_KEY', EVM_DEPLOYER_ADDRESS: '0x0000000000000000000000000000000000000014' } });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Read-only chain verification failed/);
  assert.doesNotMatch(result.stdout + result.stderr, /SECRET_KEY|SECRET_ENDPOINT/);
});

test('CR-32: the runbook keeps S0-S12 checkpoints, the Fast-only fact, one budget source and one port registry', () => {
  const runbook = readFileSync('docs/DEPLOYMENT-SOLANA.md', 'utf8');
  const current = runbook.slice(0, runbook.indexOf('Historical evidence below'));
  for (let step = 0; step <= 12; step++) assert.match(current, new RegExp(`\\| \\*\\*S${step}\\*\\* `));
  assert.match(current, /\*\*Fast only:\*\* `CctpBridgeAdapter\.sol:18,114` and `wire\.rs:7,116`/);
  assert.match(readFileSync('src/adapters/CctpBridgeAdapter.sol', 'utf8'), /uint32 public constant FAST_FINALITY = 1000;/);
  assert.match(current, /Budget numbers come \*\*only\*\* from `deploy-mainnet-budget\.mjs`/);
  assert.match(current, /### Port registry — the single source of truth/);
  assert.match(current, /\| 8940 \/ 9940 \/ 14000 \/ 14001–14060 \| fix-ops lane/);
  const ops = readFileSync('script/solana-ops.localnet.test.mjs', 'utf8');
  assert.match(ops, /PP_LOCALNET_RPC_PORT \?\? '8940'/);
});

test('CR-10: preflight reports an unreachable endpoint as a NO-GO row without naming it', () => {
  const result = spawnSync(process.execPath, ['solana/scripts/deploy-mainnet.mjs', '--preflight'], {
    encoding: 'utf8', env: { ...process.env, SOLANA_MAINNET_RPC: 'https://secret-provider-host.invalid/SECRET_PATH_KEY' },
  });
  assert.equal(result.status, 2);
  const report = JSON.parse(result.stdout);
  assert.equal(report.ok, false);
  assert.equal(report.checks.find(check => check.name === 'genesis').ok, false);
  assert.match(result.stderr, /\[deploy-mainnet\] .* step=preflight status=nogo/);
  assert.doesNotMatch(result.stdout + result.stderr, /secret-provider-host|SECRET_PATH_KEY/);
});

test('C7: creation gas is a receipt fitness on loopback, and fund-v6 requests at most 105% of the estimate', () => {
  const evm = readFileSync('script/solana-evm-deploy.sh', 'utf8');
  assert.match(evm, /if \[\[ "\$MODULE" == fund-v6 \]\]; then ARGS\+=\(--gas-estimate-multiplier 105\); fi/);
  const fitness = readFileSync('script/solana-creation-gas-fitness.sh', 'utf8');
  assert.match(fitness, /^#![^\n]+\nset \+x\n/);
  assert.doesNotMatch(fitness, /--private-key|--fork-url "\$ARBITRUM_RPC_URL"/);
  assert.match(fitness, /--fork-url arbitrum .* --host 127\.0\.0\.1/);
  assert.match(fitness, /--auto-impersonate >\/dev\/null 2>&1 &/);
  assert.match(fitness, /GAS_USED \+ MARGIN > CAP/);
  assert.equal(spawnSync('bash', ['-n', 'script/solana-creation-gas-fitness.sh']).status, 0);
  const refused = spawnSync('bash', ['script/solana-creation-gas-fitness.sh'], { encoding: 'utf8',
    env: { ...process.env, ARBITRUM_RPC_URL: 'https://SECRET_ENDPOINT.invalid', ARBITRUM_FORK_BLOCK: '', DEPLOYER_PRIVATE_KEY: 'SECRET_KEY' } });
  assert.notEqual(refused.status, 0);
  assert.doesNotMatch(refused.stdout + refused.stderr, /SECRET_ENDPOINT|SECRET_KEY/);
});
