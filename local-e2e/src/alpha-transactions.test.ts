import assert from "node:assert/strict";
import {mkdtempSync, readFileSync, rmSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {test} from "node:test";
import {type TransactionReceipt, type Hex} from "viem";
import {AlphaTransactions, reconcileAlphaTransactions, sendAlphaTransaction} from "./alpha-transactions.ts";

const hash: Hex = `0x${"ab".repeat(32)}`;
const details = {mode: "capital", side: "hub", address: `0x${"11".repeat(20)}` as Hex, functionName: "sendToSpoke"};
const receipt = (status: "success" | "reverted") => ({transactionHash: hash, status, gasUsed: 123n, blockNumber: 456n}) as TransactionReceipt;

test("broadcast hash is on disk before polling; outage survives restart and read-only reconciliation", async () => {
  const directory = mkdtempSync(join(tmpdir(), "alpha-transactions-"));
  try {
    const path = join(directory, "state.jsonl");
    let broadcasts = 0;
    const store = new AlphaTransactions(path);
    await assert.rejects(sendAlphaTransaction(store, details, async () => {broadcasts++; return hash;}, async (submittedHash) => {
      assert.equal(submittedHash, hash);
      const saved = JSON.parse(readFileSync(path, "utf8").trim());
      assert.equal(saved.hash, hash);
      assert.equal(saved.status, "submitted");
      throw new Error("post-broadcast RPC outage");
    }), /RPC outage/);
    const restarted = new AlphaTransactions(path);
    assert.equal(restarted.transactions.get(hash)?.status, "submitted");
    assert.equal(restarted.transactions.get(hash)?.receiptOutcome, "unknown");
    assert.throws(() => restarted.assertFreshMode("capital"), /reconcile/);
    assert.throws(() => restarted.assertFreshMode("income"), /reconcile/);
    await reconcileAlphaTransactions(restarted, async (entry) => {
      assert.equal(entry.hash, hash);
      throw new Error("still unavailable");
    });
    assert.equal(new AlphaTransactions(path).transactions.get(hash)?.status, "submitted");
    await reconcileAlphaTransactions(restarted, async () => receipt("success"));
    assert.equal(new AlphaTransactions(path).transactions.get(hash)?.status, "success");
    assert.throws(() => restarted.assertFreshMode("capital"), /never resubmit/);
    assert.equal(broadcasts, 1);
  } finally {rmSync(directory, {recursive: true, force: true});}
});

test("reverted receipt is durable before rejection, including reconciliation after an outage", async () => {
  const directory = mkdtempSync(join(tmpdir(), "alpha-transactions-"));
  try {
    const path = join(directory, "state.jsonl");
    const store = new AlphaTransactions(path);
    await assert.rejects(sendAlphaTransaction(store, details, async () => hash, async () => receipt("reverted")), /reverted/);
    assert.equal(new AlphaTransactions(path).transactions.get(hash)?.status, "reverted");
    store.save({...details, hash, status: "submitted"});
    await reconcileAlphaTransactions(store, async () => receipt("reverted"));
    const saved = new AlphaTransactions(path).transactions.get(hash)!;
    assert.equal(saved.status, "reverted");
    assert.equal(saved.gasUsed, "123");
    assert.equal(saved.blockNumber, "456");
    assert.throws(() => store.assertFreshMode("capital"), /reconcile/);
  } finally {rmSync(directory, {recursive: true, force: true});}
});

test("successful receipts are durable and corrupt state fails closed", async () => {
  const directory = mkdtempSync(join(tmpdir(), "alpha-transactions-"));
  try {
    const path = join(directory, "state.jsonl");
    const store = new AlphaTransactions(path);
    assert.equal((await sendAlphaTransaction(store, details, async () => hash, async () => receipt("success"))).status, "success");
    assert.equal(new AlphaTransactions(path).transactions.get(hash)?.status, "success");
    let queries = 0;
    await reconcileAlphaTransactions(store, async () => {queries++; return receipt("success");});
    assert.equal(queries, 0);
    const {appendFileSync} = await import("node:fs");
    appendFileSync(path, '{"hash":');
    assert.throws(() => new AlphaTransactions(path));
  } finally {rmSync(directory, {recursive: true, force: true});}
});
