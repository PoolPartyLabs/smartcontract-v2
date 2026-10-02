// Run reports: every scenario and API probe run writes local-e2e/reports/<time>-<kind>.json and .md with its steps and
// assertions, the gas of every transaction it sent (and per verb), the Share Price timeline (per phase, and at every
// Core Vault event), the fee ledger (flow fee, Payout Fee, performance fee and its slices, management fee, bridge
// fees) and the final balances. The v2 end-to-end runs (WP-15, WP-18) and the founder's report read the same files.
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import type { Address } from "viem";
import { coreVaultAbi, erc20Abi, shareTokenAbi } from "./abis.ts";
import { nodes, read, transactionLog, type TxRecord } from "./chain.ts";
import { ACTOR_NAMES, ARBITRUM, HARNESS_DIR, REPO_DIR, REPORTS_DIR, ROBINHOOD, actors } from "./config.ts";
import { feeLedger, sharePriceHistory, type FeeLedger, type SharePricePoint } from "./history.ts";
import { units } from "./log.ts";
import type { DeploymentState, FundRecord } from "./state.ts";

export interface ReportStep {
  n: number;
  phase: string;
  message: string;
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
  actors: Record<string, { usdc: bigint; usdg: bigint; weth: bigint; shares: bigint }>;
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

const json = (value: unknown) => JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2);
const usdc = (value: bigint) => units(value, 6, 2);
const priceOf = (sharePrice: bigint) => units(sharePrice / 10n ** 18n, 6, 6);
const time = (timestamp: bigint) => new Date(Number(timestamp) * 1000).toISOString().replace(".000Z", "Z");

export class RunReport {
  readonly startedAt = new Date();
  readonly steps: ReportStep[] = [];
  readonly timeline: TimelinePoint[] = [];
  assertions = 0;
  private currentPhase = "";
  private readonly firstTx = transactionLog.length;

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
      [f.spoke.spokeVault, "Robinhood Spoke Vault"],
      [f.spoke.uniswapV4Adapter, "Robinhood UniswapV4Adapter"],
      [f.spoke.acrossBridgeAdapter, "Robinhood AcrossBridgeAdapter"],
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
      result.actors[name] = { usdc: hubUsdc, usdg, weth, shares };
    }
    result.managerFeeVault = {
      usdc: await balance("arbitrum", ARBITRUM.usdc, f.hub.managerFeeVault),
      weth: await balance("arbitrum", ARBITRUM.weth, f.hub.managerFeeVault),
    };
    const view = (functionName: string) => read<bigint | number>("arbitrum", { address: f.hub.coreVault, abi: coreVaultAbi, functionName });
    for (const name of ["sharePrice", "shareAssets", "grossAssets", "idle", "freeIdle", "payoutReserve", "inFlightValue", "operatingCash", "fundState"]) {
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
        return { error: (err as Error).message.split("\n")[0] };
      }
    };
    await safely(() => this.mark("end of run"));
    const history = await safely(() => sharePriceHistory(this.fund));
    const fees = await safely(() => feeLedger(this.fund));
    const balances = await safely(() => this.balances());
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
      ...outcome.extra,
    };
    mkdirSync(REPORTS_DIR, { recursive: true });
    const stamp = this.startedAt.toISOString().replace(/\.\d+Z$/, "Z").replace(/:/g, "-");
    const base = join(REPORTS_DIR, `${stamp}-${this.kind}`);
    writeFileSync(`${base}.json`, json(report) + "\n");
    writeFileSync(`${base}.md`, this.markdown(report, history, fees, balances, gas, transactions));
    return { json: relative(HARNESS_DIR, `${base}.json`), md: relative(HARNESS_DIR, `${base}.md`) };
  }

  private markdown(
    r: { result: string; error?: string; startedAt: string; durationSeconds: number; commit: string; uncommittedChanges: boolean },
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
        ["Flow fee (DEC-106), seed", usdc(fees.flowFee.seed), "USDC", "Protocol Recipient"],
        ["Flow fee, deposits", usdc(fees.flowFee.deposits), "USDC", "Protocol Recipient"],
        ["Flow fee, payouts", usdc(fees.flowFee.payouts), "USDC", "Protocol Recipient"],
        ["Payout Fee (DEC-102, DEC-144)", usdc(fees.payoutFee), "USDC", "stays in Idle"],
      ];
      for (const line of fees.performanceFee) {
        const token = line.token.toLowerCase() === ARBITRUM.usdc.toLowerCase() ? "USDC" : "WETH";
        const decimals = token === "USDC" ? 6 : 18;
        const fmt = (v: bigint) => units(v, decimals, token === "USDC" ? 2 : 8);
        rows.push([`Performance fee (DEC-107) on ${fmt(line.collected)} ${token} collected`, fmt(line.performanceFee), token, "see the two slices"]);
        rows.push(["  manager part", fmt(line.managerPart), token, "ManagerFeeVault (DEC-109)"]);
        rows.push(["  protocol slice", fmt(line.protocolSlice), token, "Protocol Recipient (DEC-106)"]);
        rows.push(["  net to holders", fmt(line.toHolders), token, "holders' accumulator (DEC-014)"]);
      }
      rows.push([
        "Management fee (DEC-108, DEC-114)",
        fees.managementFeeAccrued === null ? "n/a" : usdc(fees.managementFeeAccrued),
        "USDC",
        fees.managementFeeAccrued === null ? "no accrual in this Core Vault yet (WP-07)" : "accrued",
      ]);
      rows.push([`Bridge fees to the spokes (${fees.bridgeFees.sends} sends both ways)`, usdc(fees.bridgeFees.toSpokes), "USDC", "relayers (DEC-162)"]);
      rows.push(["Bridge fees home", usdc(fees.bridgeFees.toHub), "USDG", "relayers (DEC-162)"]);
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
