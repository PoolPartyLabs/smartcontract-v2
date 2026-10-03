import assert from "node:assert/strict";
import test from "node:test";
import {alphaLogRange, logWindow, scanAlphaLogs} from "./alpha-logs.ts";

test("log range defaults to 1000 and rejects invalid configuration", () => {
  assert.equal(alphaLogRange(), 1000n);
  assert.equal(alphaLogRange("1"), 1n);
  assert.equal(alphaLogRange("10"), 10n);
  for (const value of ["0", "-1", "1.5", "NaN", "Infinity", "9007199254740992"]) {
    assert.throws(() => alphaLogRange(value), /ALPHA_LOG_RANGE/);
  }
});

test("inclusive windows respect the cap and finalized head", () => {
  assert.deepEqual(logWindow(100n, 200n, 10n), {fromBlock: 100n, toBlock: 109n});
  assert.deepEqual(logWindow(195n, 200n, 10n), {fromBlock: 195n, toBlock: 200n});
  assert.deepEqual(logWindow(200n, 200n, 1n), {fromBlock: 200n, toBlock: 200n});
  assert.equal(logWindow(201n, 200n, 10n), undefined);
  assert.throws(() => logWindow(0n, 1n, 0n));
});

test("mock clients catch up both chains in one tick with durable next-block cursors", async () => {
  const cursor = {hub: "100", spoke: "200"};
  const calls: unknown[] = [], disk: string[] = [];
  await scanAlphaLogs({sides: ["hub", "spoke"], cursor, range: 10n, deadline: 20000, now: () => 0,
    head: async (side) => side === "hub" ? 124n : 211n,
    scan: async (side, window) => {calls.push([side, window]);}, save: () => {disk.push(JSON.stringify(cursor));}});
  assert.equal(calls.length, 5);
  assert.deepEqual(calls.slice(0, 2), [["hub", {fromBlock: 100n, toBlock: 109n}], ["spoke", {fromBlock: 200n, toBlock: 209n}]]);
  assert.deepEqual(JSON.parse(disk.at(-1)!), {hub: "125", spoke: "212"});
});

test("time budget stops catch-up and failed windows do not advance persisted cursors", async () => {
  const cursor = {hub: "0"};
  let now = 0, disk = "";
  const dependencies = {sides: ["hub"] as const, cursor, range: 10n, deadline: 20, now: () => now,
    head: async () => 100n, scan: async () => {now += 10;}, save: () => {disk = JSON.stringify(cursor);}};
  await scanAlphaLogs(dependencies);
  assert.deepEqual(JSON.parse(disk), {hub: "20"});
  now = 0;
  await assert.rejects(scanAlphaLogs({...dependencies, scan: async () => {throw new Error("RPC unavailable");}}));
  assert.equal(cursor.hub, "20");
  assert.deepEqual(JSON.parse(disk), {hub: "20"});
});
