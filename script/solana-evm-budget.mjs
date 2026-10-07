import { readFileSync, readdirSync, existsSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = resolve(process.argv[2] ?? 'cache/sol-t9');
const modules = ['factory-v6', 'fund-v6', 'factory-legacy', 'fund-legacy', 'check-legacy'];
const results = [];
function files(directory) {
  if (!existsSync(directory)) return [];
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const path = resolve(directory, entry.name);
    return entry.isDirectory() ? files(path) : entry.name.endsWith('.json') && entry.name.includes('dry-run') ? [path] : [];
  });
}
function cast(args) {
  const result = spawnSync('cast', args, { encoding: 'utf8', timeout: 60000 });
  if (result.status !== 0) throw new Error('Read-only fee query failed');
  return result.stdout.trim();
}
for (const chain of ['arbitrum', 'robinhood']) {
  const rpc = process.env[chain === 'arbitrum' ? 'ARBITRUM_RPC_URL' : 'ROBINHOOD_RPC_URL'];
  for (const module of modules) {
    const directory = resolve(root, `evm-${chain}-${module}`);
    const logPath = resolve(directory, 'run.log');
    const entry = { chain, module, measuredAt: new Date().toISOString(), status: 'UNVERIFIED' };
    try {
      if (!rpc || !existsSync(logPath)) throw new Error('Missing dry run');
      const log = readFileSync(logPath, 'utf8');
      if (!log.includes('Script ran successfully.')) throw new Error('Simulation incomplete');
      if (module === 'check-legacy') { entry.status = 'read-only verification; no deployment spend'; results.push(entry); continue; }
      const candidates = files(resolve(directory, 'broadcast')).sort();
      const artifact = candidates.find(path => path.endsWith('dry-run/run-latest.json'));
      if (!artifact) throw new Error('Missing transaction artifact');
      const simulation = JSON.parse(readFileSync(artifact));
      const gasPrice = BigInt(cast(['gas-price', '--rpc-url', rpc]));
      const transactions = [];
      for (const record of simulation.transactions) {
        const transaction = record.transaction;
        const gas = BigInt(transaction.gas);
        const data = transaction.input ?? transaction.data ?? '0x';
        let executionWei = gas * gasPrice;
        let l1Wei;
        if (chain === 'arbitrum') {
          const response = cast(['call', '0x00000000000000000000000000000000000000C8',
            'gasEstimateComponents(address,bool,bytes)(uint64,uint64,uint256,uint256)',
            transaction.to ?? '0x0000000000000000000000000000000000000000', String(!transaction.to), data,
            '--from', transaction.from, '--rpc-url', rpc]);
          const values = response.split('\n').map(line => BigInt(line.split(' ')[0]));
          l1Wei = values[1] * values[2];
          executionWei = gas * values[2];
        } else {
          const serialized = cast(['mktx', ...(transaction.to ? [transaction.to] : ['--create']), '--data', data,
            '--nonce', String(BigInt(transaction.nonce)), '--gas-limit', String(gas), '--gas-price', String(gasPrice),
            '--legacy', '--chain-id', '4663', '--value', String(BigInt(transaction.value ?? '0x0'))]);
          l1Wei = BigInt(cast(['call', '0x420000000000000000000000000000000000000F',
            'getL1Fee(bytes)(uint256)', serialized, '--rpc-url', rpc]).split(' ')[0]);
        }
        transactions.push({ gas: gas.toString(), executionWei: executionWei.toString(), l1Wei: l1Wei.toString(),
          totalWei: (executionWei + l1Wei).toString() });
      }
      entry.status = 'L1-inclusive fee model at current query time; gas limits are conservative, not receipts';
      entry.currentGasPriceWei = gasPrice.toString();
      entry.transactions = transactions;
      entry.totalWei = transactions.reduce((sum, transaction) => sum + BigInt(transaction.totalWei), 0n).toString();
    } catch { entry.reason = 'Missing/failed fork, signed calldata, transaction artifacts or L1 oracle quote; never assume zero L1 fee'; }
    results.push(entry);
  }
}
const output = { measuredAt: new Date().toISOString(), noMainnetTransactions: true, measurements: results,
  limitations: 'Sequential dry-run artifacts use undeployed dependency addresses; live gasEstimateComponents may fail. Legacy scripts are evidence only, never additive launch requirements.' };
writeFileSync(resolve(root, 'evm-budget.json'), JSON.stringify(output, null, 2) + '\n');
console.log(JSON.stringify(output, null, 2));
