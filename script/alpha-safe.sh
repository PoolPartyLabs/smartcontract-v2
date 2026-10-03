#!/usr/bin/env bash
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
. "$ROOT/local-e2e/scripts/redact-urls.sh"
case "${1:-}" in
  cast|forge|node|pnpm|curl) ;;
  *) echo 'Usage: bash script/alpha-safe.sh cast|forge|node|pnpm|curl ...' >&2; exit 2 ;;
esac
"$@" 2>&1 | redact_urls
