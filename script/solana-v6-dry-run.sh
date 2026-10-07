#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$ROOT"
STATE="$ROOT/cache/solana-deploy"
mkdir -p "$STATE"
export ARBITRUM_RPC_URL='https://arb1.arbitrum.io/rpc'
export ROBINHOOD_RPC_URL='https://rpc.mainnet.chain.robinhood.com'
export ARBITRUM_FORK_BLOCK=512239244
export ROBINHOOD_FORK_BLOCK=82439071
export SOLANA_STOCK_SESSION_OPEN=1791293400 SOLANA_STOCK_SESSION_CLOSE=1791316800
export SOLANA_PRICE_MAX_AGE=3600
export PROTOCOL_RECIPIENT=0x0000000000000000000000000000000000000011
export ADAPTER_GUARDIAN=0x0000000000000000000000000000000000000012
export API_SIGNER=0x0000000000000000000000000000000000000013
export REGISTRY_OWNER="$API_SIGNER"
export FOUNDRY_BROADCAST="$STATE/broadcast"
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
