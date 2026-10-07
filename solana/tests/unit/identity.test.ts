import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { ADDRESSES } from '../helpers/addresses.ts';

test('persistent identity matches Rust, Anchor and the deployment manifest', () => {
  for (const path of ['../../programs/pp_spoke/src/lib.rs', '../../Anchor.toml', '../../../script/solana-v6-addresses.json']) {
    assert.ok(readFileSync(new URL(path, import.meta.url), 'utf8').includes(ADDRESSES.spoke));
  }
});

test('independent ABI generator matches current cross-VM golden values', () => {
  const result = spawnSync(process.execPath, [new URL('../../scripts/identity-vectors.ts', import.meta.url).pathname], { encoding: 'utf8' });
  assert.equal(result.status, 0);
  const vectors = JSON.parse(result.stdout);
  const rust = readFileSync(new URL('../../programs/pp_spoke/src/instructions/core/binding.rs', import.meta.url), 'utf8');
  const evm = readFileSync(new URL('../../../test/unit/solana/PolicyV6.t.sol', import.meta.url), 'utf8');
  for (const field of ['withoutSwap', 'withSwap', 'withoutSwapPolicy', 'withSwapPolicy', 'fund', 'vault']) {
    assert.ok(rust.includes(vectors[field].slice(2)), field);
    assert.ok(evm.includes(vectors[field].slice(2)), field);
  }
});

test('creation wrapper cannot select mainnet broadcast or arbitrary ports', () => {
  const wrapper = readFileSync(new URL('../../../script/solana-three-chain-creation.sh', import.meta.url), 'utf8');
  assert.ok(!wrapper.includes('--broadcast'));
  assert.ok(wrapper.includes('PP_LOCALNET_RPC_PORT=8998'));
  assert.ok(wrapper.includes('PP_LOCALNET_DYNAMIC_PORTS=19901-19960'));
  const builder = readFileSync(new URL('../../scripts/three-chain-creation.ts', import.meta.url), 'utf8');
  assert.ok(builder.includes('requireLoopback(connection.rpcEndpoint)'));
  assert.ok(builder.includes('TypedDataEncoder.hash'));
  assert.ok(builder.includes('hub-created'));
  assert.ok(builder.includes('stockSwapsAvailable: false'));
});
