import assert from "node:assert/strict";
import {readFileSync, writeFileSync} from "node:fs";
import {decodeFunctionData, formatEther, parseAbi, type Abi} from "viem";
import {nodes, runMain, SIDES} from "./chain.ts";
import {actors, ARBITRUM, ROBINHOOD} from "./config.ts";
import {acrossSpokePoolAbi, coreVaultAbi, erc20Abi, fundFactoryAbi, spokeVaultAbi, valueReportReceiverAbi, v4SwapRouterAbi} from "./abis.ts";
import {safeConsole as console} from "./log.ts";

async function main() {
  const state = process.env.ALPHA_REHEARSAL_STATE!;
  const startPath = `${state}/gas-start.json`;
  for (const side of SIDES) {
    assert.equal(new URL(nodes[side].rpc).hostname, "127.0.0.1");
    assert.match(await nodes[side].client.request({method: "web3_clientVersion"}), /anvil/i);
  }
  if (process.argv[2] === "start") {
    const starts = {} as Record<string, unknown>;
    for (const side of SIDES) {
      starts[side] = {block: String(await nodes[side].client.getBlockNumber()), gasPrice: String(await nodes[side].client.getGasPrice())};
    }
    writeFileSync(startPath, JSON.stringify(starts, null, 2) + "\n");
    return;
  }
  assert.equal(process.argv[2], "finish");
  const starts = JSON.parse(readFileSync(startPath, "utf8"));
  const records = [];
  const summaries = [];
  for (const side of SIDES) {
    const client = nodes[side].client;
    const end = await client.getBlockNumber();
    let protocolGas = 0n;
    let investorGas = 0n;
    let simulatedRelayGas = 0n;
    let paid = 0n;
    const pool = side === "arbitrum" ? ARBITRUM.acrossSpokePool : ROBINHOOD.acrossSpokePool;
    for (let blockNumber = BigInt(starts[side].block) + 1n; blockNumber <= end; blockNumber++) {
      const block = await client.getBlock({blockNumber, includeTransactions: true});
      for (const transaction of block.transactions) {
        const receipt = await client.getTransactionReceipt({hash: transaction.hash});
        let functionName = transaction.to ? transaction.input.slice(0, 10) : "CREATE";
        let args: readonly unknown[] = [];
        for (const abi of [coreVaultAbi, spokeVaultAbi, valueReportReceiverAbi, erc20Abi, acrossSpokePoolAbi, fundFactoryAbi, v4SwapRouterAbi,
          parseAbi(["function deploy(bytes32,bytes) returns (address)"])] as Abi[]) {
          try {const decoded = decodeFunctionData({abi, data: transaction.input}); functionName = decoded.functionName; args = decoded.args ?? []; break;} catch {}
        }
        const operator = transaction.from.toLowerCase() === actors.operator.address.toLowerCase();
        const investor = transaction.from.toLowerCase() === actors.ana.address.toLowerCase();
        const simulatedRelay = functionName === "fillRelay" || (functionName === "approve" && String(args[0]).toLowerCase() === pool.toLowerCase());
        const category = simulatedRelay ? "simulated-relayer" : operator ? "alpha-wallet" : investor ? "investor" : "fork-only-trader";
        assert.equal(receipt.status, "success", `Reverted transaction ${transaction.hash}`);
        if (simulatedRelay) simulatedRelayGas += receipt.gasUsed;
        else if (operator) {protocolGas += receipt.gasUsed; paid += receipt.gasUsed * receipt.effectiveGasPrice;}
        else if (investor) investorGas += receipt.gasUsed;
        records.push({side, category, from: transaction.from, to: transaction.to, functionName, hash: transaction.hash,
          blockNumber: String(blockNumber), gasUsed: String(receipt.gasUsed), effectiveGasPrice: String(receipt.effectiveGasPrice), status: receipt.status,
          contractAddress: receipt.contractAddress});
      }
    }
    const gasPrice = BigInt(starts[side].gasPrice);
    summaries.push({side, startBlock: starts[side].block, endBlock: String(end), gasPriceWei: String(gasPrice),
      alphaWalletGas: String(protocolGas), investorGas: String(investorGas), simulatedRelayGas: String(simulatedRelayGas),
      alphaWalletReceiptETH: formatEther(paid), alphaWalletAtPinnedGasPriceETH: formatEther(protocolGas * gasPrice),
      rafaelSixfoldPlanningETH: formatEther(protocolGas * gasPrice / 6n)});
  }
  writeFileSync(`${state}/transactions.json`, JSON.stringify(records, null, 2) + "\n");
  writeFileSync(`${state}/gas-summary.json`, JSON.stringify(summaries, null, 2) + "\n");
  console.log(JSON.stringify(summaries, null, 2));
}

await runMain(main);
