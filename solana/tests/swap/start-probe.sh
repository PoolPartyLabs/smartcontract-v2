#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(dirname "$(realpath "$0")")")")"
STATE="$ROOT/.localnet"
export PP_LOCALNET_RPC_PORT="${PP_LOCALNET_RPC_PORT-8950}"
export PP_LOCALNET_FAUCET_PORT="${PP_LOCALNET_FAUCET_PORT-9950}"
export PP_LOCALNET_GOSSIP_PORT="${PP_LOCALNET_GOSSIP_PORT-15000}"
export PP_LOCALNET_DYNAMIC_PORTS="${PP_LOCALNET_DYNAMIC_PORTS-15001-15060}"
if lsof -iTCP:"$PP_LOCALNET_RPC_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  printf '%s\n' "Track port $PP_LOCALNET_RPC_PORT occupied; stop its owner, never kill another worktree." >&2
  exit 1
fi
SLOT="$(node -e 'const fs=require("fs"); process.stdout.write(String(Math.max(JSON.parse(fs.readFileSync(process.argv[1])).warpSlot,JSON.parse(fs.readFileSync(process.argv[2])).latestSlot)))' "$STATE/manifest.json" "$ROOT/tests/swap/fixtures/v2/clone-extension.json")"
PROBE="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1])).probe)' "$ROOT/tests/swap/fixtures/wsol.json")"
mkdir -p "$STATE/swap-genesis"
find "$STATE/swap-genesis" -type f -name '*.json' -delete
cp "$STATE/accounts/"*.json "$STATE/swap-genesis/"
cp "$STATE/overrides/"*.json "$STATE/swap-genesis/"
solana-test-validator --reset --quiet --bind-address 127.0.0.1 \
  --rpc-port "$PP_LOCALNET_RPC_PORT" --faucet-port "$PP_LOCALNET_FAUCET_PORT" \
  --gossip-port "$PP_LOCALNET_GOSSIP_PORT" --dynamic-port-range "$PP_LOCALNET_DYNAMIC_PORTS" \
  --ledger "$STATE/ledger" --warp-slot "$SLOT" --account-dir "$STATE/swap-genesis" \
  --bpf-program "$PROBE" "$ROOT/tests/swap/probe/target/deploy/swap_guard_probe.so" \
  --bpf-program 7PptZ653uyn5eoAFKqs4DXR1ijxH6sf49f2YAGMLTfCx "$ROOT/target/deploy/pp_spoke.so" \
  >"$STATE/validator.log" 2>&1 &
printf '%s\n' "$!" > "$STATE/validator.pid"
for attempt in $(seq 1 120); do
  if ! kill -0 "$(cat "$STATE/validator.pid")" 2>/dev/null; then
    printf '%s\n' 'Probe validator exited; inspect local log.' >&2
    exit 1
  fi
  FINALIZED="$( (curl --silent -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"getSlot","params":[{"commitment":"finalized"}]}' "http://127.0.0.1:$PP_LOCALNET_RPC_PORT" || true) | node -e 'let input="";process.stdin.on("data",chunk=>input+=chunk);process.stdin.on("end",()=>{try{process.stdout.write(String(JSON.parse(input).result??0))}catch{process.stdout.write("0")}})')"
  if [[ "$FINALIZED" -gt "$SLOT" ]]; then printf '%s\n' "Local-only swap probe ready on port $PP_LOCALNET_RPC_PORT."; exit 0; fi
  sleep 1
done
printf '%s\n' 'Probe startup timeout; stop with scripts/localnet.sh stop.' >&2
exit 1
