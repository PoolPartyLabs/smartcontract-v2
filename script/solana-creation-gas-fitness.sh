#!/usr/bin/env bash
set +x
set -euo pipefail
# C7 / CR-18 fitness function: Hub Fund creation measured as a REAL transaction receipt, never a warm in-test number.
# On a loopback anvil fork of Arbitrum at the given pin it broadcasts the v6 factory from the pinned deployer
# (DeploySolanaV6, C1 pin guard active), builds the deploy-day plan with BuildSolanaFundV6Plan (C2: asset set from
# cache/sol-t11/native-config.hex, written by `three-chain-creation.ts prepare`), sends approve + createFundV6Committed
# from the Manager, and asserts receipt gasUsed + 1,000,000 <= ArbGasInfo maxTxGasLimit (read live, read-only).
# Every send goes to 127.0.0.1 as an --unlocked (anvil-impersonated) sender: no key reaches argv and no other endpoint
# can accept the transactions. The fork endpoint is the foundry.toml `arbitrum` alias (URL stays in the environment);
# anvil's banner prints it, so anvil output is discarded. Evidence: cache/sol-t11/creation-gas-fitness/result.json.
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$ROOT"
if [[ "$#" != 0 ]]; then printf 'No flags supported; loopback anvil only\n' >&2; exit 2; fi
: "${ARBITRUM_RPC_URL:?Source the approved rpc-env.sh without printing}"
: "${ARBITRUM_FORK_BLOCK:?Explicit fork pin (head-100) required}"
: "${PP_FITNESS_ANVIL_PORT:?Explicit loopback anvil port from the port registry required}"
: "${DEPLOYER_PRIVATE_KEY:?EVM Manager key parameter (binding signature only) required}"
: "${EVM_MANAGER_ADDRESS:?EVM Manager address required}"
for name in PROTOCOL_RECIPIENT ADAPTER_GUARDIAN API_SIGNER REGISTRY_OWNER SOLANA_STOCK_PRICE_MAX_AGE SOLANA_SOL_PRICE_MAX_AGE; do
  [[ -n "${!name:-}" ]] || { printf '%s required (factory wiring)\n' "$name" >&2; exit 2; }
done
[[ "$ARBITRUM_FORK_BLOCK" =~ ^[1-9][0-9]*$ && "$PP_FITNESS_ANVIL_PORT" =~ ^[0-9]+$ ]] || { printf 'Numeric pin and port required\n' >&2; exit 2; }
[[ -f cache/sol-t11/native-config.hex ]] || { printf 'Run three-chain-creation.ts prepare first (asset set input)\n' >&2; exit 2; }
if lsof -iTCP:"$PP_FITNESS_ANVIL_PORT" -sTCP:LISTEN >/dev/null 2>&1; then printf 'Port occupied; stop its owner, never another lane\n' >&2; exit 1; fi
DEPLOYER="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync("script/solana-v6-addresses.json")).approvedFactoryDeployer)')"
FACTORY="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync("script/solana-v6-addresses.json")).arbitrum.approvedFactory)')"
USDC=0xaf88d065e77c8cC2239327C5EDb3A432268e5831
USDC_HOLDER=0x724dc807b04555b71ed48a6896b6F41593b8C637   # Aave v3 aUSDC on Arbitrum holds the underlying USDC
MARGIN=1000000
LOCAL="http://127.0.0.1:$PP_FITNESS_ANVIL_PORT"
STATE="$ROOT/cache/sol-t11/creation-gas-fitness"
mkdir -p "$STATE"
export FOUNDRY_BROADCAST="$STATE/broadcast"
anvil --fork-url arbitrum --fork-block-number "$ARBITRUM_FORK_BLOCK" --port "$PP_FITNESS_ANVIL_PORT" --host 127.0.0.1 \
  --auto-impersonate >/dev/null 2>&1 &
ANVIL_PID=$!
# C5: Foundry's sensitive script cache keeps the RPC alias resolution; purge it with the anvil.
cleanup() { kill "$ANVIL_PID" 2>/dev/null || true; rm -rf "$ROOT/cache/DeploySolanaV6.s.sol" "$ROOT/cache/BuildSolanaFundV6Plan.s.sol"; }
trap cleanup EXIT
for _ in $(seq 1 120); do cast chain-id --rpc-url "$LOCAL" >/dev/null 2>&1 && break; sleep 0.5; done
[[ "$(cast chain-id --rpc-url "$LOCAL")" == 42161 ]] || { printf 'Loopback fork did not start\n' >&2; exit 1; }
cast rpc anvil_setBalance "$DEPLOYER" 0x56BC75E2D63100000 --rpc-url "$LOCAL" >/dev/null
cast rpc anvil_setBalance "$EVM_MANAGER_ADDRESS" 0x56BC75E2D63100000 --rpc-url "$LOCAL" >/dev/null
cast rpc anvil_setBalance "$USDC_HOLDER" 0x56BC75E2D63100000 --rpc-url "$LOCAL" >/dev/null
sanitize() { sed -E 's#https?://[^ "]+#<endpoint>#g' "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
forge script script/DeploySolanaV6.s.sol --fork-url "$LOCAL" --sender "$DEPLOYER" --unlocked --broadcast --slow \
  >"$STATE/factory.log" 2>&1 || { sanitize "$STATE/factory.log"; printf 'Factory broadcast to loopback failed; see factory.log\n' >&2; exit 1; }
sanitize "$STATE/factory.log"
[[ "$(cast code "$FACTORY" --rpc-url "$LOCAL")" != 0x ]] || { printf 'Pinned factory absent after broadcast\n' >&2; exit 1; }
forge script script/BuildSolanaFundV6Plan.s.sol --fork-url "$LOCAL" >"$STATE/plan.log" 2>&1 \
  || { sanitize "$STATE/plan.log"; printf 'Plan build failed; see plan.log\n' >&2; exit 1; }
sanitize "$STATE/plan.log"
cast send "$USDC" "transfer(address,uint256)" "$EVM_MANAGER_ADDRESS" 50000000 --from "$USDC_HOLDER" --unlocked --rpc-url "$LOCAL" >/dev/null
cast send "$USDC" "approve(address,uint256)" "$FACTORY" 50000000 --from "$EVM_MANAGER_ADDRESS" --unlocked --rpc-url "$LOCAL" >/dev/null
CALLDATA="$(cat cache/sol-t11/mainnet-creation-calldata.hex)"
TX="$(cast send "$FACTORY" "$CALLDATA" --from "$EVM_MANAGER_ADDRESS" --unlocked --gas-limit 32000000 --rpc-url "$LOCAL" --json \
  | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{const r=JSON.parse(s);if(r.status!=="0x1")process.exit(3);process.stdout.write(r.transactionHash)})')" \
  || { printf 'createFundV6Committed reverted on the loopback fork\n' >&2; exit 1; }
GAS_USED="$(cast receipt "$TX" gasUsed --rpc-url "$LOCAL")"
CAP="$(cast call 0x000000000000000000000000000000000000006C 'getGasAccountingParams()(uint256,uint256,uint256)' --rpc-url arbitrum | sed -n 3p | awk '{print $1}')"
BYTES="$(( (${#CALLDATA} - 2) / 2 ))"
node -e 'const [gas,cap,margin,bytes,pin,tx]=process.argv.slice(1).map(String);const r={measuredAt:new Date().toISOString(),pin:Number(pin),
  shape:"deploy-day plan (cache/sol-t11/native-config.hex)",calldataBytes:Number(bytes),receiptGasUsed:Number(gas),
  maxTxGasLimit:Number(cap),requiredMargin:Number(margin),headroom:Number(cap)-Number(gas),pass:Number(gas)+Number(margin)<=Number(cap),tx,
  note:"anvil receipt: L2 execution + intrinsic + calldata; Arbitrum adds its L1 poster component outside maxTxGasLimit"};
  require("fs").writeFileSync(process.argv[7],JSON.stringify(r,null,2)+"\n");console.log(JSON.stringify(r))' \
  "$GAS_USED" "$CAP" "$MARGIN" "$BYTES" "$ARBITRUM_FORK_BLOCK" "$TX" "$STATE/result.json"
if (( GAS_USED + MARGIN > CAP )); then printf 'CR-18 FAIL: creation %s gas leaves less than %s below the %s cap\n' "$GAS_USED" "$MARGIN" "$CAP" >&2; exit 1; fi
printf 'CR-18 PASS: creation receipt %s gas, %s below the %s per-tx cap\n' "$GAS_USED" "$((CAP - GAS_USED))" "$CAP"
