#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$ROOT"
if [[ "$#" != 3 || ! "$1" =~ ^(arbitrum|robinhood)$ || ! "$2" =~ ^(factory-v6|fund-v6|factory-legacy|fund-legacy|check-legacy)$ || ! "$3" =~ ^(--dry-run|--broadcast)$ ]]; then
  printf 'Usage: solana-evm-deploy.sh arbitrum|robinhood factory-v6|fund-v6|factory-legacy|fund-legacy|check-legacy --dry-run|--broadcast\n' >&2; exit 2
fi
CHAIN="$1"; MODULE="$2"; MODE="$3"
if [[ "$MODE" == --broadcast && "${PP_EVM_FOUNDER_APPROVED:-}" != YES ]]; then
  printf 'Founder approval parameter required; no transaction submitted\n' >&2; exit 1
fi
if [[ "$CHAIN" == arbitrum ]]; then
  RPC="${ARBITRUM_RPC_URL:?Explicit RPC environment required}"; PIN="${ARBITRUM_FORK_BLOCK:?Explicit fork pin required}"
else
  RPC="${ROBINHOOD_RPC_URL:?Explicit RPC environment required}"; PIN="${ROBINHOOD_FORK_BLOCK:?Explicit fork pin required}"
fi
[[ "$PIN" =~ ^[1-9][0-9]*$ ]] || { printf 'Positive numeric fork pin required\n' >&2; exit 1; }
case "$MODULE" in
  factory-v6) SCRIPT=DeploySolanaV6 ;;
  fund-v6) SCRIPT=DeploySolanaFundV6 ;;
  factory-legacy) SCRIPT=DeployFactory ;;
  fund-legacy) SCRIPT=CreateFund ;;
  check-legacy) SCRIPT=CheckAlphaDeployment ;;
esac
STATE="$ROOT/cache/sol-t9/evm-$CHAIN-$MODULE"
mkdir -p "$STATE"
export FOUNDRY_BROADCAST="$STATE/broadcast"
ARGS=(script "script/$SCRIPT.s.sol" --fork-url "$RPC" --fork-block-number "$PIN" --sender "${EVM_DEPLOYER_ADDRESS:?Explicit EVM signer address required}" --compute-units-per-second 30 --fork-retry-backoff 3000)
if [[ "$MODE" == --broadcast ]]; then
  if [[ "$MODULE" == check-legacy ]]; then printf 'Read-only check cannot broadcast\n' >&2; exit 1; fi
  if [[ "$MODULE" == factory-legacy || "$MODULE" == fund-legacy ]]; then printf 'Legacy deployment is dry-run only in this package\n' >&2; exit 1; fi
  ARGS+=(--broadcast --private-key "${PRIVATE_KEY:?EVM deployer key must be supplied through environment}")
fi
if forge "${ARGS[@]}" >"$STATE/run.log" 2>&1; then
  printf '%s %s %s PASS; evidence cache/sol-t9/evm-%s-%s\n' "$CHAIN" "$MODULE" "$MODE" "$CHAIN" "$MODULE"
else
  printf '%s %s FAIL; inspect sanitized evidence, no endpoint printed\n' "$CHAIN" "$MODULE" >&2
  exit 1
fi
