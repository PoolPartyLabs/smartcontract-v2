#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(dirname "$(realpath "$0")")")")"
STATE="$ROOT/.localnet"
export PP_LOCALNET_RPC_PORT="${PP_LOCALNET_RPC_PORT:-8997}"
export PP_LOCALNET_FAUCET_PORT="${PP_LOCALNET_FAUCET_PORT:-9997}"
export PP_LOCALNET_GOSSIP_PORT="${PP_LOCALNET_GOSSIP_PORT:-19800}"
export PP_LOCALNET_DYNAMIC_PORTS="${PP_LOCALNET_DYNAMIC_PORTS:-19801-19860}"
if lsof -iTCP:"$PP_LOCALNET_RPC_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  printf '%s\n' 'Scope port occupied; stop its owner, never another worktree.' >&2
  exit 1
fi
PROBE="$(node -e 'process.stdout.write(new (require(process.argv[1]).PublicKey)(new Uint8Array(32).fill(77)).toBase58())' "$ROOT/node_modules/@solana/web3.js")"
SLOT="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1])).warpSlot))' "$STATE/manifest.json")"
solana-test-validator --reset --quiet --bind-address 127.0.0.1 \
  --rpc-port "$PP_LOCALNET_RPC_PORT" --faucet-port "$PP_LOCALNET_FAUCET_PORT" \
  --gossip-port "$PP_LOCALNET_GOSSIP_PORT" --dynamic-port-range "$PP_LOCALNET_DYNAMIC_PORTS" \
  --ledger "$STATE/ledger" --warp-slot "$SLOT" \
  --account-dir "$STATE/accounts" --account-dir "$STATE/overrides" \
  --bpf-program "$PROBE" "$ROOT/tests/swap/probe/target/deploy/swap_guard_probe.so" \
  --bpf-program Fg6PaFpoGXkYsidMpWxTWqkZ7FEfcYkgMQHGfVNLusVw "$ROOT/target/deploy/pp_spoke.so" \
  >"$STATE/validator.log" 2>&1 &
printf '%s\n' "$!" > "$STATE/validator.pid"
for attempt in $(seq 1 120); do
  if ! kill -0 "$(cat "$STATE/validator.pid")" 2>/dev/null; then
    printf '%s\n' 'Scope validator exited; inspect local log.' >&2
    exit 1
  fi
  FINALIZED="$( (curl --silent -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"getSlot","params":[{"commitment":"finalized"}]}' "http://127.0.0.1:$PP_LOCALNET_RPC_PORT" || true) | node -e 'let input="";process.stdin.on("data",chunk=>input+=chunk);process.stdin.on("end",()=>{try{process.stdout.write(String(JSON.parse(input).result??0))}catch{process.stdout.write("0")}})')"
  if [[ "$FINALIZED" -gt "$SLOT" ]]; then printf '%s\n' 'Scope cloned-mainnet probe ready on loopback.'; exit 0; fi
  sleep 1
done
printf '%s\n' 'Scope startup timeout; use scripts/localnet.sh stop.' >&2
exit 1
