#!/usr/bin/env bash
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
if [[ "$PWD" != "$ROOT" ]]; then echo 'Run from the worktree root' >&2; exit 1; fi
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
HUB_PORT=${ALPHA_REHEARSAL_HUB_PORT:-18645}
SPOKE_PORT=${ALPHA_REHEARSAL_SPOKE_PORT:-18646}
for port in "$HUB_PORT" "$SPOKE_PORT"; do
  if lsof -ti "tcp:$port" -sTCP:LISTEN >/dev/null; then echo "Port $port is occupied" >&2; exit 1; fi
done
STATE="$ROOT/local-e2e/.state/alpha-rehearsal"
mkdir -p "$STATE"
HUB_PID= SPOKE_PID=
cleanup() {
  for pid in "$HUB_PID" "$SPOKE_PID"; do
    if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  done
  unset REHEARSAL_OPERATOR_KEY REHEARSAL_MANAGER_KEY
}
trap cleanup EXIT INT TERM
anvil --host 127.0.0.1 --port "$HUB_PORT" --chain-id 42161 --fork-url "$ARBITRUM_RPC_URL" --fork-block-number "$ARBITRUM_FORK_BLOCK" --silent >/dev/null 2>&1 & HUB_PID=$!
anvil --host 127.0.0.1 --port "$SPOKE_PORT" --chain-id 4663 --fork-url "$ROBINHOOD_RPC_URL" --fork-block-number "$ROBINHOOD_FORK_BLOCK" --silent >/dev/null 2>&1 & SPOKE_PID=$!
HUB_RPC="http://127.0.0.1:$HUB_PORT"
SPOKE_RPC="http://127.0.0.1:$SPOKE_PORT"
for attempt in {1..60}; do
  if cast chain-id --rpc-url "$HUB_RPC" >/dev/null 2>&1 && cast chain-id --rpc-url "$SPOKE_RPC" >/dev/null 2>&1; then break; fi
  sleep 1
done
[[ $(cast chain-id --rpc-url "$HUB_RPC") == 42161 && $(cast chain-id --rpc-url "$SPOKE_RPC") == 4663 ]]
export LOCAL_E2E_ARBITRUM_PORT="$HUB_PORT" LOCAL_E2E_ROBINHOOD_PORT="$SPOKE_PORT"
REHEARSAL_OPERATOR_KEY=$(node --import ./local-e2e/node_modules/tsx/dist/loader.mjs --input-type=module -e 'import {ACTOR_KEYS} from "./local-e2e/src/config.ts"; process.stdout.write(ACTOR_KEYS.operator)')
REHEARSAL_MANAGER_KEY=$(node --import ./local-e2e/node_modules/tsx/dist/loader.mjs --input-type=module -e 'import {ACTOR_KEYS} from "./local-e2e/src/config.ts"; process.stdout.write(ACTOR_KEYS.manager)')
export DEPLOYER_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export ADAPTER_GUARDIAN="$DEPLOYER_ADDRESS" PROTOCOL_RECIPIENT=0x976EA74026E726554dB657fA54763abd0C3a0aa9
export API_SIGNER=0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f REGISTRY_OWNER=0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f
export MANAGER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
export SPOKE_CAP=10000000000 MIN_FIRST_DEPOSIT=100000000 SEED_AMOUNT=100000000
export PERFORMANCE_FEE_BPS=2000 MANAGEMENT_FEE_BPS=0 SPOKE_OPERATING_CASH_FLOOR=0 SPOKE_OPERATING_CASH_TOP_UP=0
unset HUB_POOL_TOKEN0 HUB_POOL_TOKEN1 HUB_POOL_FEE HUB_POOL_TICK_SPACING HUB_AAVE_ASSET
unset SPOKE_POOL_TOKEN0 SPOKE_POOL_TOKEN1 SPOKE_POOL_FEE SPOKE_POOL_TICK_SPACING
export FOUNDRY_BROADCAST="$STATE/broadcast"
forge build >/dev/null 2>&1
pnpm --dir local-e2e alpha:rehearsal fund
for side in hub spoke; do
  if [[ "$side" == hub ]]; then rpc="$HUB_RPC"; else rpc="$SPOKE_RPC"; fi
  forge script script/DeployFactory.s.sol --rpc-url "$rpc" --private-key "$REHEARSAL_OPERATOR_KEY" --broadcast --slow --legacy --with-gas-price 100000000 >"$STATE/deploy-$side.log" 2>&1
done
export FUND_FACTORY=$(sed -n 's/^  FundFactory //p' "$STATE/deploy-hub.log" | tail -1)
[[ "$FUND_FACTORY" == $(sed -n 's/^  FundFactory //p' "$STATE/deploy-spoke.log" | tail -1) ]]
forge script script/CreateFund.s.sol --rpc-url "$HUB_RPC" --private-key "$REHEARSAL_MANAGER_KEY" --broadcast --slow --legacy --with-gas-price 100000000 >"$STATE/create-hub.log" 2>&1
export CREATION_NUMBER=$(sed -n 's/^  CREATION_NUMBER //p' "$STATE/create-hub.log")
export MANDATE_HASH=$(sed -n '/^  MANDATE_HASH/{n;s/^  //;p;}' "$STATE/create-hub.log")
export ALPHA_CORE_VAULT=$(sed -n 's/^  Core Vault //p' "$STATE/create-hub.log")
export ALPHA_SPOKE_VAULT=$(sed -n 's/^  Robinhood Spoke Vault (predicted) //p' "$STATE/create-hub.log")
export ALPHA_REPORT_RECEIVER=$(sed -n 's/^  ValueReportReceiver //p' "$STATE/create-hub.log")
export ALPHA_SHARE_TOKEN=$(sed -n 's/^  ShareToken //p' "$STATE/create-hub.log")
forge script script/CreateFund.s.sol --rpc-url "$SPOKE_RPC" --private-key "$REHEARSAL_MANAGER_KEY" --broadcast --slow --legacy --with-gas-price 100000000 >"$STATE/create-spoke.log" 2>&1
for side in hub spoke; do
  if [[ "$side" == hub ]]; then rpc="$HUB_RPC"; else rpc="$SPOKE_RPC"; fi
  forge script script/CheckAlphaDeployment.s.sol --rpc-url "$rpc" >"$STATE/check-$side.log" 2>&1
  grep 'ALPHA CHECK PASS' "$STATE/check-$side.log"
done
cast send 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 'approve(address,uint256)' "$ALPHA_CORE_VAULT" 2000000 --rpc-url "$HUB_RPC" --private-key "$REHEARSAL_MANAGER_KEY" --legacy --gas-price 100000000 --json >"$STATE/approve.json"
cast send "$ALPHA_CORE_VAULT" 'deposit(uint256,uint256)' 2000000 1 --rpc-url "$HUB_RPC" --private-key "$REHEARSAL_MANAGER_KEY" --legacy --gas-price 100000000 --json >"$STATE/deposit.json"
jq '{status,transactionHash,gasUsed}' "$STATE/deposit.json"
pnpm --dir local-e2e alpha:rehearsal smoke
export ALPHA_REHEARSAL_STATE="$STATE"
pnpm --dir local-e2e alpha:rehearsal runtime
echo 'Rehearsal passed; both private forks stop on exit.'
