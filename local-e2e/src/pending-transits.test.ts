import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { PendingTransits } from "./pending-transits.ts";

const transit = { key: "core:transit", coreVault: "core", spokeVault: "spoke", receiver: "receiver", spokeIndex: 0, transitId: "transit" };

for (const failure of ["report before fill", "temporary ACK send failure", "temporary ACK delivery failure"] as const) {
  test(`${failure} resolves by polling without a new report, including restart and backoff`, async () => {
    const directory = mkdtempSync(join(tmpdir(), "pending-transits-"));
    try {
      let now = 0;
      const file = join(directory, "queue.json");
      let queue = new PendingTransits(file, "deployment", () => now);
      queue.add(transit);
      let credited = failure !== "report before fill";
      let failed = false;
      let published = 0;
      let delivered = 0;
      let attempts = 0;
      const attempt = async (entry: typeof transit & { acknowledgement?: unknown }) => {
        attempts++;
        if (!credited) return false;
        if (failure === "temporary ACK send failure" && !failed) {
          failed = true;
          throw new Error("RPC unavailable");
        }
        if (!entry.acknowledgement) {
          published++;
          entry.acknowledgement = { payload: "vaa", sequence: "1", timestamp: 1, nonce: 0, consistencyLevel: 200 };
          queue.save();
        }
        if (failure === "temporary ACK delivery failure" && !failed) {
          failed = true;
          throw new Error("spoke unavailable");
        }
        delivered++;
        return true;
      };
      await queue.drain(attempt, () => {});
      assert.equal(queue.entries.size, 1);
      queue = new PendingTransits(file, "deployment", () => now);
      await queue.drain(attempt, () => assert.fail());
      assert.equal(attempts, 1);
      credited = true;
      now = 500;
      await queue.drain(attempt, () => assert.fail());
      assert.equal(queue.entries.size, 0);
      assert.equal(published, 1);
      assert.equal(delivered, 1);
      queue = new PendingTransits(file, "deployment", () => now);
      queue.add(transit);
      assert.equal(queue.entries.size, 0);
      assert.equal(new PendingTransits(file, "new deployment").entries.size, 0);
    } finally {
      rmSync(directory, { recursive: true });
    }
  });
}

test("unresolved transits have capped backoff but no retry limit", async () => {
  const directory = mkdtempSync(join(tmpdir(), "pending-transits-"));
  try {
    let now = 0;
    const queue = new PendingTransits(join(directory, "queue.json"), "deployment", () => now);
    queue.add(transit);
    for (let attempt = 0; attempt < 20; attempt++) {
      await queue.drain(async () => false, () => assert.fail());
      const entry = queue.entries.get(transit.key)!;
      assert.ok(entry.nextAttemptAt - now <= 30_000);
      now = entry.nextAttemptAt;
    }
    assert.equal(queue.entries.get(transit.key)!.attempts, 20);
    await queue.drain(async () => true, () => assert.fail());
    assert.equal(queue.entries.size, 0);
  } finally {
    rmSync(directory, { recursive: true });
  }
});
