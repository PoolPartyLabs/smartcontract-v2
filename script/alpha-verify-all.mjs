import {readFileSync, mkdirSync, writeFileSync, rmSync} from "node:fs";
import {spawnSync} from "node:child_process";

const [chain, path, directory] = process.argv.slice(2);
if (!["42161", "4663"].includes(chain) || !path || !directory) throw new Error("Use: alpha-verify-all.mjs CHAIN INVENTORY RECEIPT_DIRECTORY");
const records = JSON.parse(readFileSync(path, "utf8"));
if (records.some((record) => !record.contract && !["CodeStore", "CREATE3 proxy"].includes(record.kind))) throw new Error("Unknown executable: verification coverage failed");
const pending = records.filter((record) => record.contract);
if (pending.length !== (chain === "42161" ? 24 : 11)) throw new Error("Unexpected alpha executable inventory; reconcile before verifying");
mkdirSync(directory, {recursive: true});
rmSync(`${directory}/coverage.json`, {force: true});
const verified = new Set();
while (pending.length) {
  const index = pending.findIndex((record) => record.libraries.every((link) => verified.has(link.slice(link.lastIndexOf(":") + 1).toLowerCase())));
  if (index < 0) throw new Error("Missing or cyclic linked-library dependency");
  const [record] = pending.splice(index, 1);
  const args = ["forge", "verify-contract", record.address, record.contract, "--chain-id", chain,
    "--compiler-version", "v0.8.28+commit.7893614a", "--num-of-optimizations", "800", "--constructor-args", record.constructorArgs, "--watch"];
  for (const link of record.libraries) args.push("--libraries", link);
  if (chain === "42161") {
    if (!process.env.ARBISCAN_API_KEY) throw new Error("Missing ARBISCAN_API_KEY");
    args.push("--verifier", "etherscan", "--etherscan-api-key", process.env.ARBISCAN_API_KEY);
  } else args.push("--verifier", "blockscout", "--verifier-url", "https://robinhoodchain.blockscout.com/api/");
  const result = spawnSync("bash", ["script/alpha-safe.sh", ...args], {encoding: "utf8"});
  const output = result.stdout ?? "";
  writeFileSync(`${directory}/${record.address}.log`, output);
  if (result.status !== 0 || !/successfully verified|already verified|pass - verified/i.test(output)) throw new Error(`Verification unresolved: ${record.address}; inspect redacted receipt`);
  verified.add(record.address.toLowerCase());
}
writeFileSync(`${directory}/coverage.json`, JSON.stringify({chain, verified: [...verified], raw: records.filter((record) => !record.contract)}, null, 2));
console.log(`Verified every executable on ${chain}: ${verified.size}; no unknown or unverified records`);
