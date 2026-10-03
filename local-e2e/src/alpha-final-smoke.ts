import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {once} from "node:events";
import {appendFileSync, readFileSync} from "node:fs";
import {decodeEventLog, encodeAbiParameters, getAddress, parseAbi, type Abi, type Address} from "viem";
import {nodes, send, read, anvil, wallet, runMain, type Side} from "./chain.ts";
import {coreVaultAbi, spokeVaultAbi, erc20Abi, acrossSpokePoolAbi, v4SwapRouterAbi, v4SwapRouterBytecode} from "./abis.ts";
import {ACTOR_KEYS, actors, ARBITRUM, ROBINHOOD, AAVE_USDC_POOL_KEY, SPOKE_POOL_ID, SPOKE_POOL_KEY} from "./config.ts";
import {overrideGuardianSet, universal} from "./guardian.ts";
import {discoverBalanceLayout, setTokenBalance} from "./fund-accounts.ts";
import {linkedArrival, type DepositEvent} from "./arrivals.ts";
import {restampFeed} from "./price-feed.ts";
import { safeConsole as console,logger} from "./log.ts";
import {centerTick, openParams, generateFees} from "./uniswap.ts";
import {alphaAmounts} from "./alpha-amounts.ts";

async function main() {
const core = getAddress(process.env.ALPHA_CORE_VAULT!);
const spoke = getAddress(process.env.ALPHA_SPOKE_VAULT!);
const state = process.env.ALPHA_REHEARSAL_STATE!;
const apiUrl = `http://127.0.0.1:${process.env.ALPHA_API_PORT ?? "18787"}`;
const evidence = `${state}/smoke.jsonl`;
const log = logger("alpha-final");
for (const side of ["arbitrum", "robinhood"] as const) {
  assert.equal(new URL(nodes[side].rpc).hostname, "127.0.0.1");
  assert.match(await nodes[side].client.request({method: "web3_clientVersion"}), /anvil/i);
  await overrideGuardianSet(log, side);
}

async function transaction(side: Side, address: Address, abi: Abi, functionName: string, args: unknown[] = [], value = 0n) {
  const result = await send(side, "manager", {address, abi, functionName, args, value} as never);
  appendFileSync(evidence, JSON.stringify({side, address, functionName, hash: result.hash, gasUsed: result.receipt.gasUsed.toString()}) + "\n");
  return result;
}

async function waitFor(check: () => Promise<boolean>, label: string) {
  for (let attempt = 0; attempt < 120; attempt++) {
    if (await check()) return;
    await new Promise((done) => setTimeout(done, 1000));
  }
  throw new Error(`Timed out: ${label}`);
}

async function fill(deposit: DepositEvent, origin: Side, vault: Address, abi: Abi, eventName: string) {
  const destination = origin === "arbitrum" ? "robinhood" : "arbitrum";
  const token = getAddress(`0x${deposit.outputToken.slice(-40)}`);
  const pool = destination === "arbitrum" ? ARBITRUM.acrossSpokePool : ROBINHOOD.acrossSpokePool;
  const layout = await discoverBalanceLayout(destination, token, actors.keeper.address);
  await setTokenBalance(destination, layout, actors.keeper.address, deposit.outputAmount + 1000000n);
  await send(destination, "keeper", {address: token, abi: erc20Abi, functionName: "approve", args: [pool, deposit.outputAmount]});
  const fromBlock = await nodes[destination].client.getBlockNumber();
  const result = await send(destination, "keeper", {address: pool, abi: acrossSpokePoolAbi, functionName: "fillRelay", args: [{...deposit, originChainId: BigInt(nodes[origin].chain.id)}, BigInt(nodes[destination].chain.id), universal(actors.keeper.address)]});
  const arrival = await linkedArrival(origin, deposit, vault, abi, eventName, fromBlock);
  assert.ok(arrival, "Arrival must be linked through FilledRelay, not just transit id");
  appendFileSync(evidence, JSON.stringify({functionName: "fillRelay", side: destination, hash: result.hash, outputAmount: deposit.outputAmount.toString(), arrival: arrival.arrival}, (_, value) => typeof value === "bigint" ? value.toString() : value) + "\n");
}

const environment = {
  ...process.env, ARBITRUM_RPC_URL: nodes.arbitrum.rpc, ROBINHOOD_RPC_URL: nodes.robinhood.rpc,
  ALPHA_ALLOW_LOCAL_TEST_KEYS: "1", ALPHA_REHEARSAL_LOCAL_VAA: "1",
  ALPHA_KEEPER_KEY: ACTOR_KEYS.keeper, ALPHA_API_SIGNER_KEY: ACTOR_KEYS.apiSigner,
  ALPHA_API_TOKEN: "local-rehearsal-only", ALPHA_API_PORT: process.env.ALPHA_API_PORT ?? "18787", ALPHA_POLL_MS: "1000", ALPHA_REPORT_SECONDS: "10",
  ALPHA_HUB_START_BLOCK: (await nodes.arbitrum.client.getBlockNumber()).toString(),
  ALPHA_SPOKE_START_BLOCK: (await nodes.robinhood.client.getBlockNumber()).toString(),
  ALPHA_STATE_FILE: `${state}/final-cursor-${Date.now()}.json`,
};
const children: ReturnType<typeof spawn>[] = [];
try {
  for (const mode of ["api", "keeper"]) {
    const child = spawn(process.execPath, ["--import", "tsx", "src/alpha.ts", mode], {env: environment, stdio: ["ignore", "pipe", "pipe"]});
    child.stdout!.on("data", (chunk) => appendFileSync(`${state}/runtime.log`, chunk));
    child.stderr!.on("data", (chunk) => appendFileSync(`${state}/runtime.log`, chunk));
    children.push(child);
  }
  await waitFor(async () => {
    assert.ok(children.every((child) => child.exitCode === null), "Runtime exited");
    try {return (await fetch(`${apiUrl}/report`, {method: "POST"})).status === 401;} catch {return false;}
  }, "API startup");
  async function report() {
    const response = await fetch(`${apiUrl}/report`, {method: "POST", headers: {authorization: "Bearer local-rehearsal-only"}});
    assert.equal(response.status, 200, "API must publish and deliver report");
    const result = await response.json() as any;
    assert.equal(result.delivered, true);
    assert.equal(result.reportVersion, "5", "Alpha API must decode the v5 report");
  }
  await report();
  if (process.argv[2] === "close") {
    const layout = await discoverBalanceLayout("arbitrum", ARBITRUM.usdc, actors.ana.address);
    await setTokenBalance("arbitrum", layout, actors.ana.address, alphaAmounts.investor);
    await send("arbitrum", "ana", {address: ARBITRUM.usdc, abi: erc20Abi, functionName: "approve", args: [core, alphaAmounts.investor]});
    const deposit = await send("arbitrum", "ana", {address: core, abi: coreVaultAbi, functionName: "deposit", args: [alphaAmounts.investor, 1n]});
    appendFileSync(evidence, JSON.stringify({functionName: "secondFundDeposit", hash: deposit.hash}) + "\n");
    await report();
    await transaction("arbitrum", core, coreVaultAbi, "closeFund");
    const deadline = await read<bigint>("arbitrum", {address: core, abi: coreVaultAbi, functionName: "closingDeadline"});
    for (const side of ["arbitrum", "robinhood"] as const) {
      await anvil.setNextBlockTimestamp(side, deadline + 1n);
      await anvil.mine(side);
    }
    await restampFeed(log);
    await transaction("arbitrum", core, coreVaultAbi, "unwindAllAfterDeadline");
    await waitFor(async () => {
      const report = await read<any>("robinhood", {address: spoke, abi: spokeVaultAbi, functionName: "buildReport"});
      return report.unwindResults.length > 130;
    }, "CLOSE order through alpha keeper");
    await report();
    await transaction("arbitrum", core, coreVaultAbi, "finalizeClosure");
    assert.equal(await read("arbitrum", {address: core, abi: coreVaultAbi, functionName: "fundState"}), 2);
    assert.ok(await read<bigint>("arbitrum", {address: core, abi: coreVaultAbi, functionName: "closedSupply"}) > 0n);
    const frozen = await read("arbitrum", {address: core, abi: coreVaultAbi, functionName: "closedSupply"});
    await transaction("arbitrum", core, coreVaultAbi, "exitClosedFund", [actors.ana.address]);
    assert.equal(await read("arbitrum", {address: core, abi: coreVaultAbi, functionName: "closedSupply"}), frozen);
  } else {
    const sent = await transaction("arbitrum", core, coreVaultAbi, "sendToSpoke", [0n, alphaAmounts.send, 0n, "0x"]);
    const depositLog = sent.receipt.logs.find((entry) => entry.address.toLowerCase() === ARBITRUM.acrossSpokePool.toLowerCase())!;
    const deposit = decodeEventLog({abi: acrossSpokePoolAbi, ...depositLog}).args as unknown as DepositEvent;
    await fill(deposit, "arbitrum", spoke, spokeVaultAbi, "TransitArrived");
    await report();
    assert.equal(await read("robinhood", {address: spoke, abi: spokeVaultAbi, functionName: "unallocatedBalance", args: [ROBINHOOD.usdg]}), deposit.outputAmount);
    if (process.env.ALPHA_MANUAL_ACK_PROBE === "1") {
    const returned = await transaction("robinhood", spoke, spokeVaultAbi, "sendToHub", [alphaAmounts.payout, 0, 0n]);
    const returnLog = returned.receipt.logs.find((entry) => entry.address.toLowerCase() === ROBINHOOD.acrossSpokePool.toLowerCase())!;
    const returnDeposit = decodeEventLog({abi: acrossSpokePoolAbi, ...returnLog}).args as unknown as DepositEvent;
    const transitLog = returned.receipt.logs.flatMap((entry) => {
      try {const decoded = decodeEventLog({abi: spokeVaultAbi, ...entry}); return decoded.eventName === "SentToHub" ? [decoded.args as any] : [];} catch {return [];}
    })[0];
    await new Promise((done) => setTimeout(done, 3000));
    const pending = JSON.parse(readFileSync(environment.ALPHA_STATE_FILE, "utf8"));
    assert.ok(pending.work.some((work: any) => work.transitId === transitLog.transitId), "Unfilled return must remain in durable queue");
    await fill(returnDeposit, "robinhood", core, coreVaultAbi, "TransitReceived");
    await report();
    await waitFor(async () => {
      const transit = await read<any>("robinhood", {address: spoke, abi: spokeVaultAbi, functionName: "hubBoundTransit", args: [transitLog.transitId]});
      return Number(transit.state) === 2;
    }, "durable keeper Principal acknowledgement");
    const remainingTransits = await read<readonly string[]>("robinhood", {address: spoke, abi: spokeVaultAbi, functionName: "inFlightTransitIds"});
    assert.ok(!remainingTransits.includes(transitLog.transitId), "Acknowledged manual send must free its shared slot");
    const afterAcknowledgement = await read<any>("robinhood", {address: spoke, abi: spokeVaultAbi, functionName: "buildReport"});
    assert.ok(!afterAcknowledgement.inFlightToHub.some((entry: any) => entry.transitId === transitLog.transitId));
    await waitFor(async () => !JSON.parse(readFileSync(environment.ALPHA_STATE_FILE, "utf8")).work.some((work: any) => work.transitId === transitLog.transitId), "resolved transit queue removal");
    appendFileSync(evidence, JSON.stringify({functionName: "durableAcknowledgement", transitId: transitLog.transitId, returned: alphaAmounts.payout.toString(), slotFreed: true}) + "\n");
    }
    await transaction("arbitrum", core, coreVaultAbi, "requestPayout", [alphaAmounts.payout, 0, 100]);
    await report();
    const mandate = await read<any>("arbitrum", {address: core, abi: coreVaultAbi, functionName: "mandate"});
    const swapAdapter = mandate.swapAdapters.find((entry: any) => Number(entry.chainId) === 4663).adapter;
    const spokeV4 = mandate.pools.find((entry: any) => Number(entry.chainId) === 4663).adapter;
    const remaining = await read<bigint>("robinhood", {address: spoke, abi: spokeVaultAbi, functionName: "unallocatedBalance", args: [ROBINHOOD.usdg]});
    const half = remaining / 2n;
    const swapped = await transaction("robinhood", spoke, spokeVaultAbi, "swap", [swapAdapter, ROBINHOOD.usdg, ROBINHOOD.weth, half, 100, "0x"]);
    const weth = swapped.result as bigint;
    const center = await centerTick("robinhood", ROBINHOOD.v4StateView, SPOKE_POOL_ID);
    await transaction("robinhood", spoke, spokeVaultAbi, "openPosition", [spokeV4, SPOKE_POOL_ID, weth, half, openParams(center, 2000, weth, half, (await nodes.robinhood.client.getBlock()).timestamp + 3600n)]);
    for (const token of [ROBINHOOD.usdg, ROBINHOOD.weth]) {
      const layout = await discoverBalanceLayout("robinhood", token, actors.trader.address);
      await setTokenBalance("robinhood", layout, actors.trader.address, token === ROBINHOOD.usdg ? 50000000000000n : 100000n * 10n ** 18n);
    }
    const routerHash = await wallet("robinhood", "trader").deployContract({abi: v4SwapRouterAbi, bytecode: v4SwapRouterBytecode(), args: [ROBINHOOD.v4PoolManager]} as never);
    const router = (await nodes.robinhood.client.waitForTransactionReceipt({hash: routerHash})).contractAddress!;
    for (const token of [ROBINHOOD.usdg, ROBINHOOD.weth]) await send("robinhood", "trader", {address: token, abi: erc20Abi, functionName: "approve", args: [router, 2n ** 255n]});
    for (let cycle = 0; cycle < 20; cycle++) {
      await generateFees("robinhood", router, SPOKE_POOL_KEY, ROBINHOOD.v4StateView, SPOKE_POOL_ID, center, 1000);
    }
    const hub = getAddress(process.env.ALPHA_HUB_SPOKE_VAULT!);
    const aave = mandate.pools.find((entry: any) => entry.poolKey.toLowerCase() === AAVE_USDC_POOL_KEY.toLowerCase()).adapter;
    await transaction("arbitrum", core, coreVaultAbi, "allocateToHubSpokeVault", [alphaAmounts.aave]);
    await transaction("arbitrum", hub, spokeVaultAbi, "openPosition", [aave, AAVE_USDC_POOL_KEY, alphaAmounts.aave, 0n, encodeAbiParameters([{type: "uint256"}], [alphaAmounts.aave])]);
    const positions = await read<any[]>("arbitrum", {address: hub, abi: spokeVaultAbi, functionName: "positions"});
    const timestamp = (await nodes.arbitrum.client.getBlock()).timestamp + 86400n;
    for (const side of ["arbitrum", "robinhood"] as const) {
      await anvil.setNextBlockTimestamp(side, timestamp);
      await anvil.mine(side);
    }
    await restampFeed(log);
    await transaction("arbitrum", hub, spokeVaultAbi, "collectIncome", [aave, positions[0].positionKey]);
    await report();
    const hubFee = await read<bigint>("arbitrum", {address: ARBITRUM.wormholeCore, abi: parseAbi(["function messageFee() view returns (uint256)"]), functionName: "messageFee"});
    await transaction("arbitrum", core, coreVaultAbi, "requestIncomeWithdrawal", [100], hubFee);
    const requestedCollection = await read<any>("arbitrum", {address: core, abi: coreVaultAbi, functionName: "incomeCollection"});
    assert.ok(requestedCollection.pendingSpokes > 0n, "Spoke fees must publish COLLECT");
    const spokePoolHead = await nodes.robinhood.client.getBlockNumber();
    const depositEvent = acrossSpokePoolAbi.find((entry: any) => entry.name === "FundsDeposited") as any;
    await waitFor(async () => {
      const collection = await read<any>("arbitrum", {address: core, abi: coreVaultAbi, functionName: "incomeCollection"});
      const deposits = await nodes.robinhood.client.getLogs({address: ROBINHOOD.acrossSpokePool, event: depositEvent, fromBlock: spokePoolHead});
      return deposits.length > 0 || collection.pendingSpokes === 0n;
    }, "COLLECT deposit or authenticated empty result");
    const incomeLogs = await nodes.robinhood.client.getLogs({address: ROBINHOOD.acrossSpokePool, event: depositEvent, fromBlock: spokePoolHead});
    assert.ok(incomeLogs.length > 0, "Repeated real LP trades must produce bridgeable Income for the ACK regression");
    if (incomeLogs.length) {
      await fill((incomeLogs[0] as any).args, "robinhood", core, coreVaultAbi, "TransitReceived");
      const sent = await nodes.robinhood.client.getLogs({address: spoke, event: spokeVaultAbi.find((entry: any) => entry.name === "SentToHub") as any, fromBlock: spokePoolHead});
      const incomeTransit = (sent as any[]).find((entry) => Number(entry.args.transit.kind) === 1);
      assert.ok(incomeTransit, "COLLECT must emit an Income transit");
      const transitId = incomeTransit.args.transitId;
      await waitFor(async () => Number((await read<any>("robinhood", {address: spoke, abi: spokeVaultAbi, functionName: "hubBoundTransit", args: [transitId]})).state) === 2, "COLLECT Income acknowledgement confirmed on the spoke");
      assert.ok(!(await read<readonly string[]>("robinhood", {address: spoke, abi: spokeVaultAbi, functionName: "inFlightTransitIds"})).includes(transitId));
      await waitFor(async () => !JSON.parse(readFileSync(environment.ALPHA_STATE_FILE, "utf8")).work.some((work: any) => work.transitId === transitId), "COLLECT Income durable queue removal");
      appendFileSync(evidence, JSON.stringify({functionName: "incomeAcknowledgement", transitId, slotFreed: true}) + "\n");
    }
    await report();
    await waitFor(async () => {
      const collection = await read<any>("arbitrum", {address: core, abi: coreVaultAbi, functionName: "incomeCollection"});
      return collection.pendingSpokes === 0n && collection.openResults === 0n;
    }, "COLLECT order and result through alpha keeper");
    const owed = await read<bigint>("arbitrum", {address: core, abi: coreVaultAbi, functionName: "incomeOwed", args: [actors.manager.address]});
    assert.ok(owed > 0n, "Real Aave interest must become Attributed Income");
    await transaction("arbitrum", core, coreVaultAbi, "settleIncomeWithdrawal", [actors.manager.address]);
    appendFileSync(evidence, JSON.stringify({functionName: "attributedIncome", amount: owed.toString()}) + "\n");
    const cursor = JSON.parse(readFileSync(environment.ALPHA_STATE_FILE, "utf8"));
    assert.ok(cursor.lastReport);
  }
  console.log(`Final alpha ${process.argv[2] === "close" ? "closure" : "capital/payout/income"} smoke passed`);
} finally {
  for (const child of children) {
    if (child.exitCode === null) {child.kill("SIGTERM"); await once(child, "exit");}
  }
}
}

await runMain(main);
