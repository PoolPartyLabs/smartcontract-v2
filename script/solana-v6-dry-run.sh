#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$ROOT"
STATE="$ROOT/cache/solana-deploy"
mkdir -p "$STATE"
export ARBITRUM_RPC_URL='https://arb1.arbitrum.io/rpc'
export ROBINHOOD_RPC_URL='https://rpc.mainnet.chain.robinhood.com'
# CR-19: no pin in source; unset pins default to head-100 (public RPCs keep only ~6-8k blocks of state).
export ARBITRUM_FORK_BLOCK="${ARBITRUM_FORK_BLOCK:-$(($(cast block-number --rpc-url "$ARBITRUM_RPC_URL") - 100))}"
export ROBINHOOD_FORK_BLOCK="${ROBINHOOD_FORK_BLOCK:-$(($(cast block-number --rpc-url "$ROBINHOOD_RPC_URL") - 100))}"
[[ "$ARBITRUM_FORK_BLOCK" =~ ^[1-9][0-9]*$ && "$ROBINHOOD_FORK_BLOCK" =~ ^[1-9][0-9]*$ ]] || { printf 'Explicit positive numeric fork pins required\n' >&2; exit 1; }
# CR-12: separate stock (TSLA/NVDA, 24 h heartbeat + 1 h) and SOL (tight) feed max ages.
export SOLANA_STOCK_PRICE_MAX_AGE=90000 SOLANA_SOL_PRICE_MAX_AGE=7200
export PROTOCOL_RECIPIENT=0x0000000000000000000000000000000000000011
export ADAPTER_GUARDIAN=0x0000000000000000000000000000000000000012
export API_SIGNER=0x0000000000000000000000000000000000000013
export REGISTRY_OWNER="$API_SIGNER"
export FOUNDRY_BROADCAST="$STATE/broadcast"
printf '{"arbitrum":%s,"robinhood":%s}\n' "$ARBITRUM_FORK_BLOCK" "$ROBINHOOD_FORK_BLOCK" >"$STATE/pins.json"
failed=0
for side in arbitrum robinhood; do
  if [[ "$side" == arbitrum ]]; then rpc="$ARBITRUM_RPC_URL"; pin="$ARBITRUM_FORK_BLOCK";
  else rpc="$ROBINHOOD_RPC_URL"; pin="$ROBINHOOD_FORK_BLOCK"; fi
  curl --silent --fail --max-time 30 -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_gasPrice","params":[]}' \
    "$rpc" >"$STATE/$side-gas-price.json"
  if forge script script/DeploySolanaV6.s.sol --fork-url "$rpc" --fork-block-number "$pin" \
    --sender 0x0000000000000000000000000000000000000014 --compute-units-per-second 30 \
    --fork-retry-backoff 3000 >"$STATE/$side-deploy.log" 2>&1; then
    printf '%s factory simulation PASS\n' "$side"
  else
    printf '%s factory simulation FAIL; inspect cache/solana-deploy/%s-deploy.log\n' "$side" "$side"
    failed=1
  fi
done
exit "$failed"
