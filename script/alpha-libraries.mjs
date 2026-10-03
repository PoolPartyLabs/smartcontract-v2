import {readFileSync} from "node:fs";

const log = readFileSync(process.argv[2], "utf8");
const links = {};
for (const name of ["CoreVaultLogic", "CoreVaultTransitLogic", "CoreVaultIncomeLogic", "CoreVaultIncomeCollectionLogic", "CoreVaultPayoutLogic", "CoreVaultClosureLogic", "SpokeCrossChainLib", "SpokeUnwindLib", "SpokeCloseLib", "SpokeIncomeLib"]) {
  const address = log.match(new RegExp(`^  ${name} (0x[0-9a-fA-F]{40})$`, "m"))?.[1];
  if (!address || /^0x0{40}$/.test(address)) throw new Error(`Missing deployed library ${name}`);
  links[`src/${name.startsWith("Core") ? "core" : "spoke"}/${name}.sol:${name}`] = address;
}
console.log(JSON.stringify(links));
