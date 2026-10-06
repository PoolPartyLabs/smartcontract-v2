export const Q64 = 1n << 64n;
const U64_MAX = (1n << 64n) - 1n;

export type RangeInventory = {
  balance0: bigint;
  balance1: bigint;
  sqrtPriceX64: bigint;
  sqrtLowerX64: bigint;
  sqrtUpperX64: bigint;
};

export function rangeWeights(inventory: RangeInventory): { weight0: bigint; weight1: bigint } {
  const { balance0, balance1, sqrtPriceX64: price, sqrtLowerX64: lower, sqrtUpperX64: upper } = inventory;
  if (balance0 < 0n || balance1 < 0n || balance0 > U64_MAX || balance1 > U64_MAX
      || lower <= 0n || upper <= lower || price <= 0n || upper >= 1n << 128n) {
    throw new Error('Invalid raw-unit inventory or CLMM sqrt-price range');
  }
  const clamped = price < lower ? lower : price > upper ? upper : price;
  return {
    weight0: (upper - clamped) * Q64 * Q64,
    weight1: (clamped - lower) * clamped * upper,
  };
}

function validateQuote(
  inventory: RangeInventory,
  zeroForOne: boolean,
  amount: bigint,
  expectedOutput: bigint,
): { balance0: bigint; balance1: bigint } {
  if (expectedOutput <= 0n || expectedOutput > U64_MAX) throw new Error('Invalid quote output');
  const balance0 = inventory.balance0 + (zeroForOne ? -amount : expectedOutput);
  const balance1 = inventory.balance1 + (zeroForOne ? expectedOutput : -amount);
  if (balance0 > U64_MAX || balance1 > U64_MAX) throw new Error('Quote overflows token-account balance');
  return { balance0, balance1 };
}

export async function solveRatio(
  inventory: RangeInventory,
  quote: (zeroForOne: boolean, amount: bigint) => Promise<bigint>,
  iterations = 8,
): Promise<{ zeroForOne: boolean; amount: bigint; expectedOutput: bigint } | null> {
  if (!Number.isInteger(iterations) || iterations < 1 || iterations > 12) throw new Error('Bound ratio iterations to 1..12');
  const { weight0, weight1 } = rangeWeights(inventory);
  const imbalance = inventory.balance0 * weight1 - inventory.balance1 * weight0;
  if (imbalance === 0n) return null;
  const zeroForOne = imbalance > 0n;
  let lower = 0n;
  let upper = zeroForOne ? inventory.balance0 : inventory.balance1;
  if (weight0 === 0n || weight1 === 0n) {
    const expectedOutput = await quote(zeroForOne, upper);
    validateQuote(inventory, zeroForOne, upper, expectedOutput);
    return { zeroForOne, amount: upper, expectedOutput };
  }
  let best: { zeroForOne: boolean; amount: bigint; expectedOutput: bigint } | null = null;
  let bestError = imbalance < 0n ? -imbalance : imbalance;
  for (let iteration = 0; iteration < iterations && lower <= upper; iteration++) {
    const amount = (lower + upper) / 2n;
    if (amount === 0n) { lower = 1n; continue; }
    const expectedOutput = await quote(zeroForOne, amount);
    const { balance0, balance1 } = validateQuote(inventory, zeroForOne, amount, expectedOutput);
    const residual = balance0 * weight1 - balance1 * weight0;
    const error = residual < 0n ? -residual : residual;
    if (error < bestError) { bestError = error; best = { zeroForOne, amount, expectedOutput }; }
    if (residual === 0n) break;
    if (zeroForOne ? residual > 0n : residual < 0n) lower = amount + 1n;
    else upper = amount - 1n;
  }
  if (!best) throw new Error('No improving swap-to-ratio quote; refresh inventory and retry');
  return best;
}
