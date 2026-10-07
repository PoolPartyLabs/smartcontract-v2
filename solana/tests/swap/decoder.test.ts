import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { decodeRouteV2 } from '../../clients/swap/decoder.ts';

for (const file of readdirSync(new URL('./fixtures/v2/', import.meta.url)).filter(name => /^(wsol|tslax|nvdax).*\.json$/.test(name))) {
  test(`real V2 build fixture ${file} decodes exactly`, () => {
    const fixture = JSON.parse(readFileSync(new URL(`./fixtures/v2/${file}`, import.meta.url), 'utf8'));
    const route = Buffer.from(fixture.build.swapInstruction.data, 'base64');
    const decoded = decodeRouteV2(route);
    assert.equal(decoded.amountIn, BigInt(fixture.build.inAmount));
    assert.equal(decoded.quotedOut, BigInt(fixture.build.outAmount));
    assert.equal(decoded.slippageBps, fixture.build.slippageBps);
    for (const offset of [0, 26, 28, 30, 34, 35, 37, 38]) {
      const invalid = Buffer.from(route);
      invalid[offset] ^= 255;
      assert.throws(() => decodeRouteV2(invalid));
    }
    assert.throws(() => decodeRouteV2(Buffer.concat([route, Buffer.alloc(1)])));
    assert.throws(() => decodeRouteV2(route.subarray(0, 38)));
  });
}
