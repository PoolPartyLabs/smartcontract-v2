// Shared guards for the Solana operations scripts (deploy, recovery, watcher, Manager signer).
// Nothing here sends a transaction. Every error message is safe to print: endpoints, key bytes and
// secret-bearing environment values are never interpolated.
import { createRequire } from 'node:module';
import { readFileSync, statSync } from 'node:fs';

const require = createRequire(import.meta.url);
const { Keypair } = require('@solana/web3.js');
const bs58 = require('bs58');

export const MAINNET_GENESIS = '5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d';
export const R8_AUTHORITY = '6VTveiPVZVM7H9BWEsUsu4ivsrPjKw9ePrLQqHaFgJaA';
const LOOPBACK_HOSTS = ['127.0.0.1', 'localhost', '[::1]'];

// cluster 'mainnet': uncredentialed HTTPS only. cluster 'localnet': uncredentialed loopback HTTP only.
export function checkedEndpoint(cluster, endpoint) {
  let url;
  try { url = new URL(endpoint); } catch { throw new Error('Explicit RPC endpoint required; value suppressed'); }
  if (url.username || url.password) throw new Error('RPC endpoint must not embed credentials; value suppressed');
  if (cluster === 'mainnet') {
    if (url.protocol !== 'https:') throw new Error('HTTPS mainnet endpoint required; value suppressed');
  } else if (cluster === 'localnet') {
    if (url.protocol !== 'http:' || !LOOPBACK_HOSTS.includes(url.hostname) || url.pathname !== '/' || url.search || url.hash) {
      throw new Error('Localnet mode is restricted to an uncredentialed loopback HTTP validator');
    }
  } else {
    throw new Error('Cluster must be mainnet or localnet');
  }
  return endpoint;
}

// Mainnet must report the mainnet genesis; localnet must NOT (a loopback proxy to mainnet is refused).
export async function assertGenesis(connection, cluster) {
  const genesis = await connection.getGenesisHash();
  if (cluster === 'mainnet' && genesis !== MAINNET_GENESIS) throw new Error('Endpoint is not Solana mainnet');
  if (cluster === 'localnet' && genesis === MAINNET_GENESIS) throw new Error('Loopback endpoint reports the mainnet genesis; refusing');
  return genesis;
}

export function keypairFromParameter(value, label = 'key') {
  try {
    const trimmed = value?.trim() ?? '';
    const values = trimmed.startsWith('[') ? JSON.parse(trimmed) : Array.from((bs58.default ?? bs58).decode(trimmed));
    if (values.length !== 64 || !values.every(byte => Number.isInteger(byte) && byte >= 0 && byte <= 255)) throw new Error();
    return Keypair.fromSecretKey(Uint8Array.from(values));
  } catch {
    throw new Error(`Valid ${label} parameter required; value suppressed`);
  }
}

export function requireOwnerOnly(path, label = 'Signer file') {
  let stat;
  try { stat = statSync(path); } catch { throw new Error(`${label} is missing`); }
  if (!stat.isFile() || (stat.mode & 0o077) !== 0) throw new Error(`${label} requires owner-only permissions (0600)`);
}

export function keypairFromFile(path, label = 'Signer file') {
  requireOwnerOnly(path, label);
  return keypairFromParameter(readFileSync(path, 'utf8'), label);
}

const SECRET_NAME = /PRIVATE_KEY|SECRET|RPC|API_KEY|PASSWORD|TOKEN|WEBHOOK/;

// Removes secret-bearing environment values (exact match), URLs and JSON byte arrays. Base58 64-byte
// strings are NOT pattern-redacted: signatures have the same shape and operators need them.
export function sanitize(text) {
  let output = String(text ?? '');
  for (const [name, value] of Object.entries(process.env)) {
    if (SECRET_NAME.test(name) && value && value.length > 4) output = output.replaceAll(value, '<suppressed>');
  }
  return output
    .replace(/[a-z][a-z0-9+.-]*:\/\/[^\s"'<>)]+/gi, '<endpoint>')
    .replace(/\[\s*\d{1,3}(\s*,\s*\d{1,3}){31,}\s*\]/g, '<bytes>');
}

// Child processes never inherit secret-bearing variables.
export function scrubbedEnv(extra = {}) {
  const env = { ...process.env };
  for (const name of Object.keys(env)) if (SECRET_NAME.test(name)) delete env[name];
  return { ...env, ...extra };
}

// Non-secret step diagnostics on stderr: step name, status and a sanitized detail.
export function stepLogger(tool) {
  return (step, status, detail = '') => {
    const suffix = detail ? ` detail=${JSON.stringify(sanitize(detail))}` : '';
    console.error(`[${tool}] ${new Date().toISOString()} step=${step} status=${status}${suffix}`);
  };
}

export function cliFailureDetail(result) {
  const lines = `${result.stdout ?? ''}\n${result.stderr ?? ''}`.split('\n')
    .filter(line => /error|fail|insufficient|already|in use|blockhash|429|too many|timed out|refused|not found|invalid/i.test(line))
    .slice(-4).join(' | ');
  return sanitize(`exit=${result.status ?? result.signal ?? 'unknown'} ${lines}`.trim());
}
