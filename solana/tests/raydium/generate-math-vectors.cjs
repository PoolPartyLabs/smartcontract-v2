const { createRequire } = require('node:module');
const { join } = require('node:path');

if (!process.env.PP_RAYDIUM_SDK_ROOT) throw new Error('Set PP_RAYDIUM_SDK_ROOT to an isolated SDK 0.2.73-alpha install');
const sdkRequire = createRequire(join(process.env.PP_RAYDIUM_SDK_ROOT, 'package.json'));
const { LiquidityMathUtil, TickUtil } = sdkRequire('@raydium-io/raydium-sdk-v2');
const version = sdkRequire('@raydium-io/raydium-sdk-v2/package.json').version;
if (version !== '0.2.73-alpha') throw new Error('Unexpected differential SDK version');
const BN = sdkRequire('bn.js');
let seed = 2259;
function random() { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed; }
const rows = ['# Raydium SDK 0.2.73-alpha; source cc33ec28a8921a35609e83293e9e07ad830b0779',
  '# lower,upper,sqrt_lower,sqrt_upper,current_sqrt,liquidity,ceil,amount0,amount1'];
for (let index = 0; index < 256; index++) {
  const lower = index === 0 ? -443636 : index === 1 ? 0 : random() % 800000 - 400000;
  const upper = index === 0 ? 0 : index === 1 ? 443636 : Math.min(443636, lower + 1 + random() % 20000);
  const sqrtLower = TickUtil.getSqrtPriceAtTick(lower);
  const sqrtUpper = TickUtil.getSqrtPriceAtTick(upper);
  const candidates = [sqrtLower.subn(1), sqrtLower, sqrtLower.addn(1), sqrtUpper.subn(1), sqrtUpper, sqrtUpper.addn(1),
    TickUtil.getSqrtPriceAtTick(Math.floor((lower + upper) / 2))];
  const current = candidates[index % candidates.length];
  const liquidity = new BN(String(1 + random() % 1000000000));
  for (const ceil of [false, true]) {
    try {
      const { amountA, amountB } = LiquidityMathUtil.getAmountsForLiquidity(current, sqrtLower, sqrtUpper, liquidity, ceil);
      rows.push([lower, upper, sqrtLower, sqrtUpper, current, liquidity, ceil ? 1 : 0, amountA, amountB].join(','));
    } catch (error) {
      if (!String(error).includes('MaxTokenOverflow')) throw error;
    }
  }
}
process.stdout.write(rows.join('\n') + '\n');
