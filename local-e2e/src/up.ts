// `pnpm run up`: builds the contracts, starts both forks, deploys the protocol through the real Foundry scripts, puts
// the Wormhole guardian set under the harness's key, re-stamps Chainlink, funds the actors, creates a fund with the
// manager's seed (DEC-127) through script/CreateFund.s.sol, writes local-e2e/.state/deployment.json, and warms the
// fork caches: the scenario runs inside a snapshot, the snapshot is reverted, and everything it touched is read again
// while the upstream still serves the fork block (public RPCs serve fork state for minutes only; see README
// "Troubleshooting").
//
// Usage: pnpm run up [--warm-up scenario|none]
// (`pnpm up` is pnpm's own `update` command; the script needs `pnpm run up`.)
import { spawn } from "node:child_process";
import { join } from "node:path";
import { encodeDeployData, encodeFunctionData, type Address, type Hex } from "viem";
import { acrossSpokePoolAbi, v4SwapRouterAbi, v4SwapRouterBytecode, wormholeCoreAbi } from "./abis.ts";
import { anvil, deploy, explain, nodes, nodesUp, rpc, type Side } from "./chain.ts";
import { ARBITRUM, HARNESS_DIR, ROBINHOOD, actors, guardian, isMain } from "./config.ts";
import { createFund, deployFactory, forgeBuild, protocolRoles } from "./deploy.ts";
import { discoverLayouts, discoverMappingSlot, fundAccounts, mappingSlot, storageRead } from "./fund-accounts.ts";
import { WORMHOLE_SEQUENCES_SLOT, overrideGuardianSet, selfTest } from "./guardian.ts";
import { bold, green, logger, red, type Logger } from "./log.ts";
import { restampFeed } from "./price-feed.ts";
import { runScenario } from "./scenario.ts";
import { tryReadState, writeState, type DeploymentState, type NodeState } from "./state.ts";

function startForks(): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn("bash", [join(HARNESS_DIR, "scripts/start-forks.sh")], { stdio: "inherit" });
    child.on("close", (code) => (code === 0 ? resolve() : reject(new Error(`start-forks.sh failed (exit ${code})`))));
  });
}

async function nodeState(side: Side): Promise<NodeState> {
  const info = await anvil.nodeInfo(side);
  const forkBlockNumber = info.forkConfig?.forkBlockNumber;
  if (forkBlockNumber === undefined) throw new Error(`${nodes[side].label} is not a fork`);
  const block = await nodes[side].client.getBlock({ blockNumber: BigInt(forkBlockNumber) });
  return {
    rpc: nodes[side].rpc,
    chainId: nodes[side].chain.id,
    forkBlockNumber,
    forkBlockTimestamp: Number(block.timestamp),
  };
}

const PROBE_KEY: Hex = "0x00000000000000000000000000000000000000000000000000000000000000aa";

async function discoverStorage(log: Logger): Promise<DeploymentState["storage"]> {
  const fillStatusesData = encodeFunctionData({ abi: acrossSpokePoolAbi, functionName: "fillStatuses", args: [PROBE_KEY] });
  const storage: DeploymentState["storage"] = {
    balances: await discoverLayouts(),
    acrossFillStatusesSlot: {
      arbitrum: await discoverMappingSlot("arbitrum", ARBITRUM.acrossSpokePool, fillStatusesData, PROBE_KEY),
      robinhood: await discoverMappingSlot("robinhood", ROBINHOOD.acrossSpokePool, fillStatusesData, PROBE_KEY),
    },
    wormholeSequencesSlot: WORMHOLE_SEQUENCES_SLOT.toString(),
  };
  // The Wormhole table in guardian.ts says `sequences` sits at slot 4: confirm it on the live Robinhood Core.
  const emitter = actors.keeper.address;
  const read = await storageRead(
    "robinhood",
    ROBINHOOD.wormholeCore,
    encodeFunctionData({ abi: wormholeCoreAbi, functionName: "nextSequence", args: [emitter] }),
  );
  if (!read.includes(mappingSlot(emitter, WORMHOLE_SEQUENCES_SLOT))) {
    throw new Error("the Robinhood Wormhole Core does not keep sequences at slot 4");
  }
  log.info("storage layouts found", {
    usdcBalances: storage.balances.arbitrum[0].mappingSlot,
    usdgBalances: storage.balances.robinhood[0].mappingSlot,
    fillStatuses: `${storage.acrossFillStatusesSlot.arbitrum}/${storage.acrossFillStatusesSlot.robinhood}`,
  });
  return storage;
}

async function deploySwapRouter(side: Side, poolManager: Address): Promise<Address> {
  return deploy(side, "operator", encodeDeployData({ abi: v4SwapRouterAbi, bytecode: v4SwapRouterBytecode(), args: [poolManager] }) as Hex);
}

export async function up(warmUp: "scenario" | "none"): Promise<DeploymentState> {
  const log = logger("up");
  const started = Date.now();
  const running = await nodesUp();
  if (running.arbitrum || running.robinhood || tryReadState()) {
    throw new Error("the harness is already up (or a stale state file exists): run `pnpm down` first");
  }

  // Build before forking: the upstream serves fork state only briefly, so nothing slow may run after the fork.
  await forgeBuild(log);
  await startForks();
  const nodeStates = { arbitrum: await nodeState("arbitrum"), robinhood: await nodeState("robinhood") };
  log.info("forked", {
    arbitrumBlock: nodeStates.arbitrum.forkBlockNumber,
    robinhoodBlock: nodeStates.robinhood.forkBlockNumber,
  });

  const robinhood = await deployFactory("robinhood", log.child("deploy"));
  const arbitrum = await deployFactory("arbitrum", log.child("deploy"));
  if (robinhood.fundFactory !== arbitrum.fundFactory) {
    throw new Error(`DEC-054: the factory landed at ${arbitrum.fundFactory} on Arbitrum but ${robinhood.fundFactory} on Robinhood`);
  }

  const guardianSetIndex = await overrideGuardianSet(log.child("guardian"));
  await selfTest(guardianSetIndex, log.child("guardian"));
  await restampFeed(log.child("chainlink"));
  const storage = await discoverStorage(log);
  const helpers = {
    arbitrumSwapRouter: await deploySwapRouter("arbitrum", ARBITRUM.v4PoolManager),
    robinhoodSwapRouter: await deploySwapRouter("robinhood", ROBINHOOD.v4PoolManager),
  };
  log.info("trader swap routers deployed (test/mocks/v4/V4SwapRouter.sol)", helpers);
  // DEC-127: the manager seeds the fund in the creation transaction, so the actors are funded first.
  await fundAccounts({ storage, helpers }, log.child("funding"));
  const fund = await createFund(arbitrum.fundFactory, log.child("deploy"));

  const roles = protocolRoles();
  const state: DeploymentState = {
    version: 1,
    createdAt: new Date().toISOString(),
    nodes: nodeStates,
    actors: Object.fromEntries(Object.entries(actors).map(([name, account]) => [name, account.address])) as DeploymentState["actors"],
    guardian: { address: guardian.address, coreBridge: ARBITRUM.wormholeCore, guardianSetIndex },
    protocol: {
      arbitrum: {
        fundFactory: arbitrum.fundFactory,
        create3Deployer: arbitrum.create3Deployer,
        coreVaultLogic: arbitrum.coreVaultLogic,
        spokeCrossChainLib: arbitrum.spokeCrossChainLib,
        spokeUnwindLib: arbitrum.spokeUnwindLib,
        managerRegistry: arbitrum.managerRegistry,
        priceSource: arbitrum.priceSource,
        transitEscrowImplementation: arbitrum.transitEscrowImplementation,
        protocolRecipient: roles.protocolRecipient,
        adapterGuardian: roles.adapterGuardian,
        registryOwner: roles.registryOwner,
        apiSigner: roles.apiSigner,
      },
      robinhood: {
        fundFactory: robinhood.fundFactory,
        create3Deployer: robinhood.create3Deployer,
        spokeCrossChainLib: robinhood.spokeCrossChainLib,
        spokeUnwindLib: robinhood.spokeUnwindLib,
        transitEscrowImplementation: robinhood.transitEscrowImplementation,
        apiSigner: roles.apiSigner,
      },
    },
    external: { arbitrum: { ...ARBITRUM }, robinhood: { ...ROBINHOOD } },
    fund,
    helpers,
    storage,
  };
  writeState(state);
  log.info(`deployed in ${((Date.now() - started) / 1000).toFixed(0)}s`, { state: "local-e2e/.state/deployment.json" });

  if (warmUp === "scenario") await warmUpCaches(log);
  return state;
}

/** Accounts and storage slots the transactions of blocks `from..to` read or wrote, from anvil's prestate tracer.
 *  Accounts the run created are kept too: a later CREATE at the same address (a TransitEscrow clone, for instance)
 *  needs the upstream's "no account here" as much as a call needs an existing contract's code. */
async function touchedState(side: Side, from: bigint, to: bigint): Promise<Map<Address, Set<Hex>>> {
  const touched = new Map<Address, Set<Hex>>();
  for (let n = from; n <= to; n++) {
    const traces = await rpc<{ result: Record<string, { storage?: Record<Hex, Hex> }> }[]>(side, "debug_traceBlockByNumber", [
      `0x${n.toString(16)}`,
      { tracer: "prestateTracer" },
    ]);
    for (const { result } of traces) {
      for (const [address, account] of Object.entries(result)) {
        const key = address.toLowerCase() as Address;
        const slots = touched.get(key) ?? new Set<Hex>();
        for (const slot of Object.keys(account.storage ?? {})) slots.add(slot as Hex);
        touched.set(key, slots);
      }
    }
  }
  return touched;
}

/** Reads every touched account and slot again, so anvil fetches what the revert dropped from its fork cache. */
async function reread(side: Side, touched: Map<Address, Set<Hex>>): Promise<number> {
  const reads: (() => Promise<unknown>)[] = [];
  for (const [address, slots] of touched) {
    reads.push(() => nodes[side].client.getCode({ address }));
    for (const slot of slots) reads.push(() => nodes[side].client.getStorageAt({ address, slot }));
  }
  for (let i = 0; i < reads.length; i += 16) await Promise.all(reads.slice(i, i + 16).map((read) => read()));
  return reads.length;
}

/** Warms anvil's fork cache for the default fund. anvil fetches upstream state lazily at the fork block, and a public
 *  RPC stops serving that block within minutes (see README "Troubleshooting"). So right after the deployment the whole
 *  scenario runs inside a snapshot of both nodes; the state its transactions touched is collected with the prestate
 *  tracer; both nodes revert to the fresh deployment (a revert also drops what the snapshot fetched); and every touched
 *  account and slot is read again while the upstream still serves the fork block, which caches it for the session. */
async function warmUpCaches(log: Logger): Promise<void> {
  const started = Date.now();
  log.info("warm-up: running the scenario inside a snapshot of both nodes");
  const first = {
    arbitrum: (await nodes.arbitrum.client.getBlockNumber()) + 1n,
    robinhood: (await nodes.robinhood.client.getBlockNumber()) + 1n,
  };
  const snapshots = { arbitrum: await anvil.snapshot("arbitrum"), robinhood: await anvil.snapshot("robinhood") };
  let failure: unknown;
  try {
    const result = await runScenario({ keeper: "inprocess", newFund: false, quiet: true }, logger("warm-up", true));
    log.info("warm-up scenario passed", {
      steps: result.steps,
      assertions: result.assertions,
      fillsThroughSpokePool: result.fills.real,
      simulatedFills: result.fills.simulated,
    });
  } catch (err) {
    failure = err;
  }
  const touched: Record<Side, Map<Address, Set<Hex>>> = {
    arbitrum: await touchedState("arbitrum", first.arbitrum, await nodes.arbitrum.client.getBlockNumber()),
    robinhood: await touchedState("robinhood", first.robinhood, await nodes.robinhood.client.getBlockNumber()),
  };
  for (const side of ["arbitrum", "robinhood"] as const) {
    if (!(await anvil.revert(side, snapshots[side]))) throw new Error(`could not revert the ${side} snapshot`);
  }
  for (const side of ["arbitrum", "robinhood"] as const) {
    const reads = await reread(side, touched[side]);
    log.info("fork cache re-filled", { chain: nodes[side].chain.id, contracts: touched[side].size, reads });
  }
  // The revert took the clocks back to the snapshot: re-stamp Chainlink for the current block.
  await restampFeed(logger("chainlink", true));
  if (failure) {
    throw new Error(`warm-up scenario failed (both nodes reverted to the deployment; state file kept):\n${explain(failure)}`);
  }
  log.info(`warm-up done in ${((Date.now() - started) / 1000).toFixed(0)}s; both nodes back at the fresh deployment`);
}

if (isMain(import.meta.url)) {
  const args = process.argv.slice(2);
  const flag = args.indexOf("--warm-up");
  const warmUp = (flag >= 0 ? args[flag + 1] : "scenario") as "scenario" | "none";
  if (!["scenario", "none"].includes(warmUp)) {
    console.error("usage: pnpm run up [--warm-up scenario|none]");
    process.exit(1);
  }
  try {
    const state = await up(warmUp);
    console.log(`\n${green(bold("up"))}: Arbitrum One fork ${state.nodes.arbitrum.rpc} (chain 42161), Robinhood Chain fork ${state.nodes.robinhood.rpc} (chain 4663)`);
    console.log(`  FundFactory          ${state.protocol.arbitrum.fundFactory} (both chains)`);
    console.log(`  fund ${state.fund.shareSymbol.padEnd(15)} Core Vault ${state.fund.hub.coreVault}, Spoke Vault (Robinhood) ${state.fund.spoke.spokeVault}`);
    console.log(`  state                local-e2e/.state/deployment.json`);
    console.log(`  next                 pnpm keeper --auto-report 600   (another terminal), then pnpm scenario`);
  } catch (err) {
    console.error(`\n${red(bold("up failed"))}: ${explain(err)}`);
    process.exit(1);
  }
}
