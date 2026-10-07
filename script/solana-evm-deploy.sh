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
if [[ "$MODE" == --broadcast ]]; then
  EXPECTED_CHAIN=42161
  if [[ "$CHAIN" == robinhood ]]; then EXPECTED_CHAIN=4663; fi
  ACTUAL_CHAIN="$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" || { printf 'Read-only chain verification failed\n' >&2; exit 1; }
  if [[ "$ACTUAL_CHAIN" != "$EXPECTED_CHAIN" ]]; then printf 'RPC chain does not match approved destination\n' >&2; exit 1; fi
  if [[ "$(git rev-parse HEAD)" != "${PP_EVM_APPROVED_COMMIT:?Exact approved source commit required}" || -n "$(git status --porcelain --untracked-files=no)" ]]; then
    printf 'Broadcast requires the exact clean approved source checkout\n' >&2; exit 1
  fi
fi
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
status=0
forge "${ARGS[@]}" >"$STATE/run.log" 2>&1 || status=$?
node --input-type=module - "$STATE/run.log" <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';
const path = process.argv[2];
let text = readFileSync(path, 'utf8');
for (const [name, value] of Object.entries(process.env)) {
  if (/RPC|PRIVATE_KEY|SECRET|API_KEY/.test(name) && value?.length >= 4) text = text.replaceAll(value, '<suppressed>');
}
text = text.replace(/https?:\/\/[^\s"')]+/g, '<endpoint>');
writeFileSync(path, text);
NODE
printf '%s\n' "$status" >"$STATE/status"
if [[ "$status" == 0 ]]; then
  printf '%s %s %s PASS; evidence cache/sol-t9/evm-%s-%s\n' "$CHAIN" "$MODULE" "$MODE" "$CHAIN" "$MODULE"
else
  printf '%s %s FAIL; inspect sanitized evidence, no endpoint printed\n' "$CHAIN" "$MODULE" >&2
  exit 1
fi
