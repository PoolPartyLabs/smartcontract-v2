#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(dirname "$(realpath "$0")")")")"
STATE="$ROOT/.localnet"
RPC_PORT="${PP_LOCALNET_RPC_PORT:-8970}"
FAUCET_PORT="${PP_LOCALNET_FAUCET_PORT:-9970}"
GOSSIP_PORT="${PP_LOCALNET_GOSSIP_PORT:-17000}"
DYNAMIC_PORTS="${PP_LOCALNET_DYNAMIC_PORTS:-17001-17060}"
if lsof -iTCP:"$RPC_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  printf '%s\n' 'Requested RPC port occupied; stop its owner, never another worktree.' >&2
  exit 1
fi
SLOT="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1])).warpSlot))' "$STATE/manifest.json")"
solana-test-validator --reset --quiet --bind-address 127.0.0.1 \
  --rpc-port "$RPC_PORT" --faucet-port "$FAUCET_PORT" --gossip-port "$GOSSIP_PORT" --dynamic-port-range "$DYNAMIC_PORTS" \
  --slots-per-epoch 32 --ledger "$STATE/ledger" --warp-slot "$SLOT" \
  --account-dir "$STATE/accounts" --account-dir "$STATE/overrides" \
  --bpf-program Fg6PaFpoGXkYsidMpWxTWqkZ7FEfcYkgMQHGfVNLusVw "$ROOT/target/deploy/pp_spoke.so" \
  >"$STATE/validator.log" 2>&1 &
printf '%s\n' "$!" > "$STATE/validator.pid"
for attempt in $(seq 1 120); do
  FINALIZED="$( (curl --silent -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"getSlot","params":[{"commitment":"finalized"}]}' "http://127.0.0.1:$RPC_PORT" || true) | node -e 'let input="";process.stdin.on("data",chunk=>input+=chunk);process.stdin.on("end",()=>{try{process.stdout.write(String(JSON.parse(input).result??0))}catch{process.stdout.write("0")}})')"
  if [[ "$FINALIZED" -gt "$SLOT" ]]; then printf '%s\n' 'Production clone harness ready on loopback.'; exit 0; fi
  sleep 1
done
printf '%s\n' 'Validator startup timed out; use scripts/localnet.sh stop.' >&2
exit 1
