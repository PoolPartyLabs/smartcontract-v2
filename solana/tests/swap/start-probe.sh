#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(dirname "$(realpath "$0")")")")"
STATE="$ROOT/.localnet"
export PP_LOCALNET_RPC_PORT=8950 PP_LOCALNET_FAUCET_PORT=9950 PP_LOCALNET_GOSSIP_PORT=15000 PP_LOCALNET_DYNAMIC_PORTS=15001-15060
if lsof -iTCP:8950 -sTCP:LISTEN >/dev/null 2>&1; then
  printf '%s\n' 'Track port occupied; stop its owner, never kill another worktree.' >&2
  exit 1
fi
node "$ROOT/tests/swap/prepare-probe.ts"
SLOT="$(node -e 'const fs=require("fs"); process.stdout.write(String(Math.max(JSON.parse(fs.readFileSync(process.argv[1])).warpSlot,JSON.parse(fs.readFileSync(process.argv[2])).latestSlot)))' "$STATE/manifest.json" "$ROOT/tests/swap/fixtures/clone-extension.json")"
PROBE="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1])).probe)' "$ROOT/tests/swap/fixtures/wsol.json")"
solana-test-validator --reset --quiet --bind-address 127.0.0.1 \
  --rpc-port 8950 --faucet-port 9950 --gossip-port 15000 --dynamic-port-range 15001-15060 \
  --ledger "$STATE/ledger" --warp-slot "$SLOT" --account-dir "$STATE/accounts" --account-dir "$STATE/overrides" \
  --bpf-program "$PROBE" "$ROOT/tests/swap/probe/target/deploy/swap_guard_probe.so" \
  --bpf-program Fg6PaFpoGXkYsidMpWxTWqkZ7FEfcYkgMQHGfVNLusVw "$ROOT/target/deploy/pp_spoke.so" \
  >"$STATE/validator.log" 2>&1 &
printf '%s\n' "$!" > "$STATE/validator.pid"
for attempt in $(seq 1 120); do
  if ! kill -0 "$(cat "$STATE/validator.pid")" 2>/dev/null; then
    printf '%s\n' 'Probe validator exited; inspect local log.' >&2
    exit 1
  fi
  FINALIZED="$( (curl --silent -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"getSlot","params":[{"commitment":"finalized"}]}' http://127.0.0.1:8950 || true) | node -e 'let input="";process.stdin.on("data",chunk=>input+=chunk);process.stdin.on("end",()=>{try{process.stdout.write(String(JSON.parse(input).result??0))}catch{process.stdout.write("0")}})')"
  if [[ "$FINALIZED" -gt "$SLOT" ]]; then printf '%s\n' 'Local-only swap probe ready on port 8950.'; exit 0; fi
  sleep 1
done
printf '%s\n' 'Probe startup timeout; stop with scripts/localnet.sh stop.' >&2
exit 1
