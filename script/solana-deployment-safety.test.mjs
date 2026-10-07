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

test('Fund creation fails closed until the manifest pins an approved factory', () => {
  const manifest = JSON.parse(readFileSync('script/solana-v6-addresses.json', 'utf8'));
  assert.equal(manifest.arbitrum.approvedFactory, null);
  assert.match(readFileSync('script/DeploySolanaFundV6.s.sol', 'utf8'), /parseJsonAddress\(manifest, "\.arbitrum.approvedFactory"\)/);
});
