#!/usr/bin/env bash
# Starts the two long-lived anvil forks of the local-e2e harness in the background:
#   Arbitrum One (Hub Chain)       chain id 42161, port 8545 (LOCAL_E2E_ARBITRUM_PORT)
#   Robinhood Chain (Spoke Chain)  chain id 4663,  port 8546 (LOCAL_E2E_ROBINHOOD_PORT)
# Pid and log files go to local-e2e/.state/. Both nodes automine and keep the forked chain id.
#
# Environment:
#   ARBITRUM_RPC_URL, ROBINHOOD_RPC_URL  upstream RPCs (process environment, then the repo .env, then the public
#                                        endpoints of .env.example); an archive endpoint is best, and one Alchemy key
#                                        serves both chains. This script prints the host only, the log tails it shows
#                                        on a failure included; anvil's log is redacted before it reaches disk.
#   ARBITRUM_FORK_BLOCK, ROBINHOOD_FORK_BLOCK
#                                        fork blocks, read from the process environment only (default: latest). The
#                                        repo .env pins old blocks for the forge fork suites; a public RPC no longer
#                                        serves their state, so the harness never takes them from .env.
#   LOCAL_E2E_ANVIL_CUPS                 compute units per second anvil assumes for the upstream (default 150)
#   LOCAL_E2E_ANVIL_RETRIES              retries per upstream request (default 10)
#   LOCAL_E2E_ANVIL_BACKOFF_MS           initial retry backoff in ms (default 1000)
#   LOCAL_E2E_HARDFORK                   EVM hardfork of both nodes (default prague)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$HARNESS/.." && pwd)"
STATE="$HARNESS/.state"
mkdir -p "$STATE"

PUBLIC_ARBITRUM_RPC="https://arb1.arbitrum.io/rpc"
PUBLIC_ROBINHOOD_RPC="https://rpc.mainnet.chain.robinhood.com"

# Reads KEY from the repo .env without sourcing it (no side effects, no overrides).
env_file_value() {
  local key="$1" file="$REPO/.env"
  [[ -f "$file" ]] || return 0
  grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1 | sed -E "s/^[[:space:]]*${key}=//; s/^['\"]//; s/['\"]$//"
}

ARBITRUM_RPC_URL="${ARBITRUM_RPC_URL:-$(env_file_value ARBITRUM_RPC_URL)}"
ROBINHOOD_RPC_URL="${ROBINHOOD_RPC_URL:-$(env_file_value ROBINHOOD_RPC_URL)}"
ARBITRUM_RPC_URL="${ARBITRUM_RPC_URL:-$PUBLIC_ARBITRUM_RPC}"
ROBINHOOD_RPC_URL="${ROBINHOOD_RPC_URL:-$PUBLIC_ROBINHOOD_RPC}"
ARBITRUM_FORK_BLOCK="${ARBITRUM_FORK_BLOCK:-}"
ROBINHOOD_FORK_BLOCK="${ROBINHOOD_FORK_BLOCK:-}"

ARBITRUM_PORT="${LOCAL_E2E_ARBITRUM_PORT:-8545}"
ROBINHOOD_PORT="${LOCAL_E2E_ROBINHOOD_PORT:-8546}"
CUPS="${LOCAL_E2E_ANVIL_CUPS:-150}"
RETRIES="${LOCAL_E2E_ANVIL_RETRIES:-10}"
BACKOFF_MS="${LOCAL_E2E_ANVIL_BACKOFF_MS:-1000}"
READY_TIMEOUT_S="${LOCAL_E2E_READY_TIMEOUT_S:-90}"
# Both chains are Arbitrum Nitro chains; anvil would otherwise pick its newest hardfork for chain 4663 (with the
# EIP-7825 per-transaction gas cap that Nitro does not apply).
HARDFORK="${LOCAL_E2E_HARDFORK:-prague}"

command -v anvil >/dev/null || { echo "error: anvil not found (install Foundry: https://getfoundry.sh)" >&2; exit 1; }
command -v curl >/dev/null || { echo "error: curl not found" >&2; exit 1; }

upper() { tr '[:lower:]' '[:upper:]' <<<"$1"; }

# Forks this invocation started; a failure stops them so no half-started harness is left behind.
STARTED=()
fail() {
  local name
  for name in ${STARTED[@]+"${STARTED[@]}"}; do
    if [[ -f "$STATE/$name.pid" ]]; then
      kill "$(cat "$STATE/$name.pid")" 2>/dev/null || true
      rm -f "$STATE/$name.pid"
      echo "stopped the $name fork this run had started" >&2
    fi
  done
  exit 1
}

# Keeps the scheme and host of every URL in stdin, never a path or query that may carry an API key (Alchemy:
# /v2/<key>). anvil repeats its upstream URL in its log ("Endpoint: ...") and in its errors.
redact_urls() { sed -E 's,(https?://[^/?#[:space:])]+)[/?#][^[:space:])]*,\1/...,g'; }
redact() { redact_urls <<<"$1"; }

port_in_use() {
  if command -v lsof >/dev/null; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1"
  fi
}

rpc_chain_id() {
  curl -s --max-time 2 -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "http://127.0.0.1:$1" |
    sed -nE 's/.*"result":"(0x[0-9a-fA-F]+)".*/\1/p'
}

start_fork() {
  local name="$1" chain_id="$2" port="$3" url="$4" block="$5"
  local pid_file="$STATE/$name.pid" log_file="$STATE/$name.log"

  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    echo "error: the $name fork is already running (pid $(cat "$pid_file"), port $port). Run 'pnpm down' first." >&2
    exit 1
  fi
  rm -f "$pid_file"
  if port_in_use "$port"; then
    echo "error: port $port is already in use by another process; stop it or set LOCAL_E2E_$(upper "$name")_PORT." >&2
    fail
  fi

  local args=(
    --fork-url "$url"
    --chain-id "$chain_id"
    --port "$port"
    --host 127.0.0.1
    --retries "$RETRIES"
    --fork-retry-backoff "$BACKOFF_MS"
    --timeout 60000
    --compute-units-per-second "$CUPS"
    --hardfork "$HARDFORK"
  )
  if [[ -n "$block" ]]; then args+=(--fork-block-number "$block"); fi

  echo "starting the $name fork: chain $chain_id, port $port, upstream $(redact "$url"), block ${block:-latest}"
  nohup anvil "${args[@]}" > >(redact_urls >"$log_file") 2>&1 &
  echo $! >"$pid_file"
  STARTED+=("$name")
}

wait_ready() {
  local name="$1" chain_id="$2" port="$3"
  local pid_file="$STATE/$name.pid" log_file="$STATE/$name.log"
  local expected
  expected="$(printf '0x%x' "$chain_id")"
  local deadline=$((SECONDS + READY_TIMEOUT_S))
  while ((SECONDS < deadline)); do
    if ! kill -0 "$(cat "$pid_file")" 2>/dev/null; then
      echo "error: the $name fork exited during startup. Last lines of $log_file:" >&2
      tail -n 20 "$log_file" | redact_urls >&2
      if grep -qiE "state (is )?not available|missing trie node|pruned|historical state" "$log_file"; then
        echo "hint: the upstream RPC no longer serves the state of the fork block. Fork at latest (unset" >&2
        echo "      $(upper "$name")_FORK_BLOCK) or use an archive RPC (see local-e2e/README.md, Troubleshooting)." >&2
      fi
      rm -f "$pid_file"
      fail
    fi
    if [[ "$(rpc_chain_id "$port")" == "$expected" ]]; then
      echo "the $name fork is ready on http://127.0.0.1:$port (pid $(cat "$pid_file"))"
      return 0
    fi
    sleep 0.5
  done
  echo "error: the $name fork did not answer eth_chainId $expected within ${READY_TIMEOUT_S}s. Last lines of $log_file:" >&2
  tail -n 20 "$log_file" | redact_urls >&2
  fail
}

start_fork arbitrum 42161 "$ARBITRUM_PORT" "$ARBITRUM_RPC_URL" "$ARBITRUM_FORK_BLOCK"
start_fork robinhood 4663 "$ROBINHOOD_PORT" "$ROBINHOOD_RPC_URL" "$ROBINHOOD_FORK_BLOCK"
wait_ready arbitrum 42161 "$ARBITRUM_PORT"
wait_ready robinhood 4663 "$ROBINHOOD_PORT"
