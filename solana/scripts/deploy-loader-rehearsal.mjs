import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';

const require = createRequire(import.meta.url);
const { Keypair } = require('@solana/web3.js');
if (process.argv.length !== 3 || process.argv[2] !== '--broadcast-local') {
  throw new Error('Explicit --broadcast-local required; only throwaway local signing is supported');
}
const result = spawnSync(process.execPath, ['solana/scripts/deploy-local.mjs', '--broadcast'], {
  env: { ...process.env, PP_DEPLOY_LOCAL_RPC: 'http://127.0.0.1:8983', PP_DEPLOY_LOCAL_AIRDROP: '1',
    SOLANA_DEPLOYER_PRIVATE_KEY: JSON.stringify(Array.from(Keypair.generate().secretKey)) },
  stdio: 'inherit', timeout: 900000,
});
process.exitCode = result.status ?? 1;
