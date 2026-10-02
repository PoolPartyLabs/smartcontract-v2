import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { logger, redactUrls } from "../src/log.ts";

const cases = [
  ["https://rpc.example.invalid/v2/SYNTHETIC_PATH", "https://rpc.example.invalid/..."],
  ["https://rpc.example.invalid?apiKey=SYNTHETIC_QUERY", "https://rpc.example.invalid/..."],
  ["https://rpc.example.invalid#SYNTHETIC_FRAGMENT", "https://rpc.example.invalid/..."],
  ["https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@rpc.example.invalid/rpc?apiKey=SYNTHETIC_QUERY", "https://rpc.example.invalid/..."],
  ["https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@rpc.example.invalid", "https://rpc.example.invalid"],
  ["http://SYNTHETIC_USER:p%40SYNTHETIC_PASSWORD@[::1]:8545", "http://[::1]:8545"],
  ["HTTPS://SYNTHETIC_USER:SYNTHETIC_PASSWORD@rpc.example.invalid:443#SYNTHETIC_FRAGMENT", "HTTPS://rpc.example.invalid:443/..."],
  ["http://127.0.0.1:8545", "http://127.0.0.1:8545"],
] as const;
const input = cases.map(([url]) => `Endpoint: '${url}' (${url}) "${url}"`).join("\n") + "\n";
const expected = cases.map(([, url]) => `Endpoint: '${url}' (${url}) "${url}"`).join("\n") + "\n";
assert.equal(redactUrls(input), expected);
assert.equal(redactUrls(expected), expected);

const directory = mkdtempSync(join(tmpdir(), "local-e2e-redaction-"));
try {
  const script = fileURLToPath(new URL("./redact-urls.sh", import.meta.url));
  const logfile = join(directory, "fork.log");
  const result = spawnSync("bash", ["-c", 'source "$1"; redact_urls | tee "$2"', "check", script, logfile], {
    input,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, expected);
  assert.equal(readFileSync(logfile, "utf8"), expected);
} finally {
  rmSync(directory, { recursive: true, force: true });
}

const output: string[] = [];
const original = { log: console.log, warn: console.warn, error: console.error };
try {
  console.log = console.warn = console.error = (line: string) => { output.push(line); };
  const log = logger("check");
  log.info(input, { rpc: cases[3][0] });
  log.warn(input, { rpc: cases[4][0] });
  log.error(input, { rpc: cases[6][0] });
  log.child("child").info(input);
} finally {
  Object.assign(console, original);
}
assert.equal(output.length, 4);
assert.ok(output.every((line) => !line.includes("SYNTHETIC_")));
console.log(`PASS: ${cases.length} synthetic URL cases; shell stdout/disk, TypeScript, and all logger levels`);
