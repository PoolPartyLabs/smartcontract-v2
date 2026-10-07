#!/usr/bin/env bash
set -euo pipefail
set +x
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$ROOT"
if [[ "$#" != 0 ]]; then printf 'No flags supported; fork/localnet only\n' >&2; exit 2; fi
: "${DEPLOYER_PRIVATE_KEY:?Load EVM deployer parameter from .env.alpha without printing}"
: "${SOLANA_DEPLOYER_PRIVATE_KEY:?Load R8 Solana signer parameter without printing}"
: "${ARBITRUM_RPC_URL:?Source approved rpc-env.sh without printing}"
: "${ROBINHOOD_RPC_URL:?Source approved rpc-env.sh without printing}"
: "${ARBITRUM_FORK_BLOCK:?Explicit fork pin required}"
: "${ROBINHOOD_FORK_BLOCK:?Explicit fork pin required}"
: "${SOLANA_STOCK_SESSION_OPEN:?Explicit session required}"
: "${SOLANA_STOCK_SESSION_CLOSE:?Explicit session required}"
[[ "$ARBITRUM_FORK_BLOCK" =~ ^[1-9][0-9]*$ && "$ROBINHOOD_FORK_BLOCK" =~ ^[1-9][0-9]*$ ]] || exit 2
export PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY"
export PP_LOCALNET_RPC_PORT=8998 PP_LOCALNET_FAUCET_PORT=9998 PP_LOCALNET_GOSSIP_PORT=19900 PP_LOCALNET_DYNAMIC_PORTS=19901-19960
mkdir -p cache/sol-t11
rm -f cache/sol-t11/creation.json cache/sol-t11/hub-created cache/sol-t11/robinhood-created cache/sol-t11/native-acceptance.json cache/sol-t11/signer-prompts.json
node solana/scripts/three-chain-creation.ts prepare
result=0
forge test --match-contract SolanaThreeChainCreationForkTest -vv > cache/sol-t11/three-chain-fork.log 2>&1 || result=$?
node --input-type=module <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';
const path = 'cache/sol-t11/three-chain-fork.log';
let text = readFileSync(path, 'utf8');
for (const [name, value] of Object.entries(process.env)) if (/RPC|KEY|SECRET/.test(name) && value?.length > 4) text = text.replaceAll(value, '<suppressed>');
text = text.replace(/https?:\/\/[^\s"')]+/g, '<endpoint>');
writeFileSync(path, text);
NODE
if [[ -f cache/sol-t11/creation.json ]]; then
  node solana/scripts/three-chain-creation.ts export
  bash solana/tests/swap/production.start.sh
  trap 'bash solana/scripts/localnet.sh stop' EXIT
  node solana/scripts/three-chain-creation.ts accept-local
else
  printf 'Fork creation plan unavailable; inspect sanitized evidence\n' >&2
fi
if [[ "$result" != 0 ]]; then printf 'Three-chain EVM fork incomplete; NOT GO\n' >&2; exit "$result"; fi
[[ -f cache/sol-t11/hub-created && -f cache/sol-t11/robinhood-created && -f cache/sol-t11/native-acceptance.json ]]
printf 'Three-chain same-Fund creation PASS; no mainnet transactions\n'
