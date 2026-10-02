import {type Abi, type Address, type Hex} from "viem";
import {orderChannelAbi, valueReportReceiverAbi, wormholeCoreAbi} from "./abis.ts";

type Side = "hub" | "spoke";
export interface AlphaMessage {side: Side; sequence: string; payload: Hex}
interface RelayDependencies {
  sides: Record<Side, {wormhole: number; emitter: Address}>;
  bridges: Record<Side, Address>;
  receiver: Address;
  spoke: Address;
  vaaBase: string;
  read(side: Side, address: Address, functionName: string, args: unknown[], abi: Abi): Promise<any>;
  send(side: Side, address: Address, abi: Abi, functionName: string, args: unknown[], value?: bigint): Promise<unknown>;
  fetchVaa?: typeof fetch;
}

export function createAlphaDelivery({sides, bridges, receiver, spoke, vaaBase, read, send, fetchVaa = fetch}: RelayDependencies) {
  return async (message: AlphaMessage): Promise<boolean> => {
    const config = sides[message.side];
    const emitter = config.emitter.slice(2).toLowerCase().padStart(64, "0");
    const response = await fetchVaa(`${vaaBase}/${config.wormhole}/${emitter}/${message.sequence}`, {signal: AbortSignal.timeout(15000)});
    if (response.status === 404) return false;
    if (!response.ok) throw new Error("VAA service unavailable");
    const body = await response.json() as {data?: {vaa?: string}};
    if (!body.data?.vaa) throw new Error("Missing signed VAA");
    const vaa = `0x${Buffer.from(body.data.vaa, "base64").toString("hex")}` as Hex;
    const destination: Side = message.side === "spoke" ? "hub" : "spoke";
    const [verified, valid] = await read(destination, bridges[destination], "parseAndVerifyVM", [vaa], wormholeCoreAbi);
    if (!valid || verified.emitterChainId !== config.wormhole || verified.emitterAddress.toLowerCase() !== `0x${emitter}`
      || verified.sequence.toString() !== message.sequence || verified.payload.toLowerCase() !== message.payload.toLowerCase()) throw new Error("VAA verification failed");
    if (message.side === "spoke") {
      const hasReport = await read("hub", receiver, "hasReport", [0n], valueReportReceiverAbi);
      const previous = await read("hub", receiver, "lastWormholeSequence", [0n], valueReportReceiverAbi);
      if (hasReport && previous >= BigInt(message.sequence)) return true;
      await send("hub", receiver, valueReportReceiverAbi, "deliver", [vaa]);
    } else {
      const fee = await read("spoke", bridges.spoke, "messageFee", [], wormholeCoreAbi);
      try {
        await send("spoke", spoke, orderChannelAbi, "executeOrder", [vaa], fee);
      } catch (error: any) {
        if (error?.walk?.((entry: any) => entry?.data?.errorName === "OrderSequenceTooLow")) return true;
        throw error;
      }
    }
    return true;
  };
}

export async function drainAlphaPending(
  cursor: {pending: AlphaMessage[]},
  deliver: (message: AlphaMessage) => Promise<boolean>,
  save: () => void,
  onError: (message: AlphaMessage) => void,
) {
  for (const message of [...cursor.pending]) {
    try {
      if (await deliver(message)) {
        cursor.pending = cursor.pending.filter((entry) => entry !== message);
        save();
      }
    } catch {onError(message);}
  }
}
