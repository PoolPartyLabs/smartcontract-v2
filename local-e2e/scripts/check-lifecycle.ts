import assert from "node:assert/strict";
import { decodeFunctionData, encodeAbiParameters } from "viem";
import { coreVaultAbi } from "../src/abis.ts";
import { buildClaim, buildRequest } from "../src/api.ts";
import { actors } from "../src/config.ts";
import { decodeOrder, encodeOrder, orderId, ORDER_KIND, type Order } from "../src/orders.ts";
import type { DeploymentState } from "../src/state.ts";

const state = { fund: { hub: { coreVault: actors.manager.address } } } as DeploymentState;
let assertions = 0;
for (const mode of ["instant", "standard"] as const) {
  for (const maximum of [0, 37, 10_000]) {
    const [transaction] = buildRequest(state, 100_000_000n, mode, maximum);
    const decoded = decodeFunctionData({ abi: coreVaultAbi, data: transaction.data });
    assert.deepEqual(decoded.args, [100_000_000n, mode === "instant" ? 0 : 1, maximum]);
    assertions++;
  }
}
for (const maximum of [-1, 10_001, 1.5, NaN]) {
  assert.throws(() => buildRequest(state, 1n, "instant", maximum));
  assertions++;
}
const [claim] = await buildClaim(state, 42);
assert.deepEqual(decodeFunctionData({ abi: coreVaultAbi, data: claim.data }).args, [42]);
assertions++;
for (const kind of Object.values(ORDER_KIND)) {
  const order: Order = { kind, fundId: `0x${"11".repeat(32)}`, requestId: `0x${"22".repeat(32)}`, attempt: 1, deadline: 123n, fracNum: 1n, fracDen: 1n, maxLossBps: 37, payoutMode: 1, closingStartedAt: kind === ORDER_KIND.CLOSE ? 100n : 0n };
  assert.deepEqual(decodeOrder(encodeOrder(order)), order);
  const independent = encodeAbiParameters([{ type: "uint256" }, { type: "uint8" }, { type: "bytes32" }, { type: "bytes32" }, { type: "uint32" }, { type: "uint64" }, { type: "uint256" }, { type: "uint256" }, { type: "uint16" }, { type: "uint8" }, { type: "uint64" }], [1n, kind, order.fundId, order.requestId, 1, 123n, 1n, 1n, 37, 1, order.closingStartedAt]);
  assert.equal(encodeOrder(order), independent);
  assert.notEqual(orderId(order), orderId({ ...order, attempt: 2 }));
  assertions += 3;
}
assert.equal(decodeOrder("0x"), undefined);
assertions++;
console.log(`PASS: ${assertions} lifecycle builder and Solidity order-layout assertions`);
