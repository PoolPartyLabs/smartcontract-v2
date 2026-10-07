#!/usr/bin/env bash
set -euo pipefail
set +x
set -a
source /Users/rafaelzochling/gitrepos/pool-party/smartcontract-v2/.env.alpha
set +a
exec node "$(dirname "$0")/record-v2.ts" "$@"
