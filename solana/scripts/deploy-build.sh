#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$ROOT"
if [[ "$#" != 0 ]]; then printf 'Usage: deploy-build.sh (production only)\n' >&2; exit 2; fi
anchor build -- --features no-idl,no-log-ix-name
node --input-type=module <<'NODE'
import { readFileSync, writeFileSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
const binary = 'target/deploy/pp_spoke.so';
const idlPath = 'target/idl/pp_spoke.json';
const idl = JSON.parse(readFileSync(idlPath));
if (!idl.instructions?.length || !idl.events?.length) throw new Error('Off-chain IDL instructions/events missing');
const hash = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const manifest = { schema: 1, builtAt: new Date().toISOString(), programId: idl.address,
  binaryBytes: statSync(binary).size, binarySha256: hash(binary), idlSha256: hash(idlPath),
  features: ['no-idl', 'no-log-ix-name'], optLevel: 'z', overflowChecks: true,
  onChainIdl: false, indexer: 'Anchor event data, not instruction-name logs',
  decisions: ['DEC-188', 'DEC-189', 'DEC-192', 'DEC-195'], approval: 'NOT_APPROVED' };
writeFileSync('target/deploy/pp_spoke.release.json', JSON.stringify(manifest, null, 2) + '\n');
console.log(JSON.stringify(manifest, null, 2));
NODE
