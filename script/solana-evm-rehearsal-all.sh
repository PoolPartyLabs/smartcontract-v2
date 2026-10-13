#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$ROOT"
if [[ "$#" != 0 ]]; then printf 'No flags supported: fork dry runs only\n' >&2; exit 2; fi
STATE="$ROOT/cache/sol-t9"
mkdir -p "$STATE"
export ARBITRUM_FORK_BLOCK="${ARBITRUM_FORK_BLOCK:?Explicit pinned Arbitrum block required}"
export ROBINHOOD_FORK_BLOCK="${ROBINHOOD_FORK_BLOCK:?Explicit pinned Robinhood block required}"
printf '{"arbitrum":%s,"robinhood":%s}\n' "$ARBITRUM_FORK_BLOCK" "$ROBINHOOD_FORK_BLOCK" >"$STATE/evm-pins.json"
failed=0
for chain in arbitrum robinhood; do
  for module in factory-v6 fund-v6 factory-legacy fund-legacy check-legacy; do
    if ! bash script/solana-evm-deploy.sh "$chain" "$module" --dry-run; then failed=1; fi
  done
done
node script/solana-evm-budget.mjs "$STATE"
exit "$failed"
