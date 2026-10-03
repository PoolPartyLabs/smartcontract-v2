// `pnpm status`: both nodes, the keeper, the deployment, and the default fund's books at a glance.
import { formatEther, type Address } from "viem";
import { chainlinkAggregatorAbi, coreVaultAbi, erc20Abi, shareTokenAbi, valueReportReceiverAbi } from "./abis.ts";
import { anvil, explain, latestTimestamp, nodes, read, runMain, type Side } from "./chain.ts";
import { ARBITRUM, ROBINHOOD, actors, isMain, type ActorName } from "./config.ts";
import { runningKeeperPid } from "./keeper.ts";
import { safeConsole as console, bold, dim, green, red, redactUrls, units, yellow } from "./log.ts";
import { tryReadState } from "./state.ts";

async function nodeLine(side: Side): Promise<boolean> {
  const node = nodes[side];
  try {
    const [info, block] = await Promise.all([anvil.nodeInfo(side), node.client.getBlock()]);
    const lag = Math.floor(Date.now() / 1000) - Number(block.timestamp);
    console.log(
      `  ${green("up")}   ${node.label.padEnd(24)} ${node.rpc}  chain ${node.chain.id}  block ${block.number}  ` +
        `time ${new Date(Number(block.timestamp) * 1000).toISOString()} ${dim(`(${lag >= 0 ? "-" : "+"}${Math.abs(lag)}s vs wall clock)`)}  ` +
        `fork of ${redactUrls(info.forkConfig?.forkUrl ?? "?")} at ${info.forkConfig?.forkBlockNumber}  ${info.hardFork}`,
    );
    return true;
  } catch {
    console.log(`  ${red("down")} ${node.label.padEnd(24)} ${node.rpc}`);
    return false;
  }
}

export async function status(): Promise<void> {
  console.log(bold("nodes"));
  const hub = await nodeLine("arbitrum");
  const spoke = await nodeLine("robinhood");
  const keeper = runningKeeperPid();
  console.log(`${bold("keeper")}  ${keeper ? green(`running (pid ${keeper})`) : yellow("not running (pnpm keeper)")}`);
  const state = tryReadState();
  if (!state) {
    console.log(`${bold("deployment")}  ${yellow("none (pnpm run up)")}`);
    return;
  }
  const f = state.fund;
  console.log(bold("deployment") + dim("  local-e2e/.state/deployment.json"));
  console.log(`  FundFactory        ${state.protocol.arbitrum.fundFactory} (both chains)`);
  console.log(`  fund ${f.shareSymbol.padEnd(13)} fundId ${f.fundId}`);
  console.log(`  Core Vault         ${f.hub.coreVault}    ShareToken ${f.hub.shareToken}`);
  console.log(`  hub Spoke Vault    ${f.hub.spokeVault}    ValueReportReceiver ${f.hub.valueReportReceiver}`);
  console.log(`  Robinhood Spoke    ${f.spoke.spokeVault}`);
  // Mandate v2 (DEC-136): the factory's Uniswap V3 swap adapter of each chain (absent from a pre-v2 state file).
  console.log(`  swap adapters      ${f.hub.uniswapV3SwapAdapter ?? "?"} (hub)    ${f.spoke.uniswapV3SwapAdapter ?? "?"} (Robinhood)`);
  if (!hub || !spoke) return;

  try {
    const at = (address: Address, name: string, args: readonly unknown[] = []) =>
      read<any>("arbitrum", { address, abi: coreVaultAbi, functionName: name, args });
    const [supply, sharePrice, shareAssets, idle, reserve, inFlight] = await Promise.all([
      read<bigint>("arbitrum", { address: f.hub.shareToken, abi: shareTokenAbi, functionName: "totalSupply" }),
      at(f.hub.coreVault, "sharePrice"),
      at(f.hub.coreVault, "shareAssets"),
      at(f.hub.coreVault, "idle"),
      at(f.hub.coreVault, "payoutReserve"),
      at(f.hub.coreVault, "inFlightValue"),
    ]);
    console.log(bold("fund books"));
    console.log(
      `  Share Price ${units(sharePrice / 10n ** 18n)}  Share Assets ${units(shareAssets)}  shares ${units(supply, 18, 0)}  ` +
        `Idle ${units(idle)} (Payout Reserve ${units(reserve)})  In-flight ${units(inFlight)}`,
    );
    const hubNow = await latestTimestamp("arbitrum");
    const receiver = f.hub.valueReportReceiver;
    if (await read<boolean>("arbitrum", { address: receiver, abi: valueReportReceiverAbi, functionName: "hasReport", args: [0n] })) {
      const [report] = await read<readonly [any, bigint, bigint]>("arbitrum", {
        address: receiver,
        abi: valueReportReceiverAbi,
        functionName: "latestReport",
        args: [0n],
      });
      const fresh = await read<boolean>("arbitrum", { address: receiver, abi: valueReportReceiverAbi, functionName: "isReportFresh", args: [0n] });
      const age = hubNow - BigInt(report.timestamp);
      console.log(
        `  last spoke report: sequence ${report.sequence}, age ${age}s of 1588s ${fresh ? green("fresh") : red("STALE: deposits revert (pnpm warp 0, or pnpm keeper --auto-report 600)")}`,
      );
    } else {
      console.log(`  last spoke report: none yet`);
    }
    const [, answer, , updatedAt] = await read<readonly [bigint, bigint, bigint, bigint, bigint]>("arbitrum", {
      address: ARBITRUM.ethUsdFeed,
      abi: chainlinkAggregatorAbi,
      functionName: "latestRoundData",
    });
    const feedAge = hubNow - updatedAt;
    console.log(
      `  Chainlink ETH / USD ${units(answer, 8, 2)}, age ${feedAge}s of 3600s ${feedAge <= 3600n ? green("fresh") : red("STALE: mints revert (the keeper re-stamps it)")}`,
    );

    console.log(bold("actors") + dim("  (keys in src/config.ts, anvil's default mnemonic)"));
    for (const name of Object.keys(actors) as ActorName[]) {
      const address = actors[name].address;
      const [eth, usdc, usdg] = await Promise.all([
        nodes.arbitrum.client.getBalance({ address }),
        read<bigint>("arbitrum", { address: ARBITRUM.usdc, abi: erc20Abi, functionName: "balanceOf", args: [address] }),
        read<bigint>("robinhood", { address: ROBINHOOD.usdg, abi: erc20Abi, functionName: "balanceOf", args: [address] }),
      ]);
      console.log(
        `  ${name.padEnd(18)} ${address}  ETH ${Number(formatEther(eth)).toFixed(2).padStart(10)}  USDC ${units(usdc, 6, 2).padStart(16)}  USDG ${units(usdg, 6, 2).padStart(16)}`,
      );
    }
  } catch (err) {
    console.log(red(explain(err)));
  }
}

if (isMain(import.meta.url)) {
  await runMain(status);
}
