import assert from "node:assert/strict";
import {test} from "node:test";
import {collectAllowed, createAlphaTransitResolver, drainAlphaWork, type AlphaWork} from "./alpha-work.ts";

for (const kind of [0, 1]) {
  test(`runtime resolver retains kind ${kind} until spoke confirmation across ACK failure and restart`, async () => {
    let cursor = {work: [{transitId: "0x01", kind, expected: "100", attempts: 0, retryAt: 0}] as AlphaWork[]};
    let disk = "", now = 0, state = 1, credit = 99n, failures = 1, calls = 0;
    const save = () => {disk = JSON.stringify(cursor);};
    const resolver = () => createAlphaTransitResolver({
      state: async () => state,
      credited: async () => credit,
      acknowledge: async () => {
        calls++;
        if (failures-- > 0) throw new Error("ACK publication failed");
      },
      save, now: () => now,
    });
    await drainAlphaWork(cursor, resolver(), save, now);
    assert.equal(calls, 0);
    credit = 100n;
    now = 2000;
    await drainAlphaWork(cursor, resolver(), save, now);
    assert.equal(calls, 1);
    assert.equal(cursor.work.length, 1);
    cursor = JSON.parse(disk);
    now = 6000;
    await drainAlphaWork(cursor, resolver(), save, now);
    assert.equal(calls, 2);
    assert.equal(cursor.work.length, 1, "published ACK is not spoke confirmation");
    cursor = JSON.parse(disk);
    now = 14000;
    await drainAlphaWork(cursor, resolver(), save, now);
    assert.equal(calls, 2, "persisted ACK publication suppresses premature republication");
    now = 66000;
    await drainAlphaWork(cursor, resolver(), save, now);
    assert.equal(calls, 3, "undelivered ACK is republished after restart");
    state = 3;
    now = 98000;
    await drainAlphaWork(cursor, resolver(), save, now);
    assert.equal(cursor.work.length, 1, "expiry attestation alone does not release the slot");
    state = 2;
    now = 158000;
    await drainAlphaWork(cursor, resolver(), save, now);
    assert.deepEqual(JSON.parse(disk).work, []);
  });
}

test("runtime resolver frees shared slots for 130 credited COLLECT Income sends", async () => {
  const cursor = {work: [] as AlphaWork[]};
  const slots = new Set<string>();
  const states = new Map<string, number>();
  let acknowledgements = 0;
  const resolve = createAlphaTransitResolver({
    state: async (work) => states.get(work.transitId)!,
    credited: async () => 100n,
    acknowledge: async (work) => {
      acknowledgements++;
      states.set(work.transitId, 2);
      slots.delete(work.transitId);
    },
    save: () => {},
  });
  for (let index = 0; index < 130; index++) {
    assert.ok(slots.size < 64, "shared capacity must be available for the next send");
    const transitId = `0x${index.toString(16).padStart(64, "0")}` as const;
    slots.add(transitId);
    states.set(transitId, 1);
    cursor.work.push({transitId, kind: 1, expected: "100", attempts: 0, retryAt: 0});
    await drainAlphaWork(cursor, resolve, () => {}, index * 3000);
    assert.equal(cursor.work.length, 1);
    await drainAlphaWork(cursor, resolve, () => {}, index * 3000 + 2000);
    assert.equal(cursor.work.length, 0);
    assert.equal(slots.size, 0);
  }
  assert.equal(acknowledgements, 130);
});

test("runtime resolver completes locally recognized refunds without publishing ACKs", async () => {
  const resolve = createAlphaTransitResolver({
    state: async () => 4,
    credited: async () => assert.fail("refund needs no Hub credit"),
    acknowledge: async () => assert.fail("refund needs no ACK"),
    save: () => {},
  });
  assert.equal(await resolve({transitId: "0x01", kind: 1, expected: "100", attempts: 0, retryAt: 0}), true);
});

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
