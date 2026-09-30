// Time warp on BOTH nodes. The hub judges a spoke report by its own clock (DEC-099: a report older than maxReportAge
// is stale, one more than maxReportAge ahead is from the future), so a hub-only warp would make every report too old
// and every spoke-only warp would make it come from the future. Both nodes jump to the same timestamp, the Chainlink
// round is re-stamped, and every known Spoke Vault publishes a fresh report, delivered by the running keeper or, when
// none runs, directly, so deposits keep working.
//
// Usage: pnpm warp <duration> [--no-report]      duration: 3600, 90s, 30m, 72h, 3d
import { decodeEventLog, type Address, type Hex } from "viem";
import { fundFactoryAbi, spokeVaultAbi, valueReportReceiverAbi, wormholeCoreAbi } from "./abis.ts";
import { anvil, explain, latestTimestamp, nodes, read, send } from "./chain.ts";
import { ARBITRUM, ROBINHOOD, WORMHOLE_ROBINHOOD, isMain } from "./config.ts";
import { signVaa, universal } from "./guardian.ts";
import { logger, type Logger } from "./log.ts";
import { restampFeed } from "./price-feed.ts";
import { readState, type DeploymentState } from "./state.ts";
import { runningKeeperPid } from "./keeper.ts";

export function parseDuration(text: string): bigint {
  const match = /^(\d+)\s*(s|m|h|d)?$/.exec(text.trim());
  if (!match) throw new Error(`cannot read the duration "${text}" (examples: 3600, 90s, 30m, 72h, 3d)`);
  const unit = { s: 1n, m: 60n, h: 3600n, d: 86_400n }[(match[2] ?? "s") as "s" | "m" | "h" | "d"];
  return BigInt(match[1]) * unit;
}

/** Moves both nodes to `max(hub, spoke) + seconds` and mines a block on each. Returns the new timestamp. */
export async function warpClocks(seconds: bigint, log: Logger): Promise<bigint> {
  const [hub, spoke] = await Promise.all([latestTimestamp("arbitrum"), latestTimestamp("robinhood")]);
  // Both nodes land on one timestamp, strictly after their latest block (a warp of 0 moves them by one second).
  const target = (hub > spoke ? hub : spoke) + (seconds > 0n ? seconds : 1n);
  for (const side of ["arbitrum", "robinhood"] as const) {
    await anvil.setNextBlockTimestamp(side, target);
    await anvil.mine(side);
  }
  log.info("both clocks warped", { seconds, hubFrom: hub, spokeFrom: spoke, to: target, iso: new Date(Number(target) * 1000).toISOString() });
  return target;
}

export interface SpokeRef {
  fundId: Hex;
  spokeVault: Address;
  receiver: Address;
  spokeIndex: number;
}

/** Every fund with a Robinhood Spoke Vault: the default fund plus any created since (factory events). */
export async function knownSpokes(state: DeploymentState): Promise<SpokeRef[]> {
  const spokes = new Map<string, SpokeRef>();
  spokes.set(state.fund.fundId, {
    fundId: state.fund.fundId,
    spokeVault: state.fund.spoke.spokeVault,
    receiver: state.fund.hub.valueReportReceiver,
    spokeIndex: state.fund.spoke.spokeIndex,
  });
  const [hubLogs, spokeLogs] = await Promise.all([
    nodes.arbitrum.client.getLogs({
      address: state.protocol.arbitrum.fundFactory,
      event: fundFactoryAbi.find((e) => e.type === "event" && e.name === "FundCreated") as never,
      fromBlock: BigInt(state.nodes.arbitrum.forkBlockNumber) + 1n,
    }),
    nodes.robinhood.client.getLogs({
      address: state.protocol.robinhood.fundFactory,
      event: fundFactoryAbi.find((e) => e.type === "event" && e.name === "SpokeCreated") as never,
      fromBlock: BigInt(state.nodes.robinhood.forkBlockNumber) + 1n,
    }),
  ]);
  const receivers = new Map<string, Address>();
  for (const l of hubLogs as unknown as { args: { fundId: Hex; addresses: { valueReportReceiver: Address } } }[]) {
    receivers.set(l.args.fundId, l.args.addresses.valueReportReceiver);
  }
  for (const l of spokeLogs as unknown as { args: { fundId: Hex; addresses: { spokeVault: Address } } }[]) {
    const receiver = receivers.get(l.args.fundId);
    if (!receiver || spokes.has(l.args.fundId)) continue;
    spokes.set(l.args.fundId, { fundId: l.args.fundId, spokeVault: l.args.addresses.spokeVault, receiver, spokeIndex: 0 });
  }
  return [...spokes.values()];
}

/** Publishes a report from `spoke` (as the keeper account) and returns its Wormhole message. */
export async function publishReport(spoke: SpokeRef) {
  const sent = await send<readonly [bigint, bigint]>("robinhood", "keeper", {
    address: spoke.spokeVault,
    abi: spokeVaultAbi,
    functionName: "report",
  });
  for (const entry of sent.receipt.logs) {
    if (entry.address.toLowerCase() !== ROBINHOOD.wormholeCore.toLowerCase()) continue;
    const decoded = decodeEventLog({ abi: wormholeCoreAbi, data: entry.data, topics: entry.topics });
    if (decoded.eventName !== "LogMessagePublished") continue;
    const block = await nodes.robinhood.client.getBlock({ blockNumber: sent.receipt.blockNumber });
    const args = decoded.args as { sender: Address; sequence: bigint; nonce: number; payload: Hex; consistencyLevel: number };
    return {
      reportSequence: sent.result[0],
      wormholeSequence: args.sequence,
      message: {
        timestamp: Number(block.timestamp),
        nonce: Number(args.nonce),
        emitterChainId: WORMHOLE_ROBINHOOD,
        emitterAddress: universal(args.sender),
        sequence: args.sequence,
        consistencyLevel: Number(args.consistencyLevel),
        payload: args.payload,
      },
      tx: sent.hash,
    };
  }
  throw new Error(`report() on ${spoke.spokeVault} published no Wormhole message`);
}

/** Whether the hub accepted the report with this Wormhole sequence (or a later one). */
export async function delivered(spoke: SpokeRef, wormholeSequence: bigint): Promise<boolean> {
  const index = BigInt(spoke.spokeIndex);
  const [has, last] = await Promise.all([
    read<boolean>("arbitrum", { address: spoke.receiver, abi: valueReportReceiverAbi, functionName: "hasReport", args: [index] }),
    read<bigint>("arbitrum", { address: spoke.receiver, abi: valueReportReceiverAbi, functionName: "lastWormholeSequence", args: [index] }),
  ]);
  return has && last >= wormholeSequence;
}

export async function waitForDelivery(spoke: SpokeRef, wormholeSequence: bigint, timeoutSeconds: number): Promise<void> {
  const deadline = Date.now() + timeoutSeconds * 1000;
  while (Date.now() < deadline) {
    if (await delivered(spoke, wormholeSequence)) return;
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(
    `the report with Wormhole sequence ${wormholeSequence} of ${spoke.spokeVault} was not delivered within ${timeoutSeconds}s: is the keeper running?`,
  );
}

/** Signs and delivers a published report directly (used when no keeper runs). */
export async function deliverDirectly(spoke: SpokeRef, message: Parameters<typeof signVaa>[0]): Promise<Hex> {
  const index = await read<number>("arbitrum", {
    address: ARBITRUM.wormholeCore,
    abi: wormholeCoreAbi,
    functionName: "getCurrentGuardianSetIndex",
  });
  const vaa = await signVaa(message, index);
  const sent = await send("arbitrum", "keeper", { address: spoke.receiver, abi: valueReportReceiverAbi, functionName: "deliver", args: [vaa] });
  return sent.hash;
}

/** Warps both clocks, re-stamps Chainlink, and refreshes every spoke's report on the hub. `deliverer` says who carries
 *  the VAA: a running keeper (waited for) or this call. */
export async function warp(
  seconds: bigint,
  options: { log: Logger; report: boolean; deliverer: "keeper" | "self"; keeperTimeoutSeconds?: number },
): Promise<bigint> {
  const { log } = options;
  const state = readState();
  const target = await warpClocks(seconds, log);
  await restampFeed(log, "arbitrum", ARBITRUM.ethUsdFeed, target);
  if (!options.report) return target;
  // Publish every spoke's report first (one sender, in order), then wait for or perform the deliveries.
  const published: { spoke: SpokeRef; report: Awaited<ReturnType<typeof publishReport>> }[] = [];
  for (const spoke of await knownSpokes(state)) {
    try {
      const report = await publishReport(spoke);
      published.push({ spoke, report });
      log.info("fresh report published", { spokeVault: spoke.spokeVault, reportSequence: report.reportSequence, wormholeSequence: report.wormholeSequence });
    } catch (err) {
      log.error(`report() on ${spoke.spokeVault} failed: ${explain(err)}`);
      throw err;
    }
  }
  if (options.deliverer === "keeper") {
    await Promise.all(published.map(({ spoke, report }) => waitForDelivery(spoke, report.wormholeSequence, options.keeperTimeoutSeconds ?? 120)));
    log.info("the keeper delivered every fresh report", { reports: published.length });
  } else {
    for (const { spoke, report } of published) {
      const tx = await deliverDirectly(spoke, report.message);
      log.info("no keeper running: VAA signed and delivered directly", { spokeVault: spoke.spokeVault, tx });
    }
  }
  return target;
}

if (isMain(import.meta.url)) {
  const args = process.argv.slice(2);
  const duration = args.find((a) => !a.startsWith("--"));
  if (!duration) {
    console.error("usage: pnpm warp <duration> [--no-report]   (duration: 3600, 90s, 30m, 72h, 3d)");
    process.exit(1);
  }
  const log = logger("warp");
  try {
    await warp(parseDuration(duration), {
      log,
      report: !args.includes("--no-report"),
      deliverer: runningKeeperPid() ? "keeper" : "self",
    });
  } catch (err) {
    log.error(explain(err));
    process.exit(1);
  }
}
