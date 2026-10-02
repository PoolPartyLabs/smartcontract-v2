// local-e2e/.state/deployment.json: every address the harness deployed or uses, the default fund, and what the
// keeper needs. Written by `up`, read by every other script (and by the API and frontend during development).
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import type { Address, Hex } from "viem";
import { DEPLOYMENT_FILE, STATE_DIR, type ActorName, type PoolKey } from "./config.ts";

export interface NodeState {
  rpc: string;
  chainId: number;
  forkBlockNumber: number;
  forkBlockTimestamp: number;
}

/** A fund's contracts on both chains (the `FundCreated` and `SpokeCreated` events of the factories). */
export interface FundRecord {
  creationNumber: string;
  fundId: Hex;
  mandateHash: Hex;
  manager: Address;
  shareSymbol: string;
  hub: {
    chainId: number;
    coreVault: Address;
    shareToken: Address;
    managerFeeVault: Address;
    valueReportReceiver: Address;
    spokeVault: Address;
    uniswapV4Adapter: Address;
    aaveV3Adapter: Address;
    acrossBridgeAdapter: Address;
    createdInBlock: string;
  };
  spoke: {
    chainId: number;
    wormholeChainId: number;
    spokeIndex: number;
    spokeVault: Address;
    uniswapV4Adapter: Address;
    acrossBridgeAdapter: Address;
    createdInBlock: string;
  };
  poolKeys: { hub: PoolKey[]; spoke: PoolKey[] };
  poolIds: { hub: Hex[]; spoke: Hex[]; aave: Hex };
}

export interface ProtocolState {
  arbitrum: {
    fundFactory: Address;
    create3Deployer: Address;
    coreVaultLogic: Address;
    spokeCrossChainLib: Address;
    spokeUnwindLib: Address;
    managerRegistry: Address;
    priceSource: Address;
    transitEscrowImplementation: Address;
    protocolRecipient: Address;
    adapterGuardian: Address;
    registryOwner: Address;
    /** The API's key: route and quote signer (reading D-01 of DEC-112). */
    apiSigner: Address;
  };
  robinhood: {
    fundFactory: Address;
    create3Deployer: Address;
    spokeCrossChainLib: Address;
    spokeUnwindLib: Address;
    transitEscrowImplementation: Address;
    apiSigner: Address;
  };
}

/** Where a token keeps its balances: `keccak256(abi.encode(holder, index))` (Solidity mapping at slot `index`). */
export interface BalanceLayout {
  token: Address;
  mappingSlot: string;
}

export interface DeploymentState {
  /** 2: the guardian on both Cores and the API signer. */
  version: 2;
  createdAt: string;
  nodes: { arbitrum: NodeState; robinhood: NodeState };
  actors: Record<ActorName, Address>;
  /** The local guardian and the guardian set it forms on each node's Core (reports verified on Arbitrum, Hub orders
   *  on Robinhood). */
  guardian: {
    address: Address;
    arbitrum: { coreBridge: Address; guardianSetIndex: number };
    robinhood: { coreBridge: Address; guardianSetIndex: number };
  };
  protocol: ProtocolState;
  external: { arbitrum: Record<string, Address>; robinhood: Record<string, Address> };
  fund: FundRecord;
  helpers: {
    arbitrumSwapRouter: Address;
    robinhoodSwapRouter: Address;
    /** A Uniswap V3 swap adapter per chain (src/adapters/UniswapV3SwapAdapter.sol) whose route signer is the API
     *  signer and whose vault is the manager's wallet, standing in for the fund's own adapters until the factory
     *  deploys them (Mandate v2, WP-07). The API signs routes for it; `swapAdapterVault` is the only caller of `swap`. */
    swapAdapters: { arbitrum: Address; robinhood: Address };
    swapAdapterVault: Address;
  };
  storage: {
    balances: { arbitrum: BalanceLayout[]; robinhood: BalanceLayout[] };
    /** Mapping slot of `fillStatuses` in each Across SpokePool (the keeper zero-fills a new relay's status slot so a
     *  fill never needs upstream state; see README "Troubleshooting"). */
    acrossFillStatusesSlot: { arbitrum: string; robinhood: string };
    /** Mapping slot of `sequences` in the Wormhole Core on Robinhood (same purpose, for new emitters). */
    wormholeSequencesSlot: string;
  };
}

export function readState(): DeploymentState {
  if (!existsSync(DEPLOYMENT_FILE)) {
    throw new Error(`no deployment state at ${DEPLOYMENT_FILE}: run \`pnpm run up\` first`);
  }
  return JSON.parse(readFileSync(DEPLOYMENT_FILE, "utf8")) as DeploymentState;
}

export function tryReadState(): DeploymentState | undefined {
  return existsSync(DEPLOYMENT_FILE) ? readState() : undefined;
}

export function writeState(state: DeploymentState): void {
  mkdirSync(STATE_DIR, { recursive: true });
  writeFileSync(DEPLOYMENT_FILE, JSON.stringify(state, null, 2) + "\n");
}
