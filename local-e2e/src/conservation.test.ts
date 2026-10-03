import assert from "node:assert/strict";
import { test } from "node:test";
import { conservationResult, ExplainedFlows } from "./conservation.ts";

test("an unrelated 10 USDC outflow cannot become Market Costs and fails conservation", () => {
  const book = new ExplainedFlows();
  const amount = 10_000_000n;
  assert.equal(book.match({ transaction: "unrelated", token: "USDC", sender: "vault", receiver: "unknown", amount }), undefined);
  assert.deepEqual(conservationResult(100_000_000n, 0n, 0n, 90_000_000n, amount), { residual: amount, tolerance: 20n, passed: false });
});

test("a legitimate market transaction cannot explain another recipient, amount, token or transaction", () => {
  const book = new ExplainedFlows();
  const flow = { transaction: "swap", token: "USDC", sender: "vault", receiver: "adapter", amount: 10_000_000n };
  book.add({ ...flow, cause: "market", event: "Swapped" });
  for (const invalid of [{ receiver: "unknown" }, { transaction: "unrelated" }, { token: "WETH" }, { amount: flow.amount + 1n }]) assert.equal(book.match({ ...flow, ...invalid }), undefined);
  assert.deepEqual(book.match(flow), { cause: "market", event: "Swapped" });
  assert.equal(book.match(flow), undefined);
  assert.equal(conservationResult(100_000_000n - flow.amount, 0n, 0n, 90_000_000n, 0n).passed, true);
});

test("even sub-tolerance unexplained flows fail", () => {
  assert.equal(conservationResult(100n, 0n, 0n, 99n, 1n).passed, false);
});
