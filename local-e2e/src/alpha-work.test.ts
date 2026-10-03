import assert from "node:assert/strict";
import {test} from "node:test";
import {collectAllowed, drainAlphaWork, type AlphaWork} from "./alpha-work.ts";

test("durable transit queue survives a late fill, restart and temporary acknowledgement failure", async () => {
  let cursor = {work: [{transitId: "0x01", kind: 0, expected: "4966000", attempts: 0, retryAt: 0}] as AlphaWork[]};
  let disk = "";
  let filled = false, failures = 1, calls = 0;
  const resolve = async () => {
    calls++;
    if (!filled) return false;
    if (failures-- > 0) throw new Error("temporary send failure");
    return true;
  };
  const save = () => {disk = JSON.stringify(cursor);};
  await drainAlphaWork(cursor, resolve, save, 1000);
  cursor = JSON.parse(disk);
  filled = true;
  await drainAlphaWork(cursor, resolve, save, 2000);
  assert.equal(calls, 1);
  await drainAlphaWork(cursor, resolve, save, 3000);
  assert.equal(cursor.work.length, 1);
  cursor = JSON.parse(disk);
  await drainAlphaWork(cursor, resolve, save, 7000);
  assert.equal(calls, 3);
  assert.deepEqual(JSON.parse(disk).work, []);
});

test("COLLECT gate retains dust and requires positive adapter output", () => {
  assert.equal(collectAllowed(499999n, 500000n, 450000n), false);
  assert.equal(collectAllowed(500000n, 500000n, 0n), false);
  assert.equal(collectAllowed(500000n, 500000n, 465999n), true);
});
