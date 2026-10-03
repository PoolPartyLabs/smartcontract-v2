import {discoverBalanceLayout, setTokenBalance} from "./fund-accounts.ts";
import {overrideGuardianSet, guardianSetIndexOf, signVaa, universal} from "./guardian.ts";
import {logger} from "./log.ts";
import {send, read, nodes} from "./chain.ts";
import {spokeVaultAbi, coreVaultAbi, valueReportReceiverAbi, wormholeCoreAbi} from "./abis.ts";
import {ARBITRUM, ROBINHOOD, actors} from "./config.ts";
import {decodeEventLog, getAddress} from "viem";
import {spawn} from "node:child_process";
import {once} from "node:events";
import {existsSync, readFileSync} from "node:fs";
import {ACTOR_KEYS} from "./config.ts";
import {alphaAmounts} from "./alpha-amounts.ts";

for (const side of ["arbitrum", "robinhood"] as const) {
  const version = await nodes[side].client.request({method: "web3_clientVersion"});
  if (!version.toLowerCase().includes("anvil")) throw new Error("Rehearsal requires two local Anvil nodes");
  const url = new URL(nodes[side].rpc);
  if (url.hostname !== "127.0.0.1") throw new Error("Rehearsal only uses loopback");
}

if (process.argv[2] === "fund") {
  const layout = await discoverBalanceLayout("arbitrum", ARBITRUM.usdc, actors.manager.address);
  await setTokenBalance("arbitrum", layout, actors.manager.address, 2n * BigInt(process.env.SEED_AMOUNT ?? "5000000") + alphaAmounts.deposit);
  console.log("Funded throwaway manager for two alpha seeds and the parameterized deposit; balance slot", layout.mappingSlot);
} else if (process.argv[2] === "smoke") {
  const core = getAddress(process.env.ALPHA_CORE_VAULT!);
  const spoke = getAddress(process.env.ALPHA_SPOKE_VAULT!);
  const receiver = getAddress(process.env.ALPHA_REPORT_RECEIVER!);
  await overrideGuardianSet(logger("alpha-smoke"), "arbitrum");
  await overrideGuardianSet(logger("alpha-smoke"), "robinhood");
  const fee = await read<bigint>("robinhood", {address: ROBINHOOD.wormholeCore, abi: wormholeCoreAbi, functionName: "messageFee"});
  const sent = await send("robinhood", "keeper", {address: spoke, abi: spokeVaultAbi, functionName: "report", value: fee});
  const log = sent.receipt.logs.find((entry) => entry.address.toLowerCase() === ROBINHOOD.wormholeCore.toLowerCase())!;
  const event = decodeEventLog({abi: wormholeCoreAbi, ...log}) as any;
  const block = await nodes.robinhood.client.getBlock({blockNumber: sent.receipt.blockNumber});
  const vaa = await signVaa({timestamp: Number(block.timestamp), nonce: event.args.nonce, emitterChainId: 72, emitterAddress: universal(spoke), sequence: event.args.sequence, consistencyLevel: event.args.consistencyLevel, payload: event.args.payload}, await guardianSetIndexOf("arbitrum"));
  const delivered = await send("arbitrum", "keeper", {address: receiver, abi: valueReportReceiverAbi, functionName: "deliver", args: [vaa]});
  console.log("Report publication/delivery", sent.hash, delivered.hash);
  const paid = await send("arbitrum", "manager", {address: core, abi: coreVaultAbi, functionName: "requestPayout", args: [1000000n, 0, 100]});
  console.log("Instant Payout 1 USDC", paid.hash, "gas", paid.receipt.gasUsed.toString());
  console.log("Idle", (await read<bigint>("arbitrum", {address: core, abi: coreVaultAbi, functionName: "idle"})).toString());
} else if (process.argv[2] === "runtime") {
  const port = Number(process.env.ALPHA_API_PORT ?? "18787");
  const environment = {
    ...process.env,
    ARBITRUM_RPC_URL: nodes.arbitrum.rpc,
    ROBINHOOD_RPC_URL: nodes.robinhood.rpc,
    ALPHA_ALLOW_LOCAL_TEST_KEYS: "1",
    ALPHA_API_SIGNER_KEY: ACTOR_KEYS.apiSigner,
    ALPHA_KEEPER_KEY: ACTOR_KEYS.keeper,
    ALPHA_API_TOKEN: "local-rehearsal-only",
    ALPHA_API_PORT: port.toString(),
    ALPHA_HUB_START_BLOCK: (await nodes.arbitrum.client.getBlockNumber()).toString(),
    ALPHA_SPOKE_START_BLOCK: (await nodes.robinhood.client.getBlockNumber()).toString(),
    ALPHA_STATE_FILE: `${process.env.ALPHA_REHEARSAL_STATE}/cursor-${Date.now()}.json`,
    ALPHA_POLL_MS: "1000",
  };
  const children: ReturnType<typeof spawn>[] = [];
  try {
    const api = spawn(process.execPath, ["--import", "tsx", "src/alpha.ts", "api"], {env: environment, stdio: "ignore"});
    children.push(api);
    for (let attempt = 0; attempt < 60; attempt++) {
      if (api.exitCode !== null) throw new Error("Alpha API startup failed");
      try {await fetch(`http://127.0.0.1:${port}`); break;} catch {await new Promise((done) => setTimeout(done, 100));}
    }
    const unauthenticated = await fetch(`http://127.0.0.1:${port}/swap-route`, {method: "POST"});
    if (unauthenticated.status !== 401) throw new Error("Unauthenticated request accepted");
    let checks = 1;
    for (const [side, tokenIn, tokenOut] of [["hub", ARBITRUM.usdc, ARBITRUM.weth], ["spoke", ROBINHOOD.usdg, ROBINHOOD.weth]]) {
      for (const maxLossBps of [100, 0]) {
        const response = await fetch(`http://127.0.0.1:${port}/swap-route`, {method: "POST", headers: {authorization: "Bearer local-rehearsal-only"}, body: JSON.stringify({side, tokenIn, tokenOut, amountIn: "1000000", maxLossBps})});
        if (maxLossBps === 0) {
          if (response.status !== 503) throw new Error("Unbounded loss accepted");
        } else {
          if (response.status !== 200) throw new Error("Signed route failed");
          const route = await response.json() as {route: string; minAmountOut: string};
          if (!route.route.startsWith("0x") || BigInt(route.minAmountOut) <= 0n) throw new Error("Empty route");
        }
        checks++;
      }
    }
    console.log(`Alpha API: ${checks} checks passed (401, two-chain signed routes, zero-loss refusal)`);
    const keeper = spawn(process.execPath, ["--import", "tsx", "src/alpha.ts", "keeper"], {env: environment, stdio: "ignore"});
    children.push(keeper);
    for (let attempt = 0; attempt < 200 && !existsSync(environment.ALPHA_STATE_FILE); attempt++) {
      if (keeper.exitCode !== null) throw new Error("Alpha keeper startup failed");
      await new Promise((done) => setTimeout(done, 100));
    }
    const cursor = JSON.parse(readFileSync(environment.ALPHA_STATE_FILE, "utf8"));
    if (!cursor.lastReport || cursor.core.toLowerCase() !== process.env.ALPHA_CORE_VAULT!.toLowerCase()) throw new Error("Keeper did not publish/persist");
    console.log("Alpha keeper: funded startup, report publication and durable cursor passed; external VAA delivery not simulated");
  } finally {
    for (const child of children) {
      if (child.exitCode === null) {child.kill("SIGTERM"); await once(child, "exit");}
    }
  }
} else {throw new Error("Use alpha-rehearsal.ts fund|smoke|runtime");}
