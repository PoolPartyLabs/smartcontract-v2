import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

test('DEC-189: deploy refuses a public endpoint before key handling', () => {
  const result = spawnSync(process.execPath, ['solana/scripts/deploy-local.mjs'], {
    env: { ...process.env, PP_DEPLOY_LOCAL_RPC: 'https://api.mainnet-beta.solana.com', SOLANA_DEPLOYER_PRIVATE_KEY: '' },
    encoding: 'utf8',
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /restricted to an explicit loopback/);
});

test('DEC-189: no implicit deployer or default CLI authority', () => {
  const result = spawnSync(process.execPath, ['solana/scripts/deploy-local.mjs'], {
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
  const result = spawnSync(process.execPath, ['solana/scripts/deploy-local.mjs'], {
    env: { ...process.env, PP_DEPLOY_LOCAL_RPC: 'http://127.0.0.1:8995', SOLANA_DEPLOYER_PRIVATE_KEY: marker }, encoding: 'utf8',
  });
  assert.notEqual(result.status, 0);
  assert.doesNotMatch(result.stdout + result.stderr, new RegExp(marker));
  assert.match(result.stderr, /Invalid deployer parameter/);
});
