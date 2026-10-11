// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {ICoreBridge, CoreBridgeVM} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {WormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {toUniversalAddress} from "wormhole-sdk/Utils.sol";

/// @notice Smoke test for the toolchain: both mainnet forks resolve, the Uniswap V3 and Wormhole
///         dependencies compile, and the Wormhole guardian set can be overridden to sign VAAs locally.
contract ToolchainForkTest is Test {
    using WormholeOverride for ICoreBridge;

    // Arbitrum One (Hub Chain)
    address constant ARB_WORMHOLE_CORE = 0xa5f208e072434bC67592E4C49C1B991BA79BCA46;
    address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARB_UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    // Robinhood Chain (Spoke Chain)
    address constant RH_WORMHOLE_CORE = 0x141fBa8AD5D61bdaB45A047cF60b5Ad9784987FB;
    address constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant RH_UNIV3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    uint16 constant WH_CHAIN_ARBITRUM = 23;
    uint16 constant WH_CHAIN_ROBINHOOD = 72;

    function test_arbitrumFork_wormholeOverrideSignsVaa() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"));
        assertEq(block.chainid, 42_161);
        assertEq(IERC20Metadata(ARB_USDC).decimals(), 6);
        assertTrue(IUniswapV3Factory(ARB_UNIV3_FACTORY).getPool(ARB_WETH, ARB_USDC, 500) != address(0));

        ICoreBridge core = ICoreBridge(ARB_WORMHOLE_CORE);
        assertEq(core.chainId(), WH_CHAIN_ARBITRUM);
        core.setUpOverride();

        bytes32 emitter = toUniversalAddress(address(0xBEEF));
        bytes memory payload = abi.encode(uint256(1_000_000e6), uint64(block.timestamp));
        bytes memory encodedVaa = core.craftVaa(WH_CHAIN_ROBINHOOD, emitter, payload);

        (CoreBridgeVM memory parsed, bool valid, string memory reason) = core.parseAndVerifyVM(encodedVaa);
        assertTrue(valid, reason);
        assertEq(parsed.emitterChainId, WH_CHAIN_ROBINHOOD);
        assertEq(parsed.emitterAddress, emitter);
        assertEq(parsed.payload, payload);
    }

    function test_robinhoodFork_usdgAndUniswapV3() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
        assertEq(block.chainid, 4663);
        assertEq(IERC20Metadata(RH_USDG).decimals(), 6);
        assertEq(ICoreBridge(RH_WORMHOLE_CORE).chainId(), WH_CHAIN_ROBINHOOD);

        address pool = IUniswapV3Factory(RH_UNIV3_FACTORY).getPool(RH_WETH, RH_USDG, 500);
        assertTrue(pool != address(0));
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        assertGt(sqrtPriceX96, 0);
    }
}
