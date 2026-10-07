export function decodeRouteV2(data: Uint8Array) {
  const route = Buffer.from(data);
  if (route.length !== 39 || route.subarray(0, 8).toString('hex') !== 'bb64facc31c4af14'
      || route.readUInt32LE(26) !== 0 || route.readUInt32LE(30) !== 1
      || ![26, 40].includes(route[34]) || route.subarray(35).toString('hex') !== '10270001')
    throw new Error('Unsupported Jupiter V2 wire');
  const amountIn = route.readBigUInt64LE(8);
  const quotedOut = route.readBigUInt64LE(16);
  const slippageBps = route.readUInt16LE(24);
  if (amountIn === 0n || quotedOut === 0n || slippageBps >= 10_000) throw new Error('Invalid Jupiter V2 amounts');
  return { amountIn, quotedOut, slippageBps };
}
