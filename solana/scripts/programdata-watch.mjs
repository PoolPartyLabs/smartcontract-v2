// Read-only ProgramData watcher (CR-22, risk-review R09/RR11). Compares the deployed program with the
// reviewed release: program present and executable, ProgramData upgrade authority equal to the
// approved expected authority, deploy slot unchanged since the recorded baseline, and the ELF bytes
// equal to release.json binarySha256 (any capacity beyond the ELF must be zero).
//
//   node solana/scripts/programdata-watch.mjs [--cluster mainnet|localnet] [--release <release.json>]
//        [--authority <pubkey|none>] [--state <file>] [--commitment finalized|confirmed]
//
// Exit 0 = OK, 2 = ALERT (one JSON line on stdout either way), 1 = cannot check. Cron it on the dev host
// (e.g. every 5 minutes) and page on exit 2. Expected authority defaults to the approval manifest's
// expectedAuthority, then its authority. Endpoint: SOLANA_MAINNET_RPC (HTTPS, key-less or header-auth)
// or PP_LOCALNET_RPC (loopback). Never sends a transaction.
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { checkedEndpoint, assertGenesis, sanitize } from './ops-common.mjs';
import { classifyProgramAccount, parseProgramData, PROGRAMDATA_HEADER_BYTES, sha256 } from './loader-v3.mjs';

const require = createRequire(import.meta.url);
const { Connection, PublicKey } = require('@solana/web3.js');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function expectedAuthority(flag) {
  if (flag) return flag === 'none' ? null : new PublicKey(flag).toBase58();
  const manifest = JSON.parse(readFileSync(resolve(process.env.PP_DEPLOY_APPROVAL_FILE ?? resolve(root, '../script/solana-mainnet-approval.json'))));
  const value = manifest.expectedAuthority ?? manifest.authority;
  return value === 'none' ? null : new PublicKey(value).toBase58();
}

async function main() {
  const { values } = parseArgs({ args: process.argv.slice(2), strict: true, options: {
    cluster: { type: 'string', default: 'mainnet' }, release: { type: 'string' }, authority: { type: 'string' }, state: { type: 'string' },
    commitment: { type: 'string', default: 'finalized' } } });
  const cluster = values.cluster;
  const commitment = values.commitment;
  if (!['finalized', 'confirmed'].includes(commitment)) throw new Error('Commitment must be finalized or confirmed');
  const release = JSON.parse(readFileSync(resolve(values.release ?? resolve(root, 'target/deploy/pp_spoke.release.json'))));
  if (!/^[0-9a-f]{64}$/.test(release.binarySha256 ?? '') || !Number.isSafeInteger(release.binaryBytes)) throw new Error('release.json must carry binarySha256 and binaryBytes');
  const programId = new PublicKey(release.programId).toBase58();
  const authority = expectedAuthority(values.authority);
  const statePath = resolve(values.state ?? resolve(root, `../cache/programdata-watch/${cluster}-${programId}.json`));
  const connection = new Connection(checkedEndpoint(cluster, cluster === 'mainnet' ? process.env.SOLANA_MAINNET_RPC : process.env.PP_LOCALNET_RPC), commitment);
  await assertGenesis(connection, cluster);
  const findings = [];
  const report = { checkedAt: new Date().toISOString(), cluster, programId, expectedAuthority: authority, releaseSha256: release.binarySha256 };
  const program = classifyProgramAccount(await connection.getAccountInfo(new PublicKey(programId), commitment));
  report.programState = program.state;
  if (program.state !== 'deployed') {
    findings.push(`program is ${program.state}: closed, never deployed or replaced (never 'program close' while any Fund exists)`);
  } else {
    report.programData = program.programData;
    const header = parseProgramData(await connection.getAccountInfo(new PublicKey(program.programData),
      { commitment, dataSlice: { offset: 0, length: PROGRAMDATA_HEADER_BYTES } }));
    if (!header) {
      findings.push('ProgramData account missing or not loader-v3 ProgramData');
    } else {
      Object.assign(report, { slot: header.slot, authority: header.authority });
      if (header.authority !== authority) findings.push(`upgrade authority ${header.authority ?? 'none'} differs from expected ${authority ?? 'none'}`);
      const previous = existsSync(statePath) ? JSON.parse(readFileSync(statePath, 'utf8')) : null;
      if (previous && previous.slot !== header.slot) findings.push(`program upgraded: deploy slot ${previous.slot} -> ${header.slot}`);
      if (!previous || previous.slot !== header.slot || previous.sha256 !== release.binarySha256) {
        const full = parseProgramData(await connection.getAccountInfo(new PublicKey(program.programData), commitment));
        report.capacity = full.capacity;
        report.sha256 = sha256(full.data.subarray(0, release.binaryBytes));
        if (full.capacity < release.binaryBytes || report.sha256 !== release.binarySha256 || full.data.subarray(release.binaryBytes).some(byte => byte !== 0)) {
          findings.push(`on-chain ELF ${report.sha256} differs from release ${release.binarySha256}`);
        }
      } else {
        report.sha256 = previous.sha256;
      }
      if (!findings.some(finding => finding.startsWith('on-chain ELF'))) {
        mkdirSync(dirname(statePath), { recursive: true });
        writeFileSync(statePath, JSON.stringify({ slot: header.slot, sha256: report.sha256, authority: header.authority, recordedAt: report.checkedAt }));
      }
    }
  }
  report.status = findings.length ? 'ALERT' : 'OK';
  report.findings = findings;
  console.log(JSON.stringify(report));
  if (findings.length) process.exitCode = 2;
}

main().catch(error => {
  console.error(`programdata-watch: ${sanitize(error?.message ?? 'unknown failure')}`);
  process.exitCode = 1;
});
