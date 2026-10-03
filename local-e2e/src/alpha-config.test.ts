import assert from "node:assert/strict";
import {execFileSync} from "node:child_process";
import test from "node:test";

function addresses(shared: boolean): Record<string, string> {
  const result = execFileSync(process.execPath, ["--import", "tsx", "--input-type=module", "-e",
    'import {actors} from "./src/config.ts"; console.log(JSON.stringify(Object.fromEntries(Object.entries(actors).map(([name, actor]) => [name, actor.address]))))'],
    {encoding: "utf8", env: {...process.env, ALPHA_REHEARSAL_SAME_ROLES: shared ? "1" : "0"}});
  return JSON.parse(result);
}

test("alpha rehearsal shares every operational role but keeps the investor separate", () => {
  const shared = addresses(true);
  for (const role of ["manager", "keeper", "apiSigner", "protocolRecipient"]) assert.equal(shared[role], shared.operator);
  assert.notEqual(shared.ana, shared.operator);
});

test("ordinary harness actors remain distinct when alpha shared roles are disabled", () => {
  const ordinary = addresses(false);
  assert.equal(new Set(Object.values(ordinary)).size, Object.keys(ordinary).length);
});
