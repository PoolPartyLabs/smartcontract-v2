export function alphaAmount(name: string, fallback: string, maximum = 100000000n): bigint {
  const amount = BigInt(process.env[name] ?? fallback);
  if (amount <= 0n || amount > maximum) throw new Error(`Invalid alpha amount: ${name}`);
  return amount;
}

export const alphaAmounts = {
  deposit: alphaAmount("ALPHA_DEPOSIT_AMOUNT", "5000000", 10000000n),
  send: alphaAmount("ALPHA_SEND_AMOUNT", "5000000", 5000000n),
  payout: alphaAmount("ALPHA_PAYOUT_AMOUNT", "1000000", 2000000n),
  aave: alphaAmount("ALPHA_AAVE_AMOUNT", "1000000", 2000000n),
  investor: alphaAmount("ALPHA_INVESTOR_DEPOSIT", "2000000", 5000000n),
  collectMinimum: alphaAmount("ALPHA_MIN_COLLECT_USDC", "500000", 1000000n),
};
