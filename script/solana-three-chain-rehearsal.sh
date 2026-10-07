#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$ROOT"
STATE="$ROOT/cache/solana-deploy"
mkdir -p "$STATE"
export ARBITRUM_RPC_URL='https://arb1.arbitrum.io/rpc'
export ROBINHOOD_RPC_URL='https://rpc.mainnet.chain.robinhood.com'
export ARBITRUM_FORK_BLOCK="${ARBITRUM_FORK_BLOCK:-512239244}"
export ROBINHOOD_FORK_BLOCK="${ROBINHOOD_FORK_BLOCK:-82439071}"
export PP_LOCALNET_RPC_PORT=8995 PP_LOCALNET_FAUCET_PORT=9995
export PP_LOCALNET_GOSSIP_PORT=19500 PP_LOCALNET_DYNAMIC_PORTS=19501-19560
export PP_LOCALNET_RPC='http://127.0.0.1:8995'
failed=0
run() {
  local name="$1"; shift
  if "$@" >"$STATE/$name.log" 2>&1; then printf '%s PASS\n' "$name";
  else printf '%s FAIL; see cache/solana-deploy/%s.log\n' "$name" "$name"; failed=1; fi
}
run deployment forge test --match-path 'test/fork/deployment/*.t.sol' --compute-units-per-second 30 -vv
run hub-native forge test --match-path 'test/fork/cctp/ComposedSolanaFund.fork.t.sol' --compute-units-per-second 30 -vv
run hub-prices forge test --match-path 'test/fork/receiver/SolanaPriceSourceV6Fork.t.sol' --compute-units-per-second 30 -vv
run robinhood forge test --match-path 'test/fork/spoke/SpokeVaultRobinhoodFork.t.sol' --compute-units-per-second 30 -vv
if [[ ! -f "$ROOT/solana/.localnet/manifest.json" ]]; then
  run clone env SOLANA_CLONE_DELAY_MS=1000 bash solana/scripts/localnet.sh prepare
fi
if [[ -f "$ROOT/solana/.localnet/manifest.json" ]]; then
  run core-fixtures node solana/tests/core/prepare-fixtures.ts
  started=0
  cleanup() { if [[ "$started" == 1 ]]; then bash solana/scripts/localnet.sh stop; fi; }
  trap cleanup EXIT
  if bash solana/scripts/localnet.sh start >"$STATE/validator.log" 2>&1; then
    started=1
    run native-core-report bash -c 'cd solana && node --test --test-concurrency=1 tests/core/core.test.ts tests/report/report.test.ts'
  else failed=1; printf 'validator FAIL\n'; fi
fi
printf 'Separate chain legs only: this runner does NOT prove one shared three-chain Fund or transport correlation.\n'
exit "$failed"
