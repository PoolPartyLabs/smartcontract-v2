import { PublicKey } from '@solana/web3.js';

export const ADDRESSES = {
  spoke: 'Fg6PaFpoGXkYsidMpWxTWqkZ7FEfcYkgMQHGfVNLusVw',
  usdc: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
  tslax: 'XsDoVfqeBukxuZHWhdvWHBhgEHjGNst4MLodqsJHzoB',
  wsol: 'So11111111111111111111111111111111111111112',
  token: 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA',
  token2022: 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb',
  ata: 'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL',
  raydium: 'CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK',
  tslaxPool: '8aDaBQkTrS6HVMjyc6EZebgdiaXhLYGriDWKWWp1NpFF',
  solPool: '3ucNos4NbumPLZNWztqGHNFFgkHeRMBQAVemeeomsUxv',
  kamino: 'KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD',
  market: '7u3HeHxYDLhnCoErrtycNokbQYbWGzLs6JSDqGAv5PfF',
  reserve: 'D6q6wuQSrifJKZYpR1M8R4YawnLDtDsMmWM1NbBmgJ59',
  scopePrices: '3t4JZcueEzTbVP6kLxXrL3VpWx45jDer4eqysweBchNH',
  cctpTransmitter: 'CCTPV2Sm4AdWt5296sk4P66VBZ7bEhcARwFaaS9YPbeC',
  cctpMessenger: 'CCTPV2vPZJS2u2BBsUoscuikbYjnpFmbFsvVuJdgUMQe',
  wormhole: 'worm2ZoG2kUd4vFXhvjh93UUH596ayRfgQ2MgjNMTth',
  loader: 'BPFLoaderUpgradeab1e11111111111111111111111',
} as const;

export function publicKey(address: string): PublicKey {
  return new PublicKey(address);
}

export function derive(program: string, ...seeds: Buffer[]): string {
  return PublicKey.findProgramAddressSync(seeds, publicKey(program))[0].toBase58();
}

export function fundAddresses(hubCore: Buffer, spokeIndex: number, mandateHash = Buffer.alloc(32)) {
  if (hubCore.length !== 20 || !Number.isInteger(spokeIndex) || spokeIndex < 0 || spokeIndex > 65535) {
    throw new Error('Expected 20-byte Hub Core and u16 spoke index');
  }
  if (mandateHash.length !== 32) throw new Error('Expected 32-byte Mandate hash');
  const index = Buffer.alloc(2);
  index.writeUInt16LE(spokeIndex);
  const chain = Buffer.alloc(8);
  chain.writeBigUInt64LE(42161n);
  const fund = derive(ADDRESSES.spoke, Buffer.from('fund'), chain, hubCore, index, mandateHash);
  return {
    fund,
    vault: derive(ADDRESSES.spoke, Buffer.from('vault'), publicKey(fund).toBuffer()),
    emitter: derive(ADDRESSES.spoke, Buffer.from('emitter'), publicKey(fund).toBuffer()),
  };
}
