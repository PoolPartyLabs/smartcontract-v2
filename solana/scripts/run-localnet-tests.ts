import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { pendingLocalnetTests } from './pending-localnet-tests.ts';

function tests(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    if (entry.name === 'unit' || entry.name === 'helpers') return [];
    const path = join(directory, entry.name);
    return entry.isDirectory() ? tests(path) : entry.name.endsWith('.test.ts') ? [path] : [];
  });
}

const discovered = tests('tests');
for (const entry of pendingLocalnetTests) {
  if (!discovered.includes(entry.path)) throw new Error(`Pending coverage disappeared: ${entry.path}`);
}
const pending = process.argv.includes('--pending');
const selected = pending ? pendingLocalnetTests.map(entry => entry.path)
  : discovered.filter(path => !pendingLocalnetTests.some(entry => entry.path === path));
for (const entry of pendingLocalnetTests) console.log(`PENDING ${entry.path}: ${entry.reason}`);
console.log(`${pending ? 'Pending (not acceptance)' : 'Default'} localnet set: ${selected.length} files`);
const result = spawnSync(process.execPath, ['--test', '--test-concurrency=1', ...selected], { stdio: 'inherit' });
process.exitCode = result.status ?? 1;
