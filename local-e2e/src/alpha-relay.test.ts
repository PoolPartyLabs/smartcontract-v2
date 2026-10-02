import assert from "node:assert/strict";
import {test} from "node:test";
import {type Abi, type Address} from "viem";
import {createAlphaDelivery, drainAlphaPending, type AlphaMessage} from "./alpha-relay.ts";

const core: Address = "0x0000000000000000000000000000000000000001";
const spoke: Address = "0x0000000000000000000000000000000000000002";
const receiver: Address = "0x0000000000000000000000000000000000000003";
const report: AlphaMessage = {side: "spoke", sequence: "0", payload: "0x1234"};

function fixture() {
  const state = {hasReport: false, sequence: 0n, available: true, sends: [] as string[], receipts: [] as {status: string}[]};
  const deliver = createAlphaDelivery({
    sides: {hub: {wormhole: 23, emitter: core}, spoke: {wormhole: 72, emitter: spoke}},
    bridges: {hub: core, spoke}, receiver, spoke, vaaBase: "https://vaa.example.invalid",
    fetchVaa: async () => state.available
      ? Response.json({data: {vaa: Buffer.from("vaa").toString("base64")}}) : new Response(null, {status: 404}),
    read: async (side, address, functionName) => {
      if (functionName === "parseAndVerifyVM") return [{emitterChainId: 72, emitterAddress: `0x${spoke.slice(2).padStart(64, "0")}`, sequence: 0n, payload: report.payload}, true];
      assert.equal(side, "hub");
      assert.equal(address, receiver);
      if (functionName === "hasReport") return state.hasReport;
      if (functionName === "lastWormholeSequence") return state.sequence;
      throw new Error("Unexpected read");
    },
    send: async (side, address, abi: Abi, functionName) => {
      assert.equal(side, "hub");
      assert.equal(address, receiver);
      assert.equal(functionName, "deliver");
      assert.ok(abi.some((entry) => entry.type === "function" && entry.name === "deliver"));
      state.sends.push(functionName);
      state.hasReport = true;
      state.receipts.push({status: "success"});
      return state.receipts.at(-1);
    },
  });
  return {state, deliver};
}

test("API delivery accepts sequence zero only after a successful receiver delivery", async () => {
  const {state, deliver} = fixture();
  assert.equal(await deliver(report), true);
  assert.equal(state.hasReport, true);
  assert.equal(state.sequence, 0n);
  assert.deepEqual(state.sends, ["deliver"]);
  assert.deepEqual(state.receipts, [{status: "success"}]);
  assert.equal(await deliver(report), true);
  assert.equal(state.sends.length, 1);
});

test("keeper retains the first report until VAA delivery succeeds and persists completion", async () => {
  const {state, deliver} = fixture();
  const cursor = {pending: [report]};
  const saved: string[] = [];
  const save = () => saved.push(JSON.stringify(cursor));
  const onError = () => assert.fail("Unexpected delivery error");
  state.available = false;
  await drainAlphaPending(cursor, deliver, save, onError);
  assert.deepEqual(cursor.pending, [report]);
  assert.equal(state.hasReport, false);
  assert.equal(saved.length, 0);
  state.available = true;
  await drainAlphaPending(cursor, deliver, save, onError);
  assert.equal(state.hasReport, true);
  assert.equal(state.sequence, 0n);
  assert.deepEqual(state.receipts, [{status: "success"}]);
  assert.deepEqual(JSON.parse(saved[0]!).pending, []);
});

test("keeper removes an already accepted sequence-zero report without a duplicate transaction", async () => {
  const {state, deliver} = fixture();
  state.hasReport = true;
  const cursor = {pending: [report]};
  let saves = 0;
  await drainAlphaPending(cursor, deliver, () => saves++, () => assert.fail("Unexpected delivery error"));
  assert.deepEqual(cursor.pending, []);
  assert.equal(saves, 1);
  assert.deepEqual(state.sends, []);
});
