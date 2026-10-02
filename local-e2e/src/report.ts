// Run reports: every scenario and API probe run writes local-e2e/reports/<time>-<kind>.json and .md with its steps and
// assertions, the gas of every transaction it sent (and per verb), the Share Price timeline (per phase, and at every
// Core Vault event), the fee ledger (flow fee, Payout Fee, performance fee and its slices, management fee, bridge
// fees) and the final balances. The v2 end-to-end runs (WP-15, WP-18) and the founder's report read the same files.
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import type { Address } from "viem";
import { acrossSpokePoolAbi, chainlinkPriceSourceAbi, coreVaultAbi, erc20Abi, shareTokenAbi, spokeVaultAbi } from "./abis.ts";
import { nodes, read, transactionLog, type TxRecord } from "./chain.ts";
import { ACTOR_NAMES, ARBITRUM, HARNESS_DIR, REPO_DIR, REPORTS_DIR, ROBINHOOD, actors } from "./config.ts";
import { feeLedger, sharePriceHistory, type FeeLedger, type SharePricePoint } from "./history.ts";
import { redactUrls, units } from "./log.ts";
import type { DeploymentState, FundRecord } from "./state.ts";

export interface ReportStep {
  n: number;
  phase: string;
  message: string;
  transactions?: ReportTx[];
  balances?: Balances;
  fees?: FeeLedger;
}

export interface TimelinePoint {
  label: string;
  block: bigint;
  timestamp: bigint;
  sharePrice: bigint;
  shareAssets: bigint;
  totalShares: bigint;
}

export interface GasLine {
  chainId: number;
  contract: string;
  label: string;
  count: number;
  totalGas: bigint;
  minGas: bigint;
  maxGas: bigint;
}

interface ReportTx extends TxRecord {
  contract: string;
}

interface Balances {
  /** Hub USDC, Robinhood USDG, hub WETH and shares of each actor. */
  actors: Record<string, { usdc: bigint; usdg: bigint; weth: bigint; shares: bigint; incomeOwed: bigint; shareValue: bigint }>;
  managerFeeVault: { usdc: bigint; weth: bigint };
  coreVault: Record<string, bigint | number>;
}

const SIDE_NAME: Record<number, string> = { 42161: "Arbitrum", 4663: "Robinhood" };

function git(args: string[]): string {
  try {
    return execFileSync("git", ["-C", REPO_DIR, ...args], { encoding: "utf8" }).trim();
  } catch {
    return "";
  }
}

const json = (value: unknown) => JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : typeof v === "string" ? redactUrls(v) : v), 2);
const usdc = (value: bigint) => units(value, 6, 2);
/** Fees can be fractions of a cent: the ledger keeps every base unit. */
const usdcExact = (value: bigint) => units(value, 6, 6);
const priceOf = (sharePrice: bigint) => units(sharePrice / 10n ** 18n, 6, 6);
const time = (timestamp: bigint) => new Date(Number(timestamp) * 1000).toISOString().replace(".000Z", "Z");

export class RunReport {
  readonly startedAt = new Date();
  readonly steps: ReportStep[] = [];
  readonly timeline: TimelinePoint[] = [];
  assertions = 0;
  private currentPhase = "";
  private readonly firstTx = transactionLog.length;
  private capturedTx = this.firstTx;

  constructor(
    readonly kind: "scenario" | "api-probe",
    readonly state: DeploymentState,
    public fund: FundRecord,
  ) {}

  phase(title: string): void {
    this.currentPhase = title;
  }

  step(message: string): void {
    this.steps.push({ n: this.steps.length + 1, phase: this.currentPhase, message });
  }

  async capture(): Promise<void> {
    const step = this.steps.at(-1);
    if (!step) return;
    const labels = this.labels();
    step.transactions = transactionLog.slice(this.capturedTx).map((entry) => ({ ...entry, contract: entry.to ? labels.get(entry.to.toLowerCase()) ?? entry.to : "deployment" }));
    this.capturedTx = transactionLog.length;
    step.balances = await this.balances();
    step.fees = await feeLedger(this.fund);
    await this.mark(`step ${step.n}: ${step.message}`);
  }

  async conservation() {
    const core = this.fund.hub.coreVault.toLowerCase();
    const recipient = this.state.protocol.arbitrum.protocolRecipient.toLowerCase();
    const feeVault = this.fund.hub.managerFeeVault.toLowerCase();
    const logs = await nodes.arbitrum.client.getContractEvents({ address: ARBITRUM.usdc, abi: erc20Abi, eventName: "Transfer", fromBlock: BigInt(this.fund.hub.createdInBlock) });
    let valueIn = 0n;
    let valueOut = 0n;
    let fees = 0n;
    for (const log of logs) {
      const entry = log.args as { from: Address; to: Address; value: bigint };
      if (entry.to.toLowerCase() === core) valueIn += entry.value;
      if (entry.from.toLowerCase() === core) {
        if ([recipient, feeVault].includes(entry.to.toLowerCase())) fees += entry.value;
        else valueOut += entry.value;
      }
    }
    const remaining = await read<bigint>("arbitrum", { address: ARBITRUM.usdc, abi: erc20Abi, functionName: "balanceOf", args: [this.fund.hub.coreVault] });
    const residual = valueIn - valueOut - fees - remaining;
    const coreCash = { valueIn, valueOut, fees, remaining, residual, passed: residual === 0n };
    const vaults = new Set([core, this.fund.hub.spokeVault.toLowerCase(), this.fund.spoke.spokeVault.toLowerCase()]);
    const investors = new Set([actors.ana.address, actors.bruno.address, actors.manager.address].map((address) => address.toLowerCase()));
    const feeRecipients = new Set([recipient, feeVault]);
    let externalCapital = 0n;
    let investorPayments = 0n;
    let externalFeesAndSweeps = 0n;
    let marketNet = 0n;
    let bridgeNet = 0n;
    let remainingVaultCash = 0n;
    let remainingPositions = 0n;
    const marketFlows: { side: string; token: Address; transaction: string; direction: string; amount: bigint; dollars: bigint }[] = [];
    for (const side of ["arbitrum", "robinhood"] as const) {
      const base = side === "arbitrum" ? ARBITRUM.usdc : ROBINHOOD.usdg;
      const weth = side === "arbitrum" ? ARBITRUM.weth : ROBINHOOD.weth;
      const fromBlock = BigInt(side === "arbitrum" ? this.fund.hub.createdInBlock : this.fund.spoke.createdInBlock);
      const originVault = side === "arbitrum" ? this.fund.hub.coreVault : this.fund.spoke.spokeVault;
      const sends = await nodes[side].client.getContractEvents({ address: originVault, abi: side === "arbitrum" ? coreVaultAbi : spokeVaultAbi, eventName: side === "arbitrum" ? "SentToSpoke" : "SentToHub", fromBlock });
      const bridgeSends = new Set(sends.map((entry) => `${entry.transactionHash}:${(entry.args as any).transit.amountSent}`));
      const fills = await nodes[side].client.getContractEvents({ address: side === "arbitrum" ? ARBITRUM.acrossSpokePool : ROBINHOOD.acrossSpokePool, abi: acrossSpokePoolAbi, eventName: "FilledRelay", fromBlock });
      const fillTransactions = new Set(fills.map((entry) => entry.transactionHash));
      const dollarValue = async (token: Address, amount: bigint, block?: bigint) => {
        if (token.toLowerCase() === base.toLowerCase()) return amount;
        const [tokenPrice] = await read<readonly [bigint, bigint]>("arbitrum", { address: this.state.protocol.arbitrum.priceSource, abi: chainlinkPriceSourceAbi, functionName: "priceInUsdc", args: [token] }, undefined, side === "arbitrum" ? block : undefined);
        return amount * tokenPrice / 10n ** 18n;
      };
      for (const token of [base, weth]) {
        const transfers = await nodes[side].client.getContractEvents({ address: token, abi: erc20Abi, eventName: "Transfer", fromBlock });
        for (const transfer of transfers) {
          const entry = transfer.args as { from: Address; to: Address; value: bigint };
          const sender = entry.from.toLowerCase();
          const receiver = entry.to.toLowerCase();
          if (vaults.has(sender) === vaults.has(receiver)) continue;
          const incoming = vaults.has(receiver);
          const counterparty = incoming ? sender : receiver;
          const dollars = await dollarValue(token, entry.value, transfer.blockNumber);
          if (incoming && (investors.has(counterparty) || counterparty === actors.stranger.address.toLowerCase())) externalCapital += dollars;
          else if (!incoming && investors.has(counterparty)) investorPayments += dollars;
          else if (!incoming && feeRecipients.has(counterparty)) externalFeesAndSweeps += dollars;
          else if (token === base && ((!incoming && bridgeSends.has(`${transfer.transactionHash}:${entry.value}`)) || (incoming && fillTransactions.has(transfer.transactionHash)))) bridgeNet += incoming ? dollars : -dollars;
          else {
            marketNet += incoming ? dollars : -dollars;
            marketFlows.push({ side, token, transaction: transfer.transactionHash, direction: incoming ? "in" : "out", amount: entry.value, dollars });
          }
        }
        const holders = side === "arbitrum" ? [this.fund.hub.coreVault, this.fund.hub.spokeVault] : [this.fund.spoke.spokeVault];
        for (const holder of holders) remainingVaultCash += await dollarValue(token, await read<bigint>(side, { address: token, abi: erc20Abi, functionName: "balanceOf", args: [holder] }));
      }
      const spoke = side === "arbitrum" ? this.fund.hub.spokeVault : this.fund.spoke.spokeVault;
      const report = await read<any>(side, { address: spoke, abi: spokeVaultAbi, functionName: "buildReport" });
      for (const position of report.positions) {
        remainingPositions += await dollarValue(position.token0, position.principal0 + position.income0);
        if (position.token1 !== "0x0000000000000000000000000000000000000000") remainingPositions += await dollarValue(position.token1, position.principal1 + position.income1);
      }
    }
    const inFlight = await read<bigint>("arbitrum", { address: this.fund.hub.coreVault, abi: coreVaultAbi, functionName: "inFlightValue" });
    const [, , returnInFlight] = await read<readonly [bigint, bigint, bigint, bigint]>("arbitrum", { address: this.fund.hub.coreVault, abi: coreVaultAbi, functionName: "spokeCapUsage", args: [0n] });
    const bridgeFees = -bridgeNet - inFlight - returnInFlight;
    const ledger = await feeLedger(this.fund);
    const recordedBridgeFees = ledger.bridgeFees.toSpokes + ledger.bridgeFees.toHub;
    const fundRemaining = remainingVaultCash + remainingPositions + inFlight + returnInFlight;
    const fundValueIn = externalCapital + marketNet;
    const fundFees = externalFeesAndSweeps + bridgeFees;
    const fundResidual = fundValueIn - investorPayments - fundFees - fundRemaining;
    return { scope: "Fund-wide USDC value across both vault chains; USDG at 1:1, WETH at the price source (hub transaction block, current Hub rate for spoke WETH; unchanged feed asserted by the scenario)", methodology: "External capital plus independently summed net investment/swap cash flows equals investor payments plus external fees/sweeps plus bridge costs plus physical vault cash and remaining positions/transits. Sends match vault transit events; arrivals match FilledRelay transactions. Internal vault transfers cancel. Payout Fee remains fund value, never an external expense. Native gas is manager/keeper-paid (DEC-187).", externalCapital, realizedMarketPnlAndIncome: marketNet, valueIn: fundValueIn, valueOut: investorPayments, fees: fundFees, externalFeesAndSweeps, bridgeFees, recordedBridgeFees, remaining: fundRemaining, remainingVaultCash, remainingPositions, inFlight: inFlight + returnInFlight, residual: fundResidual, tolerance: 20n, passed: fundResidual >= -20n && fundResidual <= 20n && bridgeFees === recordedBridgeFees, coreCash, marketFlows };
  }

  /** A point of the Share Price timeline: the fund's books at the hub's latest block. */
  async mark(label: string): Promise<void> {
    const core = this.fund.hub.coreVault;
    const block = await nodes.arbitrum.client.getBlock();
    const at = (functionName: string) => read<bigint>("arbitrum", { address: core, abi: coreVaultAbi, functionName }, undefined, block.number);
    const [sharePrice, shareAssets, totalShares] = await Promise.all([
      at("sharePrice"),
      at("shareAssets"),
      read<bigint>("arbitrum", { address: this.fund.hub.shareToken, abi: shareTokenAbi, functionName: "totalSupply" }, undefined, block.number),
    ]);
    this.timeline.push({ label, block: block.number, timestamp: block.timestamp, sharePrice, shareAssets, totalShares });
  }

  /** Names for the addresses a reader meets in the transaction list. */
  private labels(): Map<string, string> {
    const f = this.fund;
    const s = this.state;
    const entries: [string, string][] = [
      [f.hub.coreVault, "Core Vault"],
      [f.hub.shareToken, "ShareToken"],
      [f.hub.spokeVault, "hub Spoke Vault"],
      [f.hub.valueReportReceiver, "ValueReportReceiver"],
      [f.hub.managerFeeVault, "ManagerFeeVault"],
      [f.hub.uniswapV4Adapter, "hub UniswapV4Adapter"],
      [f.hub.aaveV3Adapter, "AaveV3Adapter"],
      [f.hub.acrossBridgeAdapter, "hub AcrossBridgeAdapter"],
      [f.hub.uniswapV3SwapAdapter, "hub UniswapV3SwapAdapter (the fund's)"],
      [f.spoke.spokeVault, "Robinhood Spoke Vault"],
      [f.spoke.uniswapV4Adapter, "Robinhood UniswapV4Adapter"],
      [f.spoke.acrossBridgeAdapter, "Robinhood AcrossBridgeAdapter"],
      [f.spoke.uniswapV3SwapAdapter, "Robinhood UniswapV3SwapAdapter (the fund's)"],
      [s.protocol.arbitrum.fundFactory, "FundFactory"],
      [ARBITRUM.usdc, "USDC"],
      [ARBITRUM.weth, "WETH (Arbitrum)"],
      [ARBITRUM.acrossSpokePool, "Across SpokePool (Arbitrum)"],
      [ARBITRUM.wormholeCore, "Wormhole Core (Arbitrum)"],
      [ROBINHOOD.usdg, "USDG"],
      [ROBINHOOD.weth, "WETH (Robinhood)"],
      [ROBINHOOD.acrossSpokePool, "Across SpokePool (Robinhood)"],
      [ROBINHOOD.wormholeCore, "Wormhole Core (Robinhood)"],
      [s.helpers.arbitrumSwapRouter, "trader's V4 router (Arbitrum)"],
      [s.helpers.robinhoodSwapRouter, "trader's V4 router (Robinhood)"],
      [s.helpers.swapAdapters.arbitrum, "harness UniswapV3SwapAdapter (Arbitrum)"],
      [s.helpers.swapAdapters.robinhood, "harness UniswapV3SwapAdapter (Robinhood)"],
      ...ACTOR_NAMES.map((name) => [actors[name].address, name] as [string, string]),
    ];
    return new Map(entries.filter(([address]) => !!address).map(([address, name]) => [address.toLowerCase(), name]));
  }

  private transactions(): ReportTx[] {
    const labels = this.labels();
    return transactionLog.slice(this.firstTx).map((tx) => ({
      ...tx,
      contract: tx.to ? (labels.get(tx.to.toLowerCase()) ?? tx.to) : "(contract creation)",
    }));
  }

  private gasByVerb(transactions: ReportTx[]): GasLine[] {
    const lines = new Map<string, GasLine>();
    for (const tx of transactions) {
      const key = `${tx.chainId}|${tx.contract}|${tx.label}`;
      const line = lines.get(key) ?? { chainId: tx.chainId, contract: tx.contract, label: tx.label, count: 0, totalGas: 0n, minGas: tx.gasUsed, maxGas: tx.gasUsed };
      line.count++;
      line.totalGas += tx.gasUsed;
      if (tx.gasUsed < line.minGas) line.minGas = tx.gasUsed;
      if (tx.gasUsed > line.maxGas) line.maxGas = tx.gasUsed;
      lines.set(key, line);
    }
    return [...lines.values()];
  }

  private async balances(): Promise<Balances> {
    const f = this.fund;
    const balance = (side: "arbitrum" | "robinhood", token: Address, holder: Address) =>
      read<bigint>(side, { address: token, abi: erc20Abi, functionName: "balanceOf", args: [holder] });
    const result: Balances = { actors: {}, managerFeeVault: { usdc: 0n, weth: 0n }, coreVault: {} };
    for (const name of ACTOR_NAMES) {
      const holder = actors[name].address;
      const [hubUsdc, usdg, weth, shares] = await Promise.all([
        balance("arbitrum", ARBITRUM.usdc, holder),
        balance("robinhood", ROBINHOOD.usdg, holder),
        balance("arbitrum", ARBITRUM.weth, holder),
        balance("arbitrum", f.hub.shareToken, holder),
      ]);
      const incomeOwed = await read<bigint>("arbitrum", { address: f.hub.coreVault, abi: coreVaultAbi, functionName: "incomeOwed", args: [holder] });
      const sharePrice = await read<bigint>("arbitrum", { address: f.hub.coreVault, abi: coreVaultAbi, functionName: "sharePrice" });
      result.actors[name] = { usdc: hubUsdc, usdg, weth, shares, incomeOwed, shareValue: shares * sharePrice / 10n ** 36n };
    }
    result.managerFeeVault = {
      usdc: await balance("arbitrum", ARBITRUM.usdc, f.hub.managerFeeVault),
      weth: await balance("arbitrum", ARBITRUM.weth, f.hub.managerFeeVault),
    };
    const view = (functionName: string) => read<bigint | number>("arbitrum", { address: f.hub.coreVault, abi: coreVaultAbi, functionName });
    for (const name of ["sharePrice", "shareAssets", "grossAssets", "idle", "freeIdle", "payoutReserve", "inFlightValue", "operatingCash", "fundState", "managementFeeAccrued"]) {
      result.coreVault[name] = await view(name);
    }
    result.coreVault.totalShares = await read<bigint>("arbitrum", { address: f.hub.shareToken, abi: shareTokenAbi, functionName: "totalSupply" });
    return result;
  }

  /** Writes the JSON and Markdown files and returns their paths (relative to local-e2e/). */
  async write(outcome: { passed: boolean; error?: string; extra?: Record<string, unknown> }): Promise<{ json: string; md: string }> {
    const finishedAt = new Date();
    const transactions = this.transactions();
    const gas = this.gasByVerb(transactions);
    // Readbacks can fail when the run failed on a broken node; the report is still written with what was gathered.
    const safely = async <T>(task: () => Promise<T>): Promise<T | { error: string }> => {
      try {
        return await task();
      } catch (err) {
        return { error: redactUrls((err as Error).message.split("\n")[0]) };
      }
    };
    await safely(() => this.mark("end of run"));
    const history = await safely(() => sharePriceHistory(this.fund));
    const fees = await safely(() => feeLedger(this.fund));
    const balances = await safely(() => this.balances());
    const conservation = await safely(() => this.conservation());
    const report = {
      kind: this.kind,
      result: outcome.passed ? "pass" : "fail",
      error: outcome.error,
      startedAt: this.startedAt.toISOString(),
      finishedAt: finishedAt.toISOString(),
      durationSeconds: Math.round((finishedAt.getTime() - this.startedAt.getTime()) / 1000),
      commit: git(["rev-parse", "HEAD"]),
      uncommittedChanges: git(["status", "--porcelain", "--", "src", "script", "local-e2e/src"]) !== "",
      forks: {
        arbitrum: { chainId: this.state.nodes.arbitrum.chainId, forkBlockNumber: this.state.nodes.arbitrum.forkBlockNumber },
        robinhood: { chainId: this.state.nodes.robinhood.chainId, forkBlockNumber: this.state.nodes.robinhood.forkBlockNumber },
      },
      fund: {
        shareSymbol: this.fund.shareSymbol,
        fundId: this.fund.fundId,
        coreVault: this.fund.hub.coreVault,
        robinhoodSpokeVault: this.fund.spoke.spokeVault,
        createdInBlock: this.fund.hub.createdInBlock,
      },
      steps: this.steps,
      assertions: this.assertions,
      sharePriceTimeline: this.timeline,
      sharePriceHistory: history,
      feeLedger: fees,
      gasByVerb: gas,
      transactions,
      balances,
      conservation,
      ...outcome.extra,
    };
    mkdirSync(REPORTS_DIR, { recursive: true });
    const stamp = this.startedAt.toISOString().replace(/\.\d+Z$/, "Z").replace(/:/g, "-");
    const base = join(REPORTS_DIR, `${stamp}-${this.kind}`);
    writeFileSync(`${base}.json`, json(report) + "\n");
    writeFileSync(`${base}.md`, redactUrls(this.markdown(report, history, fees, balances, gas, transactions)));
    return { json: relative(HARNESS_DIR, `${base}.json`), md: relative(HARNESS_DIR, `${base}.md`) };
  }

  private markdown(
    r: { result: string; error?: string; startedAt: string; durationSeconds: number; commit: string; uncommittedChanges: boolean; conservation: unknown },
    history: SharePricePoint[] | { error: string },
    fees: FeeLedger | { error: string },
    balances: Balances | { error: string },
    gas: GasLine[],
    transactions: ReportTx[],
  ): string {
    const f = this.fund;
    const out: string[] = [];
    const table = (header: string[], rows: (string | number)[][]) => {
      out.push(`| ${header.join(" | ")} |`, `|${header.map(() => "---").join("|")}|`);
      for (const row of rows) out.push(`| ${row.join(" | ")} |`);
      out.push("");
    };
    out.push(`# Run report: ${this.kind} (${r.result.toUpperCase()})`, "");
    out.push(`- Started ${r.startedAt}, ${r.durationSeconds} s`);
    out.push(`- Commit \`${r.commit.slice(0, 12)}\`${r.uncommittedChanges ? " with uncommitted changes in src/, script/ or local-e2e/src/" : ""}`);
    out.push(
      `- Forks: Arbitrum One at block ${this.state.nodes.arbitrum.forkBlockNumber}, Robinhood Chain at block ${this.state.nodes.robinhood.forkBlockNumber}`,
    );
    out.push(`- Fund ${f.shareSymbol}: Core Vault \`${f.hub.coreVault}\`, Robinhood Spoke Vault \`${f.spoke.spokeVault}\``);
    out.push(`- ${this.steps.length} steps, ${this.assertions} assertions, ${transactions.length} transactions`);
    if (r.error) out.push("", "**Failure:**", "", "```", r.error, "```");
    out.push("");

    out.push("## Steps", "");
    table(["#", "Phase", "Step"], this.steps.map((s) => [s.n, s.phase, s.message.replace(/\|/g, "\\|")]));
    out.push("## Final summary", "");
    table(["Phase", "Steps", "Transactions", "Total gas", "Final Share Price", "Final Share Assets", "Final Gross Assets"], [...new Set(this.steps.map((step) => step.phase))].map((phase) => {
      const steps = this.steps.filter((step) => step.phase === phase);
      const transactions = steps.flatMap((step) => step.transactions ?? []);
      const books = steps.at(-1)?.balances?.coreVault;
      return [phase, steps.length, transactions.length, transactions.reduce((sum, transaction) => sum + transaction.gasUsed, 0n).toString(), books ? priceOf(BigInt(books.sharePrice)) : "n/a", books ? usdcExact(BigInt(books.shareAssets)) : "n/a", books ? usdcExact(BigInt(books.grossAssets)) : "n/a"];
    }));

    out.push("## Step accounting", "", "Full transaction hashes, gas, fees and every actor's balances are also stored with each step in JSON.", "");
    for (const step of this.steps) {
      if (!step.balances) continue;
      const books = step.balances.coreVault;
      out.push(`### Step ${step.n}`, "", step.message, "");
      table(["Share Price", "Share Assets", "Gross Assets", "Management fee accrued"], [[priceOf(BigInt(books.sharePrice)), usdcExact(BigInt(books.shareAssets)), usdcExact(BigInt(books.grossAssets)), usdcExact(BigInt(books.managementFeeAccrued))]]);
      table(["Actor", "USDC", "USDG", "WETH", "Shares", "Share value", "Attributed Income"], Object.entries(step.balances.actors).map(([name, position]) => [name, usdcExact(position.usdc), usdcExact(position.usdg), units(position.weth, 18, 12), units(position.shares, 18, 6), usdcExact(position.shareValue), usdcExact(position.incomeOwed)]));
      table(["Operation", "Gas", "Transaction"], (step.transactions ?? []).map((transaction) => [transaction.label, String(transaction.gasUsed), `\`${transaction.hash}\``]));
      out.push(`Fees paid: flow ${usdcExact(step.fees!.flowFee.total)} USDC; performance ${usdcExact(step.fees!.performanceFee.reduce((sum, entry) => sum + entry.performanceFee, 0n))} USDC; management ${usdcExact(step.fees!.managementFeePaid)} USDC.`, "");
    }
    out.push("## Conservation check", "", "```json", json(r.conservation), "```", "");

    out.push("## Share Price timeline", "");
    table(
      ["Point", "Block", "Time", "Share Price", "Share Assets (USDC)", "Shares"],
      this.timeline.map((p) => [p.label, String(p.block), time(p.timestamp), priceOf(p.sharePrice), usdc(p.shareAssets), units(p.totalShares, 18, 0)]),
    );

    out.push("## Share Price at every Core Vault event", "");
    if ("error" in history) out.push(`not available: ${history.error}`, "");
    else {
      table(
        ["Block", "Time", "Share Price", "Share Assets (USDC)", "Shares", "Events"],
        history.map((p) => [String(p.block), time(p.timestamp), priceOf(p.sharePrice), usdc(p.shareAssets), units(p.totalShares, 18, 0), p.events.join(", ")]),
      );
    }

    out.push("## Fee ledger", "");
    if ("error" in fees) out.push(`not available: ${fees.error}`, "");
    else {
      const rows: string[][] = [
        ["Flow fee (DEC-106), seed", usdcExact(fees.flowFee.seed), "USDC", "Protocol Recipient"],
        ["Flow fee, deposits", usdcExact(fees.flowFee.deposits), "USDC", "Protocol Recipient"],
        ["Flow fee, payouts", usdcExact(fees.flowFee.payouts), "USDC", "Protocol Recipient"],
        ["Payout Fee (DEC-102, DEC-144)", usdcExact(fees.payoutFee), "USDC", "stays in Idle"],
      ];
      for (const line of fees.performanceFee) {
        const token = line.token.toLowerCase() === ARBITRUM.usdc.toLowerCase() ? "USDC" : "WETH";
        const decimals = token === "USDC" ? 6 : 18;
        const fmt = (v: bigint) => units(v, decimals, token === "USDC" ? 6 : 12);
        rows.push([`Performance fee (DEC-107) on ${fmt(line.collected)} ${token} collected`, fmt(line.performanceFee), token, "see the two slices"]);
        rows.push(["  manager part", fmt(line.managerPart), token, "ManagerFeeVault (DEC-109)"]);
        rows.push(["  protocol slice", fmt(line.protocolSlice), token, "Protocol Recipient (DEC-106)"]);
        rows.push(["  net to holders", fmt(line.toHolders), token, "holders' accumulator (DEC-014)"]);
      }
      rows.push([
        "Management fee (DEC-108, DEC-114)",
        fees.managementFeeAccrued === null ? "n/a" : usdcExact(fees.managementFeeAccrued),
        "USDC",
        "remaining liability",
      ]);
      rows.push(["Management fee paid at closure (DEC-114)", usdcExact(fees.managementFeePaid), "USDC", "ManagerFeeVault and Protocol Recipient"]);
      rows.push([`Bridge fees, Hub to spokes (${fees.bridgeFees.toSpokesSends} sends)`, usdcExact(fees.bridgeFees.toSpokes), "USDC", "relayers (DEC-162)"]);
      rows.push([`Bridge fees, Robinhood to the Hub (${fees.bridgeFees.toHubSends} sends)`, usdcExact(fees.bridgeFees.toHub), "USDG", "relayers (DEC-162)"]);
      table(["Fee", "Amount", "Token", "Goes to"], rows);
    }

    out.push("## Gas per verb", "");
    table(
      ["Chain", "Contract", "Call", "Count", "Total gas", "Min", "Max"],
      gas.map((g) => [SIDE_NAME[g.chainId] ?? g.chainId, g.contract, g.label, g.count, g.totalGas.toLocaleString("en-US"), g.minGas.toLocaleString("en-US"), g.maxGas.toLocaleString("en-US")]),
    );

    out.push("## Transactions", "");
    table(
      ["#", "Chain", "Block", "From", "Contract", "Call", "Gas", "Hash"],
      transactions.map((t, i) => [i + 1, SIDE_NAME[t.chainId] ?? t.chainId, String(t.blockNumber), t.from, t.contract, t.label, t.gasUsed.toLocaleString("en-US"), `\`${t.hash.slice(0, 10)}\``]),
    );

    out.push("## Balances at the end", "");
    if ("error" in balances) out.push(`not available: ${balances.error}`, "");
    else {
      table(
        ["Actor", "USDC (Arbitrum)", "USDG (Robinhood)", "WETH (Arbitrum)", `Shares (${f.shareSymbol})`],
        Object.entries(balances.actors).map(([name, b]) => [name, usdc(b.usdc), usdc(b.usdg), units(b.weth, 18, 6), units(b.shares, 18, 0)]),
      );
      out.push(`ManagerFeeVault: ${usdc(balances.managerFeeVault.usdc)} USDC, ${units(balances.managerFeeVault.weth, 18, 8)} WETH`, "");
      const c = balances.coreVault;
      table(
        ["Core Vault", "Value"],
        Object.entries(c).map(([name, v]) => [
          name,
          name === "sharePrice" ? priceOf(v as bigint) : name === "totalShares" ? units(v as bigint, 18, 0) : name === "fundState" ? ["Open", "Closing", "Closed"][Number(v)] ?? String(v) : usdc(v as bigint),
        ]),
      );
    }
    return out.join("\n") + "\n";
  }
}
