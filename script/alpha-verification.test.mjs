import {test} from "node:test";
import assert from "node:assert/strict";
import {readFileSync, mkdirSync, writeFileSync, rmSync} from "node:fs";
import {spawnSync} from "node:child_process";

test("DEC-134 verification records preserve constructor bytes and reject missing links", () => {
  const directory = "local-e2e/.state/alpha-verification-test";
  mkdirSync(directory, {recursive: true});
  try {
    const artifact = JSON.parse(readFileSync("out/ManagerFeeVault.sol/ManagerFeeVault.json", "utf8"));
    const args = "00".repeat(64);
    const address = "0x0000000000000000000000000000000000000123";
    const collection = JSON.parse(readFileSync("out/CoreVaultIncomeCollectionLogic.sol/CoreVaultIncomeCollectionLogic.json", "utf8"));
    const collectionAddress = "0x0000000000000000000000000000000000000456";
    const broadcast = {transactions: [
      {transactionType: "CREATE", contractAddress: address, transaction: {input: artifact.bytecode.object + args}, additionalContracts: []},
      {transactionType: "CREATE", contractAddress: collectionAddress, transaction: {input: collection.bytecode.object}, additionalContracts: []},
    ]};
    const path = `${directory}/broadcast.json`;
    writeFileSync(path, JSON.stringify(broadcast));
    const links = {};
    for (const name of ["CoreVaultLogic", "CoreVaultTransitLogic", "CoreVaultIncomeLogic", "CoreVaultIncomeCollectionLogic", "CoreVaultPayoutLogic"]) links[`src/core/${name}.sol:${name}`] = address;
    for (const name of ["SpokeCrossChainLib", "SpokeUnwindLib", "SpokeIncomeLib"]) links[`src/spoke/${name}.sol:${name}`] = address;
    const result = spawnSync(process.execPath, ["script/alpha-verification.mjs", path], {encoding: "utf8", env: {...process.env, ALPHA_LIBRARIES: JSON.stringify(links)}});
    assert.equal(result.status, 0, result.stderr);
    const records = JSON.parse(result.stdout);
    assert.equal(records.length, 2);
    assert.equal(records[0].contract, "src/core/ManagerFeeVault.sol:ManagerFeeVault");
    assert.equal(records[0].constructorArgs, `0x${args}`);
    assert.deepEqual(records[0].libraries, []);
    assert.equal(records[1].contract, "src/core/CoreVaultIncomeCollectionLogic.sol:CoreVaultIncomeCollectionLogic");
    assert.equal(records[1].address, collectionAddress);
    assert.equal(records[1].constructorArgs, "0x");
    const missing = spawnSync(process.execPath, ["script/alpha-verification.mjs", path], {encoding: "utf8", env: {...process.env, ALPHA_LIBRARIES: "{}"}});
    assert.notEqual(missing.status, 0);
    assert.match(missing.stderr, /Supply ALPHA_LIBRARIES entry/);
  } finally {rmSync(directory, {recursive: true, force: true});}
});
