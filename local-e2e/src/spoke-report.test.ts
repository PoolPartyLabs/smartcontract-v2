import assert from "node:assert/strict";
import {test} from "node:test";
import {encodeAbiParameters, keccak256, toHex} from "viem";
import {SPOKE_REPORT_TUPLE, SPOKE_REPORT_VERSION, decodeSpokeReport} from "./spoke-report.ts";

const transitId = keccak256(toHex("manual-refund"));
const report = {
  fundId: transitId, mandateHash: transitId, sequence: 7n, spokeChainId: 4663n, blockNumber: 123n, timestamp: 456n,
  unallocated: [], positions: [], cumulativeIncome: [], collectedIncome: [], operatingCash: 0n,
  cumulativeReceived: 5000000n, cumulativeSentHome: 1000000n, arrivedTransits: [],
  inFlightToHub: [{transitId, amount: 966000n, kind: 0}], unwindResults: "0x", collectionResults: "0x",
  refundedTransits: [transitId],
};

test("v5 report preserves manual transit and authenticated refund proof", () => {
  const payload = encodeAbiParameters([{type: "uint256"}, SPOKE_REPORT_TUPLE], [SPOKE_REPORT_VERSION, report]);
  const decoded = decodeSpokeReport(payload);
  assert.deepEqual(decoded, report);
});

test("report decoder rejects obsolete versions and malformed v5 payloads", () => {
  assert.throws(() => decodeSpokeReport(encodeAbiParameters([{type: "uint256"}], [4n])), /Unsupported spoke report version: 4/);
  assert.throws(() => decodeSpokeReport(encodeAbiParameters([{type: "uint256"}], [5n])));
  assert.throws(() => decodeSpokeReport("0x"));
});
