import assert from "node:assert/strict";
import { nodes } from "../src/chain.ts";
import { runScenario } from "../src/scenario.ts";

const simulate = nodes.arbitrum.client.simulateContract.bind(nodes.arbitrum.client);
let acknowledgementSimulations = 0;
let injectedFailures = 0;
nodes.arbitrum.client.simulateContract = (async (call: any) => {
  if (call.functionName === "acknowledgeSpokeTransit") {
    const result = await simulate(call);
    acknowledgementSimulations++;
    if (acknowledgementSimulations === 2) {
      injectedFailures++;
      throw new Error("Synthetic temporary ACK-send RPC failure after successful preflight");
    }
    return result;
  }
  return simulate(call);
}) as typeof nodes.arbitrum.client.simulateContract;

try {
  assert.ok(Number(process.env.KEEPER_FILL_DELAY_SECONDS) > Number(process.env.KEEPER_VAA_DELAY_SECONDS), "Run with fill delay greater than report delivery delay");
  const result = await runScenario({ keeper: "inprocess", newFund: true, quiet: false, report: true });
  assert.equal(injectedFailures, 1);
  assert.ok(acknowledgementSimulations > 2, "ACK publication retries without requiring a newer report");
  console.log(`PASS recovery scenario: ${result.steps} steps / ${result.assertions} assertions; one injected ACK-send failure; delayed fills`);
} finally {
  nodes.arbitrum.client.simulateContract = simulate;
}
