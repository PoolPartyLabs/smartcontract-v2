// ABIs: the protocol's from the committed local-e2e/abis (what the API and frontend consume), and minimal
// human-readable ABIs for the external protocols the harness drives.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseAbi, type Abi } from "viem";
import { ABI_DIR, REPO_DIR } from "./config.ts";

function load(name: string): Abi {
  return JSON.parse(readFileSync(join(ABI_DIR, `${name}.json`), "utf8")) as Abi;
}

export const coreVaultAbi = load("CoreVault");
export const spokeVaultAbi = load("SpokeVault");
export const shareTokenAbi = load("ShareToken");
export const valueReportReceiverAbi = load("ValueReportReceiver");
export const fundFactoryAbi = load("FundFactory");
export const uniswapV4AdapterAbi = load("UniswapV4Adapter");
export const aaveV3AdapterAbi = load("AaveV3Adapter");
export const acrossBridgeAdapterAbi = load("AcrossBridgeAdapter");
export const uniswapV3SwapAdapterAbi = load("UniswapV3SwapAdapter");
export const managerFeeVaultAbi = load("ManagerFeeVault");
export const managerRegistryAbi = load("ManagerRegistry");
export const chainlinkPriceSourceAbi = load("ChainlinkPriceSource");

export const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function totalSupply() view returns (uint256)",
  "function deposit() payable",
]);

/** Across SpokePool (bytes32 generation; both live implementations expose these, verified on the forks). */
export const acrossSpokePoolAbi = parseAbi([
  "struct V3RelayData { bytes32 depositor; bytes32 recipient; bytes32 exclusiveRelayer; bytes32 inputToken; bytes32 outputToken; uint256 inputAmount; uint256 outputAmount; uint256 originChainId; uint256 depositId; uint32 fillDeadline; uint32 exclusivityDeadline; bytes message; }",
  "struct V3RelayExecutionEventInfo { bytes32 updatedRecipient; bytes32 updatedMessageHash; uint256 updatedOutputAmount; uint8 fillType; }",
  "event FundsDeposited(bytes32 inputToken, bytes32 outputToken, uint256 inputAmount, uint256 outputAmount, uint256 indexed destinationChainId, uint256 indexed depositId, uint32 quoteTimestamp, uint32 fillDeadline, uint32 exclusivityDeadline, bytes32 indexed depositor, bytes32 recipient, bytes32 exclusiveRelayer, bytes message)",
  "event FilledRelay(bytes32 inputToken, bytes32 outputToken, uint256 inputAmount, uint256 outputAmount, uint256 repaymentChainId, uint256 indexed originChainId, uint256 indexed depositId, uint32 fillDeadline, uint32 exclusivityDeadline, bytes32 exclusiveRelayer, bytes32 indexed relayer, bytes32 depositor, bytes32 recipient, bytes32 messageHash, V3RelayExecutionEventInfo relayExecutionInfo)",
  "function fillRelay(V3RelayData relayData, uint256 repaymentChainId, bytes32 repaymentAddress)",
  "function fillStatuses(bytes32 relayHash) view returns (uint256)",
  "function getCurrentTime() view returns (uint256)",
  "function chainId() view returns (uint256)",
  "function pausedFills() view returns (bool)",
  "function numberOfDeposits() view returns (uint32)",
  "function fillDeadlineBuffer() view returns (uint32)",
  "error ExpiredFillDeadline()",
  "error RelayFilled()",
  "error NotExclusiveRelayer()",
  "error FillsArePaused()",
  "error InvalidRepaymentAddress()",
]);

/** Wormhole Core Bridge (lib/wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol, the parts the harness uses). */
export const wormholeCoreAbi = parseAbi([
  "struct GuardianSet { address[] keys; uint32 expirationTime; }",
  "struct Signature { bytes32 r; bytes32 s; uint8 v; uint8 guardianIndex; }",
  "struct VM { uint8 version; uint32 timestamp; uint32 nonce; uint16 emitterChainId; bytes32 emitterAddress; uint64 sequence; uint8 consistencyLevel; bytes payload; uint32 guardianSetIndex; Signature[] signatures; bytes32 hash; }",
  "event LogMessagePublished(address indexed sender, uint64 sequence, uint32 nonce, bytes payload, uint8 consistencyLevel)",
  "function parseAndVerifyVM(bytes encodedVM) view returns (VM vm, bool valid, string reason)",
  "function getCurrentGuardianSetIndex() view returns (uint32)",
  "function getGuardianSet(uint32 index) view returns (GuardianSet)",
  "function nextSequence(address emitter) view returns (uint64)",
  "function chainId() view returns (uint16)",
  "function messageFee() view returns (uint256)",
  "function publishMessage(uint32 nonce, bytes payload, uint8 consistencyLevel) payable returns (uint64 sequence)",
]);

/** The order channel's consumer (`SpokeVault.executeOrder`, WP-07 plan D4) and the errors of
 *  src/libraries/OrderVerifier.sol and OrderCodec.sol, for the keeper's relay before the entry is in the exported
 *  Spoke Vault ABI. */
export const orderChannelAbi = parseAbi([
  "function executeOrder(bytes vaa) payable returns (uint64 reportSequence)",
  "event OrderExecuted(uint8 kind, bytes32 orderId, uint64 wormholeSequence)",
  "error InvalidOrderVaa(string reason)",
  "error OrderEmitterChainMismatch(uint16 emitterChainId)",
  "error OrderEmitterMismatch(bytes32 emitterAddress)",
  "error OrderSequenceTooLow(uint64 minSequence, uint64 sequence)",
  "error OrderFundMismatch(bytes32 fundId)",
  "error OrderExpired(uint64 deadline)",
  "error UnsupportedOrderVersion(uint256 version)",
  "error OrderPayloadTooShort(uint256 length)",
  "error UnknownOrderKind(uint8 kind)",
  "error InvalidOrderFraction(uint256 fracNum, uint256 fracDen)",
  "error InvalidPayoutMode(uint8 payoutMode)",
]);

export const stateViewAbi = parseAbi([
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  "function getLiquidity(bytes32 poolId) view returns (uint128)",
]);

export const chainlinkAggregatorAbi = parseAbi([
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
  "function aggregator() view returns (address)",
  "function decimals() view returns (uint8)",
]);

export const aavePoolAbi = parseAbi([
  "function getReserveNormalizedIncome(address asset) view returns (uint256)",
]);

/** test/mocks/v4/V4SwapRouter.sol, a third-party trader's router on `PoolManager.unlock` (deployed by `up`). */
export const v4SwapRouterAbi = parseAbi([
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "constructor(address manager)",
  "function swap(PoolKey key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) returns (int256 delta)",
  "function manager() view returns (address)",
]);

/** Creation code of the V4SwapRouter test helper, from the forge build output. */
export function v4SwapRouterBytecode(): `0x${string}` {
  return forgeArtifact("V4SwapRouter.sol", "V4SwapRouter").bytecode;
}

/** A contract's ABI and creation code from the forge build output (`out/<file>/<contract>.json`). */
export function forgeArtifact(file: string, contract: string): { abi: Abi; bytecode: `0x${string}` } {
  const artifact = JSON.parse(readFileSync(join(REPO_DIR, "out", file, `${contract}.json`), "utf8"));
  return { abi: artifact.abi as Abi, bytecode: artifact.bytecode.object as `0x${string}` };
}

/** Every error the protocol and the external contracts can revert with, for decoding reverts that bubble up through
 *  another contract (an adapter's error surfacing from a vault call, for instance). */
export const allErrorsAbi: Abi = (() => {
  const seen = new Set<string>();
  const errors: Abi[number][] = [];
  const all = [
    coreVaultAbi,
    spokeVaultAbi,
    shareTokenAbi,
    valueReportReceiverAbi,
    fundFactoryAbi,
    uniswapV4AdapterAbi,
    aaveV3AdapterAbi,
    acrossBridgeAdapterAbi,
    uniswapV3SwapAdapterAbi,
    managerFeeVaultAbi,
    managerRegistryAbi,
    chainlinkPriceSourceAbi,
    acrossSpokePoolAbi,
    orderChannelAbi,
  ];
  for (const abi of all) {
    for (const item of abi) {
      if (item.type !== "error") continue;
      const key = `${item.name}(${item.inputs.map((i) => i.type).join(",")})`;
      if (seen.has(key)) continue;
      seen.add(key);
      errors.push(item);
    }
  }
  return errors as Abi;
})();
