import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../solana/package.json', import.meta.url));
const { Keypair } = require('@solana/web3.js');

test('DEC-189: deploy refuses a public endpoint before key handling', () => {
  const result = spawnSync(process.execPath, ['solana/scripts/deploy-local.mjs', '--broadcast'], {
    env: { ...process.env, PP_DEPLOY_LOCAL_RPC: 'https://api.mainnet-beta.solana.com', SOLANA_DEPLOYER_PRIVATE_KEY: '' },
    encoding: 'utf8',
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /restricted to an explicit loopback/);
});

test('DEC-189: no implicit deployer or default CLI authority', () => {
  const result = spawnSync(process.execPath, ['solana/scripts/deploy-local.mjs', '--broadcast'], {
    env: { ...process.env, PP_DEPLOY_LOCAL_RPC: 'http://127.0.0.1:8995', SOLANA_DEPLOYER_PRIVATE_KEY: '' }, encoding: 'utf8',
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /SOLANA_DEPLOYER_PRIVATE_KEY is required/);
});

test('DEC-188: EVM orchestration contains no broadcast or private-key argument', () => {
  for (const file of ['script/solana-v6-dry-run.sh', 'script/solana-three-chain-rehearsal.sh']) {
    assert.doesNotMatch(readFileSync(file, 'utf8'), /--broadcast|--private-key|\.env/);
  }
});

test('invalid key errors never include the supplied secret', () => {
  const marker = 'INVALID_SECRET_MUST_NOT_BE_PRINTED';
  const result = spawnSync(process.execPath, ['solana/scripts/deploy-local.mjs', '--broadcast'], {
    env: { ...process.env, PP_DEPLOY_LOCAL_RPC: 'http://127.0.0.1:8995', SOLANA_DEPLOYER_PRIVATE_KEY: marker }, encoding: 'utf8',
  });
  assert.notEqual(result.status, 0);
  assert.doesNotMatch(result.stdout + result.stderr, new RegExp(marker));
  assert.match(result.stderr, /Invalid deployer parameter/);
});

test('valid local key cannot deploy without explicit broadcast', () => {
  const secret = JSON.stringify(Array.from(Keypair.generate().secretKey));
  const result = spawnSync(process.execPath, ['solana/scripts/deploy-local.mjs'], {
    env: { ...process.env, SOLANA_DEPLOYER_PRIVATE_KEY: secret }, encoding: 'utf8',
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /explicit --broadcast/);
  assert.ok(!(result.stdout + result.stderr).includes(secret));
});

test('malformed endpoint and embedded credentials are never disclosed', () => {
  for (const endpoint of ['SECRET_RPC_NOT_A_URL', 'http://user:SECRET_RPC@127.0.0.1:8970/']) {
    const result = spawnSync(process.execPath, ['solana/scripts/deploy-local.mjs', '--broadcast'], {
      env: { ...process.env, PP_DEPLOY_LOCAL_RPC: endpoint }, encoding: 'utf8',
    });
    assert.notEqual(result.status, 0);
    assert.doesNotMatch(result.stdout + result.stderr, /SECRET_RPC/);
  }
});

test('out-of-range JSON key bytes cannot silently coerce to a valid key', () => {
  const values = Array.from(Keypair.generate().secretKey);
  values[0] += 256;
  const result = spawnSync(process.execPath, ['solana/scripts/deploy-local.mjs', '--broadcast'], {
    env: { ...process.env, SOLANA_DEPLOYER_PRIVATE_KEY: JSON.stringify(values) }, encoding: 'utf8',
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Invalid deployer parameter/);
});

test('C1: the deterministic factory is pinned in the reviewed manifest; creation and S4 fail closed otherwise', () => {
  const manifest = JSON.parse(readFileSync('script/solana-v6-addresses.json', 'utf8'));
  // Pinned before S1 so S4 never dirties the approved checkout (deterministic for the recorded deployer).
  assert.equal(manifest.arbitrum.approvedFactory, '0xe964f36Eb23E95e20049D97122f375FbFe6B40dE');
  assert.equal(manifest.robinhood.approvedFactory, manifest.arbitrum.approvedFactory);
  assert.equal(manifest.approvedFactoryDeployer, '0x26cD63ca3fe96e1D963f0160cb7542CEd13A53DE');
  const script = readFileSync('script/DeploySolanaFundV6.s.sol', 'utf8');
  assert.match(script, /parseJsonAddress\(manifest, "\.arbitrum.approvedFactory"\)/);
  // CR-35: a zero (unknown) pin still refuses Fund creation.
  assert.match(script, /if \(approvedFactory == address\(0\)\) revert FactoryNotApproved\(\);/);
  const factory = readFileSync('script/DeploySolanaV6.s.sol', 'utf8');
  assert.match(factory, /vm\.isContext\(VmSafe\.ForgeContext\.ScriptBroadcast\) && address\(result\.factory\) != pinned/);
  // The pin is reproducible only with the recursive checkout's full remapping set (CBOR metadata -> CREATE2/CREATE3).
  assert.match(readFileSync('foundry.toml', 'utf8'), /^auto_detect_remappings = false$/m);
  assert.equal(readFileSync('remappings.txt', 'utf8').trim().split('\n').length, 23);
});

test('C2: the deploy-day plan builder reads the live pinned factory, never deploys or broadcasts, and shares the rehearsed shape', () => {
  const builder = readFileSync('script/BuildSolanaFundV6Plan.s.sol', 'utf8');
  assert.doesNotMatch(builder, /startBroadcast|vm\.broadcast|_deployV6\(/);
  assert.match(builder, /parseJsonAddress\(vm\.readFile\("script\/solana-v6-addresses\.json"\), "\.arbitrum\.approvedFactory"\)/);
  assert.match(builder, /if \(address\(factory\)\.code\.length == 0\) revert FactoryNotLive/);
  assert.match(builder, /factory\.wiring\(\)\.coreVaultCreationCodeHash/);
  assert.match(builder, /vm\.envUint\("DEPLOYER_PRIVATE_KEY"\)/);
  assert.match(readFileSync('test/fork/deployment/SolanaThreeChainCreation.fork.t.sol', 'utf8'), /is Test, SolanaFundV6Plan/);
  const gate = readFileSync('solana/scripts/three-chain-creation.ts', 'utf8');
  assert.match(gate, /Plan factory is not the manifest-pinned approvedFactory/);
});
