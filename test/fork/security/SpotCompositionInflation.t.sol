// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {EndToEndScenario} from "../e2e/EndToEnd.t.sol";

/// @notice Security regression (docs/security/FINDINGS.md S-1, static-analysis finding SA-01), on the pinned Arbitrum One
///         fork against the live WETH/USDC 0.05% pool. Was PoC
///         `test_POC_forkHubSharePriceFollowsPoolSpotCompositionNotTheOracle`: the hub Uniswap V4 position was valued
///         from the token amounts it holds at the pool's spot price, so moving the pool away from the oracle price, in
///         either direction, raised Share Assets and a Payout claimed then was paid at the raised price.
/// @dev Fix (S-1, `CoreVaultLogic._oracleComposition`): the position is valued from its liquidity and range at the
///      price-source price. The test moves the live pool down and up and asserts the attack now FAILS: the adapter
///      still reports the spot split, but Share Assets and the claim's Share Price stay at their oracle-price values.
contract SpotCompositionInflationForkTest is EndToEndScenario {
    uint256 internal constant PAYOUT = 1000e6;

    int24 internal center;
    uint256 internal assetsFair;
    uint256 internal priceFair;
    uint256 internal assetsDown;
    uint256 internal paidOut;

    function test_SEC_S1_forkHubSharePriceIgnoresPoolSpotComposition() public {
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
        assertApproxEqAbs(assetsDown, assetsFair, 1, "S-1: Share Assets did not follow the pushed pool");
        emit log_named_decimal_uint("Share Assets at the oracle price (USDC)", assetsFair, 6);
        emit log_named_decimal_uint("Share Assets with the pool pushed down (USDC)", assetsDown, 6);
    }

    /// @dev A Payout claimed in that state is priced at the oracle-price Share Price and paid from Idle.
    function _claimAtTheRaisedPrice() internal {
        vm.startPrank(ana);
        ICoreVault.PayoutReceipt memory receipt = core.requestPayout(PAYOUT, ICoreVaultPayouts.PayoutMode.Instant, 0);
        vm.stopPrank();
        assertEq(receipt.unwindProceeds, 0, "paid from Free Idle, nothing unwound");
        assertApproxEqRel(receipt.sharePrice, priceFair, 1e9, "S-1: the claim burned at the oracle-price Share Price");
        uint256 fairGross = receipt.sharesBurned * priceFair / 1e36;
        assertApproxEqAbs(receipt.usdcGross, fairGross, 1e6, "S-1: no more USDC left Idle than the shares were worth");
        // What left Share Assets: the gross less the Payout Fee, which stays in Idle (DEC-144).
        paidOut = receipt.usdcGross - receipt.payoutFee;
        emit log_named_decimal_uint("Share Price at the oracle price (USDC)", priceFair, 24);
        emit log_named_decimal_uint("Share Price the claim burned at (USDC)", receipt.sharePrice, 24);
    }

    /// @dev Above the range the adapter reports the position as USDC only; Share Assets stay at fair.
    function _pushUpAndRead() internal {
        _swapToTick(arbitrumRouter, _hubPoolKey(), ARB_V4_STATE_VIEW, center + 3 * HALF_RANGE);
        IAdapter.PositionValue memory lifted = IAdapter(hubUniswap).positionValue(hubUniswapPosition);
        assertEq(lifted.principal0, 0, "out of range above: the position is reported as USDC only");
        uint256 assetsUp = core.shareAssets() + paidOut;
        assertApproxEqAbs(assetsUp, assetsFair, 1e6, "S-1: Share Assets stay at fair in this direction too");
        emit log_named_decimal_uint("Share Assets with the pool pushed up, payout added back (USDC)", assetsUp, 6);
    }

    /// @dev Back at the starting price the valuation is still fair, less what the payout took out.
    function _restoreAndRead() internal {
        _swapToTick(arbitrumRouter, _hubPoolKey(), ARB_V4_STATE_VIEW, center);
        uint256 assetsRestored = core.shareAssets() + paidOut;
        assertApproxEqAbs(assetsRestored, assetsFair, 1e6, "S-1: the pool price never moved the valuation");
        emit log_named_decimal_uint("Share Assets with the pool restored, payout added back (USDC)", assetsRestored, 6);
    }

    /// @dev The trader's WETH and USDC at the oracle price.
    function _traderValue() internal view returns (uint256) {
        return IERC20(ARB_USDC).balanceOf(trader) + _usdcValue(ARB_WETH, IERC20(ARB_WETH).balanceOf(trader));
    }
}
