// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ISpokeVaultUnwind} from "../../../src/interfaces/ISpokeVaultUnwind.sol";
import {ISwapAdapter} from "../../../src/interfaces/ISwapAdapter.sol";
import {Mandate, PoolConfig} from "../../../src/mandate/Mandate.sol";

/// @notice Independent verification plan T14 (review L-05): a single-asset position whose asset is not USDC (an Aave
///         WETH reserve) once made every automatic unwind that reached it revert, because the unwind looked for the
///         other token of a one-token pool. Since the unwind sells through the Mandate swap adapter (DEC-136 item 4)
///         such a step needs no route of its own: its WETH is sold like any other. D-24 (DEC-148 item 1 reading): it
///         has a sale, so the requester's maximum applies to it, unlike a position that returns only the base token.
contract SpokeVaultSingleAssetUnwindTest is SpokeVaultTestBase {
    bytes32 internal constant AAVE_WETH = keccak256("aave WETH");
    bytes32 internal constant REQUEST = keccak256("request");

    bytes32 internal wethKey;

    function setUp() public {
        _setUpMocks();
        hubAave.addPool(AAVE_WETH, address(weth), address(0));
        _deployHubWithAaveWeth();
        usdc.mint(address(core), 10_000e6);

        // 400 USDC allocated, swapped into 0.2 WETH at 2,000 through the swap adapter (DEC-136), all of it supplied
        // to the WETH reserve.
        core.allocate(vault, 400e6);
        vm.startPrank(manager);
        vault.swap(address(hubSwap), address(usdc), address(weth), 400e6, 0, "");
        (wethKey,,) = vault.openPosition(address(hubAave), AAVE_WETH, 0.2e18, 0, "");
        vm.stopPrank();
    }

    function test_REVIEW_T14_singleAssetNonUsdcStepIsSoldThroughTheSwapAdapter() public {
        ISpokeVaultUnwind.UnwindResult memory r = core.unwind(vault, _unwindRequest(REQUEST, 1, 1, 0, true));
        assertEq(r.proceeds, 400e6, "the WETH step paid 400 USDC");
        assertEq(r.delivered, 1);
        assertEq(vault.unallocatedBalance(address(weth)), 0, "the WETH it returned was sold");
        (,,,,, bool open) = hubAave.position(wethKey);
        assertFalse(open, "the WETH position closed");
    }

    /// @dev D-24: a non-base single-asset position has a sale, so the requester's maximum applies: a 3% loss under a
    ///      1% maximum leaves it out (DEC-148), with the swap adapter's error as the reason.
    function test_D24_singleAssetNonUsdcStepIsSubjectToTheMaximum() public {
        hubSwap.setHaircutBps(300);
        vm.expectEmit(address(vault));
        emit ISpokeVaultUnwind.UnwindStepExcluded(
            REQUEST,
            address(hubAave),
            wethKey,
            abi.encodeWithSelector(ISwapAdapter.InsufficientOutput.selector, 388e6, 396e6)
        );
        ISpokeVaultUnwind.UnwindResult memory r = core.unwind(vault, _unwindRequest(REQUEST, 1, 1, 100, true));
        assertEq(r.excluded, 1);
        assertEq(r.proceeds, 0);
        (, uint256 principal,,,, bool open) = hubAave.position(wethKey);
        assertTrue(open, "left out whole");
        assertEq(principal, 0.2e18);
        assertEq(vault.positions().length, 1);
        assertFalse(vault.unwindDelivered(REQUEST, address(hubAave), wethKey));
        assertEq(vault.unallocatedBalance(address(weth)), 0, "nothing of the step stayed");
    }

    function _deployHubWithAaveWeth() internal {
        Mandate memory m = _mandate();
        PoolConfig[] memory pools = new PoolConfig[](m.pools.length + 1);
        for (uint256 i; i < m.pools.length; ++i) {
            pools[i] = m.pools[i];
        }
        pools[m.pools.length] = PoolConfig(HUB, address(hubAave), AAVE_WETH);
        m.pools = pools;

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
