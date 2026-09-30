// The end-to-end scenario over JSON-RPC: the phases of test/fork/e2e/EndToEnd.t.sol with real signed transactions from
// the actors on the two local forks, the keeper filling Across deposits and delivering VAAs, and an extra phase that
// brings Principal home through Across so the hub-side fill is exercised too. Every step asserts; the first failed
// assertion stops the run with a non-zero exit code.
//
// Usage: pnpm scenario [--keeper auto|inprocess|external] [--new-fund]
//   --keeper auto (default): use a running `pnpm keeper` if there is one, else start the keeper in-process.
//   --new-fund: create a fresh fund through script/CreateFund.s.sol first (automatic when the deployed fund was used).
import {
  decodeAbiParameters,
  decodeEventLog,
  encodeAbiParameters,
  type Abi,
  type Address,
  type Hex,
  type TransactionReceipt,
} from "viem";
import {
  aaveV3AdapterAbi,
  acrossSpokePoolAbi,
  chainlinkAggregatorAbi,
  chainlinkPriceSourceAbi,
  coreVaultAbi,
  erc20Abi,
  managerRegistryAbi,
  shareTokenAbi,
  spokeVaultAbi,
  uniswapV4AdapterAbi,
  valueReportReceiverAbi,
  wormholeCoreAbi,
} from "./abis.ts";
import { explain, latestTimestamp, nodes, nodesUp, read, send, simulateRevert, type Side } from "./chain.ts";
import {
  AAVE_USDC_POOL_KEY,
  ARBITRUM,
  ARBITRUM_CHAIN_ID,
  HUB_POOL_ID,
  HUB_POOL_KEY,
  ROBINHOOD,
  ROBINHOOD_CHAIN_ID,
  SPOKE_POOL_ID,
  SPOKE_POOL_KEY,
  WORMHOLE_ROBINHOOD,
  actors,
  isMain,
  type ActorName,
} from "./config.ts";
import { createFund } from "./deploy.ts";
import { universal } from "./guardian.ts";
import { DEFAULT_KEEPER_OPTIONS, runningKeeperPid, startKeeper, type Keeper } from "./keeper.ts";
import { bold, dim, green, logger, red, units, type Logger } from "./log.ts";
import { ensureFeedFresh } from "./price-feed.ts";
import { readState, type DeploymentState, type FundRecord } from "./state.ts";
import { centerTick, currentTick, generateFees, openParams, swapParams } from "./uniswap.ts";
import { waitForDelivery, warp, type SpokeRef } from "./warp.ts";

// ---------------------------------------------------------------------------------------------------------------------
// Scenario parameters (test/fork/e2e/EndToEndBase.sol and EndToEnd.t.sol)
// ---------------------------------------------------------------------------------------------------------------------

const USD = 10n ** 6n;
const WHOLE = 10n ** 18n;
const ANA_DEPOSIT = 10_000n * USD;
const HUB_ALLOCATION = 5_000n * USD;
const AAVE_SUPPLY = 2_000n * USD;
const HUB_V4_USDC = 3_000n * USD;
const BRIDGE_AMOUNT = 4_000n * USD;
const BRIDGE_FEE_BPS = 4n; // the e2e quote: 1.60 USDC on 4,000
const SPOKE_V4_USDG = 3_000n * USD;
const RETURN_AMOUNT = 500n * USD;
const RETURN_FEE = 100_000n; // 0.10 USDC (2 bps)
const BRUNO_DEPOSIT = 11_000n * USD;
const ANA_PAYOUT = 3_000n * USD;
const BRUNO_ABOVE_FREE_IDLE = 1_000n * USD;
const DONATION = 1_234n * USD;
const HALF_RANGE = 200;
const SWING = 40;
const SWAP_TOLERANCE_BPS = 300n;
const FLOW_FEE_BPS = 25n;
const SPOKE_OPERATING_CASH_TOP_UP = 10n * USD;
const INITIAL_SHARE_PRICE = 10n ** 24n;
const WAIT_SECONDS = 120;

// TransitState and TransferKind (src/interfaces/FundTypes.sol); PayoutMode (ICoreVault).
const SENT = 1;
const ARRIVAL_CONFIRMED = 2;
const PRINCIPAL = 0;
const INSTANT = 0;
const STANDARD = 1;

// ---------------------------------------------------------------------------------------------------------------------
// Assertions and the numbered step log
// ---------------------------------------------------------------------------------------------------------------------

class AssertionFailed extends Error {}

class Run {
  step = 0;
  assertions = 0;
  constructor(readonly log: Logger, readonly quiet: boolean) {}

  phase(title: string) {
    if (!this.quiet) console.log(`\n${bold(`== ${title}`)}`);
  }

  ok(message: string) {
    this.step++;
    if (!this.quiet) console.log(`${dim(`#${String(this.step).padStart(2, "0")}`)} ${green("ok")}  ${message}`);
  }

  note(message: string) {
    if (!this.quiet) console.log(`    ${dim(message)}`);
  }

  eq(actual: unknown, expected: unknown, label: string) {
    this.assertions++;
    const a = typeof actual === "string" ? actual.toLowerCase() : actual;
    const e = typeof expected === "string" ? expected.toLowerCase() : expected;
    if (a !== e) throw new AssertionFailed(`${label}: expected ${String(expected)}, got ${String(actual)}`);
  }

  true(condition: boolean, label: string) {
    this.assertions++;
    if (!condition) throw new AssertionFailed(label);
  }

  approx(actual: bigint, expected: bigint, tolerance: bigint, label: string) {
    this.assertions++;
    const diff = actual > expected ? actual - expected : expected - actual;
    if (diff > tolerance) {
      throw new AssertionFailed(`${label}: expected ${expected} +/- ${tolerance}, got ${actual}`);
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------------------------------------------------

const view = <T>(side: Side, address: Address, abi: Abi, functionName: string, args: readonly unknown[] = [], at?: bigint) =>
  read<T>(side, { address, abi, functionName, args }, undefined, at);

/** Aave's scaled-balance rounding moves the principal of an Exact-Value Position by at most a unit per measurement
 *  (AAVE-3), so values read in different blocks may differ by that much; reads within one block are exact. */
const AAVE_ROUNDING = 2n;

const tx = <T = unknown>(side: Side, who: ActorName, address: Address, abi: Abi, functionName: string, args: readonly unknown[] = []) =>
  send<T>(side, who, { address, abi, functionName, args });

const balance = (side: Side, token: Address, holder: Address) => view<bigint>(side, token, erc20Abi, "balanceOf", [holder]);

const price = (x: bigint) => units(x / 10n ** 18n, 6); // Share Price is USDC per share times 1e18

function events(receipt: TransactionReceipt, address: Address, abi: Abi, eventName: string) {
  const found: Record<string, any>[] = [];
  for (const entry of receipt.logs) {
    if (entry.address.toLowerCase() !== address.toLowerCase()) continue;
    try {
      const decoded = decodeEventLog({ abi, data: entry.data, topics: entry.topics });
      if (decoded.eventName === eventName) found.push(decoded.args as Record<string, any>);
    } catch {
      // another event
    }
  }
  return found;
}

/** The PayoutReceipt a claim emitted (`PayoutExecuted` or `PartialPayoutExecuted`), as mined. */
function payoutReceipt(receipt: TransactionReceipt, core: Address): Record<string, any> {
  const full = events(receipt, core, coreVaultAbi, "PayoutExecuted");
  const partial = events(receipt, core, coreVaultAbi, "PartialPayoutExecuted");
  const found = [...full, ...partial];
  if (found.length !== 1) throw new AssertionFailed(`expected one payout event, found ${found.length}`);
  return found[0].receipt;
}

async function waitFor<T>(what: string, probe: () => Promise<T | undefined | false>, seconds = WAIT_SECONDS): Promise<T> {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    const value = await probe();
    if (value !== undefined && value !== false) return value as T;
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new AssertionFailed(`timed out after ${seconds}s waiting for ${what} (is the keeper running?)`);
}

async function deadline(side: Side): Promise<bigint> {
  return (await latestTimestamp(side)) + 3600n;
}

const mulDiv = (a: bigint, b: bigint, d: bigint) => (a * b) / d;

// ShareMath (src/libraries/ShareMath.sol)
const sharesFor = (usdc: bigint, sharePrice: bigint) => mulDiv(usdc, WHOLE, sharePrice) * WHOLE;
const usdcFor = (shares: bigint, sharePrice: bigint) => mulDiv(shares, sharePrice, 10n ** 36n);
const bps = (amount: bigint, b: bigint) => mulDiv(amount, b, 10_000n);

// ---------------------------------------------------------------------------------------------------------------------
// The scenario
// ---------------------------------------------------------------------------------------------------------------------

export interface ScenarioOptions {
  keeper: "auto" | "inprocess" | "external";
  newFund: boolean;
  quiet: boolean;
}

export interface ScenarioResult {
  steps: number;
  assertions: number;
  fund: FundRecord;
  keeper: "inprocess" | "external";
  fills: { real: number; simulated: number };
}

export async function runScenario(options: ScenarioOptions, parentLog?: Logger): Promise<ScenarioResult> {
  const log = parentLog ?? logger("scenario", options.quiet);
  const run = new Run(log, options.quiet);
  const state = readState();
  const up = await nodesUp();
  if (!up.arbitrum || !up.robinhood) throw new Error("both forks must be running: `pnpm run up` first");

  // --------------------------------------------------------------------------------------------------------------
  // Phase 0: fund and keeper
  // --------------------------------------------------------------------------------------------------------------
  run.phase("Phase 0: fund and keeper");
  let fund = state.fund;
  const used = (await view<bigint>("arbitrum", fund.hub.shareToken, shareTokenAbi, "totalSupply")) > 0n;
  if (options.newFund || used) {
    run.note(used ? "the deployed fund already has shares: creating a fresh fund for this run" : "creating a fresh fund (--new-fund)");
    fund = await createFund(state.protocol.arbitrum.fundFactory, log.child("deploy"));
    run.ok(`fresh fund ${fund.shareSymbol} created through script/CreateFund.s.sol (Core Vault ${fund.hub.coreVault})`);
  } else {
    run.ok(`the deployed fund ${fund.shareSymbol} is unused (Core Vault ${fund.hub.coreVault})`);
  }
  const external = options.keeper === "external" || (options.keeper === "auto" && runningKeeperPid() !== undefined);
  let keeper: Keeper | undefined;
  if (external) {
    if (!runningKeeperPid()) throw new Error("--keeper external: no running keeper (start `pnpm keeper` first)");
    run.ok(`using the running keeper (pid ${runningKeeperPid()})`);
  } else {
    const keeperState: DeploymentState = { ...state, fund };
    keeper = await startKeeper(keeperState, { ...DEFAULT_KEEPER_OPTIONS, autoReportSeconds: 0, quiet: options.quiet }, log.child("keeper"));
    run.ok("keeper started in-process (Across fills, Wormhole VAAs, Chainlink re-stamps)");
  }

  const core = fund.hub.coreVault;
  const share = fund.hub.shareToken;
  const hubSpoke = fund.hub.spokeVault;
  const hubUni = fund.hub.uniswapV4Adapter;
  const hubAave = fund.hub.aaveV3Adapter;
  const receiver = fund.hub.valueReportReceiver;
  const spokeVault = fund.spoke.spokeVault;
  const spokeUni = fund.spoke.uniswapV4Adapter;
  const recipient = state.protocol.arbitrum.protocolRecipient;
  const priceSource = state.protocol.arbitrum.priceSource;
  const spokeRef: SpokeRef = { fundId: fund.fundId, spokeVault, receiver, spokeIndex: fund.spoke.spokeIndex };
  const A = actors;

  const usdcValue = async (token: Address, amount: bigint, at?: bigint) => {
    if (amount === 0n) return 0n;
    if (token.toLowerCase() === ARBITRUM.usdc.toLowerCase()) return amount;
    const [p] = await view<readonly [bigint, bigint]>("arbitrum", priceSource, chainlinkPriceSourceAbi, "priceInUsdc", [token], at);
    return mulDiv(amount, p, WHOLE);
  };
  const principalValue = async (r: any, at?: bigint) => {
    let value = 0n;
    for (const u of r.unallocated) value += await usdcValue(u.token, u.amount, at);
    for (const p of r.positions) value += (await usdcValue(p.token0, p.principal0, at)) + (await usdcValue(p.token1, p.principal1, at));
    return value;
  };
  // DEC-042, DEC-104: Share Assets rebuilt bucket by bucket (EndToEndBase `_sumOfBuckets`), every read in block `at`.
  const sumOfBuckets = async (at: bigint) => {
    let total = await view<bigint>("arbitrum", core, coreVaultAbi, "idle", [], at);
    total += await principalValue(await view("arbitrum", hubSpoke, spokeVaultAbi, "buildReport", [], at), at);
    total += await view<bigint>("arbitrum", core, coreVaultAbi, "inFlightValue", [], at);
    if (await view<boolean>("arbitrum", receiver, valueReportReceiverAbi, "hasReport", [0n], at)) {
      const [r] = await view<readonly [any, bigint, bigint]>("arbitrum", receiver, valueReportReceiverAbi, "latestReport", [0n], at);
      total += await principalValue(r, at);
    }
    return total;
  };
  const bucketsMatch = async (label: string) => {
    const at = await nodes.arbitrum.client.getBlockNumber();
    run.eq(await view<bigint>("arbitrum", core, coreVaultAbi, "shareAssets", [], at), await sumOfBuckets(at), label);
  };
  const shareAssets = () => view<bigint>("arbitrum", core, coreVaultAbi, "shareAssets");
  const sharePrice = () => view<bigint>("arbitrum", core, coreVaultAbi, "sharePrice");
  const idle = () => view<bigint>("arbitrum", core, coreVaultAbi, "idle");
  const minWethFor = async (usdcIn: bigint) => {
    const [p] = await view<readonly [bigint, bigint]>("arbitrum", priceSource, chainlinkPriceSourceAbi, "priceInUsdc", [ARBITRUM.weth]);
    return (mulDiv(usdcIn, WHOLE, p) * (10_000n - SWAP_TOLERANCE_BPS)) / 10_000n;
  };
  const warpBoth = async (seconds: bigint) => {
    await warp(seconds, { log: log.child("warp"), report: true, deliverer: "keeper", keeperTimeoutSeconds: WAIT_SECONDS });
  };

  const mandate = await view<any>("arbitrum", core, coreVaultAbi, "mandate");
  const spokeCfg = mandate.spokes[0];
  const maxBridgeFeeBps = BigInt(mandate.maxBridgeFeeBps);

  let realFills = 0;
  let simulatedFills = 0;
  try {
    // ------------------------------------------------------------------------------------------------------------
    // Phase 1: the fund as created (DEC-053, DEC-054, FF-OQ-1)
    // ------------------------------------------------------------------------------------------------------------
    run.phase("Phase 1: the fund as created (DEC-053, DEC-054)");
    run.eq(state.protocol.arbitrum.fundFactory, state.protocol.robinhood.fundFactory, "DEC-054: one factory address on both chains");
    run.eq(await view("arbitrum", core, coreVaultAbi, "mandateHash"), fund.mandateHash, "DEC-053: Mandate hash on the Core Vault");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "mandateHash"), fund.mandateHash, "FF-OQ-1: the spoke's Mandate is the hub's");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "coreVault"), core, "the spoke names its Core Vault");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "fundId"), fund.fundId, "the spoke carries the fund id");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "baseToken"), ROBINHOOD.usdg, "DEC-031: USDG on Robinhood");
    run.ok(`one factory ${state.protocol.arbitrum.fundFactory} on both chains; the Robinhood Spoke Vault carries the hub's Mandate ${fund.mandateHash.slice(0, 10)}...`);
    run.eq(BigInt(mandate.hubChainId), BigInt(ARBITRUM_CHAIN_ID), "DEC-011: Arbitrum One is the Hub Chain");
    run.eq(mandate.spokes.length, 1, "one spoke");
    run.eq(BigInt(spokeCfg.chainId), BigInt(ROBINHOOD_CHAIN_ID), "the spoke is Robinhood Chain");
    run.eq(Number(spokeCfg.wormholeChainId), WORMHOLE_ROBINHOOD, "DEC-086: Wormhole chain 72");
    run.eq(spokeCfg.spokeVault, universal(spokeVault), "DEC-054: the predicted Robinhood Spoke Vault");
    run.eq(Number(spokeCfg.maxReportAge), 1588, "ruling 2026-09-29: 1,587 s plus one block");
    run.eq(mandate.pools[0].poolKey, HUB_POOL_ID, "DEC-030: hub WETH/USDC 0.05%");
    run.eq(mandate.pools[1].poolKey, AAVE_USDC_POOL_KEY, "DEC-018, DEC-028: Aave USDC on the hub");
    run.eq(mandate.pools[2].poolKey, SPOKE_POOL_ID, "DEC-030: spoke WETH/USDG 0.05%");
    run.eq(mandate.unwindOrder.length, 2, "feedback question 2: automatic unwind on hub positions only");
    run.eq(mandate.unwindOrder[0].adapter, hubUni, "DEC-069: hub Uniswap V4 first");
    run.eq(mandate.unwindOrder[1].adapter, hubAave, "DEC-069: then Aave");
    run.eq(mandate.bridgeAdapters.length, 2, "DEC-088: Across on both sides");
    run.eq(Number(mandate.payoutFeeBps), 200, "DEC-102: Payout Fee 2%");
    run.eq(Number(mandate.standardPayoutTerm), 72 * 3600, "DEC-060: 72 h term");
    run.eq(BigInt(mandate.minFirstDeposit), 100n * USD, "DEC-061: 100 USDC minimum first deposit");
    run.eq(Number(mandate.performanceFeeBps), 2000, "DEC-107: performance fee 20%");
    run.eq(Number(mandate.managementFeeBps), 0, "DEC-108: management fee 0");
    run.eq(BigInt(await view<number>("arbitrum", core, coreVaultAbi, "flowFeeBps")), FLOW_FEE_BPS, "DEC-106: flow fee 25 bps");
    run.ok(
      `Mandate: hub V4 WETH/USDC + Aave USDC, spoke V4 WETH/USDG, Across both ways, Spoke Cap ${units(BigInt(spokeCfg.spokeCap), 6, 0)} USDC, ` +
        `max bridge fee ${maxBridgeFeeBps} bps, Payout Fee 2%, 72 h term, performance fee 20%, maxReportAge 1588 s`,
    );

    // ------------------------------------------------------------------------------------------------------------
    // Phase 2: Ana deposits 10,000 USDC (DEC-061, DEC-106, DEC-035)
    // ------------------------------------------------------------------------------------------------------------
    run.phase("Phase 2: Ana deposits 10,000 USDC (DEC-035, DEC-061, DEC-106)");
    await tx("arbitrum", "ana", ARBITRUM.usdc, erc20Abi, "approve", [core, ANA_DEPOSIT]);
    const belowMinimum = BigInt(mandate.minFirstDeposit) - 1n;
    run.eq(
      await simulateRevert("arbitrum", "ana", { address: core, abi: coreVaultAbi, functionName: "deposit", args: [belowMinimum, 0n] }),
      "BelowMinFirstDeposit",
      "DEC-061: below the Mandate minimum",
    );
    run.ok(`a first deposit of ${units(belowMinimum)} USDC reverts BelowMinFirstDeposit`);
    const recipientBefore = await balance("arbitrum", ARBITRUM.usdc, recipient);
    const anaDeposit = await tx<readonly [bigint, bigint]>("arbitrum", "ana", core, coreVaultAbi, "deposit", [ANA_DEPOSIT, 0n]);
    const [anaShares, anaCharged] = anaDeposit.result;
    const fee = bps(ANA_DEPOSIT, FLOW_FEE_BPS);
    run.eq(fee, 25n * USD, "flow fee 25 USDC");
    run.eq((await balance("arbitrum", ARBITRUM.usdc, recipient)) - recipientBefore, fee, "DEC-106: flow fee to the protocol");
    run.eq(anaShares, 9_975n * WHOLE, "DEC-061: 9,975 whole shares at 1.00");
    run.eq(anaCharged, ANA_DEPOSIT, "DEC-035: nothing left over at 1.00");
    run.eq(await balance("arbitrum", share, A.ana.address), anaShares, "Ana holds her shares");
    run.eq(await idle(), ANA_DEPOSIT - fee, "Idle");
    run.eq(await shareAssets(), ANA_DEPOSIT - fee, "Share Assets");
    run.eq(await sharePrice(), INITIAL_SHARE_PRICE, "DEC-061: 1 share = 1.00 USDC");
    run.ok(`Ana deposits 10,000 USDC: 9,975 shares at 1.000000, 25.00 USDC flow fee to the Protocol Recipient (tx ${anaDeposit.hash.slice(0, 10)})`);

    // ------------------------------------------------------------------------------------------------------------
    // Phase 3: hub allocation, Aave supply, a Uniswap V4 position, income on both (DEC-017, DEC-068, DEC-079, DEC-092)
    // ------------------------------------------------------------------------------------------------------------
    run.phase("Phase 3: hub allocation, Aave supply, Uniswap V4 position, income (DEC-017, DEC-068, DEC-079, DEC-092)");
    const idleBeforeAllocation = await idle();
    await tx("arbitrum", "manager", core, coreVaultAbi, "allocateToHubSpokeVault", [HUB_ALLOCATION]);
    run.eq(await idle(), idleBeforeAllocation - HUB_ALLOCATION, "DEC-072: Free Idle allocated");
    run.eq(await view("arbitrum", hubSpoke, spokeVaultAbi, "unallocatedBalance", [ARBITRUM.usdc]), HUB_ALLOCATION, "DEC-055: Unallocated Balance");
    run.eq(await shareAssets(), idleBeforeAllocation, "DEC-104: a move between buckets keeps Share Assets");
    run.ok("manager allocates 5,000 USDC of Free Idle to the hub Spoke Vault");

    const aaveOpen = await tx<readonly [Hex, bigint, bigint]>("arbitrum", "manager", hubSpoke, spokeVaultAbi, "openPosition", [
      hubAave,
      AAVE_USDC_POOL_KEY,
      AAVE_SUPPLY,
      0n,
      encodeAbiParameters([{ type: "uint256" }], [AAVE_SUPPLY]),
    ]);
    const hubAavePosition = aaveOpen.result[0];
    run.eq(aaveOpen.result[1], AAVE_SUPPLY, "AAVE-2: explicit amount supplied");
    run.ok("manager supplies 2,000 USDC to Aave V3 through the Aave adapter");

    const half = HUB_V4_USDC / 2n;
    const usdcBeforeSwap = await view<bigint>("arbitrum", hubSpoke, spokeVaultAbi, "unallocatedBalance", [ARBITRUM.usdc]);
    const hubSwap = await tx<bigint>("arbitrum", "manager", hubSpoke, spokeVaultAbi, "swapExactInput", [
      hubUni,
      HUB_POOL_ID,
      ARBITRUM.usdc,
      half,
      await minWethFor(half),
      swapParams(await deadline("arbitrum")),
    ]);
    const hubWeth = hubSwap.result;
    run.eq(await view("arbitrum", hubSpoke, spokeVaultAbi, "unallocatedBalance", [ARBITRUM.weth]), hubWeth, "DEC-080: swap output credited");
    const hubCenter = await centerTick("arbitrum", ARBITRUM.v4StateView, HUB_POOL_ID);
    const hubOpen = await tx<readonly [Hex, bigint, bigint]>("arbitrum", "manager", hubSpoke, spokeVaultAbi, "openPosition", [
      hubUni,
      HUB_POOL_ID,
      hubWeth,
      half,
      openParams(hubCenter, HALF_RANGE, hubWeth, half, await deadline("arbitrum")),
    ]);
    const [hubUniPosition, hubUsed0, hubUsed1] = hubOpen.result;
    run.true(hubUsed0 > 0n && hubUsed1 > 0n, "both tokens used");
    run.eq(await view("arbitrum", hubSpoke, spokeVaultAbi, "unallocatedBalance", [ARBITRUM.weth]), hubWeth - hubUsed0, "DEC-079: unused WETH back");
    run.eq(
      await view("arbitrum", hubSpoke, spokeVaultAbi, "unallocatedBalance", [ARBITRUM.usdc]),
      usdcBeforeSwap - half - hubUsed1,
      "DEC-079: unused USDC back",
    );
    run.eq((await view<readonly unknown[]>("arbitrum", hubSpoke, spokeVaultAbi, "positions")).length, 2, "two hub positions");
    run.ok(
      `manager swaps 1,500 USDC for ${units(hubWeth, 18, 4)} WETH and opens a V4 range [${hubCenter - HALF_RANGE}, ${hubCenter + HALF_RANGE}] ` +
        `with ${units(hubUsed0, 18, 4)} WETH + ${units(hubUsed1)} USDC`,
    );

    await warpBoth(3600n);
    const aaveValue = await view<any>("arbitrum", hubAave, aaveV3AdapterAbi, "positionValue", [hubAavePosition]);
    run.eq(aaveValue.principal0, AAVE_SUPPLY, "DEC-068: principal stays the amount supplied");
    run.true(aaveValue.income0 > 0n, "DEC-068: interest since supply is income");
    run.ok(`both clocks warped 1 h (fresh spoke report delivered): Aave interest ${units(aaveValue.income0)} USDC is income, principal stays 2,000`);

    const hubTicks = await generateFees("arbitrum", state.helpers.arbitrumSwapRouter, HUB_POOL_KEY, ARBITRUM.v4StateView, HUB_POOL_ID, hubCenter, SWING);
    run.true(Math.abs(hubTicks[0] - (hubCenter - SWING)) <= 1 && Math.abs(hubTicks[2] - hubCenter) <= 1, "swaps reached their target ticks");
    const hubV4Value = await view<any>("arbitrum", hubUni, uniswapV4AdapterAbi, "positionValue", [hubUniPosition]);
    run.true(hubV4Value.income0 > 0n, "DEC-079: WETH fees");
    run.true(hubV4Value.income1 > 0n, "DEC-079: USDC fees");
    await bucketsMatch("DEC-092, DEC-104: income is outside Share Assets");
    run.ok(
      `trader swings the hub pool to ticks ${hubTicks.join(" / ")}: the position earned ${units(hubV4Value.income0, 18, 6)} WETH + ` +
        `${units(hubV4Value.income1)} USDC in fees, outside Share Assets`,
    );

    // ------------------------------------------------------------------------------------------------------------
    // Phase 4: 4,000 USDC to Robinhood through the live Across SpokePool (DEC-037, DEC-066, DEC-085, DEC-087, QA19)
    // ------------------------------------------------------------------------------------------------------------
    run.phase("Phase 4: 4,000 USDC to Robinhood through the live Across SpokePool (DEC-037, DEC-066, DEC-085, QA19)");
    const bridgeFee = bps(BRIDGE_AMOUNT, BRIDGE_FEE_BPS < maxBridgeFeeBps ? BRIDGE_FEE_BPS : maxBridgeFeeBps);
    const quoteTimestamp = Number(await latestTimestamp("arbitrum"));
    const quote = { outputAmount: BRIDGE_AMOUNT - bridgeFee, quoteTimestamp, exclusivityDeadline: 0, exclusiveRelayer: "0x0000000000000000000000000000000000000000" };
    const [capValue, capSent, capToHub, cap] = await view<readonly [bigint, bigint, bigint, bigint]>("arbitrum", core, coreVaultAbi, "spokeCapUsage", [0n]);
    const above = cap - (capValue + capSent + capToHub) + USD;
    if (above <= (await view<bigint>("arbitrum", core, coreVaultAbi, "freeIdle"))) {
      run.eq(
        await simulateRevert("arbitrum", "manager", {
          address: core,
          abi: coreVaultAbi,
          functionName: "sendToSpoke",
          args: [0n, above, 0n, { ...quote, outputAmount: above - bps(above, BRIDGE_FEE_BPS < maxBridgeFeeBps ? BRIDGE_FEE_BPS : maxBridgeFeeBps) }],
        }),
        "SpokeCapExceeded",
        "DEC-037, DEC-095: the Spoke Cap bounds the send",
      );
      run.ok(`a send of ${units(above, 6, 0)} USDC, above the ${units(cap, 6, 0)} USDC Spoke Cap, reverts SpokeCapExceeded`);
    } else {
      run.note(`Spoke Cap refusal not exercised: ${units(above, 6, 0)} USDC above the cap exceeds Free Idle`);
    }
    const maxFee = bps(BRIDGE_AMOUNT, maxBridgeFeeBps);
    run.eq(
      await simulateRevert("arbitrum", "manager", {
        address: core,
        abi: coreVaultAbi,
        functionName: "sendToSpoke",
        args: [0n, BRIDGE_AMOUNT, 0n, { ...quote, outputAmount: BRIDGE_AMOUNT - maxFee - 1n }],
      }),
      "BridgeFeeAboveMax",
      "QA19: the quote's fee above maxBridgeFeeBps",
    );
    run.ok(`a quote charging more than ${maxBridgeFeeBps} bps reverts BridgeFeeAboveMax`);

    const assetsBeforeSend = await shareAssets();
    const idleBeforeSend = await idle();
    const depositIdBefore = await view<number>("arbitrum", ARBITRUM.acrossSpokePool, acrossSpokePoolAbi, "numberOfDeposits");
    const sendTx = await tx<Hex>("arbitrum", "manager", core, coreVaultAbi, "sendToSpoke", [0n, BRIDGE_AMOUNT, 0n, quote]);
    const transitId = sendTx.result;
    const transit = await view<any>("arbitrum", core, coreVaultAbi, "transit", [transitId]);
    const amountToArrive: bigint = transit.amountToArrive;
    const sendBlock = await nodes.arbitrum.client.getBlock({ blockNumber: sendTx.receipt.blockNumber });
    run.eq(Number(transit.state), SENT, "DEC-066: state Sent");
    run.eq(amountToArrive, BRIDGE_AMOUNT - bridgeFee, "DEC-085: the quote's outputAmount");
    run.eq(BigInt(transit.bridgeRef), BigInt(depositIdBefore), "Across deposit id");
    run.eq(BigInt(transit.fillDeadline), sendBlock.timestamp + 6n * 3600n, "DEC-066: 6 h fill deadline");
    const [deposited] = events(sendTx.receipt, ARBITRUM.acrossSpokePool, acrossSpokePoolAbi, "FundsDeposited");
    run.true(deposited !== undefined, "the live SpokePool emitted FundsDeposited");
    run.eq(deposited.destinationChainId, BigInt(ROBINHOOD_CHAIN_ID), "destination Robinhood");
    run.eq(deposited.depositId, BigInt(depositIdBefore), "deposit id");
    run.eq(deposited.depositor, universal(transit.escrow), "DEC-066: the per-send escrow is the depositor");
    run.eq(deposited.inputToken, universal(ARBITRUM.usdc), "USDC in");
    run.eq(deposited.outputToken, universal(ROBINHOOD.usdg), "USDG out");
    run.eq(deposited.inputAmount, BRIDGE_AMOUNT, "input amount");
    run.eq(deposited.outputAmount, amountToArrive, "output amount");
    run.eq(BigInt(deposited.quoteTimestamp), BigInt(quoteTimestamp), "quote timestamp");
    run.eq(BigInt(deposited.fillDeadline), BigInt(transit.fillDeadline), "fill deadline");
    run.eq(deposited.recipient, universal(spokeVault), "DEC-087: the Mandate's Spoke Vault");
    const [version, messageFund, messageOrigin, messageTransit, messageKind] = decodeAbiParameters(
      [{ type: "uint256" }, { type: "bytes32" }, { type: "uint256" }, { type: "bytes32" }, { type: "uint8" }],
      deposited.message,
    );
    run.true(version > 0n, "TransitMessage version");
    run.eq(messageFund, fund.fundId, "message fund id");
    run.eq(messageOrigin, BigInt(ARBITRUM_CHAIN_ID), "message origin");
    run.eq(messageTransit, transitId, "message transit id");
    run.eq(Number(messageKind), PRINCIPAL, "message kind Principal");
    run.eq(await idle(), idleBeforeSend - BRIDGE_AMOUNT, "Idle debited");
    run.eq(await view("arbitrum", core, coreVaultAbi, "inFlightValue"), amountToArrive, "DEC-085: In-flight Value at the amount that will arrive");
    run.eq(assetsBeforeSend - (await shareAssets()), bridgeFee, "DEC-085: Share Assets drop by the bridge fee only");
    const [, inFlightSentAfter, , capAfter] = await view<readonly [bigint, bigint, bigint, bigint]>("arbitrum", core, coreVaultAbi, "spokeCapUsage", [0n]);
    run.eq(inFlightSentAfter, BRIDGE_AMOUNT, "DEC-066 C1: the Spoke Cap counts the amount sent");
    run.eq(capAfter, BigInt(spokeCfg.spokeCap), "Spoke Cap");
    run.eq(await view("arbitrum", ARBITRUM.usdc, erc20Abi, "allowance", [core, ARBITRUM.acrossSpokePool]), 0n, "DEC-087: approval reset");
    run.ok(
      `manager sends 4,000 USDC: Across deposit ${depositIdBefore}, ${units(amountToArrive)} USDG to arrive (fee ${units(bridgeFee)}), ` +
        `escrow ${transit.escrow} as depositor, transit ${transitId.slice(0, 10)}... Sent`,
    );

    // ------------------------------------------------------------------------------------------------------------
    // Phase 5: the keeper fills on Robinhood; a WETH/USDG position; fees (DEC-090, DEC-096, OQ-09)
    // ------------------------------------------------------------------------------------------------------------
    run.phase("Phase 5: Across fill on Robinhood, spoke position, fees (DEC-079, DEC-090, DEC-096, OQ-09)");
    await waitFor("the Across fill on Robinhood", () => view<boolean>("robinhood", spokeVault, spokeVaultAbi, "hasArrived", [transitId]));
    const fills = await nodes.robinhood.client.getLogs({
      address: ROBINHOOD.acrossSpokePool,
      event: acrossSpokePoolAbi.find((e) => e.type === "event" && e.name === "FilledRelay") as never,
      args: { originChainId: BigInt(ARBITRUM_CHAIN_ID), depositId: BigInt(depositIdBefore) } as never,
      fromBlock: BigInt(fund.spoke.createdInBlock),
    });
    if (fills.length === 1) {
      const filled = (fills[0] as unknown as { args: Record<string, any> }).args;
      run.eq(filled.recipient, universal(spokeVault), "FilledRelay recipient");
      run.eq(filled.outputAmount, amountToArrive, "FilledRelay output amount");
      run.eq(filled.relayer, universal(A.keeper.address), "the keeper relayed");
      realFills++;
      run.ok(`the keeper filled deposit ${depositIdBefore} through the Robinhood SpokePool's fillRelay (FilledRelay, relayer ${A.keeper.address})`);
    } else {
      simulatedFills++;
      run.note("no FilledRelay: the keeper used the simulated fill path (see the keeper log)");
    }
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "arrivals", [transitId]), amountToArrive, "OQ-09: credited total per transit id");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "cumulativeReceived"), amountToArrive, "cumulative received");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "operatingCash"), SPOKE_OPERATING_CASH_TOP_UP, "DEC-096: the arrival tops up Operating Cash");
    run.eq(
      await view("robinhood", spokeVault, spokeVaultAbi, "unallocatedBalance", [ROBINHOOD.usdg]),
      amountToArrive - SPOKE_OPERATING_CASH_TOP_UP,
      "Unallocated Balance on the spoke",
    );
    run.ok(`the Spoke Vault credited ${units(amountToArrive)} USDG: 10.00 to Operating Cash, the rest to Unallocated Balance`);

    const spokeHalf = SPOKE_V4_USDG / 2n;
    const spokeSwap = await tx<bigint>("robinhood", "manager", spokeVault, spokeVaultAbi, "swapExactInput", [
      spokeUni,
      SPOKE_POOL_ID,
      ROBINHOOD.usdg,
      spokeHalf,
      await minWethFor(spokeHalf),
      swapParams(await deadline("robinhood")),
    ]);
    const spokeWeth = spokeSwap.result;
    const spokeCenter = await centerTick("robinhood", ROBINHOOD.v4StateView, SPOKE_POOL_ID);
    const spokeOpen = await tx<readonly [Hex, bigint, bigint]>("robinhood", "manager", spokeVault, spokeVaultAbi, "openPosition", [
      spokeUni,
      SPOKE_POOL_ID,
      spokeWeth,
      spokeHalf,
      openParams(spokeCenter, HALF_RANGE, spokeWeth, spokeHalf, await deadline("robinhood")),
    ]);
    const [spokeUniPosition, spokeUsed0, spokeUsed1] = spokeOpen.result;
    run.true(spokeUsed0 > 0n && spokeUsed1 > 0n, "both tokens used on the spoke");
    run.eq((await view<readonly unknown[]>("robinhood", spokeVault, spokeVaultAbi, "positions")).length, 1, "one spoke position");
    run.ok(`manager swaps 1,500 USDG for ${units(spokeWeth, 18, 4)} WETH on Robinhood and opens a V4 range around tick ${spokeCenter}`);

    const spokeTicks = await generateFees("robinhood", state.helpers.robinhoodSwapRouter, SPOKE_POOL_KEY, ROBINHOOD.v4StateView, SPOKE_POOL_ID, spokeCenter, SWING);
    const spokeV4Value = await view<any>("robinhood", spokeUni, uniswapV4AdapterAbi, "positionValue", [spokeUniPosition]);
    run.true(spokeV4Value.income0 > 0n, "DEC-079: WETH fees on the spoke");
    run.true(spokeV4Value.income1 > 0n, "DEC-079: USDG fees on the spoke");
    run.ok(`trader swings the spoke pool to ticks ${spokeTicks.join(" / ")}: ${units(spokeV4Value.income0, 18, 6)} WETH + ${units(spokeV4Value.income1)} USDG fees`);

    // ------------------------------------------------------------------------------------------------------------
    // Phase 6: the report on the real Robinhood Core, the VAA delivered on Arbitrum (DEC-066, DEC-086, DEC-090, DEC-093)
    // ------------------------------------------------------------------------------------------------------------
    run.phase("Phase 6: report on Robinhood, VAA delivered on Arbitrum (DEC-066, DEC-083, DEC-086, DEC-090, DEC-093)");
    const assetsBeforeReport = await shareAssets();
    const inFlightBeforeReport = await view<bigint>("arbitrum", core, coreVaultAbi, "inFlightValue");
    run.eq(inFlightBeforeReport, amountToArrive, "the transit is still in flight on the hub");
    const reported = await tx<readonly [bigint, bigint]>("robinhood", "stranger", spokeVault, spokeVaultAbi, "report");
    const [reportSequence, wormholeSequence] = reported.result;
    const [published] = events(reported.receipt, ROBINHOOD.wormholeCore, wormholeCoreAbi, "LogMessagePublished");
    run.true(published !== undefined, "the real Robinhood Core published the report");
    run.eq(published.sender, spokeVault, "DEC-086: the Spoke Vault is the emitter");
    run.eq(published.sequence, wormholeSequence, "Wormhole sequence");
    run.eq(Number(published.consistencyLevel), 1, "DEC-093: finalized");
    run.ok(`anyone calls report(): report ${reportSequence}, Wormhole sequence ${wormholeSequence}, finalized, on the Robinhood Core`);

    await waitForDelivery(spokeRef, wormholeSequence, WAIT_SECONDS);
    const [latest] = await view<readonly [any, bigint, bigint]>("arbitrum", receiver, valueReportReceiverAbi, "latestReport", [0n]);
    run.eq(latest.sequence, reportSequence, "DEC-093: the delivered report");
    run.eq(latest.fundId, fund.fundId, "report fund id");
    run.eq(latest.spokeChainId, BigInt(ROBINHOOD_CHAIN_ID), "report spoke chain");
    run.true(
      latest.arrivedTransits.some((t: any) => t.transitId === transitId && t.amount === amountToArrive),
      "DEC-090, OQ-09: the arrival is listed by transit id at its credited total",
    );
    run.eq(latest.cumulativeReceived, amountToArrive, "cumulative received in the report");
    run.eq(latest.operatingCash, SPOKE_OPERATING_CASH_TOP_UP, "DEC-096: Operating Cash on its own line");
    run.eq(latest.positions.length, 1, "one position in the report");
    run.true(latest.positions[0].income0 + latest.positions[0].income1 > 0n, "DEC-079: income apart from principal");
    run.eq(await view("arbitrum", receiver, valueReportReceiverAbi, "isReportFresh", [0n]), true, "DEC-099: within the report lifetime");
    run.ok(`the keeper signed the VAA with the local guardian and delivered it: the hub accepted report ${reportSequence}`);

    const transitAfter = await view<any>("arbitrum", core, coreVaultAbi, "transit", [transitId]);
    run.eq(Number(transitAfter.state), ARRIVAL_CONFIRMED, "DEC-066, DEC-090: ArrivalConfirmed");
    run.eq(await view("arbitrum", core, coreVaultAbi, "inFlightValue"), 0n, "DEC-085: In-flight Value dropped");
    const [spokeValue, sentAfterReport] = await view<readonly [bigint, bigint, bigint, bigint]>("arbitrum", core, coreVaultAbi, "spokeCapUsage", [0n]);
    run.eq(sentAfterReport, 0n, "DEC-066: the Spoke Cap is released on arrival");
    const [, answer] = await view<readonly [bigint, bigint, bigint, bigint, bigint]>("arbitrum", ARBITRUM.ethUsdFeed, chainlinkAggregatorAbi, "latestRoundData");
    const [wethPrice] = await view<readonly [bigint, bigint]>("arbitrum", priceSource, chainlinkPriceSourceAbi, "priceInUsdc", [ROBINHOOD.weth]);
    const [usdgPrice] = await view<readonly [bigint, bigint]>("arbitrum", priceSource, chainlinkPriceSourceAbi, "priceInUsdc", [ROBINHOOD.usdg]);
    run.eq(wethPrice, mulDiv(answer, 10n ** 24n, 10n ** 26n), "ruling 2026-09-29: Chainlink ETH / USD for WETH");
    run.eq(usdgPrice, WHOLE, "ruling 2026-09-29: USDG at 1:1");
    const spokePrincipal = await principalValue(latest);
    run.eq(spokeValue, spokePrincipal, "the hub's spoke value is the report's principal");
    run.approx(await shareAssets(), assetsBeforeReport - inFlightBeforeReport + spokePrincipal, AAVE_ROUNDING, "DEC-083: the spoke value entered Share Assets");
    run.true(spokePrincipal < amountToArrive, "DEC-096: Operating Cash and the swap's Market Costs left");
    run.true(spokePrincipal > (amountToArrive * 99n) / 100n, "within 1% of the amount that arrived");
    await bucketsMatch("DEC-104: Share Assets is the sum of its buckets");
    run.true((await view<bigint>("arbitrum", core, coreVaultAbi, "grossAssets")) > (await shareAssets()), "DEC-098: Gross Assets add income and Operating Cash");
    run.ok(
      `transit ArrivalConfirmed, In-flight Value 0, spoke principal ${units(spokePrincipal)} USDC (WETH at Chainlink ${units(answer, 8, 2)}, USDG 1:1); ` +
        `Share Assets ${units(await shareAssets())}, Share Price ${price(await sharePrice())}`,
    );

    // ------------------------------------------------------------------------------------------------------------
    // Phase 7 (beyond the fork test): Principal comes home through Across, filled on the hub (DEC-085, DEC-104, OQ-01)
    // ------------------------------------------------------------------------------------------------------------
    run.phase("Phase 7: 500 USDG of Principal comes home through Across (DEC-085, DEC-104, OQ-01, CV-OQ-1)");
    const idleBeforeReturn = await idle();
    const assetsBeforeReturn = await shareAssets();
    const returnQuote = {
      outputAmount: RETURN_AMOUNT - RETURN_FEE,
      quoteTimestamp: Number(await latestTimestamp("robinhood")),
      exclusivityDeadline: 0,
      exclusiveRelayer: "0x0000000000000000000000000000000000000000",
    };
    const returnTx = await tx<Hex>("robinhood", "manager", spokeVault, spokeVaultAbi, "sendToHub", [RETURN_AMOUNT, PRINCIPAL, 0n, returnQuote]);
    const returnId = returnTx.result;
    const [returnDeposit] = events(returnTx.receipt, ROBINHOOD.acrossSpokePool, acrossSpokePoolAbi, "FundsDeposited");
    run.true(returnDeposit !== undefined, "the Robinhood SpokePool emitted FundsDeposited");
    run.eq(returnDeposit.destinationChainId, BigInt(ARBITRUM_CHAIN_ID), "destination Arbitrum");
    run.eq(returnDeposit.recipient, universal(core), "the Core Vault receives");
    run.eq(returnDeposit.outputToken, universal(ARBITRUM.usdc), "USDC out");
    run.ok(`manager sends 500 USDG home: Across deposit ${returnDeposit.depositId} from Robinhood, ${units(returnQuote.outputAmount)} USDC to arrive`);

    const received = await waitFor("the Across fill on Arbitrum", async () => {
      const logs = await nodes.arbitrum.client.getLogs({
        address: core,
        event: coreVaultAbi.find((e) => e.type === "event" && e.name === "TransitReceived") as never,
        args: { transitId: returnId } as never,
        fromBlock: BigInt(fund.hub.createdInBlock),
      });
      return logs.length > 0 ? (logs as unknown as { args: Record<string, any> }[]) : undefined;
    });
    const hubFills = await nodes.arbitrum.client.getLogs({
      address: ARBITRUM.acrossSpokePool,
      event: acrossSpokePoolAbi.find((e) => e.type === "event" && e.name === "FilledRelay") as never,
      args: { originChainId: BigInt(ROBINHOOD_CHAIN_ID), depositId: returnDeposit.depositId } as never,
      fromBlock: BigInt(fund.hub.createdInBlock),
    });
    if (hubFills.length === 1) {
      realFills++;
      run.ok(`the keeper filled it through the Arbitrum SpokePool's fillRelay; the Core Vault got ${units(received[0].args.amount)} USDC (matched: ${received[0].args.matched})`);
    } else {
      simulatedFills++;
      run.note("no FilledRelay on Arbitrum: the keeper used the simulated fill path");
    }
    const returnReport = await tx<readonly [bigint, bigint]>("robinhood", "stranger", spokeVault, spokeVaultAbi, "report");
    await waitForDelivery(spokeRef, returnReport.result[1], WAIT_SECONDS);
    const credited = await nodes.arbitrum.client.getLogs({
      address: core,
      event: coreVaultAbi.find((e) => e.type === "event" && e.name === "TransitReceived") as never,
      args: { transitId: returnId } as never,
      fromBlock: BigInt(fund.hub.createdInBlock),
    });
    const matchedTotal = (credited as unknown as { args: Record<string, any> }[])
      .filter((l) => l.args.matched)
      .reduce((sum, l) => sum + (l.args.amount as bigint), 0n);
    run.eq(matchedTotal, returnQuote.outputAmount, "OQ-01: credited up to what the report listed");
    run.eq(await idle(), idleBeforeReturn + returnQuote.outputAmount, "Principal reached Idle");
    run.eq(await view("arbitrum", core, coreVaultAbi, "unmatchedArrivals"), 0n, "nothing held apart");
    run.eq(await view("arbitrum", core, coreVaultAbi, "inFlightValue"), 0n, "no return leg in flight once credited");
    run.approx(assetsBeforeReturn - (await shareAssets()), RETURN_FEE, AAVE_ROUNDING, "DEC-085: Share Assets drop by the bridge fee only");
    await bucketsMatch("DEC-104: Share Assets is the sum of its buckets");
    run.ok(`the next report listed the transfer as Principal and the hub credited ${units(matchedTotal)} USDC to Idle`);

    // ------------------------------------------------------------------------------------------------------------
    // Phase 8: hub income collected and split at collection (ruling 2026-09-29, DEC-106, DEC-107, DEC-109)
    // ------------------------------------------------------------------------------------------------------------
    run.phase("Phase 8: hub income collected and split (ruling 2026-09-29, DEC-092, DEC-106, DEC-107, DEC-109)");
    const assetsBeforeCollect = await shareAssets();
    // Mined amounts (IncomeCollected): Aave interest grows every second, so a simulation's result is a block early.
    const collected = async (adapter: Address, position: Hex) => {
      const sent = await tx("arbitrum", "manager", hubSpoke, spokeVaultAbi, "collectIncome", [adapter, position]);
      const [event] = events(sent.receipt, hubSpoke, spokeVaultAbi, "IncomeCollected");
      return event as { income0: bigint; income1: bigint };
    };
    const v4Collect = await collected(hubUni, hubUniPosition);
    const aaveCollect = await collected(hubAave, hubAavePosition);
    run.true(v4Collect.income0 > 0n && v4Collect.income1 > 0n, "V4 fees collected");
    run.true(aaveCollect.income0 > 0n, "DEC-068: Aave interest collected");
    const usdcIncome = await view<bigint>("arbitrum", hubSpoke, spokeVaultAbi, "collectedIncome", [ARBITRUM.usdc]);
    const wethIncome = await view<bigint>("arbitrum", hubSpoke, spokeVaultAbi, "collectedIncome", [ARBITRUM.weth]);
    run.eq(usdcIncome, v4Collect.income1 + aaveCollect.income0, "USDC income bucket");
    run.eq(wethIncome, v4Collect.income0, "WETH income bucket");
    run.approx(await shareAssets(), assetsBeforeCollect, AAVE_ROUNDING, "DEC-092: collection leaves Share Assets");
    run.ok(`manager collects ${units(usdcIncome)} USDC + ${units(wethIncome, 18, 6)} WETH of hub income; Share Assets unchanged`);

    const sliceBps = BigInt(await view<number>("arbitrum", state.protocol.arbitrum.managerRegistry, managerRegistryAbi, "protocolSliceBps", [A.manager.address]));
    run.eq(sliceBps, 5000n, "DEC-106: 50% protocol slice");
    const feeVault = fund.hub.managerFeeVault;
    const split = async (token: Address, amount: bigint) => {
      const managerFee = bps(amount, 2000n);
      const slice = bps(managerFee, sliceBps);
      const net = amount - managerFee;
      const recipientBefore = await balance("arbitrum", token, recipient);
      const vaultBefore = await balance("arbitrum", token, feeVault);
      const collectedBefore = await view<bigint>("arbitrum", core, coreVaultAbi, "collectedIncome", [token]);
      const forwarded = await tx<bigint>("arbitrum", "stranger", hubSpoke, spokeVaultAbi, "forwardIncomeToCoreVault", [token]);
      run.eq(forwarded.result, amount, "permissionless forward");
      run.eq((await balance("arbitrum", token, recipient)) - recipientBefore, slice, "DEC-106: protocol slice");
      run.eq((await balance("arbitrum", token, feeVault)) - vaultBefore, managerFee - slice, "DEC-109: ManagerFeeVault");
      run.eq((await view<bigint>("arbitrum", core, coreVaultAbi, "collectedIncome", [token])) - collectedBefore, net, "the net to the accumulator");
      return { managerFee, slice, net };
    };
    const usdcSplit = await split(ARBITRUM.usdc, usdcIncome);
    const wethSplit = await split(ARBITRUM.weth, wethIncome);
    run.approx(await view("arbitrum", core, coreVaultAbi, "attributedIncome", [A.ana.address, ARBITRUM.usdc]), usdcSplit.net, 1n, "DEC-014: Ana held while it was earned");
    run.approx(await view("arbitrum", core, coreVaultAbi, "attributedIncome", [A.ana.address, ARBITRUM.weth]), wethSplit.net, 1n, "DEC-014: Ana's WETH");
    run.ok(
      `a stranger forwards it: 20% fee split 50/50 at collection, USDC ${units(usdcSplit.slice)} to the Protocol Recipient, ` +
        `${units(usdcSplit.managerFee - usdcSplit.slice)} to the ManagerFeeVault, ${units(usdcSplit.net)} to holders (WETH likewise)`,
    );

    // ------------------------------------------------------------------------------------------------------------
    // Phase 9: Bruno enters at the new Share Price (DEC-014, DEC-035, DEC-061, OQ-10)
    // ------------------------------------------------------------------------------------------------------------
    run.phase("Phase 9: Bruno deposits 11,000 USDC at the new Share Price (DEC-014, DEC-035, DEC-061)");
    await ensureFeedFresh(log.child("chainlink"), 600n);
    const priceBeforeBruno = await sharePrice();
    const assetsBeforeBruno = await shareAssets();
    const anaUsdcIncome = await view<bigint>("arbitrum", core, coreVaultAbi, "attributedIncome", [A.ana.address, ARBITRUM.usdc]);
    const brunoUsdcBefore = await balance("arbitrum", ARBITRUM.usdc, A.bruno.address);
    await tx("arbitrum", "bruno", ARBITRUM.usdc, erc20Abi, "approve", [core, BRUNO_DEPOSIT]);
    const brunoDeposit = await tx("arbitrum", "bruno", core, coreVaultAbi, "deposit", [BRUNO_DEPOSIT, 0n]);
    // The mined mint (Deposited): the price is read inside the transaction's block.
    const [minted] = events(brunoDeposit.receipt, core, coreVaultAbi, "Deposited");
    const mintPrice: bigint = minted.sharePrice;
    const brunoShares: bigint = minted.shares;
    const brunoCharged: bigint = minted.usdcForShares + minted.flowFee;
    const brunoFee = bps(BRUNO_DEPOSIT, FLOW_FEE_BPS);
    run.eq(minted.flowFee, brunoFee, "DEC-106: flow fee on the amount offered");
    const expectedShares = sharesFor(BRUNO_DEPOSIT - brunoFee, mintPrice);
    const forShares = usdcFor(expectedShares, mintPrice);
    run.approx(mintPrice, priceBeforeBruno, priceBeforeBruno / 10n ** 9n, "DEC-083: minted at the Share Price read before");
    run.eq(await balance("arbitrum", share, A.bruno.address), brunoShares, "Bruno holds his shares");
    run.eq(brunoShares, expectedShares, "DEC-035: whole shares at the new Share Price");
    run.eq(brunoShares % WHOLE, 0n, "whole shares");
    run.eq(minted.usdcForShares, forShares, "what the shares cost");
    run.eq(brunoCharged, forShares + brunoFee, "charged the shares' price plus the flow fee");
    run.eq(brunoUsdcBefore - (await balance("arbitrum", ARBITRUM.usdc, A.bruno.address)), brunoCharged, "DEC-061: the remainder stays in his wallet");
    run.approx(await shareAssets(), (minted.shareAssets as bigint) + forShares, AAVE_ROUNDING, "Share Assets grow by what the shares cost");
    run.approx(assetsBeforeBruno, minted.shareAssets, AAVE_ROUNDING, "the mint valued the fund as the view did");
    run.approx(await sharePrice(), priceBeforeBruno, priceBeforeBruno / 10n ** 9n, "DEC-061: rounding only");
    run.eq(await view("arbitrum", core, coreVaultAbi, "attributedIncome", [A.bruno.address, ARBITRUM.usdc]), 0n, "DEC-014: none of the income already generated");
    run.eq(await view("arbitrum", core, coreVaultAbi, "attributedIncome", [A.bruno.address, ARBITRUM.weth]), 0n, "DEC-014: none of the WETH income");
    run.eq(await view("arbitrum", core, coreVaultAbi, "attributedIncome", [A.ana.address, ARBITRUM.usdc]), anaUsdcIncome, "DEC-014: Ana keeps hers");
    run.ok(`Bruno deposits 11,000 USDC: ${units(brunoShares, 18, 0)} shares at ${price(priceBeforeBruno)}, charged ${units(brunoCharged)} USDC`);

    // ------------------------------------------------------------------------------------------------------------
    // Phase 10: Ana's Income Withdrawal (DEC-025, DEC-073, DEC-109, LC-143)
    // ------------------------------------------------------------------------------------------------------------
    run.phase("Phase 10: Ana withdraws her income (DEC-025, DEC-073, LC-143)");
    const anaUsdc = await view<bigint>("arbitrum", core, coreVaultAbi, "attributedIncome", [A.ana.address, ARBITRUM.usdc]);
    const anaWeth = await view<bigint>("arbitrum", core, coreVaultAbi, "attributedIncome", [A.ana.address, ARBITRUM.weth]);
    const anaUsdcBefore = await balance("arbitrum", ARBITRUM.usdc, A.ana.address);
    const anaWethBefore = await balance("arbitrum", ARBITRUM.weth, A.ana.address);
    const anaSharesBefore = await balance("arbitrum", share, A.ana.address);
    run.eq((await tx<bigint>("arbitrum", "ana", core, coreVaultAbi, "withdrawIncome", [ARBITRUM.usdc])).result, anaUsdc, "DEC-073: Income Withdrawal pays Attributed Income");
    run.eq((await tx<bigint>("arbitrum", "ana", core, coreVaultAbi, "withdrawIncome", [ARBITRUM.weth])).result, anaWeth, "WETH income");
    run.eq((await balance("arbitrum", ARBITRUM.usdc, A.ana.address)) - anaUsdcBefore, anaUsdc, "LC-143: no flow fee on Income Withdrawal");
    run.eq((await balance("arbitrum", ARBITRUM.weth, A.ana.address)) - anaWethBefore, anaWeth, "DEC-109: paid in kind");
    run.eq(await balance("arbitrum", share, A.ana.address), anaSharesBefore, "DEC-025: no share is burned");
    run.eq(await view("arbitrum", core, coreVaultAbi, "attributedIncome", [A.ana.address, ARBITRUM.usdc]), 0n, "nothing left owed");
    run.eq((await tx<bigint>("arbitrum", "bruno", core, coreVaultAbi, "withdrawIncome", [ARBITRUM.usdc])).result, 0n, "DEC-014: Bruno has nothing to withdraw");
    run.ok(`Ana withdraws ${units(anaUsdc)} USDC + ${units(anaWeth, 18, 6)} WETH of income without burning shares; Bruno gets 0`);

    // ------------------------------------------------------------------------------------------------------------
    // Phase 11: Ana's Standard Payout of 3,000 USDC (DEC-024, DEC-060, DEC-067, DEC-072, DEC-077, DEC-105, DEC-106)
    // ------------------------------------------------------------------------------------------------------------
    run.phase("Phase 11: Ana's Standard Payout of 3,000 USDC (DEC-060, DEC-067, DEC-072, DEC-077, DEC-105)");
    const idleBeforePayout = await idle();
    const request = await tx("arbitrum", "ana", core, coreVaultAbi, "requestPayout", [ANA_PAYOUT, STANDARD]);
    const requestBlock = await nodes.arbitrum.client.getBlock({ blockNumber: request.receipt.blockNumber });
    const anaRequest = await view<any>("arbitrum", core, coreVaultAbi, "payoutRequest", [A.ana.address]);
    run.eq(anaRequest.reserved, ANA_PAYOUT, "DEC-072: reserved as USDC");
    run.eq(await view("arbitrum", core, coreVaultAbi, "payoutReserve"), ANA_PAYOUT, "Payout Reserve");
    run.eq(anaRequest.termEndsAt, requestBlock.timestamp + 72n * 3600n, "DEC-060: 72 h term");
    run.eq(await balance("arbitrum", share, A.ana.address), anaSharesBefore, "DEC-077: nothing burned at request");
    run.eq(
      await simulateRevert("arbitrum", "ana", { address: core, abi: coreVaultAbi, functionName: "claimPayout", args: ["0x"] }),
      "PayoutTermNotEnded",
      "DEC-060: no claim before the term ends",
    );
    run.ok("Ana requests a Standard Payout of 3,000 USDC: reserved, term 72 h; claiming now reverts PayoutTermNotEnded");

    await warpBoth(72n * 3600n);
    run.ok("both clocks warped 72 h; Chainlink re-stamped; a fresh spoke report delivered by the keeper");
    const payoutPrice = await sharePrice();
    const recipientBeforePayout = await balance("arbitrum", ARBITRUM.usdc, recipient);
    const anaBeforeClaim = await balance("arbitrum", ARBITRUM.usdc, A.ana.address);
    const anaClaim = await tx<any>("arbitrum", "ana", core, coreVaultAbi, "claimPayout", ["0x"]);
    const r1 = payoutReceipt(anaClaim.receipt, core);
    const anaBurn = sharesFor(ANA_PAYOUT, r1.sharePrice);
    const anaGross = usdcFor(anaBurn, r1.sharePrice);
    run.approx(r1.sharePrice, payoutPrice, payoutPrice / 10n ** 9n, "DEC-105: one Share Price, the one read before the claim");
    run.eq(r1.sharesBurned, anaBurn, "DEC-077: whole shares rounded down");
    run.eq(r1.usdcGross, anaGross, "gross");
    run.true(anaGross <= ANA_PAYOUT, "DEC-077: never above the request");
    run.eq(r1.unwindProceeds, 0n, "DEC-067: Idle paid");
    run.eq(r1.payoutFee, 0n, "DEC-102: no Payout Fee on a Standard Payout");
    run.eq(r1.flowFee, bps(anaGross, FLOW_FEE_BPS), "DEC-106: flow fee on the amount paid");
    run.eq(r1.usdcPaid, anaGross - r1.flowFee, "paid");
    run.eq(r1.usdcOutstanding, 0n, "nothing outstanding");
    run.eq((await balance("arbitrum", ARBITRUM.usdc, A.ana.address)) - anaBeforeClaim, r1.usdcPaid, "Ana received it");
    run.eq((await balance("arbitrum", ARBITRUM.usdc, recipient)) - recipientBeforePayout, r1.flowFee, "flow fee to the protocol");
    run.eq(await balance("arbitrum", share, A.ana.address), anaSharesBefore - anaBurn, "shares burned");
    run.eq(await idle(), idleBeforePayout - anaGross, "Idle paid it");
    run.eq(await view("arbitrum", core, coreVaultAbi, "payoutReserve"), 0n, "DEC-072: reserve released");
    run.eq((await view<any>("arbitrum", core, coreVaultAbi, "payoutRequest", [A.ana.address])).open, false, "DEC-024: request closed");
    run.ok(`Ana claims: ${units(anaBurn, 18, 0)} shares burned at ${price(r1.sharePrice)}, ${units(r1.usdcPaid)} USDC paid, ${units(r1.flowFee)} flow fee`);

    // ------------------------------------------------------------------------------------------------------------
    // Phase 12: Bruno's Instant Payout above Free Idle, with an automatic unwind (DEC-059, DEC-068, DEC-069, DEC-081,
    //           DEC-097, DEC-102, DEC-105)
    // ------------------------------------------------------------------------------------------------------------
    run.phase("Phase 12: Bruno's Instant Payout above Free Idle, with an unwind (DEC-069, DEC-081, DEC-102, DEC-105)");
    const free = await view<bigint>("arbitrum", core, coreVaultAbi, "freeIdle");
    const instantPrice = await sharePrice();
    const brunoRequest = free + BRUNO_ABOVE_FREE_IDLE;
    const brunoBalance = await balance("arbitrum", share, A.bruno.address);
    run.true(usdcFor(brunoBalance, instantPrice) > brunoRequest, "Bruno holds more than he asks");
    const burnable = sharesFor(brunoRequest, instantPrice);
    const wanted = usdcFor(burnable < brunoBalance ? burnable : brunoBalance, instantPrice);
    const shortfall = wanted - free;
    const target = shortfall + (shortfall * 200n) / 10_000n;
    const supply = await view<bigint>("arbitrum", share, shareTokenAbi, "totalSupply");
    const operatingCashBefore = await view<bigint>("arbitrum", core, coreVaultAbi, "operatingCash");
    const aavePrincipalBefore = (await view<any>("arbitrum", hubAave, aaveV3AdapterAbi, "positionValue", [hubAavePosition])).principal0 as bigint;
    const brunoUsdcBeforeClaim = await balance("arbitrum", ARBITRUM.usdc, A.bruno.address);
    const hubUnallocated = await view<bigint>("arbitrum", hubSpoke, spokeVaultAbi, "unallocatedBalance", [ARBITRUM.usdc]);
    const v4 = await view<any>("arbitrum", hubUni, uniswapV4AdapterAbi, "positionValue", [hubUniPosition]);
    const spotValue = async (p: any) =>
      (p.principal1 as bigint) + (await view<bigint>("arbitrum", hubUni, uniswapV4AdapterAbi, "spotQuote", [HUB_POOL_ID, ARBITRUM.weth, p.principal0]));
    const v4Value = await spotValue(v4);
    const v4Liquidity = v4.liquidity as bigint;

    await tx("arbitrum", "bruno", core, coreVaultAbi, "requestPayout", [brunoRequest, INSTANT]);
    run.eq((await view<any>("arbitrum", core, coreVaultAbi, "payoutRequest", [A.bruno.address])).reserved, 0n, "DEC-095: no reserve for an Instant Payout");
    run.ok(`Bruno requests an Instant Payout of ${units(brunoRequest)} USDC, 1,000 above Free Idle (${units(free)})`);

    // One hint per position the unwind may visit, in Mandate order: the V4 step's WETH swap gets a Chainlink-based
    // minimum stricter than the vault's own floor; Aave needs none (EndToEnd.t.sol `_unwindHints`).
    const hintShortfall = target > hubUnallocated ? target - hubUnallocated : 0n;
    const wethOut = v4Value <= hintShortfall ? (v4.principal0 as bigint) : mulDiv(v4.principal0, hintShortfall, v4Value);
    const hints = encodeAbiParameters(
      [
        {
          type: "tuple[]",
          components: [
            {
              name: "swaps",
              type: "tuple[]",
              components: [
                { name: "adapter", type: "address" },
                { name: "poolKey", type: "bytes32" },
                { name: "tokenIn", type: "address" },
                { name: "minAmountOut", type: "uint256" },
                { name: "params", type: "bytes" },
              ],
            },
          ],
        },
      ],
      [
        [
          {
            swaps: [
              {
                adapter: hubUni,
                poolKey: HUB_POOL_ID,
                tokenIn: ARBITRUM.weth,
                minAmountOut: ((await usdcValue(ARBITRUM.weth, wethOut)) * (10_000n - SWAP_TOLERANCE_BPS)) / 10_000n,
                params: swapParams(await deadline("arbitrum")),
              },
            ],
          },
          { swaps: [] },
        ],
      ],
    );
    const brunoClaim = await tx<any>("arbitrum", "bruno", core, coreVaultAbi, "claimPayout", [hints]);
    const r2 = payoutReceipt(brunoClaim.receipt, core);
    const unwound = events(brunoClaim.receipt, hubSpoke, spokeVaultAbi, "UnwoundForPayout");
    run.eq(unwound.length, 1, "one automatic unwind");
    run.approx(unwound[0].usdcTarget, target, AAVE_ROUNDING, "DEC-081: the shortfall plus 2%");
    run.eq(unwound[0].usdcProceeds, r2.unwindProceeds, "DEC-080: proceeds reached Idle through returnToIdle");
    run.true(unwound[0].usdcProceeds > 0n, "the unwind produced USDC");
    const positionsAfter = await view<readonly { adapter: Address }[]>("arbitrum", hubSpoke, spokeVaultAbi, "positions");
    const unwindShortfall = target - hubUnallocated;
    if (v4Value <= unwindShortfall) {
      run.eq(positionsAfter.length, 1, "DEC-069: the whole V4 value was needed, so it closed first");
      run.eq(positionsAfter[0].adapter, hubAave, "Aave remains");
    } else {
      run.eq(positionsAfter.length, 2, "final verification: the V4 position was only decreased");
      run.true(
        ((await view<any>("arbitrum", hubUni, uniswapV4AdapterAbi, "positionValue", [hubUniPosition])).liquidity as bigint) < v4Liquidity,
        "DEC-069: the hub V4 position was unwound first, by the shortfall only",
      );
    }
    const aavePrincipalAfter = (await view<any>("arbitrum", hubAave, aaveV3AdapterAbi, "positionValue", [hubAavePosition])).principal0 as bigint;
    run.true(aavePrincipalAfter <= aavePrincipalBefore, "Aave principal never grows in an unwind");
    run.true(aavePrincipalBefore - aavePrincipalAfter <= (unwindShortfall * SWAP_TOLERANCE_BPS) / 10_000n, "DEC-059: Aave covers at most what the V4 swap fell short");
    run.eq(r2.totalShares, supply, "total shares at the claim");
    run.eq(r2.sharePrice, r2.totalShares === 0n ? INITIAL_SHARE_PRICE : mulDiv(r2.shareAssets, 10n ** 36n, r2.totalShares), "DEC-105: the burn at the Share Price read after the unwind");
    run.eq(r2.usdcGross, usdcFor(r2.sharesBurned, r2.sharePrice), "gross");
    run.eq(r2.payoutFee, bps(r2.usdcGross, 200n), "DEC-102: 2% Payout Fee");
    run.eq((await view<bigint>("arbitrum", core, coreVaultAbi, "operatingCash")) - operatingCashBefore, r2.payoutFee, "DEC-102: into Operating Cash");
    run.eq(r2.flowFee, bps(r2.usdcGross, FLOW_FEE_BPS), "DEC-106: flow fee");
    run.eq(r2.usdcPaid, r2.usdcGross - r2.payoutFee - r2.flowFee, "paid");
    run.eq((await balance("arbitrum", ARBITRUM.usdc, A.bruno.address)) - brunoUsdcBeforeClaim, r2.usdcPaid, "Bruno received it");
    run.eq(r2.payoutSettlementPrice, mulDiv(r2.unwindProceeds, 10n ** 36n, r2.sharesBurned), "DEC-084, DEC-105: Settlement Price recorded only");
    run.eq(await balance("arbitrum", share, A.bruno.address), brunoBalance - r2.sharesBurned, "shares burned");
    const brunoRequestAfter = await view<any>("arbitrum", core, coreVaultAbi, "payoutRequest", [A.bruno.address]);
    if (r2.usdcOutstanding === 0n) {
      run.eq(brunoRequestAfter.open, false, "DEC-074: the Payout closed the request");
      const toBurn = sharesFor(brunoRequest, r2.sharePrice);
      run.eq(r2.sharesBurned, toBurn < brunoBalance ? toBurn : brunoBalance, "DEC-077: rounded down at the consolidated price");
    } else {
      run.eq(brunoRequestAfter.open, true, "DEC-068: Partial Payout leaves the request open");
      run.eq(brunoRequestAfter.usdcOutstanding, brunoRequest - r2.usdcGross, "DEC-068: the rest stays open");
    }
    run.ok(
      `Bruno claims: unwind target ${units(target)} USDC (shortfall + 2%), hub V4 first, proceeds ${units(r2.unwindProceeds)}; ` +
        `${units(r2.sharesBurned, 18, 0)} shares burned at ${price(r2.sharePrice)}, ${units(r2.usdcPaid)} USDC paid, Payout Fee ${units(r2.payoutFee)}` +
        (r2.usdcOutstanding > 0n ? `, ${units(r2.usdcOutstanding)} outstanding (Partial Payout)` : ""),
    );

    // ------------------------------------------------------------------------------------------------------------
    // Phase 13: invariants (DEC-072, DEC-080, DEC-091, DEC-101, DEC-104)
    // ------------------------------------------------------------------------------------------------------------
    run.phase("Phase 13: value-base invariants and a swept donation (DEC-072, DEC-080, DEC-091, DEC-101, DEC-104)");
    run.true((await view<bigint>("arbitrum", core, coreVaultAbi, "payoutReserve")) <= (await idle()), "DEC-072: Payout Reserve <= Idle");
    run.eq((await view<bigint>("arbitrum", share, shareTokenAbi, "totalSupply")) % WHOLE, 0n, "DEC-091: totalSupply is whole shares");
    await bucketsMatch("DEC-104: Share Assets equals the sum of buckets");
    run.eq((await tx<bigint>("arbitrum", "stranger", core, coreVaultAbi, "sweepExcess", [ARBITRUM.usdc])).result, 0n, "DEC-080: the ledger covers every unit held");
    run.ok("Payout Reserve <= Idle, totalSupply in whole shares, Share Assets = sum of buckets, nothing to sweep");

    const priceBeforeDonation = await sharePrice();
    const idleBeforeDonation = await idle();
    const recipientBeforeSweep = await balance("arbitrum", ARBITRUM.usdc, recipient);
    await tx("arbitrum", "stranger", ARBITRUM.usdc, erc20Abi, "transfer", [core, DONATION]);
    run.eq(await sharePrice(), priceBeforeDonation, "DEC-080: a donation never moves the Share Price");
    run.eq(await idle(), idleBeforeDonation, "DEC-080: nor Idle");
    run.eq(await view("arbitrum", core, coreVaultAbi, "excessRecipient"), recipient, "the Protocol Recipient collects excess");
    run.eq((await tx<bigint>("arbitrum", "stranger", core, coreVaultAbi, "sweepExcess", [ARBITRUM.usdc])).result, DONATION, "DEC-080, DEC-101: swept by the garbage collector");
    run.eq((await balance("arbitrum", ARBITRUM.usdc, recipient)) - recipientBeforeSweep, DONATION, "the donation reached the Protocol Recipient");
    run.eq(await sharePrice(), priceBeforeDonation, "Share Price unchanged");
    await bucketsMatch("DEC-104 after the sweep");
    run.ok(`a stranger donates 1,234 USDC to the Core Vault: Share Price stays ${price(priceBeforeDonation)}, the donation is swept to the Protocol Recipient`);

    const result: ScenarioResult = {
      steps: run.step,
      assertions: run.assertions,
      fund,
      keeper: external ? "external" : "inprocess",
      fills: { real: realFills, simulated: simulatedFills },
    };
    if (!options.quiet) {
      console.log(
        `\n${green(bold("PASS"))} ${run.step} steps, ${run.assertions} assertions; Across fills: ${realFills} through SpokePool.fillRelay, ` +
          `${simulatedFills} simulated; keeper ${result.keeper}; fund ${fund.shareSymbol} ${fund.hub.coreVault}`,
      );
    }
    return result;
  } catch (err) {
    const message = err instanceof AssertionFailed ? err.message : explain(err);
    console.error(`\n${red(bold("FAIL"))} after step #${String(run.step).padStart(2, "0")}: ${message}`);
    throw err;
  } finally {
    if (keeper) await keeper.stop();
  }
}

if (isMain(import.meta.url)) {
  const args = process.argv.slice(2);
  const keeperFlag = args.indexOf("--keeper");
  const keeperMode = (keeperFlag >= 0 ? args[keeperFlag + 1] : "auto") as ScenarioOptions["keeper"];
  if (!["auto", "inprocess", "external"].includes(keeperMode)) {
    console.error("usage: pnpm scenario [--keeper auto|inprocess|external] [--new-fund]");
    process.exit(1);
  }
  try {
    await runScenario({ keeper: keeperMode, newFund: args.includes("--new-fund"), quiet: false });
    process.exit(0);
  } catch {
    process.exit(1);
  }
}
