import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

function tests(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    if (entry.name === 'unit' || entry.name === 'helpers') return [];
    const path = join(directory, entry.name);
    return entry.isDirectory() ? tests(path) : entry.name.endsWith('.test.ts') ? [path] : [];
  });
}

const result = spawnSync(process.execPath, ['--test', '--test-concurrency=1', ...tests('tests')], { stdio: 'inherit' });
process.exitCode = result.status ?? 1;
