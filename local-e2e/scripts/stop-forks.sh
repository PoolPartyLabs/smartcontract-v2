#!/usr/bin/env bash
# Stops what the local-e2e harness started, and only that: the processes named by the pid files in
# local-e2e/.state/ (the keeper first, then both anvil forks). Any other anvil process is left alone.
# The deployment state goes with the forks (it describes chain state that no longer exists); logs are kept.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$(cd "$HERE/.." && pwd)/.state"

# Stops the process in `$STATE/$1.pid` if it is still the `$2` process that was started (a stale pid may have
# been reused by an unrelated process).
stop() {
  local name="$1" expected="$2" pid_file="$STATE/$1.pid"
  [[ -f "$pid_file" ]] || { echo "$name: not running (no pid file)"; return 0; }
  local pid
  pid="$(cat "$pid_file")"
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "$name: not running (stale pid $pid)"
    rm -f "$pid_file"
    return 0
  fi
  local command
  command="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
  if [[ "$command" != *"$expected"* ]]; then
    echo "$name: pid $pid is not the harness's $expected process ($command); leaving it alone"
    rm -f "$pid_file"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  local waited=0
  while kill -0 "$pid" 2>/dev/null && ((waited < 100)); do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    echo "$name: pid $pid did not stop on SIGTERM, killed"
  else
    echo "$name: stopped (pid $pid)"
  fi
  rm -f "$pid_file"
}

mkdir -p "$STATE"
stop keeper node
stop arbitrum anvil
stop robinhood anvil
rm -f "$STATE/deployment.json"
