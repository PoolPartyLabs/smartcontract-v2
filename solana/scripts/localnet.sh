#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
STATE="$ROOT/.localnet"
# Per-worktree ports so parallel tracks can run validators side by side (defaults keep the single-run behavior).
RPC_PORT="${PP_LOCALNET_RPC_PORT:-8899}"
FAUCET_PORT="${PP_LOCALNET_FAUCET_PORT:-9900}"
GOSSIP_PORT="${PP_LOCALNET_GOSSIP_PORT:-1024}"
DYNAMIC_PORTS="${PP_LOCALNET_DYNAMIC_PORTS:-1025-1065}"
case "${1:-}" in
  prepare)
    node "$ROOT/scripts/prepare-localnet.ts"
    ;;
  start)
    if [[ ! -f "$STATE/manifest.json" ]]; then
      printf '%s\n' 'Run localnet.sh prepare first.' >&2
      exit 1
    fi
    if [[ ! -f "$ROOT/target/deploy/pp_spoke.so" ]]; then
      printf '%s\n' 'Run anchor build inside solana/ first.' >&2
      exit 1
    fi
    if [[ -f "$STATE/validator.pid" ]] && kill -0 "$(cat "$STATE/validator.pid")" 2>/dev/null; then
      printf '%s\n' 'This worktree validator is already running.' >&2
      exit 1
    fi
    if lsof -iTCP:"$RPC_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      printf '%s\n' "Port $RPC_PORT is occupied; stop its owner, never kill another worktree." >&2
      exit 1
    fi
    SLOT="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1])).warpSlot))' "$STATE/manifest.json")"
    solana-test-validator --reset --quiet --bind-address 127.0.0.1 \
      --rpc-port "$RPC_PORT" --faucet-port "$FAUCET_PORT" \
      --gossip-port "$GOSSIP_PORT" --dynamic-port-range "$DYNAMIC_PORTS" --ledger "$STATE/ledger" --warp-slot "$SLOT" \
      --account-dir "$STATE/accounts" --account-dir "$STATE/overrides" \
      --bpf-program Fg6PaFpoGXkYsidMpWxTWqkZ7FEfcYkgMQHGfVNLusVw "$ROOT/target/deploy/pp_spoke.so" \
      >"$STATE/validator.log" 2>&1 &
    printf '%s\n' "$!" > "$STATE/validator.pid"
    for attempt in $(seq 1 120); do
      if ! kill -0 "$(cat "$STATE/validator.pid")" 2>/dev/null; then
        printf '%s\n' 'Validator exited; inspect the local-only validator.log.' >&2
        exit 1
      fi
      if curl --silent --fail -H 'content-type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' \
        http://127.0.0.1:"$RPC_PORT" | grep -q '"ok"'; then
        FINALIZED="$(curl --silent --fail -H 'content-type: application/json' \
          --data '{"jsonrpc":"2.0","id":1,"method":"getSlot","params":[{"commitment":"finalized"}]}' \
          http://127.0.0.1:"$RPC_PORT" | node -e 'let input=""; process.stdin.on("data",chunk=>input+=chunk); process.stdin.on("end",()=>process.stdout.write(String(JSON.parse(input).result ?? 0)))')"
        if [[ "$FINALIZED" -gt "$SLOT" ]]; then
          printf '%s\n' "Cloned local validator ready with a post-warp finalized root on loopback port $RPC_PORT."
          exit 0
        fi
      fi
      sleep 1
    done
    printf '%s\n' 'Validator startup timed out; use localnet.sh stop.' >&2
    exit 1
    ;;
  stop)
    if [[ -f "$STATE/validator.pid" ]]; then
      PID="$(cat "$STATE/validator.pid")"
      if kill -0 "$PID" 2>/dev/null; then
        COMMAND="$(ps -p "$PID" -o command=)"
        if [[ "$COMMAND" != *solana-test-validator* || "$COMMAND" != *"$STATE/ledger"* ]]; then
          printf '%s\n' 'PID does not belong to this worktree validator; refusing to kill.' >&2
          exit 1
        fi
        kill "$PID"
      fi
      rm -f "$STATE/validator.pid"
    fi
    ;;
  *) printf '%s\n' 'Usage: localnet.sh prepare|start|stop' >&2; exit 2 ;;
esac
