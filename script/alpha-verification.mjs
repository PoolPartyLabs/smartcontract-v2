import {readFileSync} from "node:fs";

const libraries = JSON.parse(process.env.ALPHA_LIBRARIES ?? "{}");
const names = [
  "AaveV3Adapter", "AcrossBridgeAdapter", "UniswapV3SwapAdapter", "UniswapV4Adapter", "CoreVault",
  "ManagerFeeVault", "ManagerRegistry", "ShareToken", "TransitEscrow", "Create3Deployer", "FundFactory",
  "ChainlinkPriceSource", "ValueReportReceiver", "SpokeVault", "CoreVaultLogic", "CoreVaultTransitLogic",
  "CoreVaultIncomeLogic", "CoreVaultIncomeCollectionLogic", "CoreVaultPayoutLogic", "SpokeCrossChainLib", "SpokeUnwindLib", "SpokeIncomeLib",
];
const artifacts = names.map((name) => {
  const artifact = JSON.parse(readFileSync(`out/${name}.sol/${name}.json`, "utf8"));
  let bytecode = artifact.bytecode.object.replace(/^0x/, "");
  const links = [];
  for (const [file, entries] of Object.entries(artifact.bytecode.linkReferences)) {
    for (const [library, positions] of Object.entries(entries)) {
      const id = `${file}:${library}`;
      const address = libraries[id];
      if (!/^0x[0-9a-fA-F]{40}$/.test(address ?? "")) throw new Error(`Supply ALPHA_LIBRARIES entry ${id}`);
      links.push(`${id}:${address}`);
      for (const {start, length} of positions) {
        bytecode = bytecode.slice(0, start * 2) + address.slice(2).toLowerCase() + bytecode.slice((start + length) * 2);
      }
    }
  }
  const metadata = typeof artifact.metadata === "string" ? JSON.parse(artifact.metadata) : artifact.metadata;
  const file = Object.keys(metadata.settings.compilationTarget)[0];
  return {contract: `${file}:${name}`, prefix: bytecode.toLowerCase(), libraries: links};
});
const seen = new Set();
const records = [];
function record(address, initCode) {
  if (!address || !initCode || seen.has(address.toLowerCase())) return;
  seen.add(address.toLowerCase());
  const code = initCode.replace(/^0x/, "").toLowerCase();
  const artifact = artifacts.find((entry) => code.startsWith(entry.prefix));
  if (!artifact) {
    const kind = code.startsWith("75363d3d") ? "CREATE3 proxy"
      : /^61[0-9a-f]{4}80600a3d393df300/.test(code) ? "CodeStore" : "Unknown executable; verification required";
    records.push({address, rawCreationCode: initCode, kind});
    return;
  }
  records.push({address, contract: artifact.contract, constructorArgs: `0x${code.slice(artifact.prefix.length)}`, libraries: artifact.libraries});
}
for (const path of process.argv.slice(2)) {
  const broadcast = JSON.parse(readFileSync(path, "utf8"));
  for (const transaction of broadcast.transactions) {
    if (transaction.transactionType === "CREATE" || transaction.transactionType === "CREATE2") {
      const input = transaction.transaction.input;
      record(transaction.contractAddress, transaction.transactionType === "CREATE2" ? `0x${input.slice(66)}` : input);
    }
    for (const additional of transaction.additionalContracts ?? []) record(additional.address, additional.initCode);
  }
}
if (!process.argv.slice(2).length) throw new Error("Supply broadcast run JSON paths");
console.log(JSON.stringify(records, null, 2));
