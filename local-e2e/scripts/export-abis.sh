#!/usr/bin/env bash
# Exports the ABIs of the protocol contracts from the forge build output to local-e2e/abis/<Contract>.json, so an
# API or a frontend can consume them without Foundry. Runs `forge build` first (pass --no-build to skip it).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$HARNESS/.." && pwd)"
OUT_DIR="$HARNESS/abis"

# <source file>:<contract> under src/.
CONTRACTS=(
  CoreVault.sol:CoreVault
  SpokeVault.sol:SpokeVault
  ShareToken.sol:ShareToken
  ValueReportReceiver.sol:ValueReportReceiver
  FundFactory.sol:FundFactory
  UniswapV4Adapter.sol:UniswapV4Adapter
  AaveV3Adapter.sol:AaveV3Adapter
  AcrossBridgeAdapter.sol:AcrossBridgeAdapter
  UniswapV3SwapAdapter.sol:UniswapV3SwapAdapter
  ManagerFeeVault.sol:ManagerFeeVault
  ManagerRegistry.sol:ManagerRegistry
  ChainlinkPriceSource.sol:ChainlinkPriceSource
)

if [[ "${1:-}" != "--no-build" ]]; then
  (cd "$REPO" && forge build)
fi

mkdir -p "$OUT_DIR"
for entry in "${CONTRACTS[@]}"; do
  file="${entry%%:*}"
  name="${entry##*:}"
  artifact="$REPO/out/$file/$name.json"
  [[ -f "$artifact" ]] || { echo "error: $artifact not found (did forge build run?)" >&2; exit 1; }
  node -e '
    const fs = require("node:fs");
    const [artifact, target] = process.argv.slice(1);
    const { abi } = JSON.parse(fs.readFileSync(artifact, "utf8"));
    fs.writeFileSync(target, JSON.stringify(abi, null, 2) + "\n");
  ' "$artifact" "$OUT_DIR/$name.json"
  echo "abis/$name.json"
done
