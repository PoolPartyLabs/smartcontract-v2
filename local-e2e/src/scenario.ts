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
