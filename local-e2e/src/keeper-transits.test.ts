import assert from "node:assert/strict";
import {mkdtempSync, rmSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {test} from "node:test";
import {createKeeperTransitRetry, queueReportTransits} from "./keeper-transits.ts";
import {PendingTransits} from "./pending-transits.ts";

test("harness queues Principal and Income and confirms ACK on the spoke after restart", async () => {
  const directory = mkdtempSync(join(tmpdir(), "keeper-transits-"));
  try {
    let now = 0, state = 1, calls = 0;
    const file = join(directory, "queue.json");
    let queue = new PendingTransits(file, "deployment", () => now);
    const entries = [{transitId: "principal", kind: 0}, {transitId: "income", kind: 1}];
    queueReportTransits({inFlightToHub: entries}, (transitId) => queue.add({key: transitId, transitId, coreVault: "core", spokeVault: "spoke", receiver: "receiver", spokeIndex: 0}));
    assert.equal(queue.entries.size, 2);
    const retry = createKeeperTransitRetry({
      state: async () => state,
      acknowledge: async () => {
        calls++;
        if (now === 0) throw new Error("ACK delivery unavailable");
      },
    });
    await queue.drain(retry, () => {});
    queue = new PendingTransits(file, "deployment", () => now);
    now = 500;
    await queue.drain(retry, () => assert.fail());
    assert.equal(queue.entries.size, 2, "successful delivery without state confirmation stays durable");
    state = 3;
    now = 1500;
    await queue.drain(retry, () => assert.fail());
    assert.equal(queue.entries.size, 2, "expiry attestation is not a recognized refund");
    state = 2;
    now = 3500;
    await queue.drain(retry, () => assert.fail());
    assert.equal(queue.entries.size, 0);
    assert.equal(calls, 6);
    assert.equal(new PendingTransits(file, "deployment").entries.size, 0);
  } finally {
    rmSync(directory, {recursive: true});
  }
});

test("harness confirms shared slot reuse over 130 Income sends", async () => {
  const slots = new Set<string>();
  const states = new Map<string, number>();
  let calls = 0;
  const retry = createKeeperTransitRetry({
    state: async (entry) => states.get(entry.transitId)!,
    acknowledge: async (entry) => {
      calls++;
      states.set(entry.transitId, 2);
      slots.delete(entry.transitId);
    },
  });
  for (let index = 0; index < 130; index++) {
    assert.ok(slots.size < 64);
    const transitId = String(index);
    queueReportTransits({inFlightToHub: [{transitId}]}, (identifier) => slots.add(identifier));
    states.set(transitId, 1);
    assert.equal(await retry({key: transitId, transitId, coreVault: "core", spokeVault: "spoke", receiver: "receiver", spokeIndex: 0, attempts: 0, nextAttemptAt: 0}), true);
    assert.equal(slots.size, 0);
  }
  assert.equal(calls, 130);
});

test("harness completes recognized refunds without ACK publication", async () => {
  const retry = createKeeperTransitRetry({state: async () => 4, acknowledge: async () => assert.fail()});
  assert.equal(await retry({key: "refund", transitId: "refund", coreVault: "core", spokeVault: "spoke", receiver: "receiver", spokeIndex: 0, attempts: 0, nextAttemptAt: 0}), true);
});
