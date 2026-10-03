export interface BoundaryFlow {
  transaction: string;
  token: string;
  sender: string;
  receiver: string;
  amount: bigint;
}

export interface FlowEvidence extends BoundaryFlow {
  cause: "capital" | "market" | "payment" | "fee" | "bridge";
  event: string;
}

export class ExplainedFlows {
  readonly evidence: FlowEvidence[] = [];

  add(flow: FlowEvidence) {
    if (flow.amount > 0n) this.evidence.push({ ...flow, transaction: flow.transaction.toLowerCase(), token: flow.token.toLowerCase(), sender: flow.sender.toLowerCase(), receiver: flow.receiver.toLowerCase() });
  }

  match(flow: BoundaryFlow): Pick<FlowEvidence, "cause" | "event"> | undefined {
    const match = this.evidence.find((entry) => entry.transaction === flow.transaction.toLowerCase() && entry.token === flow.token.toLowerCase() && entry.sender === flow.sender.toLowerCase() && entry.receiver === flow.receiver.toLowerCase() && entry.amount >= flow.amount);
    if (!match) return undefined;
    match.amount -= flow.amount;
    return { cause: match.cause, event: match.event };
  }
}

export function conservationResult(valueIn: bigint, payments: bigint, fees: bigint, remaining: bigint, unexplained: bigint) {
  const residual = valueIn - payments - fees - remaining;
  return { residual, tolerance: 20n, passed: residual >= -20n && residual <= 20n && unexplained === 0n };
}
