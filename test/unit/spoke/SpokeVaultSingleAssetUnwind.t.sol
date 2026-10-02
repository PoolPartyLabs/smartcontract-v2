// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {Mandate, PoolConfig} from "../../../src/mandate/Mandate.sol";

/// @notice Independent verification plan T14 (review L-05): a single-asset position whose asset is not USDC (an Aave
///         WETH reserve) made `_unwindRoute` look for the other token of a one-token pool, so every automatic unwind
///         that reached that step reverted `UnexpectedToken`, before any hint could name a route. The step now takes
///         its swap route from the claimant's hint, like a pool that does not pair the token with USDC, and is refused
///         with a named error when no hint gives one.
contract SpokeVaultSingleAssetUnwindTest is SpokeVaultTestBase {
    bytes32 internal constant AAVE_WETH = keccak256("aave WETH");

    bytes32 internal wethKey;

    function setUp() public {
        _setUpMocks();
        hubAave.addPool(AAVE_WETH, address(weth), address(0));
        _deployHubWithAaveWeth();
        usdc.mint(address(core), 10_000e6);

        // 400 USDC allocated, swapped into 0.2 WETH at 2,000 through the swap adapter (DEC-136), all of it supplied
        // to the WETH reserve. The unwind's hinted route still sells in the Uniswap pool until WP-09: USDC liquidity.
        core.allocate(vault, 400e6);
        vm.startPrank(manager);
        vault.swap(address(hubSwap), address(usdc), address(weth), 400e6, 0, "");
        (wethKey,,) = vault.openPosition(address(hubAave), AAVE_WETH, 0.2e18, 0, "");
        vm.stopPrank();
        usdc.mint(address(hubUni), 10_000e6);
        hubUni.addLiquidity(address(usdc), 10_000e6);
        hubUni.setSwapRate(2000e6, 1e18);
    }

    function test_REVIEW_T14_singleAssetNonUsdcStepUnwindsThroughTheHintedRoute() public {
        SpokeUnwindTypes.UnwindHint[] memory hints = new SpokeUnwindTypes.UnwindHint[](1);
        hints[0].swaps = new SpokeUnwindTypes.UnwindSwap[](1);
        hints[0].swaps[0] = SpokeUnwindTypes.UnwindSwap(address(hubUni), HUB_POOL, address(weth), 0, "");

        assertEq(core.unwind(vault, 400e6, SpokeUnwindTypes.encodeHints(hints)), 400e6, "the WETH step paid 400 USDC");
        assertEq(vault.unallocatedBalance(address(weth)), 0, "the WETH it returned was swapped");
        (,,,,, bool open) = hubAave.position(wethKey);
        assertFalse(open, "the WETH position closed");
    }

    function test_REVIEW_T14_singleAssetNonUsdcStepWithoutARouteIsRefusedByName() public {
        vm.expectRevert(abi.encodeWithSelector(SpokeUnwindTypes.MissingUnwindSwap.selector, address(weth)));
        core.unwind(vault, 400e6, "");
    }

    function _deployHubWithAaveWeth() internal {
        Mandate memory m = _mandate();
        PoolConfig[] memory pools = new PoolConfig[](m.pools.length + 1);
        for (uint256 i; i < m.pools.length; ++i) {
            pools[i] = m.pools[i];
        }
        pools[m.pools.length] = PoolConfig(HUB, address(hubAave), AAVE_WETH);
        m.pools = pools;
        // The WETH reserve position is the only open one, so the registry-order unwind reaches it (DEC-137 interim).

        vm.chainId(HUB);
        vault = new SpokeVault(
            m,
            FUND_ID,
            HUB,
            address(core),
            address(usdc),
            makeAddr("hubAcrossSpokePool"),
            address(0),
            address(escrowImplementation),
            excessRecipient
        );
        hubUni.setVault(address(vault));
        hubAave.setVault(address(vault));
    }
}
