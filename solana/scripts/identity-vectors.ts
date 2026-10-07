import { AbiCoder, keccak256 } from 'ethers';
import { publicKey, ADDRESSES, fundAddresses } from '../tests/helpers/addresses.ts';

const abi = AbiCoder.defaultAbiCoder();
const word = (value: number) => '0x' + value.toString(16).padStart(64, '0');
const zero = word(0);
const type = 'tuple(bytes32 program,bytes32 spoke,bytes32 usdcMint,bytes32 managerKey,uint256 chainId,tuple(bytes32 mint,address accountingId,bool stock)[] assets,tuple(bytes32 program,bytes32 pool,bytes32 reserve,bytes32 token0,bytes32 token1)[] venues,tuple(address,address,address,uint32,bytes32,bytes32,bytes32,bytes32,uint256) transport,bytes32 swapPolicyHash)';
const pub = (key: string) => '0x' + publicKey(key).toBuffer().toString('hex');
const vault = '0xf33ef011782bb01b1cf6ea9095db6c03278a314b670e89eb33101bd25dcd9dd4';
const config = [pub(ADDRESSES.spoke), '0x1ee39f01232b2e295e21e516f476e557768949820bc25b6f3b5466250070b0f1', pub(ADDRESSES.usdc), '0x0f0248bf50f38b8fa1b2f34e5ee9070476e3c10c3e72eefd4e4ddc58e0a5a3a1', 1,
  [[pub(ADDRESSES.usdc), '0x06dcacb276039c31d0c4d13c8d7b4d129b4e7253', false]],
  [[pub(ADDRESSES.kamino), zero, pub(ADDRESSES.reserve), pub(ADDRESSES.usdc), zero]],
  ['0xaf88d065e77c8cc2239327c5edb3a432268e5831', '0x28b5a0e9c621a5badaa536219b3a228c8168cf5d', '0x81d40f21f12a8f0e3252bccb954d722d4c464b64', 5, '0x7982cec8701aa4528f0d651030ecac78bb73226fe7646083d8d29db7d79ceeaa', vault, pub(ADDRESSES.cctpMessenger), vault, 50000], zero];
const nativeHash = (values: any[]) => keccak256(abi.encode(['uint256', type], [6, values]));
const policyHash = (values: any[]) => keccak256(abi.encode(['bytes32', 'bytes32', 'bytes32'], [keccak256(Buffer.from('PoolParty/SolanaPolicy/v6')), word(10), nativeHash(values)]));
const withoutSwap = nativeHash(config);
config[8] = '0x94cb3ff011a748f6413901cc90b64fa6cd56661a6176fb194e5b82ea355046dd';
const withSwap = nativeHash(config);
config[1] = zero;
const transport = config[7] as any[];
for (const index of [4, 5, 7]) transport[index] = zero;
const withSwapPolicy = policyHash(config);
config[8] = zero;
const withoutSwapPolicy = policyHash(config);
const target = fundAddresses(Buffer.alloc(20, 2), 1, Buffer.alloc(32, 3));
console.log(JSON.stringify({ program: pub(ADDRESSES.spoke), withoutSwap, withSwap, withoutSwapPolicy, withSwapPolicy, fund: pub(target.fund), vault: pub(target.vault), emitter: pub(target.emitter) }, null, 2));
