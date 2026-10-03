// The end-to-end scenario over JSON-RPC: the phases of test/fork/e2e/EndToEnd.t.sol with real signed transactions from
// the actors on the two local forks, the keeper filling Across deposits and delivering VAAs, an extra phase that
// brings Principal home through Across so the hub-side fill is exercised too, the Hub-to-spoke order channel and the
// fund's closure. Every step asserts; the first failed assertion stops the run with a non-zero exit code. Each run
// writes a run report to local-e2e/reports/ (src/report.ts).
//
// Usage: pnpm scenario [--keeper auto|inprocess|external] [--new-fund]
//   --keeper auto (default): use a running `pnpm keeper` if there is one, else start the keeper in-process.
//   --new-fund: create a fresh fund through script/CreateFund.s.sol first (automatic when the deployed fund was used).
import {
  decodeAbiParameters,
  decodeEventLog,
  encodeAbiParameters,
  encodeDeployData,
  encodePacked,
  keccak256,
  zeroAddress,
  type Abi,
  type Address,
  type Hex,
  type TransactionReceipt,
} from "viem";
import {
  aaveV3AdapterAbi,
  acrossBridgeAdapterAbi,
  acrossSpokePoolAbi,
  chainlinkAggregatorAbi,
  chainlinkPriceSourceAbi,
  coreVaultAbi,
  erc20Abi,
  forgeArtifact,
  managerRegistryAbi,
  shareTokenAbi,
  spokeVaultAbi,
  uniswapV3SwapAdapterAbi,
  uniswapV4AdapterAbi,
  valueReportReceiverAbi,
  wormholeCoreAbi,
} from "./abis.ts";
import { API_SLIPPAGE_BPS, quoteSwapRoute } from "./api.ts";
import { deploy, explain, latestTimestamp, nodes, nodesUp, read, send, sendAs, simulateRevert, type Side } from "./chain.ts";
import {
  AAVE_USDC_POOL_KEY,
  ARBITRUM,
  ARBITRUM_CHAIN_ID,
  FUND_PLAN,
  HUB_POOL_ID,
  HUB_POOL_KEY,
  ROBINHOOD,
  ROBINHOOD_CHAIN_ID,
  SPOKE_POOL_ID,
  SPOKE_POOL_KEY,
  WORMHOLE_ARBITRUM,
  WORMHOLE_ROBINHOOD,
  actors,
  isMain,
  type ActorName,
} from "./config.ts";
import { freshFund } from "./deploy.ts";
import {decodeSpokeReport} from "./spoke-report.ts";
import { guardianSetIndexOf, signVaa, universal } from "./guardian.ts";
import { DEFAULT_KEEPER_OPTIONS, runningKeeperPid, startKeeper, type Keeper } from "./keeper.ts";
import { safeConsole as console, bold, dim, green, logger, red, units, type Logger } from "./log.ts";
import { ORDER_CONSISTENCY, ORDER_KIND, ORDER_KIND_NAME, ORDER_LIFETIME, encodeOrder, orderId, type Order } from "./orders.ts";
import { ensureFeedFresh } from "./price-feed.ts";
import { linkedArrival, type DepositEvent, type LinkedArrival } from "./arrivals.ts";
import { RunReport } from "./report.ts";
import { readState, type DeploymentState, type FundRecord } from "./state.ts";
import { FEE_TIERS } from "./swap-route.ts";
import { centerTick, currentTick, generateFees, openParams, oracleAmounts, swapParams } from "./uniswap.ts";
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
const SPOKE_V4_USDG = 3_000n * USD;
const RETURN_AMOUNT = 500n * USD;
const BRUNO_DEPOSIT = 11_000n * USD;
const ANA_PAYOUT = 3_000n * USD;
const BRUNO_ABOVE_FREE_IDLE = 1_000n * USD;
const DONATION = 1_234n * USD;
const HALF_RANGE = 200;
const SWING = 40;
const SWAP_TOLERANCE_BPS = 300n;
/** The manager's maximum loss against the pool mid on his swaps (DEC-142 item 3; 0 would mean none, D-23). */
const MANAGER_MAX_LOSS_BPS = 100;
const FLOW_FEE_BPS = 25n;
const INITIAL_SHARE_PRICE = 10n ** 24n;
const WAD = 10n ** 18n;
const WAIT_SECONDS = 120;

// TransitState and TransferKind (src/interfaces/FundTypes.sol); PayoutMode (ICoreVault).
const SENT = 1;
const ARRIVAL_CONFIRMED = 2;
const PRINCIPAL = 0;
const INSTANT = 0;
const STANDARD = 1;
// FundState (src/interfaces/ICoreVaultLifecycle.sol, DEC-121, DEC-147).
const OPEN = 0;
const CLOSING = 1;

// ---------------------------------------------------------------------------------------------------------------------
// Assertions and the numbered step log
// ---------------------------------------------------------------------------------------------------------------------

class AssertionFailed extends Error {}

/** Failures the scenario already printed (the entry point prints any other). */
const reported = new WeakSet<object>();

class Run {
  step = 0;
  assertions = 0;
  blockers: string[] = [];
  /** The run report, when this run writes one; every phase start is a point of its Share Price timeline. */
  report?: RunReport;
  constructor(readonly log: Logger, readonly quiet: boolean) {}

  async phase(title: string) {
    if (!this.quiet) console.log(`\n${bold(`== ${title}`)}`);
    if (!this.report) return;
    this.report.phase(title);
    if (!title.startsWith("Phase 0")) await this.report.mark(`start of ${title.split(":")[0]}`);
  }

  async ok(message: string) {
    this.step++;
    this.report?.step(message);
    if (this.report) await this.report.capture();
    if (!this.quiet) console.log(`${dim(`#${String(this.step).padStart(2, "0")}`)} ${green("ok")}  ${message}`);
  }

  async independent(title: string, action: () => Promise<void>) {
    await this.phase(title);
    try {
      await action();
    } catch (err) {
      const message = `${title}: ${err instanceof AssertionFailed ? err.message : explain(err)}`;
      this.blockers.push(message);
      this.note(`BLOCKED: ${message}`);
    }
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

const tx = <T = unknown>(side: Side, who: ActorName, address: Address, abi: Abi, functionName: string, args: readonly unknown[] = [], value = 0n) =>
  send<T>(side, who, { address, abi, functionName, args, value });

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
const ceilDiv = (a: bigint, d: bigint) => (a + d - 1n) / d;

/** The Core Vault's `eventName` events since `fromBlock`, with their blocks and transactions. */
async function coreEvents(core: Address, eventName: string, fromBlock: bigint) {
  const logs = await nodes.arbitrum.client.getContractEvents({ address: core, abi: coreVaultAbi, eventName, fromBlock } as never);
  return logs as unknown as { blockNumber: bigint; transactionHash: Hex; args: Record<string, any> }[];
}

/** Waits for the fill of `deposit` (made on `origin`) and the vault's arrival event in it, linked through `FilledRelay`
 *  (src/arrivals.ts). `arrived` only tells a transfer that landed without one (the keeper's simulated fill, which
 *  impersonates the pool) from one still on its way: such a transfer cannot be linked, so it fails the run. */
async function waitForArrival(
  what: string,
  origin: Side,
  deposit: DepositEvent,
  vault: Address,
  abi: Abi,
  eventName: string,
  fromBlock: bigint,
  arrived: () => Promise<boolean>,
): Promise<LinkedArrival> {
  return waitFor(what, async () => {
    const linked = await linkedArrival(origin, deposit, vault, abi, eventName, fromBlock);
    if (linked || !(await arrived())) return linked;
    // The fill and the arrival share a transaction: a fill mined between the two reads is found now.
    const again = await linkedArrival(origin, deposit, vault, abi, eventName, fromBlock);
    if (again) return again;
    throw new AssertionFailed(
      `${what}: the transfer arrived but no FilledRelay fills deposit ${deposit.depositId}; an arrival is linked to its deposit only ` +
        "through FilledRelay, never by its transit id (was the keeper's fill simulated? use --fill-mode auto or real)",
    );
  });
}

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
  /** Write a run report to local-e2e/reports/ (the warm-up of `up` does not). */
  report: boolean;
}

export interface ScenarioResult {
  steps: number;
  assertions: number;
  fund: FundRecord;
  keeper: "inprocess" | "external";
  fills: { real: number; simulated: number };
  /** The run report's files, relative to local-e2e/. */
  report?: { json: string; md: string };
}

export async function runScenario(options: ScenarioOptions, parentLog?: Logger): Promise<ScenarioResult> {
  const log = parentLog ?? logger("scenario", options.quiet);
  const run = new Run(log, options.quiet);
  const state = readState();
  if (options.report) run.report = new RunReport("scenario", state, state.fund);
  const up = await nodesUp();
  if (!up.arbitrum || !up.robinhood) throw new Error("both forks must be running: `pnpm run up` first");

  // --------------------------------------------------------------------------------------------------------------
  // Phase 0: fund and keeper
  // --------------------------------------------------------------------------------------------------------------
  await run.phase("Phase 0: fund and keeper");
  const fresh = await freshFund(state, log.child("deploy"), options.newFund);
  const fund = fresh.fund;
  if (run.report) run.report.fund = fund;
  if (fresh.created) {
    run.note(options.newFund ? "creating a fresh fund (--new-fund)" : "the deployed fund was used: a fresh fund for this run");
    await run.ok(`fresh fund ${fund.shareSymbol} created through script/CreateFund.s.sol (Core Vault ${fund.hub.coreVault})`);
  } else {
    await run.ok(`the deployed fund ${fund.shareSymbol} is unused (Core Vault ${fund.hub.coreVault})`);
  }
  const external = options.keeper === "external" || (options.keeper === "auto" && runningKeeperPid() !== undefined);
  let keeper: Keeper | undefined;
  if (external) {
    if (!runningKeeperPid()) throw new Error("--keeper external: no running keeper (start `pnpm keeper` first)");
    await run.ok(`using the running keeper (pid ${runningKeeperPid()})`);
  } else {
    const keeperState: DeploymentState = { ...state, fund };
    keeper = await startKeeper(keeperState, { ...DEFAULT_KEEPER_OPTIONS, autoReportSeconds: 0, quiet: options.quiet }, log.child("keeper"));
    await run.ok("keeper started in-process (Across fills, Wormhole VAAs, Chainlink re-stamps)");
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
  const orderFee = () => view<bigint>("arbitrum", ARBITRUM.wormholeCore, wormholeCoreAbi, "messageFee");

  const usdcValue = async (token: Address, amount: bigint, at?: bigint) => {
    if (amount === 0n) return 0n;
    if (token.toLowerCase() === ARBITRUM.usdc.toLowerCase()) return amount;
    const [p] = await view<readonly [bigint, bigint]>("arbitrum", priceSource, chainlinkPriceSourceAbi, "priceInUsdc", [token], at);
    return mulDiv(amount, p, WHOLE);
  };
  const unitPrice = async (token: Address, at?: bigint) => {
    if (token.toLowerCase() === ARBITRUM.usdc.toLowerCase()) return WHOLE;
    const [p] = await view<readonly [bigint, bigint]>("arbitrum", priceSource, chainlinkPriceSourceAbi, "priceInUsdc", [token], at);
    return p;
  };
  // Security review S-1 (CoreVaultLogic._oracleComposition): a range position is valued at the price-source price from
  // its liquidity and ticks, never at the pool's spot composition; a single-token position keeps its reported principal.
  const positionAmounts = async (p: any, at?: bigint): Promise<[bigint, bigint]> => {
    if (p.token1 === zeroAddress || p.tickLower >= p.tickUpper || p.liquidity === 0n) return [p.principal0, p.principal1];
    return oracleAmounts(p.tickLower, p.tickUpper, p.liquidity, await unitPrice(p.token0, at), await unitPrice(p.token1, at));
  };
  const principalValue = async (r: any, at?: bigint) => {
    let value = 0n;
    for (const u of r.unallocated) value += await usdcValue(u.token, u.amount, at);
    for (const p of r.positions) {
      const [amount0, amount1] = await positionAmounts(p, at);
      value += (await usdcValue(p.token0, amount0, at)) + (await usdcValue(p.token1, amount1, at));
    }
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
    const managementFee = await view<bigint>("arbitrum", core, coreVaultAbi, "managementFeeAccrued", [], at);
    return total > managementFee ? total - managementFee : 0n;
  };
  const bucketsMatch = async (label: string) => {
    const at = await nodes.arbitrum.client.getBlockNumber();
    run.eq(await view<bigint>("arbitrum", core, coreVaultAbi, "shareAssets", [], at), await sumOfBuckets(at), label);
  };
  const shareAssets = () => view<bigint>("arbitrum", core, coreVaultAbi, "shareAssets");
  const principalAssets = async () => (await shareAssets()) + (await view<bigint>("arbitrum", core, coreVaultAbi, "managementFeeAccrued"));
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
  // DEC-127, DEC-061, DEC-113 (D-34): the manager's seed buys whole shares at 1.00 after the flow fee.
  const seedAmount = BigInt(FUND_PLAN.SEED_AMOUNT);
  const seedFee = bps(seedAmount, FLOW_FEE_BPS);
  const seedShares = sharesFor(seedAmount - seedFee, INITIAL_SHARE_PRICE);
  const seedIdle = usdcFor(seedShares, INITIAL_SHARE_PRICE);

  let realFills = 0;
  try {
    // ------------------------------------------------------------------------------------------------------------
    // Phase 1: the fund as created (DEC-053, DEC-054, FF-OQ-1)
    // ------------------------------------------------------------------------------------------------------------
    await run.phase("Phase 1: the fund as created, with the manager's seed (DEC-053, DEC-054, DEC-127)");
    run.eq(state.protocol.arbitrum.fundFactory, state.protocol.robinhood.fundFactory, "DEC-054: one factory address on both chains");
    run.eq(await view("arbitrum", core, coreVaultAbi, "mandateHash"), fund.mandateHash, "DEC-053: Mandate hash on the Core Vault");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "mandateHash"), fund.mandateHash, "FF-OQ-1: the spoke's Mandate is the hub's");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "coreVault"), core, "the spoke names its Core Vault");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "fundId"), fund.fundId, "the spoke carries the fund id");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "baseToken"), ROBINHOOD.usdg, "DEC-031: USDG on Robinhood");
    await run.ok(`one factory ${state.protocol.arbitrum.fundFactory} on both chains; the Robinhood Spoke Vault carries the hub's Mandate ${fund.mandateHash.slice(0, 10)}...`);
    run.eq(BigInt(mandate.hubChainId), BigInt(ARBITRUM_CHAIN_ID), "DEC-011: Arbitrum One is the Hub Chain");
    run.eq(mandate.spokes.length, 1, "one spoke");
    run.eq(BigInt(spokeCfg.chainId), BigInt(ROBINHOOD_CHAIN_ID), "the spoke is Robinhood Chain");
    run.eq(Number(spokeCfg.wormholeChainId), WORMHOLE_ROBINHOOD, "DEC-086: Wormhole chain 72");
    run.eq(spokeCfg.spokeVault, universal(spokeVault), "DEC-054: the predicted Robinhood Spoke Vault");
    run.eq(Number(spokeCfg.maxReportAge), 1588, "ruling 2026-09-29: 1,587 s plus one block");
    run.eq(mandate.pools[0].poolKey, HUB_POOL_ID, "DEC-030: hub WETH/USDC 0.05%");
    run.eq(mandate.pools[1].poolKey, AAVE_USDC_POOL_KEY, "DEC-018, DEC-028: Aave USDC on the hub");
    run.eq(mandate.pools[2].poolKey, SPOKE_POOL_ID, "DEC-030: spoke WETH/USDG 0.05%");
    // Mandate v2 (WP-07 B): the tokens of each chain, one factory-deployed swap adapter per chain, the Hub's Wormhole
    // chain; no unwind order (DEC-137, DEC-139), Standard Payout term (DEC-154) or bridge fee bound (DEC-156).
    const tokensOf = (chainId: number) =>
      (mandate.tokens as { chainId: bigint; token: Address }[]).filter((t) => Number(t.chainId) === chainId).map((t) => t.token);
    run.eq(tokensOf(ARBITRUM_CHAIN_ID).join(), [ARBITRUM.usdc, ARBITRUM.weth].join(), "DEC-123, DEC-136: hub Mandate tokens USDC and WETH");
    run.eq(tokensOf(ROBINHOOD_CHAIN_ID).join(), [ROBINHOOD.usdg, ROBINHOOD.weth].join(), "DEC-136: spoke Mandate tokens USDG and WETH");
    run.eq(Number(mandate.hubWormholeChainId), WORMHOLE_ARBITRUM, "DEC-120, D-15: the Hub's Wormhole chain 23");
    run.eq(mandate.swapAdapters.length, 2, "DEC-136: one swap adapter per fund chain");
    run.eq(mandate.swapAdapters[0].adapter, fund.hub.uniswapV3SwapAdapter, "DEC-136: the factory's hub swap adapter");
    run.eq(mandate.swapAdapters[1].adapter, fund.spoke.uniswapV3SwapAdapter, "DEC-136: the factory's Robinhood swap adapter");
    run.eq((await view<Address[]>("robinhood", spokeVault, spokeVaultAbi, "swapAdapters")).join(), fund.spoke.uniswapV3SwapAdapter, "DEC-136: the Spoke Vault pins it");
    run.eq(mandate.bridgeAdapters.length, 2, "DEC-088: Across on both sides");
    run.eq(Number(mandate.payoutFeeBps), 200, "DEC-102: Payout Fee 2%");
    run.eq(Number(await view<number>("arbitrum", core, coreVaultAbi, "standardPayoutTerm")), 72 * 3600, "DEC-154: the 72 h protocol term");
    run.eq(BigInt(mandate.minFirstDeposit), 100n * USD, "DEC-061: 100 USDC minimum first deposit");
    run.eq(Number(mandate.performanceFeeBps), 2000, "DEC-107, DEC-184: performance fee 20%, within 10% to 90%");
    run.eq(Number(mandate.managementFeeBps), Number(FUND_PLAN.MANAGEMENT_FEE_BPS), "DEC-108, DEC-186: configured management fee");
    run.eq(mandate.operatingCash.length, 1, "DEC-096: the spoke's Operating Cash entry only");
    // Ruling 2026-10-02: nothing spends Operating Cash in the MVP, so the harness fund plans floor and top-up 0 (the
    // environment may set others; every later check reads the vault's own parameters).
    run.eq(BigInt(mandate.operatingCash[0].floor), BigInt(FUND_PLAN.SPOKE_OPERATING_CASH_FLOOR), "DEC-096: the planned spoke Operating Cash floor");
    run.eq(BigInt(mandate.operatingCash[0].topUp), BigInt(FUND_PLAN.SPOKE_OPERATING_CASH_TOP_UP), "DEC-096: the planned spoke top-up");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "operatingCashFloor"), BigInt(mandate.operatingCash[0].floor), "the Spoke Vault starts at the Mandate's floor");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "operatingCashTopUp"), BigInt(mandate.operatingCash[0].topUp), "the Spoke Vault starts at the Mandate's top-up");
    run.eq(BigInt(await view<number>("arbitrum", core, coreVaultAbi, "flowFeeBps")), FLOW_FEE_BPS, "DEC-106: flow fee 25 bps");
    await run.ok(
      `Mandate: hub V4 WETH/USDC + Aave USDC, spoke V4 WETH/USDG, Across both ways (the adapter's fee rule, DEC-162), ` +
        `Spoke Cap ${units(BigInt(spokeCfg.spokeCap), 6, 0)} USDC, Payout Fee 2%, 72 h term, performance fee 20%, maxReportAge 1588 s; ` +
        `Mandate v2: tokens USDC/WETH and USDG/WETH, a V3 swap adapter per chain, Hub Wormhole chain 23; spoke Operating Cash floor ` +
        `${units(BigInt(mandate.operatingCash[0].floor))} and top-up ${units(BigInt(mandate.operatingCash[0].topUp))} USDG (ruling 2026-10-02: 0)`,
    );

    const [seeded] = await coreEvents(core, "FundSeeded", BigInt(fund.hub.createdInBlock));
    run.true(seeded !== undefined, "DEC-127: FundSeeded in the creation transaction");
    run.eq(BigInt(seeded.blockNumber), BigInt(fund.hub.createdInBlock), "DEC-127: seeded in the creation block");
    run.eq(seeded.args.manager, fund.manager, "DEC-127: the manager seeds");
    run.eq(seeded.args.flowFee, seedFee, "DEC-106, D-34: the seed pays the flow fee");
    run.eq(seeded.args.shares, seedShares, "DEC-035, DEC-061: whole shares at 1.00");
    run.eq(seeded.args.usdcAmount, seedIdle, "DEC-035: the sub-share remainder stays with the manager");
    run.true(seedAmount >= BigInt(mandate.minFirstDeposit), "DEC-061, DEC-127: the seed reaches the Mandate minimum");
    run.eq(await balance("arbitrum", share, fund.manager), seedShares, "the manager holds the first shares");
    run.eq(await view("arbitrum", core, coreVaultAbi, "managerPeakShares"), seedShares, "DEC-146: the seed is the first peak");
    run.eq(await view("arbitrum", share, shareTokenAbi, "totalSupply"), seedShares, "the seed is the whole supply");
    run.eq(Number(await view("arbitrum", core, coreVaultAbi, "fundState")), OPEN, "DEC-121, DEC-147: the fund is Open");
    run.eq(await idle(), seedIdle, "Idle holds the seed");
    run.eq(await sharePrice(), INITIAL_SHARE_PRICE, "DEC-061: 1 share = 1.00 USDC");
    await run.ok(
      `the manager seeded ${units(seedAmount)} USDC at creation: ${units(seedShares, 18, 0)} shares at 1.000000, ` +
        `${units(seedFee)} flow fee, ${units(seedIdle)} in Idle (DEC-127)`,
    );

    // ------------------------------------------------------------------------------------------------------------
    // Phase 2: Ana deposits 10,000 USDC (DEC-061, DEC-106, DEC-035)
    // ------------------------------------------------------------------------------------------------------------
    await run.phase("Phase 2: Ana deposits 10,000 USDC after the seed (DEC-035, DEC-106, DEC-127)");
    await tx("arbitrum", "ana", ARBITRUM.usdc, erc20Abi, "approve", [core, ANA_DEPOSIT]);
    const recipientBefore = await balance("arbitrum", ARBITRUM.usdc, recipient);
    const anaDeposit = await tx<readonly [bigint, bigint]>("arbitrum", "ana", core, coreVaultAbi, "deposit", [ANA_DEPOSIT, 0n]);
    const [anaShares, anaCharged] = anaDeposit.result;
    const fee = bps(ANA_DEPOSIT, FLOW_FEE_BPS);
    run.eq(fee, 25n * USD, "flow fee 25 USDC");
    run.eq((await balance("arbitrum", ARBITRUM.usdc, recipient)) - recipientBefore, fee, "DEC-106: flow fee to the protocol");
    run.eq(anaShares, 9_975n * WHOLE, "DEC-127: 9,975 whole shares at the seed's 1.00");
    run.eq(anaCharged, ANA_DEPOSIT, "DEC-035: nothing left over at 1.00");
    run.eq(await balance("arbitrum", share, A.ana.address), anaShares, "Ana holds her shares");
    run.eq(await idle(), seedIdle + ANA_DEPOSIT - fee, "Idle: the seed and Ana's deposit");
    await bucketsMatch("Share Assets deduct management fee accrual");
    run.true((await sharePrice()) <= INITIAL_SHARE_PRICE, "DEC-114: management fee reduces the initial Share Price");
    await run.ok(`Ana deposits 10,000 USDC: 9,975 shares at 1.000000, 25.00 USDC flow fee to the Protocol Recipient (tx ${anaDeposit.hash.slice(0, 10)})`);

    // ------------------------------------------------------------------------------------------------------------
    // Phase 3: hub allocation, Aave supply, a Uniswap V4 position, income on both (DEC-017, DEC-068, DEC-079, DEC-092)
    // ------------------------------------------------------------------------------------------------------------
    await run.phase("Phase 3: hub allocation, Aave supply, Uniswap V4 position, income (DEC-017, DEC-068, DEC-079, DEC-092)");
    const idleBeforeAllocation = await idle();
    await tx("arbitrum", "manager", core, coreVaultAbi, "allocateToHubSpokeVault", [HUB_ALLOCATION]);
    run.eq(await idle(), idleBeforeAllocation - HUB_ALLOCATION, "DEC-072: Free Idle allocated");
    run.eq(await view("arbitrum", hubSpoke, spokeVaultAbi, "unallocatedBalance", [ARBITRUM.usdc]), HUB_ALLOCATION, "DEC-055: Unallocated Balance");
    await bucketsMatch("DEC-104: allocation preserves principal net of management fee");
    await run.ok("manager allocates 5,000 USDC of Free Idle to the hub Spoke Vault");

    const aaveOpen = await tx<readonly [Hex, bigint, bigint]>("arbitrum", "manager", hubSpoke, spokeVaultAbi, "openPosition", [
      hubAave,
      AAVE_USDC_POOL_KEY,
      AAVE_SUPPLY,
      0n,
      encodeAbiParameters([{ type: "uint256" }], [AAVE_SUPPLY]),
    ]);
    const hubAavePosition = aaveOpen.result[0];
    run.eq(aaveOpen.result[1], AAVE_SUPPLY, "AAVE-2: explicit amount supplied");
    await run.ok("manager supplies 2,000 USDC to Aave V3 through the Aave adapter");

    // DEC-136 (founder chat 1 of 2026-10-02): the manager swaps through the fund's Uniswap V3 swap adapter, never in a
    // Mandate position pool; with no API route the adapter picks the best direct fee tier (DEC-153) and the manager's
    // loss bound against the pool mid holds the output (DEC-142 item 3).
    const half = HUB_V4_USDC / 2n;
    const hubSwapAdapter = fund.hub.uniswapV3SwapAdapter;
    const usdcBeforeSwap = await view<bigint>("arbitrum", hubSpoke, spokeVaultAbi, "unallocatedBalance", [ARBITRUM.usdc]);
    const wethBeforeSwap = await view<bigint>("arbitrum", hubSpoke, spokeVaultAbi, "unallocatedBalance", [ARBITRUM.weth]);
    run.eq(
      await simulateRevert("arbitrum", "manager", {
        address: hubSpoke,
        abi: spokeVaultAbi,
        functionName: "swap",
        args: [hubSwapAdapter, ARBITRUM.usdc, ARBITRUM.weth, half, 1, "0x"],
      }),
      "InsufficientOutput",
      "DEC-142, D-23: a 1 bp loss bound is below any pool fee, so the swap is refused",
    );
    const hubSwap = await tx<bigint>("arbitrum", "manager", hubSpoke, spokeVaultAbi, "swap", [
      hubSwapAdapter,
      ARBITRUM.usdc,
      ARBITRUM.weth,
      half,
      MANAGER_MAX_LOSS_BPS,
      "0x",
    ]);
    const hubWeth = hubSwap.result;
    const [hubSwapped] = events(hubSwap.receipt, hubSpoke, spokeVaultAbi, "Swapped");
    const [hubAdapterSwapped] = events(hubSwap.receipt, hubSwapAdapter, uniswapV3SwapAdapterAbi, "Swapped");
    run.eq(hubSwapped.adapter, hubSwapAdapter, "DEC-136: through the fund's swap adapter");
    run.eq(hubSwapped.amountIn, half, "Swapped amount in");
    run.eq(hubSwapped.amountOut, hubWeth, "Swapped amount out");
    run.eq(Number(hubSwapped.maxLossBps), MANAGER_MAX_LOSS_BPS, "doc 15 gap 4: the event carries the manager's bound");
    run.eq(hubSwapped.minOut, bps(hubSwapped.spotOut, 10_000n - BigInt(MANAGER_MAX_LOSS_BPS)), "DEC-142: no API route, so the minimum is the mid less the bound");
    run.true(hubWeth >= hubSwapped.minOut, "DEC-142: the output meets the minimum");
    run.true(hubWeth >= (await minWethFor(half)), "within 3% of the Chainlink value");
    run.true((FEE_TIERS as readonly number[]).includes(Number(hubAdapterSwapped.directFee)), "DEC-153: the best direct V3 tier");
    run.eq(await view("arbitrum", hubSpoke, spokeVaultAbi, "unallocatedBalance", [ARBITRUM.usdc]), usdcBeforeSwap - half, "DEC-080: exactly the input debited");
    run.eq(await view("arbitrum", hubSpoke, spokeVaultAbi, "unallocatedBalance", [ARBITRUM.weth]), wethBeforeSwap + hubWeth, "DEC-080: swap output credited");
    await run.ok(
      `manager swaps 1,500 USDC for ${units(hubWeth, 18, 4)} WETH through the fund's swap adapter, no API route: V3 tier ` +
        `${Number(hubAdapterSwapped.directFee) / 10_000}%, minimum ${units(hubSwapped.minOut, 18, 4)} (mid less ${MANAGER_MAX_LOSS_BPS} bps); a 1 bp bound reverts InsufficientOutput`,
    );
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
    await run.ok(
      `manager opens a V4 range [${hubCenter - HALF_RANGE}, ${hubCenter + HALF_RANGE}] with ${units(hubUsed0, 18, 4)} WETH + ${units(hubUsed1)} USDC`,
    );

    await warpBoth(3600n);
    const aaveValue = await view<any>("arbitrum", hubAave, aaveV3AdapterAbi, "positionValue", [hubAavePosition]);
    run.eq(aaveValue.principal0, AAVE_SUPPLY, "DEC-068: principal stays the amount supplied");
    run.true(aaveValue.income0 > 0n, "DEC-068: interest since supply is income");
    await run.ok(`both clocks warped 1 h (fresh spoke report delivered): Aave interest ${units(aaveValue.income0)} USDC is income, principal stays 2,000`);

    const hubTicks = await generateFees("arbitrum", state.helpers.arbitrumSwapRouter, HUB_POOL_KEY, ARBITRUM.v4StateView, HUB_POOL_ID, hubCenter, SWING);
    run.true(Math.abs(hubTicks[0] - (hubCenter - SWING)) <= 1 && Math.abs(hubTicks[2] - hubCenter) <= 1, "swaps reached their target ticks");
    const hubV4Value = await view<any>("arbitrum", hubUni, uniswapV4AdapterAbi, "positionValue", [hubUniPosition]);
    run.true(hubV4Value.income0 > 0n, "DEC-079: WETH fees");
    run.true(hubV4Value.income1 > 0n, "DEC-079: USDC fees");
    await bucketsMatch("DEC-092, DEC-104: income is outside Share Assets");
    await run.ok(
      `trader swings the hub pool to ticks ${hubTicks.join(" / ")}: the position earned ${units(hubV4Value.income0, 18, 6)} WETH + ` +
        `${units(hubV4Value.income1)} USDC in fees, outside Share Assets`,
    );

    // ------------------------------------------------------------------------------------------------------------
    // Phase 4: 4,000 USDC to Robinhood through the live Across SpokePool (DEC-037, DEC-066, DEC-085, DEC-087, DEC-158,
    //          DEC-162)
    // ------------------------------------------------------------------------------------------------------------
    await run.phase("Phase 4: 4,000 USDC to Robinhood, the adapter fixing every term (DEC-037, DEC-066, DEC-085, DEC-158, DEC-162)");
    const hubAcross = fund.hub.acrossBridgeAdapter;
    // DEC-162: the adapter prices the send from the route's last sends; a fresh route pays the initial rate plus the
    // fixed part (doc 12 §6, OPEN), both read from the adapter.
    const [quotedToArrive, quotedRate] = await view<readonly [bigint, bigint]>("arbitrum", hubAcross, acrossBridgeAdapterAbi, "quoteSend", [
      ARBITRUM.usdc,
      BigInt(ROBINHOOD_CHAIN_ID),
      BRIDGE_AMOUNT,
      "0x",
    ]);
    const initialRate = await view<bigint>("arbitrum", hubAcross, acrossBridgeAdapterAbi, "INITIAL_RATE");
    const hubFixedFee = await view<bigint>("arbitrum", hubAcross, acrossBridgeAdapterAbi, "fixedFee", [ARBITRUM.usdc]);
    const bridgeFee = BRIDGE_AMOUNT - quotedToArrive;
    run.eq(quotedRate, initialRate, "DEC-162: a route's first send pays the initial rate");
    run.eq(bridgeFee, ceilDiv(BRIDGE_AMOUNT * quotedRate, WAD) + hubFixedFee, "DEC-162: ceil(amount x rate) plus the fixed part");
    await run.ok(`the hub Across adapter quotes ${units(quotedToArrive)} USDG to arrive for 4,000 USDC: rate ${units(quotedRate, 16, 2)}%, fee ${units(bridgeFee)}`);

    const [capValue, capSent, capToHub, cap] = await view<readonly [bigint, bigint, bigint, bigint]>("arbitrum", core, coreVaultAbi, "spokeCapUsage", [0n]);
    const above = cap - (capValue + capSent + capToHub) + USD;
    if (above <= (await view<bigint>("arbitrum", core, coreVaultAbi, "freeIdle"))) {
      run.eq(
        await simulateRevert("arbitrum", "manager", { address: core, abi: coreVaultAbi, functionName: "sendToSpoke", args: [0n, above, 0n, "0x"] }),
        "SpokeCapExceeded",
        "DEC-037, DEC-095: the Spoke Cap bounds the send",
      );
      await run.ok(`a send of ${units(above, 6, 0)} USDC, above the ${units(cap, 6, 0)} USDC Spoke Cap, reverts SpokeCapExceeded`);
    } else {
      run.note(`Spoke Cap refusal not exercised: ${units(above, 6, 0)} USDC above the cap exceeds Free Idle`);
    }
    run.eq(
      await simulateRevert("arbitrum", "manager", {
        address: core,
        abi: coreVaultAbi,
        functionName: "sendToSpoke",
        args: [0n, BRIDGE_AMOUNT, 0n, encodeAbiParameters([{ type: "uint256" }], [BRIDGE_AMOUNT - 1n])],
      }),
      "QuotesNotSupported",
      "DEC-158: the manager passes no bridge parameter",
    );
    await run.ok("a manager who passes his own quote in bridgeData is refused by the adapter (QuotesNotSupported, DEC-158)");

    const assetsBeforeSend = await principalAssets();
    const idleBeforeSend = await idle();
    // DEC-096: the arrival tops Operating Cash up only while it is below its floor (SpokeCrossChainLib
    // `topUpOperatingCash`), so the spoke's cash and Unallocated Balance are read before the fill can land.
    const spokeCashBefore = await view<bigint>("robinhood", spokeVault, spokeVaultAbi, "operatingCash");
    const spokeFloor = await view<bigint>("robinhood", spokeVault, spokeVaultAbi, "operatingCashFloor");
    const spokeTopUp = await view<bigint>("robinhood", spokeVault, spokeVaultAbi, "operatingCashTopUp");
    const spokeUnallocatedBefore = await view<bigint>("robinhood", spokeVault, spokeVaultAbi, "unallocatedBalance", [ROBINHOOD.usdg]);
    const depositIdBefore = await view<number>("arbitrum", ARBITRUM.acrossSpokePool, acrossSpokePoolAbi, "numberOfDeposits");
    const sendTx = await tx<Hex>("arbitrum", "manager", core, coreVaultAbi, "sendToSpoke", [0n, BRIDGE_AMOUNT, 0n, "0x"]);
    const transitId = sendTx.result;
    const transit = await view<any>("arbitrum", core, coreVaultAbi, "transit", [transitId]);
    const amountToArrive: bigint = transit.amountToArrive;
    const sendBlock = await nodes.arbitrum.client.getBlock({ blockNumber: sendTx.receipt.blockNumber });
    run.eq(Number(transit.state), SENT, "DEC-066: state Sent");
    run.eq(amountToArrive, quotedToArrive, "DEC-162: the adapter's amount to arrive is its quote");
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
    run.eq(BigInt(deposited.quoteTimestamp), sendBlock.timestamp, "DEC-158: the adapter quotes at the send's time");
    run.eq(BigInt(deposited.exclusiveRelayer), 0n, "DEC-158, S-9: no exclusive relayer");
    run.eq(Number(deposited.exclusivityDeadline), 0, "no exclusivity");
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
    run.approx(assetsBeforeSend - (await principalAssets()), bridgeFee, AAVE_ROUNDING, "DEC-085: principal drops by the bridge fee only");
    const [, inFlightSentAfter, , capAfter] = await view<readonly [bigint, bigint, bigint, bigint]>("arbitrum", core, coreVaultAbi, "spokeCapUsage", [0n]);
    run.eq(inFlightSentAfter, BRIDGE_AMOUNT, "DEC-066 C1: the Spoke Cap counts the amount sent");
    run.eq(capAfter, BigInt(spokeCfg.spokeCap), "Spoke Cap");
    run.eq(await view("arbitrum", ARBITRUM.usdc, erc20Abi, "allowance", [core, ARBITRUM.acrossSpokePool]), 0n, "DEC-087: approval reset");
    const [priced] = events(sendTx.receipt, hubAcross, acrossBridgeAdapterAbi, "SendPriced");
    run.true(priced !== undefined, "DEC-162: the adapter recorded the send for its fee rule");
    run.eq(priced.rateWad, quotedRate, "SendPriced rate");
    run.eq(priced.fee, bridgeFee, "SendPriced fee");
    await run.ok(
      `manager sends 4,000 USDC with no bridge parameter: Across deposit ${depositIdBefore}, ${units(amountToArrive)} USDG to arrive ` +
        `(fee ${units(bridgeFee)}), escrow ${transit.escrow} as depositor, transit ${transitId.slice(0, 10)}... Sent`,
    );

    // ------------------------------------------------------------------------------------------------------------
    // Phase 5: the keeper fills on Robinhood; a WETH/USDG position; fees (DEC-090, DEC-096, OQ-09)
    // ------------------------------------------------------------------------------------------------------------
    await run.phase("Phase 5: Across fill on Robinhood, spoke position, fees (DEC-079, DEC-090, DEC-096, OQ-09)");
    // Plan amendments (WP-15): the arrival is the Spoke Vault's TransitArrived in the transaction of the FilledRelay that
    // fills this send's deposit, never any arrival under its transit id.
    const spokeFill = await waitForArrival(
      "the Across fill on Robinhood",
      "arbitrum",
      deposited as DepositEvent,
      spokeVault,
      spokeVaultAbi,
      "TransitArrived",
      BigInt(fund.spoke.createdInBlock),
      () => view<boolean>("robinhood", spokeVault, spokeVaultAbi, "hasArrived", [transitId]),
    );
    realFills++;
    run.eq(spokeFill.fill.relayer, universal(A.keeper.address), "the keeper relayed");
    run.eq(spokeFill.fill.recipient, universal(spokeVault), "FilledRelay recipient");
    run.eq(spokeFill.fill.outputAmount, amountToArrive, "FilledRelay output amount");
    run.eq(spokeFill.arrival.transitId, transitId, "DEC-090: the fill of the send's deposit carries its transit id");
    run.eq(spokeFill.arrival.originChainId, BigInt(ARBITRUM_CHAIN_ID), "from the Hub Chain");
    run.eq(spokeFill.arrival.token, ROBINHOOD.usdg, "in the base token");
    run.eq(spokeFill.arrival.amount, amountToArrive, "the amount to arrive");
    run.eq(Number(spokeFill.arrival.kind), PRINCIPAL, "as Principal");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "hasArrived", [transitId]), true, "the Spoke Vault shows the transit arrived");
    await run.ok(
      `the keeper filled deposit ${depositIdBefore} through the Robinhood SpokePool's fillRelay; its FilledRelay links the Spoke Vault's ` +
        `TransitArrived in the same transaction (tx ${spokeFill.receipt.transactionHash.slice(0, 10)}) to transit ${transitId.slice(0, 10)}...`,
    );
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "arrivals", [transitId]), amountToArrive, "OQ-09: credited total per transit id");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "cumulativeReceived"), amountToArrive, "cumulative received");
    const arrivedUsdg = spokeUnallocatedBefore + amountToArrive;
    const topUp = spokeCashBefore < spokeFloor ? (spokeTopUp < arrivedUsdg ? spokeTopUp : arrivedUsdg) : 0n;
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "operatingCash"), spokeCashBefore + topUp, "DEC-096: a top-up only below the floor");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "unallocatedBalance", [ROBINHOOD.usdg]), arrivedUsdg - topUp, "Unallocated Balance on the spoke");
    await run.ok(
      `the Spoke Vault credited ${units(amountToArrive)} USDG to Unallocated Balance` +
        (topUp > 0n
          ? `, ${units(topUp)} of it to Operating Cash (below its ${units(spokeFloor)} floor)`
          : `; Operating Cash ${units(spokeCashBefore)} is not below its floor ${units(spokeFloor)}, so no top-up (ruling 2026-10-02: floor 0)`),
    );

    // Founder chat 1 of 2026-10-02, DEC-143, D-01: on the spoke the manager swaps on a route the API signed for the
    // fund's Robinhood swap adapter (the best V3 path QuoterV2 finds, its minimum the stricter of the quote and the
    // Chainlink value, each less the API's slippage); the stricter of it and the manager's bound applies (DEC-142).
    const spokeHalf = SPOKE_V4_USDG / 2n;
    const spokeSwapAdapter = fund.spoke.uniswapV3SwapAdapter;
    const signed = await quoteSwapRoute(
      { ...state, fund },
      "robinhood",
      ROBINHOOD.usdg,
      ROBINHOOD.weth,
      spokeHalf,
      API_SLIPPAGE_BPS,
      spokeSwapAdapter,
      undefined,
      await minWethFor(spokeHalf),
    );
    run.eq(signed.adapter, spokeSwapAdapter, "D-01: the API signs for the fund's own Robinhood swap adapter");
    run.eq(signed.signer, await view("robinhood", spokeSwapAdapter, uniswapV3SwapAdapterAbi, "routeSigner"), "D-01: the adapter's route signer is the API key");
    const usdgBeforeSwap = await view<bigint>("robinhood", spokeVault, spokeVaultAbi, "unallocatedBalance", [ROBINHOOD.usdg]);
    const spokeSwap = await tx<bigint>("robinhood", "manager", spokeVault, spokeVaultAbi, "swap", [
      spokeSwapAdapter,
      ROBINHOOD.usdg,
      ROBINHOOD.weth,
      spokeHalf,
      MANAGER_MAX_LOSS_BPS,
      signed.encodedRoute,
    ]);
    const spokeWeth = spokeSwap.result;
    const [spokeSwapped] = events(spokeSwap.receipt, spokeVault, spokeVaultAbi, "Swapped");
    const [spokeAdapterSwapped] = events(spokeSwap.receipt, spokeSwapAdapter, uniswapV3SwapAdapterAbi, "Swapped");
    run.eq(spokeSwapped.adapter, spokeSwapAdapter, "DEC-136: through the fund's Robinhood swap adapter");
    run.eq(spokeAdapterSwapped.legsHash, signed.legsHash, "DEC-143: the signed route's legs ran");
    run.true(spokeSwapped.minOut >= signed.route.minAmountOut, "DEC-142: the API minimum holds (the stricter of it and the bound)");
    run.true(spokeWeth >= spokeSwapped.minOut, "the output meets the minimum");
    run.eq(await view("robinhood", spokeVault, spokeVaultAbi, "unallocatedBalance", [ROBINHOOD.usdg]), usdgBeforeSwap - spokeHalf, "DEC-080: exactly the input debited");
    await run.ok(
      `manager swaps 1,500 USDG for ${units(spokeWeth, 18, 4)} WETH on a route the API signed (${signed.path.fees.length} hop(s), fees ` +
        `${signed.path.fees.join("/")}; quoted ${units(signed.quotedAmountOut, 18, 4)}, signed minimum ${units(signed.route.minAmountOut, 18, 4)})`,
    );
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
    await run.ok(`manager opens a V4 range around tick ${spokeCenter} on Robinhood with ${units(spokeUsed0, 18, 4)} WETH + ${units(spokeUsed1)} USDG`);

    const spokeTicks = await generateFees("robinhood", state.helpers.robinhoodSwapRouter, SPOKE_POOL_KEY, ROBINHOOD.v4StateView, SPOKE_POOL_ID, spokeCenter, SWING);
    const spokeV4Value = await view<any>("robinhood", spokeUni, uniswapV4AdapterAbi, "positionValue", [spokeUniPosition]);
    run.true(spokeV4Value.income0 > 0n, "DEC-079: WETH fees on the spoke");
    run.true(spokeV4Value.income1 > 0n, "DEC-079: USDG fees on the spoke");
    await run.ok(`trader swings the spoke pool to ticks ${spokeTicks.join(" / ")}: ${units(spokeV4Value.income0, 18, 6)} WETH + ${units(spokeV4Value.income1)} USDG fees`);

    // ------------------------------------------------------------------------------------------------------------
    // Phase 6: the report on the real Robinhood Core, the VAA delivered on Arbitrum (DEC-066, DEC-086, DEC-090, DEC-093)
    // ------------------------------------------------------------------------------------------------------------
    await run.phase("Phase 6: report on Robinhood, VAA delivered on Arbitrum (DEC-066, DEC-083, DEC-086, DEC-090, DEC-093)");
    const assetsBeforeReport = await principalAssets();
    const inFlightBeforeReport = await view<bigint>("arbitrum", core, coreVaultAbi, "inFlightValue");
    run.eq(inFlightBeforeReport, amountToArrive, "the transit is still in flight on the hub");
    const reported = await tx<readonly [bigint, bigint]>("robinhood", "stranger", spokeVault, spokeVaultAbi, "report");
    const [reportSequence, wormholeSequence] = reported.result;
    const [published] = events(reported.receipt, ROBINHOOD.wormholeCore, wormholeCoreAbi, "LogMessagePublished");
    run.true(published !== undefined, "the real Robinhood Core published the report");
    const decodedReport = decodeSpokeReport(published.payload);
    run.eq(decodedReport.sequence, reportSequence, "v5 payload decodes the report sequence");
    run.true(Array.isArray(decodedReport.refundedTransits), "v5 payload includes authenticated refund proofs");
    run.eq(published.sender, spokeVault, "DEC-086: the Spoke Vault is the emitter");
    run.eq(published.sequence, wormholeSequence, "Wormhole sequence");
    run.eq(Number(published.consistencyLevel), 1, "DEC-093: finalized");
    await run.ok(`anyone calls report(): report ${reportSequence}, Wormhole sequence ${wormholeSequence}, finalized, on the Robinhood Core`);

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
    run.eq(latest.operatingCash, await view("robinhood", spokeVault, spokeVaultAbi, "operatingCash"), "DEC-096: Operating Cash on its own line");
    run.eq(latest.positions.length, 1, "one position in the report");
    run.true(latest.positions[0].income0 + latest.positions[0].income1 > 0n, "DEC-079: income apart from principal");
    run.eq(await view("arbitrum", receiver, valueReportReceiverAbi, "isReportFresh", [0n]), true, "DEC-099: within the report lifetime");
    await run.ok(`the keeper signed the VAA with the local guardian and delivered it: the hub accepted report ${reportSequence}`);

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
    run.approx(await principalAssets(), assetsBeforeReport - inFlightBeforeReport + spokePrincipal, AAVE_ROUNDING, "DEC-083: the spoke value entered principal");
    // With no Operating Cash top-up (floor 0) nothing leaves the principal for sure: the swap's Market Costs lower it,
    // and the WETH it bought is valued at Chainlink, not at the pool's price, so the principal may land on either side
    // of what arrived (security review S-1).
    run.approx(spokePrincipal, amountToArrive, amountToArrive / 100n, "within 1% of the amount that arrived (Market Costs, Chainlink against the pool)");
    await bucketsMatch("DEC-104: Share Assets is the sum of its buckets");
    run.true((await view<bigint>("arbitrum", core, coreVaultAbi, "grossAssets")) > (await shareAssets()), "DEC-098: Gross Assets add income and Operating Cash");
    await run.ok(
      `transit ArrivalConfirmed, In-flight Value 0, spoke principal ${units(spokePrincipal)} USDC (WETH at Chainlink ${units(answer, 8, 2)}, USDG 1:1); ` +
        `Share Assets ${units(await shareAssets())}, Share Price ${price(await sharePrice())}`,
    );

    // ------------------------------------------------------------------------------------------------------------
    // Phase 7 (beyond the fork test): Principal comes home through Across, filled on the hub (DEC-085, DEC-104, OQ-01)
    // ------------------------------------------------------------------------------------------------------------
    await run.phase("Phase 7: 500 USDG of Principal comes home through Across (DEC-085, DEC-104, DEC-162, OQ-01, CV-OQ-1)");
    const idleBeforeReturn = await idle();
    const assetsBeforeReturn = await principalAssets();
    const spokeAcross = fund.spoke.acrossBridgeAdapter;
    const [returnToArrive] = await view<readonly [bigint, bigint]>("robinhood", spokeAcross, acrossBridgeAdapterAbi, "quoteSend", [
      ROBINHOOD.usdg,
      BigInt(ARBITRUM_CHAIN_ID),
      RETURN_AMOUNT,
      "0x",
    ]);
    const returnFee = RETURN_AMOUNT - returnToArrive;
    // DEC-158, DEC-176: the manager names the amount, the kind and the bridge rank only; the spoke's Across adapter fixes
    // every bridge term (WP-07C dropped the quote argument).
    const returnTx = await tx<Hex>("robinhood", "manager", spokeVault, spokeVaultAbi, "sendToHub", [RETURN_AMOUNT, PRINCIPAL, 0n]);
    const returnId = returnTx.result;
    const returnTransit = await view<any>("robinhood", spokeVault, spokeVaultAbi, "hubBoundTransit", [returnId]);
    run.eq(returnTransit.amountToArrive, returnToArrive, "DEC-162: the spoke adapter's amount to arrive is its quote");
    const [returnDeposit] = events(returnTx.receipt, ROBINHOOD.acrossSpokePool, acrossSpokePoolAbi, "FundsDeposited");
    run.true(returnDeposit !== undefined, "the Robinhood SpokePool emitted FundsDeposited");
    run.eq(returnDeposit.destinationChainId, BigInt(ARBITRUM_CHAIN_ID), "destination Arbitrum");
    run.eq(returnDeposit.recipient, universal(core), "the Core Vault receives");
    run.eq(returnDeposit.outputToken, universal(ARBITRUM.usdc), "USDC out");
    run.eq(returnDeposit.outputAmount, returnToArrive, "DEC-162: output amount fixed by the adapter");
    await run.ok(
      `manager sends 500 USDG home with no bridge parameter: Across deposit ${returnDeposit.depositId} from Robinhood, ` +
        `${units(returnToArrive)} USDC to arrive (fee ${units(returnFee)}, fixed by the spoke adapter)`,
    );

    // The Core Vault's TransitReceived in the transaction of the FilledRelay that fills this deposit (plan amendments,
    // WP-15); the transit id the hub then credits under is the one that fill carried. `arrived` only detects an
    // unlinkable (simulated) fill.
    const hubFill = await waitForArrival(
      "the Across fill on Arbitrum",
      "robinhood",
      returnDeposit as DepositEvent,
      core,
      coreVaultAbi,
      "TransitReceived",
      BigInt(fund.hub.createdInBlock),
      async () => (await coreEvents(core, "TransitReceived", BigInt(fund.hub.createdInBlock))).some((e) => e.args.transitId === returnId),
    );
    realFills++;
    run.eq(hubFill.fill.relayer, universal(A.keeper.address), "the keeper relayed on Arbitrum");
    run.eq(hubFill.fill.recipient, universal(core), "FilledRelay recipient: the Core Vault");
    run.eq(hubFill.arrival.transitId, returnId, "DEC-090: the fill of the send's deposit carries its transit id");
    run.eq(hubFill.arrival.originChainId, BigInt(ROBINHOOD_CHAIN_ID), "from Robinhood");
    run.eq(hubFill.arrival.amount, returnToArrive, "the amount to arrive");
    run.eq(hubFill.arrival.matched, false, "OQ-01: held until a report lists it");
    await run.ok(
      `the keeper filled it through the Arbitrum SpokePool's fillRelay; its FilledRelay links the Core Vault's TransitReceived ` +
        `(${units(hubFill.arrival.amount)} USDC, held until a report lists it) to transit ${returnId.slice(0, 10)}...`,
    );
    const returnReport = await tx<readonly [bigint, bigint]>("robinhood", "stranger", spokeVault, spokeVaultAbi, "report");
    await waitForDelivery(spokeRef, returnReport.result[1], WAIT_SECONDS);
    // The credit happens when the hub accepts the report that lists the transfer: the matched TransitReceived of the
    // linked transit id in that delivery's transaction.
    const [acceptedReturn] = (await coreEvents(core, "ReportAccepted", sendTx.receipt.blockNumber)).filter((e) => e.args.reportSequence === returnReport.result[0]);
    run.true(acceptedReturn !== undefined, "the hub accepted the report that lists the transfer");
    const delivery = await nodes.arbitrum.client.waitForTransactionReceipt({ hash: acceptedReturn.transactionHash, pollingInterval: 100 });
    const matchedTotal = events(delivery, core, coreVaultAbi, "TransitReceived")
      .filter((e) => e.transitId === returnId && e.matched)
      .reduce((sum, e) => sum + (e.amount as bigint), 0n);
    run.eq(matchedTotal, returnToArrive, "OQ-01: credited up to what the report listed");
    run.eq(await idle(), idleBeforeReturn + returnToArrive, "Principal reached Idle");
    run.eq(await view("arbitrum", core, coreVaultAbi, "unmatchedArrivals"), 0n, "nothing held apart");
    run.eq(await view("arbitrum", core, coreVaultAbi, "inFlightValue"), 0n, "no return leg in flight once credited");
    run.approx(assetsBeforeReturn - (await principalAssets()), returnFee, AAVE_ROUNDING, "DEC-085: principal drops by the bridge fee only");
    await bucketsMatch("DEC-104: Share Assets is the sum of its buckets");
    await run.ok(`the next report listed the transfer as Principal and the hub credited ${units(matchedTotal)} USDC to Idle`);
    await waitFor("manual sendToHub acknowledgement", async () => {
      const transit = await view<any>("robinhood", spokeVault, spokeVaultAbi, "hubBoundTransit", [returnId]);
      return Number(transit.state) === 2;
    });
    const remainingTransits = await view<readonly Hex[]>("robinhood", spokeVault, spokeVaultAbi, "inFlightTransitIds");
    run.true(!remainingTransits.includes(returnId), "acknowledged manual sendToHub frees its shared in-flight slot");
    const afterAcknowledgement = await view<any>("robinhood", spokeVault, spokeVaultAbi, "buildReport");
    run.true(!afterAcknowledgement.inFlightToHub.some((entry: any) => entry.transitId === returnId), "acknowledged manual transit leaves the v5 report");
    await run.ok("the keeper acknowledged the manual sendToHub and freed its shared send slot");

    // ------------------------------------------------------------------------------------------------------------
    // Phase 8: hub income collected and split at collection (ruling 2026-09-29, DEC-106, DEC-107, DEC-109)
    // ------------------------------------------------------------------------------------------------------------
    await run.phase("Phase 8: hub income collected and split (ruling 2026-09-29, DEC-092, DEC-106, DEC-107, DEC-109)");
    const assetsBeforeCollect = await principalAssets();
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
    run.approx(await principalAssets(), assetsBeforeCollect, AAVE_ROUNDING, "DEC-092: collection leaves principal");
    await run.ok(`manager collects ${units(usdcIncome)} USDC + ${units(wethIncome, 18, 6)} WETH of hub income; Share Assets unchanged`);

    const sliceBps = BigInt(await view<number>("arbitrum", state.protocol.arbitrum.managerRegistry, managerRegistryAbi, "protocolSliceBps", [A.manager.address]));
    run.eq(sliceBps, 5000n, "DEC-106: 50% protocol slice");
    const feeVault = fund.hub.managerFeeVault;
    const recipientBeforeCollection = await balance("arbitrum", ARBITRUM.usdc, recipient);
    const feeVaultBeforeCollection = await balance("arbitrum", ARBITRUM.usdc, feeVault);
    const requestedIncome = await tx("arbitrum", "ana", core, coreVaultAbi, "requestIncomeWithdrawal", [0], await orderFee());
    const collectionEvents = events(requestedIncome.receipt, core, coreVaultAbi, "IncomeCollectionClosed");
    const hubCollection = collectionEvents.find((event) => event.source === 0n);
    run.true(!!hubCollection, "DEC-172: Hub income converted in the collection");
    if (!hubCollection) throw new Error("missing Hub income collection event");
    run.true(hubCollection.dollars > usdcIncome, "DEC-124: WETH income sold for USDC");
    run.eq(hubCollection.fee + hubCollection.attributed, hubCollection.dollars, "DEC-161: collection dollars split");
    run.eq((await balance("arbitrum", ARBITRUM.usdc, recipient)) - recipientBeforeCollection, hubCollection.protocolSlice, "protocol fee paid in USDC");
    run.eq((await balance("arbitrum", ARBITRUM.usdc, feeVault)) - feeVaultBeforeCollection, hubCollection.fee - hubCollection.protocolSlice, "manager fee paid in USDC");
    run.eq(await balance("arbitrum", ARBITRUM.weth, feeVault), 0n, "no in-kind fee retained");
    run.eq(await view("arbitrum", hubSpoke, spokeVaultAbi, "collectedIncome", [ARBITRUM.weth]), 0n, "all Hub WETH income sold");
    await waitFor("income collection on every spoke", async () => {
      const collection = await view<any>("arbitrum", core, coreVaultAbi, "incomeCollection");
      return collection.pendingSpokes === 0n && collection.openResults === 0n;
    });
    const supplyAtCollection = await view<bigint>("arbitrum", share, shareTokenAbi, "totalSupply");
    run.eq(supplyAtCollection, seedShares + anaShares, "the seed's and Ana's shares");
    run.true(await view<bigint>("arbitrum", core, coreVaultAbi, "incomeOwed", [A.ana.address]) > 0n, "DEC-161: Ana has converted dollars");
    await run.ok("income collected on every chain, sold to dollars, and attributed at each collection's rate");

    // ------------------------------------------------------------------------------------------------------------
    // Phase 9: Bruno enters at the new Share Price (DEC-014, DEC-035, DEC-061, OQ-10)
    // ------------------------------------------------------------------------------------------------------------
    await run.phase("Phase 9: Bruno deposits 11,000 USDC at the new Share Price (DEC-014, DEC-035, DEC-061)");
    await ensureFeedFresh(log.child("chainlink"), 600n);
    const priceBeforeBruno = await sharePrice();
    const anaUsdcIncome = await view<bigint>("arbitrum", core, coreVaultAbi, "incomeOwed", [A.ana.address]);
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
    const beforeMintBlock = brunoDeposit.receipt.blockNumber - 1n;
    const feeBeforeMint = await view<bigint>("arbitrum", core, coreVaultAbi, "managementFeeAccrued", [], beforeMintBlock);
    const feeAfterMint = await view<bigint>("arbitrum", core, coreVaultAbi, "managementFeeAccrued", [], brunoDeposit.receipt.blockNumber);
    const feeDrift = feeAfterMint > feeBeforeMint ? feeAfterMint - feeBeforeMint : feeBeforeMint - feeAfterMint;
    run.approx(await view<bigint>("arbitrum", core, coreVaultAbi, "shareAssets", [], beforeMintBlock), minted.shareAssets, AAVE_ROUNDING + feeDrift, "the mint valuation differs only by fee accrual and Aave rounding");
    run.approx(await sharePrice(), priceBeforeBruno, priceBeforeBruno / 10n ** 9n, "DEC-061: rounding only");
    run.eq(await view("arbitrum", core, coreVaultAbi, "incomeOwed", [A.bruno.address]), 0n, "DEC-014: none of the income already generated");
    run.eq(await view("arbitrum", core, coreVaultAbi, "unconvertedIncome", [A.bruno.address, 0n, ARBITRUM.weth]), 0n, "DEC-014: none of the WETH income");
    run.eq(await view("arbitrum", core, coreVaultAbi, "incomeOwed", [A.ana.address]), anaUsdcIncome, "DEC-014: Ana keeps hers");
    await run.ok(`Bruno deposits 11,000 USDC: ${units(brunoShares, 18, 0)} shares at ${price(priceBeforeBruno)}, charged ${units(brunoCharged)} USDC`);

    // ------------------------------------------------------------------------------------------------------------
    // Phase 10: Ana's Income Withdrawal (DEC-025, DEC-073, DEC-109, LC-143)
    // ------------------------------------------------------------------------------------------------------------
    await run.phase("Phase 10: Ana withdraws her income (DEC-025, DEC-073, LC-143)");
    const anaUsdc = await view<bigint>("arbitrum", core, coreVaultAbi, "incomeOwed", [A.ana.address]);
    run.true(anaUsdc > 0n, "DEC-124: actual Income Withdrawal is nonzero");
    const anaUsdcBeforeWithdrawal = await balance("arbitrum", ARBITRUM.usdc, A.ana.address);
    const anaSharesBefore = await balance("arbitrum", share, A.ana.address);
    run.eq((await tx<bigint>("arbitrum", "ana", core, coreVaultAbi, "settleIncomeWithdrawal", [A.ana.address])).result, anaUsdc, "DEC-124: Income Withdrawal pays converted USDC");
    run.eq((await balance("arbitrum", ARBITRUM.usdc, A.ana.address)) - anaUsdcBeforeWithdrawal, anaUsdc, "USDC received without Payout Fee or flow fee");
    run.eq(await balance("arbitrum", share, A.ana.address), anaSharesBefore, "no shares burned");
    run.eq(await view("arbitrum", core, coreVaultAbi, "incomeOwed", [A.ana.address]), 0n, "nothing left owed");
    run.eq((await tx<bigint>("arbitrum", "bruno", core, coreVaultAbi, "withdrawIncome", [])).result, 0n, "DEC-014: Bruno has no earlier income");
    await run.ok("Income Withdrawal pays only USDC and leaves the shares unchanged");

    // ------------------------------------------------------------------------------------------------------------
    // Phase 11: Ana's Standard Payout of 3,000 USDC (DEC-024, DEC-060, DEC-067, DEC-072, DEC-077, DEC-105, DEC-106)
    // ------------------------------------------------------------------------------------------------------------
    await run.phase("Phase 11: Ana's Standard Payout of 3,000 USDC (DEC-060, DEC-067, DEC-072, DEC-077, DEC-105)");
    const idleBeforePayout = await idle();
    const request = await tx("arbitrum", "ana", core, coreVaultAbi, "requestPayout", [ANA_PAYOUT, STANDARD, 0]);
    const requestBlock = await nodes.arbitrum.client.getBlock({ blockNumber: request.receipt.blockNumber });
    const anaRequest = await view<any>("arbitrum", core, coreVaultAbi, "payoutRequest", [A.ana.address]);
    run.eq(anaRequest.reserved, ANA_PAYOUT, "DEC-072: reserved as USDC");
    run.eq(await view("arbitrum", core, coreVaultAbi, "payoutReserve"), ANA_PAYOUT, "Payout Reserve");
    run.eq(anaRequest.termEndsAt, requestBlock.timestamp + 72n * 3600n, "DEC-060: 72 h term");
    run.eq(await balance("arbitrum", share, A.ana.address), anaSharesBefore, "DEC-077: nothing burned at request");
    run.eq(
      await simulateRevert("arbitrum", "ana", { address: core, abi: coreVaultAbi, functionName: "claimPayout", args: [0] }),
      "PayoutTermNotEnded",
      "DEC-060: no claim before the term ends",
    );
    await run.ok("Ana requests a Standard Payout of 3,000 USDC: reserved, term 72 h; claiming now reverts PayoutTermNotEnded");

    await warpBoth(72n * 3600n);
    await run.ok("both clocks warped 72 h; Chainlink re-stamped; a fresh spoke report delivered by the keeper");
    const payoutPrice = await sharePrice();
    const recipientBeforePayout = await balance("arbitrum", ARBITRUM.usdc, recipient);
    const anaBeforeClaim = await balance("arbitrum", ARBITRUM.usdc, A.ana.address);
    const anaClaim = await tx<any>("arbitrum", "ana", core, coreVaultAbi, "claimPayout", [0]);
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
    await run.ok(`Ana claims: ${units(anaBurn, 18, 0)} shares burned at ${price(r1.sharePrice)}, ${units(r1.usdcPaid)} USDC paid, ${units(r1.flowFee)} flow fee`);

    // ------------------------------------------------------------------------------------------------------------
    // Phase 12: Bruno's Instant Payout above Free Idle, with an automatic unwind (DEC-059, DEC-068, DEC-069, DEC-081,
    //           DEC-097, DEC-102, DEC-105)
    // ------------------------------------------------------------------------------------------------------------
    await run.phase("Phase 12: Bruno's Instant Payout above Free Idle, with an unwind (DEC-069, DEC-081, DEC-102, DEC-105, DEC-144)");
    const free = await view<bigint>("arbitrum", core, coreVaultAbi, "freeIdle");
    const instantPrice = await sharePrice();
    const brunoRequest = free + BRUNO_ABOVE_FREE_IDLE;
    const brunoBalance = await balance("arbitrum", share, A.bruno.address);
    run.true(usdcFor(brunoBalance, instantPrice) > brunoRequest, "Bruno holds more than he asks");
    const supply = await view<bigint>("arbitrum", share, shareTokenAbi, "totalSupply");
    const operatingCashBefore = await view<bigint>("arbitrum", core, coreVaultAbi, "operatingCash");
    const aavePrincipalBefore = (await view<any>("arbitrum", hubAave, aaveV3AdapterAbi, "positionValue", [hubAavePosition])).principal0 as bigint;
    const v4LiquidityBefore = (await view<any>("arbitrum", hubUni, uniswapV4AdapterAbi, "positionValue", [hubUniPosition])).liquidity as bigint;
    const brunoUsdcBeforeClaim = await balance("arbitrum", ARBITRUM.usdc, A.bruno.address);
    const idleBeforeClaim = await idle();
    const spokeBeforeClaim = await nodes.robinhood.client.getBlockNumber();
    let brunoClaim = await tx<any>("arbitrum", "bruno", core, coreVaultAbi, "requestPayout", [brunoRequest, INSTANT, 0]);
    const hubUnwindReceipt = brunoClaim.receipt;
    if (events(brunoClaim.receipt, core, coreVaultAbi, "OrderPublished").length) {
      await run.ok("Bruno's Instant Payout unwinds the Hub and awaits the spoke; no shares burned before its report");
      await waitFor("Bruno post-unwind settlement", async () => (await simulateRevert("arbitrum", "stranger", { address: core, abi: coreVaultAbi, functionName: "settlePayout", args: [A.bruno.address] })) === undefined);
      brunoClaim = await tx<any>("arbitrum", "stranger", core, coreVaultAbi, "settlePayout", [A.bruno.address]);
    }
    const r2 = payoutReceipt(brunoClaim.receipt, core);
    const unwound = events(hubUnwindReceipt, hubSpoke, spokeVaultAbi, "UnwoundForPayout");
    run.eq(unwound.length, 1, "one automatic proportional unwind");
    run.true(unwound[0].fracNum > 0n && unwound[0].fracNum <= unwound[0].fracDen, "DEC-137: bounded proportional fraction");
    run.true(unwound[0].result.proceeds <= r2.unwindProceeds, "DEC-080: Hub and spoke proceeds reached Idle");
    run.true(r2.unwindProceeds > 0n, "the unwind produced USDC");
    const aavePrincipalAfter = (await view<any>("arbitrum", hubAave, aaveV3AdapterAbi, "positionValue", [hubAavePosition])).principal0 as bigint;
    const v4LiquidityAfter = (await view<any>("arbitrum", hubUni, uniswapV4AdapterAbi, "positionValue", [hubUniPosition])).liquidity as bigint;
    run.true(aavePrincipalAfter < aavePrincipalBefore, "DEC-137: Aave delivers its proportional share");
    run.true(v4LiquidityAfter < v4LiquidityBefore, "DEC-137: V4 also delivers, regardless of registry order");
    run.approx(v4LiquidityBefore - v4LiquidityAfter, mulDiv(v4LiquidityBefore, unwound[0].fracNum, unwound[0].fracDen), 1n, "V4 liquidity exits at the stored fraction");
    run.true(r2.marketCost >= unwound[0].result.marketCost, "Hub and spoke Market Costs recorded");
    const returnSends = await nodes.robinhood.client.getContractEvents({ address: spokeVault, abi: spokeVaultAbi, eventName: "SentToHub", fromBlock: spokeBeforeClaim + 1n });
    const networkCosts = returnSends.reduce((sum, entry) => {
      const transit = (entry.args as any).transit;
      return sum + BigInt(transit.amountSent) - BigInt(transit.amountToArrive);
    }, 0n);
    run.eq(r2.leaverCost, r2.marketCost + networkCosts, "DEC-118: Instant requester pays Market Costs and return Network Costs");
    run.eq(r2.totalShares, supply, "total shares at the claim");
    run.eq(r2.sharePrice, r2.totalShares === 0n ? INITIAL_SHARE_PRICE : mulDiv(r2.shareAssets + r2.leaverCost, 10n ** 36n, r2.totalShares), "DEC-105: the burn at the Share Price read after the unwind");
    run.eq(r2.usdcGross, usdcFor(r2.sharesBurned, r2.sharePrice), "gross");
    run.eq(r2.payoutFee, bps(r2.usdcGross, 200n), "DEC-102: 2% Payout Fee");
    run.eq(await view<bigint>("arbitrum", core, coreVaultAbi, "operatingCash"), operatingCashBefore, "DEC-144: not into Operating Cash");
    run.eq(await idle(), idleBeforeClaim + r2.unwindProceeds - r2.usdcGross + r2.payoutFee + r2.leaverCost, "DEC-102, DEC-144: the Payout Fee stays in Idle");
    run.eq(r2.flowFee, bps(r2.usdcGross, FLOW_FEE_BPS), "DEC-106: flow fee");
    run.eq(r2.usdcPaid, r2.usdcGross - r2.payoutFee - r2.flowFee - r2.leaverCost, "paid");
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
    await run.ok(
      `Bruno exits inline: proportional Hub unwind, proceeds ${units(r2.unwindProceeds)}; ` +
        `${units(r2.sharesBurned, 18, 0)} shares burned at ${price(r2.sharePrice)}, ${units(r2.usdcPaid)} USDC paid, Payout Fee ${units(r2.payoutFee)} kept in Idle` +
        (r2.usdcOutstanding > 0n ? `, ${units(r2.usdcOutstanding)} outstanding (Partial Payout)` : ""),
    );

    // ------------------------------------------------------------------------------------------------------------
    // Phase 13: invariants (DEC-072, DEC-080, DEC-091, DEC-101, DEC-104)
    // ------------------------------------------------------------------------------------------------------------
    await run.independent("Phase 12b: spoke UNWIND and post-report settlement (DEC-105, DEC-111, DEC-139, DEC-151, DEC-160)", async () => {
      const available = await view<bigint>("arbitrum", core, coreVaultAbi, "freeIdle");
      const hubValue = await principalValue(await view<any>("arbitrum", hubSpoke, spokeVaultAbi, "buildReport"));
      const requested = available + hubValue + 100n * USD;
      run.true(usdcFor(await balance("arbitrum", share, A.ana.address), await sharePrice()) > requested, "Ana can request beyond Idle and all Hub positions");
      const request = await tx("arbitrum", "ana", core, coreVaultAbi, "requestPayout", [requested, STANDARD, 1]);
      await warpBoth(72n * 3600n + 1n);
      const firstClaim = await tx("arbitrum", "ana", core, coreVaultAbi, "claimPayout", [1], await orderFee());
      const published = events(firstClaim.receipt, core, coreVaultAbi, "OrderPublished").filter((entry) => Number(entry.kind) === ORDER_KIND.UNWIND);
      run.eq(published.length, 1, "the Hub publishes UNWIND without impersonation");
      await run.ok(`Ana requests ${units(requested)} USDC: Hub UNWIND ${published[0].orderId}, awaiting the spoke`);
      await waitFor("UNWIND execution", async () => {
        const logs = await nodes.robinhood.client.getContractEvents({ address: spokeVault, abi: spokeVaultAbi, eventName: "OrderExecuted", fromBlock: BigInt(fund.spoke.createdInBlock) });
        return logs.some((entry) => (entry.args as any).orderId === published[0].orderId);
      });
      await waitFor("post-unwind arrival and report", async () => {
        return (await simulateRevert("arbitrum", "stranger", { address: core, abi: coreVaultAbi, functionName: "settlePayout", args: [A.ana.address] })) === undefined;
      });
      const paidBefore = await balance("arbitrum", ARBITRUM.usdc, A.ana.address);
      const settlement = await tx("arbitrum", "stranger", core, coreVaultAbi, "settlePayout", [A.ana.address]);
      const receipt = payoutReceipt(settlement.receipt, core);
      run.true(receipt.sharesBurned > 0n && receipt.usdcPaid > 0n, "permissionless settlement burns and pays");
      run.eq(receipt.usdcGross, usdcFor(receipt.sharesBurned, receipt.sharePrice), "DEC-105: one post-unwind Share Price for the whole burn");
      run.eq((await balance("arbitrum", ARBITRUM.usdc, A.ana.address)) - paidBefore, receipt.usdcPaid, "Ana receives USDC");
      run.true(receipt.excludedPositions > 0n, "DEC-148: 1 bp excludes lossy V4 sales");
      run.true(receipt.usdcOutstanding > 0n, "tight maximum leaves a Partial Payout open");
      run.eq(receipt.payoutFee, 0n, "Standard Payout has no Payout Fee");
      await run.ok(`Standard Payout at maxLossBps=1 excludes ${receipt.excludedPositions} positions; stranger settles ${units(receipt.usdcPaid)} USDC, ${units(receipt.usdcOutstanding)} outstanding`);
      const aaveBeforeRetry = await view<any>("arbitrum", hubAave, aaveV3AdapterAbi, "positionValue", [hubAavePosition]);
      const requestBeforeRetry = await view<any>("arbitrum", core, coreVaultAbi, "payoutRequest", [A.ana.address]);
      const retry = await tx("arbitrum", "ana", core, coreVaultAbi, "claimPayout", [0], await orderFee());
      const requestAfterRetry = await view<any>("arbitrum", core, coreVaultAbi, "payoutRequest", [A.ana.address]);
      run.eq(requestAfterRetry.requestId, requestBeforeRetry.requestId, "DEC-151: retry retains request id");
      run.eq(requestAfterRetry.fracNum, requestBeforeRetry.fracNum, "DEC-151: retry retains fraction numerator");
      run.eq(requestAfterRetry.fracDen, requestBeforeRetry.fracDen, "DEC-151: retry retains fraction denominator");
      run.eq((await view<any>("arbitrum", hubAave, aaveV3AdapterAbi, "positionValue", [hubAavePosition])).principal0, aaveBeforeRetry.principal0, "DEC-151: delivered Aave position is not sold again");
      let retried = retry;
      if (events(retry.receipt, core, coreVaultAbi, "OrderPublished").length) {
        await waitFor("retry report and arrival", async () => (await simulateRevert("arbitrum", "stranger", { address: core, abi: coreVaultAbi, functionName: "settlePayout", args: [A.ana.address] })) === undefined);
        retried = await tx("arbitrum", "stranger", core, coreVaultAbi, "settlePayout", [A.ana.address]);
      }
      const retryReceipt = payoutReceipt(retried.receipt, core);
      run.eq(retryReceipt.excludedPositions, 0n, "DEC-140: unbounded retry sells excluded positions");
      run.true(retryReceipt.marketCostAbsorbed <= retryReceipt.marketCost, "DEC-141: absorbed Market Costs are bounded");
      await run.ok(`maxLossBps=0 retry sells only undelivered positions; pays ${units(retryReceipt.usdcPaid)} USDC, fund absorbs ${units(retryReceipt.marketCostAbsorbed)} USDC Market Costs`);
    });

    await run.phase("Phase 13: value-base invariants and a swept donation (DEC-072, DEC-080, DEC-091, DEC-101, DEC-104)");
    run.true((await view<bigint>("arbitrum", core, coreVaultAbi, "payoutReserve")) <= (await idle()), "DEC-072: Payout Reserve <= Idle");
    run.eq((await view<bigint>("arbitrum", share, shareTokenAbi, "totalSupply")) % WHOLE, 0n, "DEC-091: totalSupply is whole shares");
    await bucketsMatch("DEC-104: Share Assets equals the sum of buckets");
    run.eq((await tx<bigint>("arbitrum", "stranger", core, coreVaultAbi, "sweepExcess", [ARBITRUM.usdc])).result, 0n, "DEC-080: the ledger covers every unit held");
    await run.ok("Payout Reserve <= Idle, totalSupply in whole shares, Share Assets = sum of buckets, nothing to sweep");

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
    await run.ok(`a stranger donates 1,234 USDC to the Core Vault: Share Price stays ${price(priceBeforeDonation)}, the donation is swept to the Protocol Recipient`);

    // ------------------------------------------------------------------------------------------------------------
    // Phase 14: the Hub-to-spoke order channel and executeOrder (DEC-093, DEC-111, DEC-120, DEC-139; WP-07 D4)
    // ------------------------------------------------------------------------------------------------------------
    await run.phase("Phase 14: the Hub-to-spoke order channel and executeOrder (DEC-093, DEC-111, DEC-120, DEC-139)");
    await warpBoth(0n);
    // Until the Core Vault publishes orders itself (WP-09 on), an order is published from its address (impersonated)
    // on the live Arbitrum Core, so the keeper's relay, the guardian on the Robinhood Core and the Spoke Vault's
    // `executeOrder` run now. Only a kind the Spoke Vault does not execute yet is published that way: an executed UNWIND
    // would sell the fund's positions for a request nobody made. Each kind is probed first by simulating `executeOrder`
    // with a VAA for the Core Vault's next sequence: a stub executor reverts OrderKindNotSupported, and only after every
    // order check passed. The kinds the Spoke Vault executes are published by the Core Vault itself in the phases of
    // the payouts, the income collection and the closure.
    const KINDS = [ORDER_KIND.UNWIND, ORDER_KIND.CLOSE, ORDER_KIND.COLLECT];
    const kindNames = (kinds: number[]) => kinds.map((k) => ORDER_KIND_NAME[k]).join(", ");
    const hubFee = await view<bigint>("arbitrum", ARBITRUM.wormholeCore, wormholeCoreAbi, "messageFee");
    const spokeFee = await view<bigint>("robinhood", ROBINHOOD.wormholeCore, wormholeCoreAbi, "messageFee");
    const spokeGuardianSet = await guardianSetIndexOf("robinhood");
    const hubNow = await latestTimestamp("arbitrum");
    const spokeNow = await latestTimestamp("robinhood");
    const orderOf = (kind: number): Order => ({
      kind,
      fundId: fund.fundId,
      requestId: keccak256(encodePacked(["string", "uint8", "uint256"], ["local-e2e order channel", kind, hubNow])),
      attempt: 0,
      deadline: hubNow + ORDER_LIFETIME,
      fracNum: kind === ORDER_KIND.UNWIND ? 1n : kind === ORDER_KIND.CLOSE ? 1n : 0n,
      fracDen: kind === ORDER_KIND.UNWIND ? 10n : kind === ORDER_KIND.CLOSE ? 1n : 0n,
      maxLossBps: 0,
      payoutMode: INSTANT,
      closingStartedAt: kind === ORDER_KIND.CLOSE ? (hubNow < spokeNow ? hubNow : spokeNow) : 0n,
    });
    const orderVaa = (sequence: bigint, timestamp: bigint, payload: Hex, emitter: Address = core) =>
      signVaa(
        {
          timestamp: Number(timestamp),
          nonce: 0,
          emitterChainId: WORMHOLE_ARBITRUM,
          emitterAddress: universal(emitter),
          sequence,
          consistencyLevel: ORDER_CONSISTENCY,
          payload,
        },
        spokeGuardianSet,
      );
    const executeRevert = (vaa: Hex) =>
      simulateRevert("robinhood", "keeper", { address: spokeVault, abi: spokeVaultAbi, functionName: "executeOrder", args: [vaa], value: spokeFee });

    const nextSequence = await view<bigint>("arbitrum", ARBITRUM.wormholeCore, wormholeCoreAbi, "nextSequence", [core]);
    const probed = new Map<number, string | undefined>();
    for (const kind of KINDS) probed.set(kind, await executeRevert(await orderVaa(nextSequence, hubNow, encodeOrder(orderOf(kind)))));
    const stubs = KINDS.filter((k) => probed.get(k) === "OrderKindNotSupported");
    const executes = KINDS.filter((k) => probed.get(k) === undefined);
    run.eq(
      stubs.length + executes.length,
      KINDS.length,
      `every kind either executes or is not supported yet (${KINDS.map((k) => `${ORDER_KIND_NAME[k]}: ${probed.get(k) ?? "executes"}`).join(", ")})`,
    );
    await run.ok(
      `executeOrder probed with one order of each kind for the Core Vault's next sequence ${nextSequence}: ` +
        (stubs.length ? `${kindNames(stubs)} not supported yet (OrderKindNotSupported, after the order checks)` : "none refused") +
        (executes.length ? `; ${kindNames(executes)} executed (left to the phases that publish them)` : ""),
    );

    if (stubs.length === 0) {
      run.note("every order kind executes on the Spoke Vault: the Core Vault's own orders exercise the channel in the payout, income and closure phases");
    } else {
      const unsupportedBefore = keeper?.stats.ordersUnsupported ?? 0;
      const published: { kind: number; order: Order; message: Record<string, any>; timestamp: bigint }[] = [];
      for (const kind of stubs) {
        const order = orderOf(kind);
        const sent = await sendAs("arbitrum", core, {
          address: ARBITRUM.wormholeCore,
          abi: wormholeCoreAbi,
          functionName: "publishMessage",
          args: [0, encodeOrder(order), ORDER_CONSISTENCY],
          value: hubFee,
        });
        const [message] = events(sent.receipt, ARBITRUM.wormholeCore, wormholeCoreAbi, "LogMessagePublished");
        run.eq(message.sender, core, "DEC-111: the Core Vault is the emitter");
        run.eq(Number(message.consistencyLevel), ORDER_CONSISTENCY, "DEC-120 item 1: instant consistency");
        const block = await nodes.arbitrum.client.getBlock({ blockNumber: sent.receipt.blockNumber });
        published.push({ kind, order, message, timestamp: block.timestamp });
      }
      await run.ok(
        `${kindNames(stubs)} order(s) published from the Core Vault on the live Arbitrum Core at instant consistency: ` +
          `sequence(s) ${published.map((p) => p.message.sequence).join(", ")}, message fee ${hubFee} wei`,
      );

      if (keeper) {
        await waitFor("the keeper's relay of the orders", async () => published.every((p) => keeper!.handledOrder(core, p.message.sequence)));
        run.eq(keeper.stats.ordersUnsupported - unsupportedBefore, stubs.length, "the keeper counted each order as not yet supported");
        await run.ok(
          "the keeper signed each order for the Robinhood Core and called executeOrder, paying the report's message fee; the Spoke Vault " +
            "answered OrderKindNotSupported, which the keeper logs as not yet supported: nothing left waiting, nothing retried",
        );
        // A restart: a second keeper started after the publication rescans both chains from the fork block, discovers
        // the fund from the factories' events (as it does every fund) and relays the orders too. It runs in the same
        // process as the first keeper, so their transactions share one nonce queue.
        const restarted = await startKeeper(state, { ...DEFAULT_KEEPER_OPTIONS, autoReportSeconds: 0, quiet: true }, log.child("restarted"));
        try {
          await waitFor("a restarted keeper's relay of the orders", async () => published.every((p) => restarted.handledOrder(core, p.message.sequence)));
          run.eq(restarted.stats.ordersUnsupported, stubs.length, "the restarted keeper treats them the same way");
        } finally {
          await restarted.stop();
        }
        await run.ok("a keeper started after the orders were published rescans from the fork block and relays them too");
      } else {
        run.note("external keeper: its log shows each order relayed and refused as not yet supported");
      }

      // The keeper's VAA of the first order, rebuilt: a refused order reverted the whole call, so the order cursor did
      // not move and the same VAA is refused the same way (not OrderSequenceTooLow); an order from another emitter is
      // refused by the order checks before any executor runs.
      const first = published[0];
      const firstVaa = await orderVaa(first.message.sequence, first.timestamp, first.message.payload);
      run.eq(await executeRevert(firstVaa), "OrderKindNotSupported", "DEC-093: a refused order leaves the order cursor where it was");
      run.eq(
        await executeRevert(await orderVaa(first.message.sequence, first.timestamp, first.message.payload, A.stranger.address)),
        "OrderEmitterMismatch",
        "DEC-111: only the fund's Core Vault emits its orders",
      );
      await run.ok(
        `the ${ORDER_KIND_NAME[first.kind]} order's VAA is still refused as not supported (the cursor did not move); the same order from ` +
          "another emitter is refused by the order checks (OrderEmitterMismatch)",
      );

      // Acceptance in full: the same VAA passes OrderVerifier against the live Robinhood Core through the test receiver
      // (test/mocks/wormhole/OrderVerifierHarness.sol), which has no executor to refuse it, and executes once.
      const receiverArtifact = forgeArtifact("OrderVerifierHarness.sol", "OrderReceiverHarness");
      const orderReceiver = await deploy(
        "robinhood",
        "stranger",
        encodeDeployData({ abi: receiverArtifact.abi, bytecode: receiverArtifact.bytecode, args: [ROBINHOOD.wormholeCore, WORMHOLE_ARBITRUM, core, fund.fundId] }),
        "deploy OrderReceiverHarness",
      );
      const executed = await tx("robinhood", "keeper", orderReceiver, receiverArtifact.abi, "execute", [firstVaa]);
      const [done] = events(executed.receipt, orderReceiver, receiverArtifact.abi, "OrderExecuted");
      run.eq(Number(done.kind), first.kind, "the order kind");
      run.eq(done.orderId, orderId(first.order), "OrderCodec: one id per (kind, fund, request, attempt)");
      run.eq(done.wormholeSequence, first.message.sequence, "the Hub's sequence");
      run.eq(
        await simulateRevert("robinhood", "keeper", { address: orderReceiver, abi: receiverArtifact.abi, functionName: "execute", args: [firstVaa] }),
        "OrderSequenceTooLow",
        "DEC-093: an order executes once",
      );
      await run.ok("the same VAA passes OrderVerifier on the live Robinhood Core (emitter chain 23, the Core Vault, the fund, the sequence) and executes once; a replay reverts");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Phase 15: the manager's base and the fund's closure (DEC-146, DEC-147, DEC-149, D-26, D-27)
    // ------------------------------------------------------------------------------------------------------------
    await run.phase("Phase 15: the manager's base and the fund's closure (DEC-117, DEC-146, DEC-147, DEC-149)");
    const managerShares = await balance("arbitrum", share, fund.manager);
    const peak = await view<bigint>("arbitrum", core, coreVaultAbi, "managerPeakShares");
    const base = peak - peak / 2n;
    run.eq(managerShares, peak, "DEC-146: the manager holds his peak");
    const closePrice = await sharePrice();
    const overBase = usdcFor(managerShares - base + WHOLE, closePrice); // leaves less than half of the peak
    const withinBase = usdcFor(((managerShares - base) / WHOLE) * WHOLE, closePrice);
    run.eq(
      await simulateRevert("arbitrum", "manager", { address: core, abi: coreVaultAbi, functionName: "requestPayout", args: [overBase, INSTANT, 0] }),
      "ManagerMustCloseFund",
      "DEC-146, DEC-147 item 1: below half of the peak the manager must close the fund",
    );
    run.eq(
      await simulateRevert("arbitrum", "manager", { address: core, abi: coreVaultAbi, functionName: "requestPayout", args: [withinBase, INSTANT, 0] }),
      undefined,
      "DEC-146: down to half of the peak the manager may request",
    );
    await run.ok(`a manager request of ${units(overBase)} USDC would leave him under half of his ${units(peak, 18, 0)}-share peak: ManagerMustCloseFund; ${units(withinBase)} USDC is allowed`);

    const closing = await tx("arbitrum", "manager", core, coreVaultAbi, "closeFund");
    const closedAt = (await nodes.arbitrum.client.getBlock({ blockNumber: closing.receipt.blockNumber })).timestamp;
    const [closingEvent] = events(closing.receipt, core, coreVaultAbi, "FundClosing");
    run.eq(closingEvent.closingStartedAt, closedAt, "DEC-147: FundClosing at the block time");
    run.eq(Number(await view("arbitrum", core, coreVaultAbi, "fundState")), CLOSING, "DEC-147: Closing");
    run.eq(await view("arbitrum", core, coreVaultAbi, "closingStartedAt"), closedAt, "closingStartedAt");
    await run.ok(`the manager calls closeFund: the fund is Closing since ${new Date(Number(closedAt) * 1000).toISOString()}`);

    await tx("arbitrum", "bruno", ARBITRUM.usdc, erc20Abi, "approve", [core, 1_000n * USD]);
    run.eq(
      await simulateRevert("arbitrum", "bruno", { address: core, abi: coreVaultAbi, functionName: "deposit", args: [1_000n * USD, 0n] }),
      "FundNotOpen",
      "DEC-147 item 2: no deposit while Closing",
    );
    run.eq(
      await simulateRevert("arbitrum", "ana", { address: core, abi: coreVaultAbi, functionName: "requestPayout", args: [100n * USD, STANDARD, 0] }),
      "FundNotOpen",
      "DEC-147 item 2: no new Payout Request while Closing",
    );
    run.eq(
      await simulateRevert("arbitrum", "ana", { address: core, abi: coreVaultAbi, functionName: "claimPayout", args: [0] }),
      "FundNotOpen",
      "D-26: no claim while Closing",
    );
    run.eq(
      await simulateRevert("arbitrum", "manager", { address: core, abi: coreVaultAbi, functionName: "closeFund" }),
      "FundNotOpen",
      "DEC-149: closing is irreversible and happens once",
    );
    const managerIncome = await view<bigint>("arbitrum", core, coreVaultAbi, "incomeOwed", [fund.manager]);
    const withdrawn = await tx<bigint>("arbitrum", "manager", core, coreVaultAbi, "withdrawIncome", []);
    run.eq(withdrawn.result, managerIncome, "DEC-117 item 4: Income Withdrawal stays open while Closing");
    await run.ok(
      `while Closing: deposits, new requests, claims and a second closeFund revert FundNotOpen; ` +
        `the manager still withdraws ${units(managerIncome)} USDC of his seed's income`,
    );

    await run.independent("Phase 16: full closure and frozen exits (DEC-114, DEC-135, DEC-149, DEC-150, DEC-163, DEC-167)", async () => {
      const feeBefore = await balance("arbitrum", ARBITRUM.usdc, fund.hub.managerFeeVault);
      const recipientBefore = await balance("arbitrum", ARBITRUM.usdc, recipient);
      run.eq(await simulateRevert("arbitrum", "stranger", { address: core, abi: coreVaultAbi, functionName: "unwindAllAfterDeadline", value: await orderFee() }), "ClosingDeadlineNotReached", "DEC-149: stranger cannot unwind before the deadline");
      await tx("arbitrum", "manager", hubSpoke, spokeVaultAbi, "closePosition", [hubAave, hubAavePosition, "0x"]);
      run.true(!(await view<any[]>("arbitrum", hubSpoke, spokeVaultAbi, "positions")).some((position) => position.adapter.toLowerCase() === hubAave.toLowerCase()), "manager partially unwinds Aave while Closing");
      await run.ok("manager closes the remaining Hub Aave position during the 72-hour closure window; premature stranger unwind is refused");
      await warpBoth(72n * 3600n + 1n);
      const unwind = await send("arbitrum", "stranger", { address: core, abi: coreVaultAbi, functionName: "unwindAllAfterDeadline", value: await orderFee(), gas: 15_000_000n });
      run.eq(events(unwind.receipt, core, coreVaultAbi, "ClosureUnwindFailed").length, 0, "Hub closure unwind succeeds rather than swallowing an under-gassed call");
      const closeOrders = events(unwind.receipt, core, coreVaultAbi, "OrderPublished").filter((entry) => Number(entry.kind) === ORDER_KIND.CLOSE);
      run.eq(closeOrders.length, 1, "Hub publishes CLOSE");
      await run.ok(`stranger unwinds the Hub after the deadline and publishes CLOSE ${closeOrders[0].orderId}`);
      await waitFor("CLOSE execution", async () => {
        const logs = await nodes.robinhood.client.getContractEvents({ address: spokeVault, abi: spokeVaultAbi, eventName: "OrderExecuted", fromBlock: BigInt(fund.spoke.createdInBlock) });
        return logs.some((entry) => (entry.args as any).orderId === closeOrders[0].orderId);
      });
      await waitFor("post-close transits credited", async () => {
        const [report] = await view<readonly [any, bigint, bigint]>("arbitrum", receiver, valueReportReceiverAbi, "latestReport", [0n]);
        const [principal, , returning] = await view<readonly [bigint, bigint, bigint, bigint]>("arbitrum", core, coreVaultAbi, "spokeCapUsage", [0n]);
        return report.positions.length === 0 && report.unallocated.every((entry: any) => entry.amount === 0n) && principal === 0n && returning === 0n && (await view<bigint>("arbitrum", core, coreVaultAbi, "unmatchedArrivals")) === 0n;
      });
      await run.ok("CLOSE executes on Robinhood; its Principal fill and empty post-close report arrive before any further warp");
      await waitFor("empty post-close report", async () => {
        const [report] = await view<readonly [any, bigint, bigint]>("arbitrum", receiver, valueReportReceiverAbi, "latestReport", [0n]);
        return report.positions.length === 0 && report.unallocated.every((entry: any) => entry.amount === 0n) && report.inFlightToHub.length === 0;
      });
      await run.ok("Hub ACKNOWLEDGE orders retire resolved Principal sends; final report has no In-flight Value");
      const terminal = await send("arbitrum", "stranger", { address: core, abi: coreVaultAbi, functionName: "unwindAllAfterDeadline", value: await orderFee(), gas: 15_000_000n });
      const [terminalOrder] = events(terminal.receipt, core, coreVaultAbi, "OrderPublished");
      await waitFor("terminal CLOSE result after acknowledgements", async () => {
        const [report] = await view<readonly [any, bigint, bigint]>("arbitrum", receiver, valueReportReceiverAbi, "latestReport", [0n]);
        return report.unwindResults.toLowerCase().includes(terminalOrder.orderId.slice(2).toLowerCase()) && report.inFlightToHub.length === 0;
      });
      await tx("arbitrum", "manager", core, coreVaultAbi, "requestIncomeWithdrawal", [0], await orderFee());
      await waitFor("final income collection", async () => {
        const collection = await view<any>("arbitrum", core, coreVaultAbi, "incomeCollection");
        return collection.pendingSpokes === 0n && collection.openResults === 0n;
      });
      const finalized = await tx("arbitrum", "stranger", core, coreVaultAbi, "finalizeClosure");
      const [closed] = events(finalized.receipt, core, coreVaultAbi, "FundClosed");
      run.eq(Number(await view("arbitrum", core, coreVaultAbi, "fundState")), 2, "fund Closed");
      if (Number(FUND_PLAN.MANAGEMENT_FEE_BPS) > 0) run.true(closed.managementFeePaid > 0n, "DEC-114: accrued management fee paid");
      run.true((await balance("arbitrum", ARBITRUM.usdc, fund.hub.managerFeeVault)) >= feeBefore, "manager fees held in USDC");
      run.true((await balance("arbitrum", ARBITRUM.usdc, recipient)) > recipientBefore, "protocol slice paid in USDC");
      await run.ok(`finalizeClosure freezes ${units(closed.closedIdle)} USDC / ${units(closed.closedSupply, 18, 0)} shares; management fee ${units(closed.managementFeePaid)} USDC`);
      run.eq(await balance("arbitrum", share, fund.manager), 0n, "DEC-167: finalizeClosure burns and pays the manager's shares");
      await warp(1589n, { log: log.child("warp"), report: false, deliverer: "keeper" });
      run.eq(await view("arbitrum", receiver, valueReportReceiverAbi, "isReportFresh", [0n]), false, "closed exits run with a deliberately stale spoke report");
      await run.ok("manager exits at finalization; Ana and Bruno's frozen exits need no fresh report after a 1,589-second warp");
      for (const name of ["ana", "bruno", "manager"] as const) {
        const shares = await balance("arbitrum", share, A[name].address);
        if (shares === 0n) continue;
        const exited = await tx("arbitrum", "stranger", core, coreVaultAbi, "exitClosedFund", [A[name].address]);
        const [event] = events(exited.receipt, core, coreVaultAbi, "ClosedFundExited");
        run.eq(event.gross, mulDiv(shares, closed.closedIdle, closed.closedSupply), "DEC-167: frozen split");
        run.eq(event.flowFee, bps(event.gross, FLOW_FEE_BPS), "DEC-150: flow fee only");
        run.eq(await balance("arbitrum", share, A[name].address), 0n, "all shares burned");
        await run.ok(`${name} exits Closed at the frozen split: ${units(event.paid)} USDC, no report or Payout Fee`);
      }
      run.eq(await view("arbitrum", share, shareTokenAbi, "totalSupply"), 0n, "every remaining investor exited");
      await tx("arbitrum", "stranger", core, coreVaultAbi, "sweepExcess", [ARBITRUM.usdc]);
      await run.ok("zero-supply garbage collection sweeps remaining USDC to the Protocol Recipient");
      const conservation = await run.report?.conservation();
      if (conservation) {
        run.true(conservation.passed, "fund-wide conservation: value in = value out + fees + remaining");
        run.true(conservation.coreCash.passed, "Core Vault USDC cash conservation");
        run.true(conservation.bridgeFees > 0n, "conservation includes actual bridge costs, not internal sends as market income");
        run.eq(conservation.remainingPositions, 0n, "conservation has no remaining investment positions");
        run.eq(conservation.inFlight, 0n, "conservation has no unresolved transits");
        await run.ok(`fund-wide conservation residual ${conservation.residual} USDC base units; bridge costs ${units(conservation.bridgeFees)} USDC`);
      }
    });

    if (run.blockers.length) throw new AssertionFailed(run.blockers.join("\n"));
    const result: ScenarioResult = {
      steps: run.step,
      assertions: run.assertions,
      fund,
      keeper: external ? "external" : "inprocess",
      fills: { real: realFills, simulated: keeper?.stats.simulatedFills ?? 0 },
    };
    if (run.report) {
      run.report.assertions = run.assertions;
      result.report = await run.report.write({ passed: true, extra: { keeper: result.keeper, fills: result.fills, keeperStats: keeper?.stats } });
    }
    if (!options.quiet) {
      console.log(
        `\n${green(bold("PASS"))} ${run.step} steps, ${run.assertions} assertions; Across fills: ${realFills} through SpokePool.fillRelay, ` +
          `each linked to its deposit by FilledRelay; keeper ${result.keeper}; fund ${fund.shareSymbol} ${fund.hub.coreVault}`,
      );
      if (result.report) console.log(`run report: local-e2e/${result.report.md} (and .json)`);
    }
    return result;
  } catch (err) {
    const message = err instanceof AssertionFailed ? err.message : explain(err);
    console.error(`\n${red(bold("FAIL"))} after step #${String(run.step).padStart(2, "0")}: ${message}`);
    if (err && typeof err === "object") reported.add(err);
    if (run.report) {
      run.report.assertions = run.assertions;
      const files = await run.report.write({ passed: false, error: message, extra: { keeperStats: keeper?.stats } });
      console.error(`run report: local-e2e/${files.md} (and .json)`);
    }
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
    await runScenario({ keeper: keeperMode, newFund: args.includes("--new-fund"), quiet: false, report: true });
    process.exit(0);
  } catch (err) {
    if (!(err && typeof err === "object" && reported.has(err))) console.error(`\n${red(bold("FAIL"))}: ${explain(err)}`);
    process.exit(1);
  }
}
