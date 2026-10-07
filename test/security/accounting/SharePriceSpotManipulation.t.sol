// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {MockV4} from "../../mocks/v4/MockV4.sol";
import {AccountingPocFixture} from "./AccountingPocFixture.sol";

/// @notice The whole attack in one call, so it runs inside one transaction and can be funded by a flash loan.
/// @dev `MockV4.setTick` stands in for the two legs of the attacker's own swap sandwich on the pool (buy WETH up to
///      the moved price, sell it back). On a real pool the two legs cost the attacker only the pool fee on the
///      liquidity crossed, which the test bounds with the pool's own math.
contract FlashExitAttacker {
    function attack(
        ICoreVault core,
        IERC20 usdc,
        MockV4 pool,
        bytes32 poolId,
        int24 fairTick,
        int24 movedTick,
        uint256 amount,
        bool drainIdle
    ) external returns (uint256 usdcPaid) {
        usdc.approve(address(core), amount);
        // 1. Mint at the fair Share Price.
        core.deposit(amount, 0);
        // 2. First leg: push the pool's spot price away from the oracle price.
        pool.setTick(poolId, movedTick);
        // 3. Exit at the inflated Share Price, paid from Idle. No term, no lock (Instant Payout). Asking for exactly
        //    Free Idle keeps the claim Idle-paid (no unwind), so the inflated value is never tested against a sale.
        usdcPaid =
        core.requestPayout(drainIdle ? core.freeIdle() : 1_000_000_000e6, ICoreVaultPayouts.PayoutMode.Instant, 0)
        .usdcPaid;
        // 4. Second leg: bring the pool back.
        pool.setTick(poolId, fairTick);
    }
}

/// @title Regression (security review S-1): a spot move inside one transaction no longer inflates the Share Price
/// @notice Was PoC `test_POC_sharePriceInflatedByPoolSpotMoveInOneTransaction` (CRITICAL): Share Assets valued a
///         Uniswap V4 position at the token amounts it holds at the pool's `slot0` price, priced by the oracle, so a
///         claimant who pushed the pool inside its own transaction exited at an inflated Share Price paid from Idle.
///
/// Fix (S-1, `CoreVaultLogic._oracleComposition`): a range position is valued from its `liquidity`, `tickLower` and
/// `tickUpper` at the price the price source gives, so `slot0` never reaches Share Assets. These tests run the same
/// one-transaction attack (`FlashExitAttacker.attack`) and assert that it now FAILS: Share Assets do not move with
/// spot, the attacker leaves with less than it borrowed, and the remaining Shareholder keeps its value.
contract SharePriceSpotManipulationPoC is AccountingPocFixture {
    /// @dev +-4,050 ticks: the position covers about -33 % / +50 % around the fair price.
    int24 internal constant HALF_WIDTH = 4050;
    /// @dev The attacker only has to leave the fund's range; 13,860 ticks is a price four times the oracle price.
    int24 internal constant TICK_MOVED = TICK_FAIR + 13_860;
    uint256 internal constant FLASH_LOAN = 300_000e6;

    function setUp() public {
        _deployFund(2000, 25);
    }

    function test_SEC_S1_spotMoveInOneTransactionNoLongerInflatesSharePrice() public {
        _deposit(alice, 1_000_000e6);
        _openHubPosition(800_000e6, HALF_WIDTH);
        uint256 fairAssets = core.shareAssets();
        uint256 fairPrice = core.sharePrice();
        uint256 aliceFair = _valueOf(alice);
        assertApproxEqAbs(fairAssets, 997_500e6, 1e6, "fair Share Assets: Idle plus the position at the oracle price");

        // The spot move alone leaves the published value bases where they were (no token moved, the oracle did not).
        uint256 snapshot = vm.snapshotState();
        v4.setTick(hubPoolId, TICK_MOVED);
        assertEq(core.shareAssets(), fairAssets, "S-1: Share Assets ignore the pool's spot price");
        assertEq(core.sharePrice(), fairPrice, "S-1: Share Price ignores the pool's spot price");
        vm.revertToState(snapshot);

        // The attack, in one call.
        FlashExitAttacker attacker = new FlashExitAttacker();
        usdc.mint(address(attacker), FLASH_LOAN);
        _refreshPrices();
        attacker.attack(core, usdc, v4, hubPoolId, TICK_FAIR, TICK_MOVED, FLASH_LOAN, false);

        // The round trip costs the attacker the two flow fees and the Payout Fee; it cannot repay the loan in full.
        assertLt(usdc.balanceOf(address(attacker)), FLASH_LOAN, "S-1: the attacker leaves with less than it borrowed");
        assertEq(shares.balanceOf(address(attacker)), 0, "full exit");
        assertGe(core.sharePrice(), fairPrice, "S-1: the Share Price is not below the fair price after the attack");
        assertGe(_valueOf(alice) + 1, aliceFair, "S-1: the remaining Shareholder lost nothing");
    }

    /// @notice The same attack against a full-range position: the valuation no longer follows spot, so a holder of
    ///         9 % of the shares is paid its own value and Free Idle stays.
    function test_SEC_S1_fullRangePositionNoLongerLetsAHolderDrainFreeIdle() public {
        int24 movedTick = TICK_FAIR + 41_590;
        _deposit(alice, 1_000_000e6);
        _openHubPositionAt(800_000e6, -887_270, 887_270);
        uint256 aliceFair = _valueOf(alice);
        uint256 fairPrice = core.sharePrice();

        FlashExitAttacker attacker = new FlashExitAttacker();
        uint256 loan = 100_000e6;
        usdc.mint(address(attacker), loan);
        _refreshPrices();
        attacker.attack(core, usdc, v4, hubPoolId, TICK_FAIR, movedTick, loan, true);

        assertGt(core.freeIdle(), 190_000e6, "S-1: Free Idle is not drained");
        assertLt(usdc.balanceOf(address(attacker)), loan, "S-1: the attacker leaves with less than it put in");
        assertGe(core.sharePrice(), fairPrice, "S-1: the Share Price did not fall");
        assertGe(_valueOf(alice) + 1, aliceFair, "S-1: the remaining Shareholder lost nothing");
    }
}
