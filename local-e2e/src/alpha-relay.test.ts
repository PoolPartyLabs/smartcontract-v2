import assert from "node:assert/strict";
import {test} from "node:test";
import {createPublicClient, custom, encodeErrorResult, encodeFunctionResult, type Abi, type Address} from "viem";
import {orderChannelAbi} from "./abis.ts";
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

function orderFixture() {
  const state = {minSequence: 1n, attempts: [] as bigint[], executions: [] as bigint[], expired: false};
  let currentSequence = 0n;
  const client = createPublicClient({transport: custom({
    request: async ({method}) => {
      assert.equal(method, "eth_call");
      if (currentSequence < state.minSequence || state.expired) {
        const data = state.expired
          ? encodeErrorResult({abi: orderChannelAbi, errorName: "OrderExpired", args: [1n]})
          : encodeErrorResult({abi: orderChannelAbi, errorName: "OrderSequenceTooLow", args: [state.minSequence, currentSequence]});
        throw {code: 3, message: "execution reverted", data};
      }
      return encodeFunctionResult({abi: orderChannelAbi, functionName: "executeOrder", result: 0n});
    },
  }, {retryCount: 0})});
  const deliver = createAlphaDelivery({
    sides: {hub: {wormhole: 23, emitter: core}, spoke: {wormhole: 72, emitter: spoke}},
    bridges: {hub: core, spoke}, receiver, spoke, vaaBase: "https://vaa.example.invalid",
    fetchVaa: async (url) => Response.json({data: {vaa: Buffer.from(String(url).split("/").at(-1)!).toString("base64")}}),
    read: async (side, address, functionName, args) => {
      assert.equal(side, "spoke");
      assert.equal(address, spoke);
      if (functionName === "parseAndVerifyVM") {
        currentSequence = BigInt(Buffer.from(String(args[0]).slice(2), "hex").toString());
        return [{emitterChainId: 23, emitterAddress: `0x${core.slice(2).padStart(64, "0")}`, sequence: currentSequence, payload: "0x1234"}, true];
      }
      assert.equal(functionName, "messageFee");
      return 1n;
    },
    send: async (side, address, abi, functionName, args, value) => {
      assert.equal(side, "spoke");
      assert.equal(address, spoke);
      assert.equal(functionName, "executeOrder");
      state.attempts.push(currentSequence);
      await client.simulateContract({account: core, address, abi, functionName, args, value});
      state.minSequence = currentSequence + 1n;
      state.executions.push(currentSequence);
      return {status: "success"};
    },
  });
  return {state, deliver};
}

const firstOrder: AlphaMessage = {side: "hub", sequence: "1", payload: "0x1234"};
const nextOrder: AlphaMessage = {...firstOrder, sequence: "2"};

test("keeper decodes an externally executed order and continues to later messages", async () => {
  const {state, deliver} = orderFixture();
  state.minSequence = 2n;
  const cursor = {pending: [firstOrder, nextOrder]};
  const saved: string[] = [];
  await drainAlphaPending(cursor, deliver, () => saved.push(JSON.stringify(cursor)), () => assert.fail("Unexpected relay error"));
  assert.deepEqual(state.attempts, [1n, 2n]);
  assert.deepEqual(state.executions, [2n]);
  assert.deepEqual(JSON.parse(saved[0]!).pending, [nextOrder]);
  assert.deepEqual(JSON.parse(saved[1]!).pending, []);
});

test("restart removes an executed order left on disk after a persistence failure", async () => {
  const {state, deliver} = orderFixture();
  const cursor = {pending: [firstOrder, nextOrder]};
  let disk = JSON.stringify(cursor);
  let failures = 0;
  await drainAlphaPending(cursor, deliver, () => {throw new Error("Persistence interrupted");}, () => failures++);
  assert.equal(failures, 2);
  assert.deepEqual(state.executions, [1n, 2n]);
  const restarted = JSON.parse(disk) as {pending: AlphaMessage[]};
  await drainAlphaPending(restarted, deliver, () => {disk = JSON.stringify(restarted);}, () => assert.fail("Unexpected replay error"));
  assert.deepEqual(state.attempts, [1n, 2n, 1n, 2n]);
  assert.deepEqual(state.executions, [1n, 2n]);
  assert.deepEqual(JSON.parse(disk).pending, []);
});

test("other decoded order errors remain pending instead of being treated as executed", async () => {
  const {state, deliver} = orderFixture();
  state.expired = true;
  const cursor = {pending: [firstOrder]};
  let failures = 0;
  await drainAlphaPending(cursor, deliver, () => assert.fail("Failed order must not be persisted as delivered"), () => failures++);
  assert.equal(failures, 1);
  assert.deepEqual(cursor.pending, [firstOrder]);
  assert.deepEqual(state.executions, []);
});
