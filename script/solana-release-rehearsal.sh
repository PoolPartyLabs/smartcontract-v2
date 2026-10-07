#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$ROOT/solana"
STATE="$ROOT/cache/sol-t9"
mkdir -p "$STATE"
export PP_LOCALNET_RPC_PORT="${PP_LOCALNET_RPC_PORT:-8983}"
export PP_LOCALNET_FAUCET_PORT="${PP_LOCALNET_FAUCET_PORT:-9983}"
export PP_LOCALNET_GOSSIP_PORT="${PP_LOCALNET_GOSSIP_PORT:-18300}"
export PP_LOCALNET_DYNAMIC_PORTS="${PP_LOCALNET_DYNAMIC_PORTS:-18301-18360}"
export PP_REHEARSAL_CU_LIMIT=900000
export PP_REHEARSAL_METRICS="$STATE/compute-metrics.jsonl"
export NODE_OPTIONS="${NODE_OPTIONS:-} --import=$ROOT/solana/scripts/deploy-compute-budget.mjs"
if [[ "$#" != 1 || ! "$1" =~ ^(core|production|legacy)$ ]]; then
  printf 'Usage: solana-release-rehearsal.sh core|production|legacy\n' >&2; exit 2
fi
MODE="$1"
started=0
cleanup() {
  if [[ "$started" == 1 ]]; then
    node scripts/deploy-operation-budget.mjs >"$STATE/$MODE-operation-budget.json" || true
    bash scripts/localnet.sh stop
  fi
}
trap cleanup EXIT
if [[ ! -f .localnet/manifest.json ]]; then bash scripts/localnet.sh prepare; fi
case "$1" in
  core)
    node tests/core/prepare-fixtures.ts
    bash scripts/localnet.sh start
    started=1
    node scripts/deploy-idl-smoke.mjs
    node scripts/run-localnet-tests.ts
    ;;
  production)
    node tests/swap/production.prepare.ts
    bash tests/swap/production.start.sh
    started=1
    node --test tests/swap/production.localnet.test.ts
    ;;
  legacy)
    anchor build -- --features no-idl,no-log-ix-name,rehearsal-v1-swap
    node tests/rehearsal/prepare.ts
    bash scripts/localnet.sh start
    started=1
    node --test tests/rehearsal/lifecycle.test.ts
    ;;
esac
node scripts/deploy-operation-budget.mjs >"$STATE/$1-operation-budget.json"
printf 'Local cloned leg only; no correlated three-chain or mainnet acceptance claimed.\n'
