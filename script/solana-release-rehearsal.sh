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
if [[ "$#" != 1 || ! "$1" =~ ^(core|production|legacy)$ ]]; then
  printf 'Usage: solana-release-rehearsal.sh core|production|legacy\n' >&2; exit 2
fi
started=0
cleanup() { if [[ "$started" == 1 ]]; then bash scripts/localnet.sh stop; fi; }
trap cleanup EXIT
if [[ ! -f .localnet/manifest.json ]]; then bash scripts/localnet.sh prepare; fi
case "$1" in
  core)
    node tests/core/prepare-fixtures.ts
    bash scripts/localnet.sh start
    started=1
    node --import ./scripts/deploy-compute-budget.mjs scripts/run-localnet-tests.ts
    ;;
  production)
    node tests/swap/production.prepare.ts
    bash tests/swap/production.start.sh
    started=1
    node --import ./scripts/deploy-compute-budget.mjs --test tests/swap/production.localnet.test.ts
    ;;
  legacy)
    anchor build -- --features no-idl,no-log-ix-name,rehearsal-v1-swap
    node tests/rehearsal/prepare.ts
    bash scripts/localnet.sh start
    started=1
    node --import ./scripts/deploy-compute-budget.mjs --test tests/rehearsal/lifecycle.test.ts
    ;;
esac
printf 'Local cloned leg only; no correlated three-chain or mainnet acceptance claimed.\n'
