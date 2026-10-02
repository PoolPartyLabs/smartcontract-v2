// Deployment through the repository's real Foundry scripts (docs/DEPLOYMENT.md): script/DeployFactory.s.sol on both
// nodes with the operator's key, then script/CreateFund.s.sol with the manager's key, `createFund` on the hub and
// `createSpoke` on Robinhood with the creation number and Mandate hash the hub emitted.
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { decodeEventLog, getAddress, type Address, type Hex, type Log } from "viem";
import { fundFactoryAbi, shareTokenAbi } from "./abis.ts";
import { PRUNED_STATE_HINT, isPrunedStateError, nodes, read, recordTransaction, type Side } from "./chain.ts";
import {
  ACTOR_KEYS,
  AAVE_USDC_POOL_KEY,
  FUND_PLAN,
  HUB_POOL_ID,
  HUB_POOL_KEY,
  REPO_DIR,
  SPOKE_POOL_ID,
  SPOKE_POOL_KEY,
  STATE_DIR,
  WORMHOLE_ROBINHOOD,
  actors,
} from "./config.ts";
import type { Logger } from "./log.ts";
import type { FundRecord } from "./state.ts";

const BROADCAST_DIR = join(STATE_DIR, "broadcast");

interface ForgeRun {
  output: string;
  broadcast: {
    transactions: { hash: Hex; contractName?: string; function?: string }[];
    receipts: {
      transactionHash: Hex;
      blockNumber: Hex;
      logs: Log[];
      status: Hex;
      from: Address;
      to: Address | null;
      gasUsed: Hex;
      effectiveGasPrice: Hex;
    }[];
    returns: Record<string, { internal_type: string; value: string }>;
  };
}

/** Runs a command in the repository root and returns its combined output; rejects with the tail of it. */
function run(command: string, args: string[], env: Record<string, string>, log: Logger): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: REPO_DIR, env: { ...process.env, ...env } });
    let output = "";
    child.stdout.on("data", (d) => (output += d));
    child.stderr.on("data", (d) => (output += d));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) return resolve(output);
      const tail = output.trim().split("\n").slice(-40).join("\n");
      log.error(`${command} ${args.slice(0, 2).join(" ")} failed (exit ${code})`);
      const hint = isPrunedStateError(tail) ? `\n${PRUNED_STATE_HINT}` : "";
      reject(new Error(`${command} ${args.slice(0, 2).join(" ")} failed:\n${tail}${hint}`));
    });
  });
}

/** `forge build` in the repository (the scripts read creation code from out/, the scenario the swap router). */
export async function forgeBuild(log: Logger): Promise<void> {
  log.info("forge build");
  await run("forge", ["build"], {}, log);
}

async function forgeScript(
  script: "DeployFactory" | "CreateFund",
  side: Side,
  privateKey: Hex,
  env: Record<string, string>,
  log: Logger,
): Promise<ForgeRun> {
  const node = nodes[side];
  log.info(`forge script script/${script}.s.sol`, { chain: node.chain.id, rpc: node.rpc });
  const output = await run(
    "forge",
    ["script", `script/${script}.s.sol`, "--rpc-url", node.rpc, "--broadcast", "--slow", "--private-key", privateKey],
    { ...env, FOUNDRY_BROADCAST: BROADCAST_DIR },
    log,
  );
  const file = join(BROADCAST_DIR, `${script}.s.sol`, String(node.chain.id), "run-latest.json");
  const result: ForgeRun = { output, broadcast: JSON.parse(readFileSync(file, "utf8")) };
  for (const receipt of result.broadcast.receipts) {
    const tx = result.broadcast.transactions.find((t) => t.hash.toLowerCase() === receipt.transactionHash.toLowerCase());
    const what = tx?.function?.split("(")[0] ?? (tx?.contractName ? `deploy ${tx.contractName}` : "transaction");
    recordTransaction(side, `${what} (forge ${script})`, {
      ...receipt,
      blockNumber: BigInt(receipt.blockNumber),
      gasUsed: BigInt(receipt.gasUsed),
      effectiveGasPrice: BigInt(receipt.effectiveGasPrice),
    });
  }
  return result;
}

export interface FactoryDeployment {
  create3Deployer: Address;
  coreVaultLogic: Address;
  spokeCrossChainLib: Address;
  spokeUnwindLib: Address;
  managerRegistry: Address;
  priceSource: Address;
  fundFactory: Address;
  transitEscrowImplementation: Address;
}

/** Protocol wiring handed to script/DeployFactory.s.sol: the fee wallet is its own actor; the operator guards the
 *  adapters; the API signer owns the ManagerRegistry and signs swap routes and bridge quotes (reading D-01 of DEC-112;
 *  the scripts read `API_SIGNER` once Mandate v2 wires the swap adapters). */
export function protocolRoles() {
  return {
    protocolRecipient: actors.protocolRecipient.address,
    adapterGuardian: actors.operator.address,
    registryOwner: actors.apiSigner.address,
    apiSigner: actors.apiSigner.address,
  };
}

/** script/DeployFactory.s.sol on one node with the operator's key. */
export async function deployFactory(side: Side, log: Logger): Promise<FactoryDeployment> {
  const roles = protocolRoles();
  const { broadcast } = await forgeScript(
    "DeployFactory",
    side,
    ACTOR_KEYS.operator,
    {
      PROTOCOL_RECIPIENT: roles.protocolRecipient,
      ADAPTER_GUARDIAN: roles.adapterGuardian,
      REGISTRY_OWNER: roles.registryOwner,
      API_SIGNER: roles.apiSigner,
    },
    log,
  );
  // `run()` returns FactoryDeployment.Deployment: (create3Deployer, coreVaultLogic, spokeCrossChainLib,
  // spokeUnwindLib, managerRegistry, priceSource, factory), printed by forge as a tuple.
  const tuple = broadcast.returns.d?.value ?? "";
  const addresses = tuple.match(/0x[0-9a-fA-F]{40}/g)?.map((a) => getAddress(a)) ?? [];
  if (addresses.length !== 7) throw new Error(`unexpected DeployFactory return value: ${tuple}`);
  const [create3Deployer, coreVaultLogic, spokeCrossChainLib, spokeUnwindLib, managerRegistry, priceSource, fundFactory] =
    addresses;
  const code = await nodes[side].client.getCode({ address: fundFactory });
  if (!code || code === "0x") throw new Error(`no FundFactory code at ${fundFactory} on ${nodes[side].label}`);
  const transitEscrowImplementation = await read<Address>(side, {
    address: fundFactory,
    abi: fundFactoryAbi,
    functionName: "transitEscrowImplementation",
  });
  log.info("FundFactory deployed", { chain: nodes[side].chain.id, fundFactory });
  return {
    create3Deployer,
    coreVaultLogic,
    spokeCrossChainLib,
    spokeUnwindLib,
    managerRegistry,
    priceSource,
    fundFactory,
    transitEscrowImplementation,
  };
}

function eventFrom(run: ForgeRun, eventName: "FundCreated" | "SpokeCreated") {
  for (const receipt of run.broadcast.receipts) {
    for (const entry of receipt.logs) {
      try {
        const decoded = decodeEventLog({ abi: fundFactoryAbi, data: entry.data, topics: entry.topics as never });
        if (decoded.eventName === eventName) {
          return { args: decoded.args as unknown as Record<string, any>, blockNumber: BigInt(receipt.blockNumber) };
        }
      } catch {
        // another contract's event
      }
    }
  }
  throw new Error(`no ${eventName} event in the CreateFund broadcast`);
}

/** script/CreateFund.s.sol on both nodes with the manager's key: `createFund` on the hub, then `createSpoke` on
 *  Robinhood with the creation number and Mandate hash of the hub's `FundCreated`. */
export async function createFund(fundFactory: Address, log: Logger): Promise<FundRecord> {
  const manager = actors.manager.address;
  const planEnv = { FUND_FACTORY: fundFactory, MANAGER: manager, ...FUND_PLAN };

  const hubRun = await forgeScript("CreateFund", "arbitrum", ACTOR_KEYS.manager, planEnv, log);
  const created = eventFrom(hubRun, "FundCreated");
  const a = created.args.addresses;
  const creationNumber = (created.args.creationNumber as bigint).toString();
  const mandateHash = created.args.mandateHash as Hex;
  log.info("createFund", { creationNumber, fundId: created.args.fundId, mandateHash, coreVault: a.coreVault });

  const spokeRun = await forgeScript(
    "CreateFund",
    "robinhood",
    ACTOR_KEYS.manager,
    { ...planEnv, CREATION_NUMBER: creationNumber, MANDATE_HASH: mandateHash },
    log,
  );
  const spoke = eventFrom(spokeRun, "SpokeCreated");
  const s = spoke.args.addresses;
  log.info("createSpoke", { spokeVault: s.spokeVault });

  const hubChain = (a.chains as any[]).find((c) => Number(c.chainId) === nodes.arbitrum.chain.id);
  if (!hubChain) throw new Error("FundCreated carries no hub chain addresses");
  if (spoke.args.fundId !== created.args.fundId) throw new Error("SpokeCreated fund id differs from FundCreated");
  if (spoke.args.mandateHash !== mandateHash) throw new Error("SpokeCreated Mandate hash differs from FundCreated");

  const shareSymbol = await read<string>("arbitrum", { address: a.shareToken, abi: shareTokenAbi, functionName: "symbol" });
  return {
    creationNumber,
    fundId: created.args.fundId as Hex,
    mandateHash,
    manager,
    shareSymbol,
    hub: {
      chainId: nodes.arbitrum.chain.id,
      coreVault: a.coreVault,
      shareToken: a.shareToken,
      managerFeeVault: a.managerFeeVault,
      valueReportReceiver: a.valueReportReceiver,
      spokeVault: hubChain.spokeVault,
      uniswapV4Adapter: hubChain.uniswapV4Adapter,
      aaveV3Adapter: hubChain.aaveV3Adapter,
      acrossBridgeAdapter: hubChain.acrossBridgeAdapter,
      createdInBlock: created.blockNumber.toString(),
    },
    spoke: {
      chainId: nodes.robinhood.chain.id,
      wormholeChainId: WORMHOLE_ROBINHOOD,
      spokeIndex: 0,
      spokeVault: s.spokeVault,
      uniswapV4Adapter: s.uniswapV4Adapter,
      acrossBridgeAdapter: s.acrossBridgeAdapter,
      createdInBlock: spoke.blockNumber.toString(),
    },
    poolKeys: { hub: [HUB_POOL_KEY], spoke: [SPOKE_POOL_KEY] },
    poolIds: { hub: [HUB_POOL_ID], spoke: [SPOKE_POOL_ID], aave: AAVE_USDC_POOL_KEY },
  };
}
