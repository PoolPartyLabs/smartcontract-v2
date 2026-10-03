import {test} from "node:test";
import assert from "node:assert/strict";
import {mkdtempSync, writeFileSync, readFileSync, rmSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {spawnSync} from "node:child_process";

test("verification loop orders dependencies and fails closed on unknown/unverified records", () => {
  const directory = mkdtempSync(join(tmpdir(), "alpha-verification-"));
  try {
    const address = (index) => `0x${index.toString(16).padStart(40, "0")}`;
    const records = Array.from({length: 11}, (_, index) => ({address: address(index + 1), contract: `src/Example.sol:Example${index}`, constructorArgs: "0x1234", libraries: index ? [`src/Example.sol:Example0:${address(1)}`] : []})).reverse();
    const inventory = join(directory, "inventory.json");
    const calls = join(directory, "calls");
    writeFileSync(inventory, JSON.stringify(records));
    writeFileSync(join(directory, "forge"), '#!/usr/bin/env bash\nprintf "%s\\n" "$3" >> "$CALLS"\nif [[ "$FAIL_VERIFY" == 1 ]]; then echo "Submitted GUID only"; else echo "Contract successfully verified"; fi\n', {mode: 0o700});
    const env = {...process.env, PATH: `${directory}:${process.env.PATH}`, CALLS: calls};
    const run = (extra = {}) => spawnSync(process.execPath, ["script/alpha-verify-all.mjs", "4663", inventory, join(directory, "receipts")], {env: {...env, ...extra}, encoding: "utf8"});
    assert.equal(run().status, 0);
    assert.equal(readFileSync(calls, "utf8").split("\n")[0], "src/Example.sol:Example0");
    assert.equal(JSON.parse(readFileSync(join(directory, "receipts/coverage.json"))).verified.length, 11);
    assert.notEqual(run({FAIL_VERIFY: "1"}).status, 0);
    writeFileSync(inventory, JSON.stringify([...records, {address: address(12), kind: "Unknown executable; verification required"}]));
    assert.notEqual(run().status, 0);
  } finally {rmSync(directory, {recursive: true, force: true});}
});
