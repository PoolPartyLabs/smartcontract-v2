// Arrivals linked to the bridge deposits that carried them (plan amendments, WP-15). A transit id travels in the Across
// message the sender writes, and any depositor can write any id (DEC-090, OQ-09), so an id alone never says which
// transfer arrived. A transfer is found on its destination through the Across `FilledRelay` that fills its origin
// deposit: same origin chain and deposit id (both indexed), and the same relay data (tokens, amounts, depositor,
// recipient, deadlines, exclusive relayer and the hash of the message). The vault's arrival event is then the one in
// that fill's transaction, and its transit id is checked against the send's.
import { decodeEventLog, keccak256, type Abi, type Address, type Hex, type TransactionReceipt } from "viem";
import { acrossSpokePoolAbi } from "./abis.ts";
import { nodes, type Side } from "./chain.ts";
import { ARBITRUM, ROBINHOOD } from "./config.ts";

const POOL_OF: Record<Side, Address> = { arbitrum: ARBITRUM.acrossSpokePool, robinhood: ROBINHOOD.acrossSpokePool };
const FILLED_RELAY = acrossSpokePoolAbi.find((e) => e.type === "event" && e.name === "FilledRelay")!;

/** The fields of an origin `FundsDeposited` event (bytes32 generation) that a fill repeats. */
export interface DepositEvent {
  depositId: bigint;
  inputToken: Hex;
  outputToken: Hex;
  inputAmount: bigint;
  outputAmount: bigint;
  depositor: Hex;
  recipient: Hex;
  exclusiveRelayer: Hex;
  fillDeadline: number | bigint;
  exclusivityDeadline: number | bigint;
  message: Hex;
}

export interface LinkedArrival {
  /** The destination SpokePool's `FilledRelay` arguments (relayer, repayment chain, relay execution info, ...). */
  fill: Record<string, any>;
  /** The fill's transaction, where the vault logged the arrival. */
  receipt: TransactionReceipt;
  /** The vault's arrival event in that transaction, decoded. */
  arrival: Record<string, any>;
}

const same = (a: Hex, b: Hex) => a.toLowerCase() === b.toLowerCase();

/** Whether a `FilledRelay` fills exactly this deposit's relay data. */
function fills(fill: Record<string, any>, deposit: DepositEvent): boolean {
  return (
    same(fill.inputToken, deposit.inputToken) &&
    same(fill.outputToken, deposit.outputToken) &&
    fill.inputAmount === deposit.inputAmount &&
    fill.outputAmount === deposit.outputAmount &&
    same(fill.depositor, deposit.depositor) &&
    same(fill.recipient, deposit.recipient) &&
    same(fill.exclusiveRelayer, deposit.exclusiveRelayer) &&
    BigInt(fill.fillDeadline) === BigInt(deposit.fillDeadline) &&
    BigInt(fill.exclusivityDeadline) === BigInt(deposit.exclusivityDeadline) &&
    same(fill.messageHash, keccak256(deposit.message))
  );
}

/** The fill of `deposit` (made on `origin`) on the other chain, and the `eventName` event `vault` logged in the fill's
 *  transaction; undefined while no `FilledRelay` fills it (not filled yet, or filled by impersonating the pool, which
 *  logs none). Throws when the fill's transaction holds no such event, or more than one. */
export async function linkedArrival(
  origin: Side,
  deposit: DepositEvent,
  vault: Address,
  vaultAbi: Abi,
  eventName: string,
  fromBlock: bigint,
): Promise<LinkedArrival | undefined> {
  const destination: Side = origin === "arbitrum" ? "robinhood" : "arbitrum";
  const client = nodes[destination].client;
  const logs = (await client.getLogs({
    address: POOL_OF[destination],
    event: FILLED_RELAY as never,
    args: { originChainId: BigInt(nodes[origin].chain.id), depositId: deposit.depositId } as never,
    fromBlock,
  })) as unknown as { args: Record<string, any>; transactionHash: Hex }[];
  const matching = logs.filter((l) => fills(l.args, deposit));
  if (matching.length === 0) return undefined;
  if (matching.length > 1) throw new Error(`${matching.length} fills of deposit ${deposit.depositId}: a relay fills once`);
  const receipt = await client.getTransactionReceipt({ hash: matching[0].transactionHash });
  const arrivals: Record<string, any>[] = [];
  for (const entry of receipt.logs) {
    if (entry.address.toLowerCase() !== vault.toLowerCase()) continue;
    try {
      const decoded = decodeEventLog({ abi: vaultAbi, data: entry.data, topics: entry.topics });
      if (decoded.eventName === eventName) arrivals.push(decoded.args as Record<string, any>);
    } catch {
      // another event of the vault
    }
  }
  if (arrivals.length !== 1) {
    throw new Error(`the fill ${matching[0].transactionHash} of deposit ${deposit.depositId} logged ${arrivals.length} ${eventName} events at ${vault}`);
  }
  return { fill: matching[0].args, receipt, arrival: arrivals[0] };
}
