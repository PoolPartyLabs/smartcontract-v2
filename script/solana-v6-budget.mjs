import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const directory = resolve(process.argv[2] ?? 'cache/solana-deploy');
const measurements = [];
for (const chain of ['arbitrum', 'robinhood']) {
  const log = readFileSync(resolve(directory, `${chain}-deploy.log`), 'utf8');
  const gas = log.match(/Estimated total gas used for script:\s*(\d+)/)?.[1];
  const price = JSON.parse(readFileSync(resolve(directory, `${chain}-gas-price.json`), 'utf8')).result;
  if (!gas || !/^0x[0-9a-f]+$/i.test(price ?? '')) {
    measurements.push({ chain, status: 'UNVERIFIED: no completed simulation and gas measurement' });
    continue;
  }
  const wei = BigInt(gas) * BigInt(price);
  measurements.push({ chain, status: 'factory-only estimate; excludes Fund creation and L1 data fee',
    gas: gas, currentGasPriceWei: BigInt(price).toString(), executionWei: wei.toString(),
    executionEth: `${wei / 10n ** 18n}.${(wei % 10n ** 18n).toString().padStart(18, '0')}` });
}
console.log(JSON.stringify({ measuredAt: new Date().toISOString(), measurements }, null, 2));
