import {decodeAbiParameters, type AbiParameter, type Hex} from "viem";
import {spokeVaultAbi} from "./abis.ts";

export const SPOKE_REPORT_VERSION = 5n;
const buildReport = spokeVaultAbi.find((entry) => entry.type === "function" && entry.name === "buildReport");
if (!buildReport || buildReport.type !== "function") throw new Error("Missing buildReport ABI");
export const SPOKE_REPORT_TUPLE = buildReport.outputs[0] as AbiParameter;
if (!("components" in SPOKE_REPORT_TUPLE) || SPOKE_REPORT_TUPLE.components.at(-1)?.name !== "refundedTransits") {
  throw new Error("Spoke report ABI must include the v5 refund proof");
}

export function decodeSpokeReport(payload: Hex): Record<string, any> {
  const [version] = decodeAbiParameters([{type: "uint256"}], payload);
  if (version !== SPOKE_REPORT_VERSION) throw new Error(`Unsupported spoke report version: ${version}`);
  const [, report] = decodeAbiParameters([{type: "uint256"}, SPOKE_REPORT_TUPLE], payload);
  return report as Record<string, any>;
}
