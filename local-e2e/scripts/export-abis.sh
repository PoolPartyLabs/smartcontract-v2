#!/usr/bin/env bash
# Exports the ABIs of the protocol contracts from the forge build output to local-e2e/abis/<Contract>.json, so an
# API or a frontend can consume them without Foundry. Runs `forge build` first (pass --no-build to skip it).
#
# A contract's ABI also gets the events and errors of the external libraries linked into its bytecode, followed
# through library-into-library links (the Core Vault's CoreVaultLogic, CoreVaultTransitLogic, CoreVaultIncomeLogic and
# CoreVaultPayoutLogic; the Spoke Vault's SpokeCrossChainLib, SpokeUnwindLib and SpokeIncomeLib). A linked library runs
# by DELEGATECALL, so what it emits is logged at the vault's address and what it reverts with bubbles up from the
# vault's calls, but solc leaves those definitions out of the vault's own ABI (IncomeDistributed, for one). An entry
# the contract already declares is kept as is; the merged ones follow, sorted by kind and name.
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
  echo "abis/$name.json"
  node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const [artifact, target, outDir] = process.argv.slice(1);
    const read = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
    const { abi, bytecode } = read(artifact);
    // An event or error by its signature; an event also by which inputs are indexed (its topics).
    const key = (item) =>
      `${item.type} ${item.name}(${item.inputs.map((i) => i.type + (item.type === "event" && i.indexed ? " indexed" : "")).join(",")})`;
    const known = new Set(abi.filter((i) => i.type === "event" || i.type === "error").map(key));
    const merged = [];
    const from = new Map();
    // The libraries linked into the bytecode, then those linked into theirs.
    const queue = [bytecode.linkReferences ?? {}];
    const visited = new Set();
    while (queue.length) {
      for (const [source, libraries] of Object.entries(queue.shift())) {
        for (const library of Object.keys(libraries)) {
          if (visited.has(library)) continue;
          visited.add(library);
          const libraryArtifact = path.join(outDir, path.basename(source), `${library}.json`);
          if (!fs.existsSync(libraryArtifact)) throw new Error(`${libraryArtifact} not found (linked into ${path.basename(artifact)})`);
          const lib = read(libraryArtifact);
          queue.push(lib.bytecode.linkReferences ?? {});
          for (const item of lib.abi) {
            if (item.type !== "event" && item.type !== "error") continue;
            const k = key(item);
            if (known.has(k)) continue;
            known.add(k);
            merged.push(item);
            from.set(k, library);
          }
        }
      }
    }
    merged.sort((a, b) => a.type.localeCompare(b.type) || a.name.localeCompare(b.name));
    fs.writeFileSync(target, JSON.stringify([...abi, ...merged], null, 2) + "\n");
    const events = merged.filter((i) => i.type === "event").map((i) => `${i.name} (${from.get(key(i))})`);
    if (visited.size) {
      console.log(`  linked: ${[...visited].join(", ")}; merged ${merged.length} entries` + (events.length ? `, events ${events.join(", ")}` : ""));
    }
  ' "$artifact" "$OUT_DIR/$name.json" "$REPO/out"
done
