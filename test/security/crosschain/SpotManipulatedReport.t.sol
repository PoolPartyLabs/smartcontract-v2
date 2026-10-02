// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {MockPermit2} from "../../mocks/v4/MockPermit2.sol";
import {MockV4} from "../../mocks/v4/MockV4.sol";
import {CrossChainFixture} from "./helpers/CrossChainFixture.sol";

/// @title Regression (security review S-1): a report taken while the spoke pool's spot price is pushed no longer
///        overstates Share Assets on the hub
/// @notice Was PoC `test_POC_spotManipulatedReportInflatesPayout` (high, cross-chain lens): `SpokeVault.report()` is
///         permissionless and snapshots every Uniswap V4 position at the pool's CURRENT `slot0` composition; the hub
///         priced those amounts with its oracle, so a report taken while the pool was pushed out of the range read up
///         to `(k + 1) / 2` times the position and a Shareholder's Payout was paid above the shares' worth.
///
/// Fix (S-1, `CoreVaultLogic._oracleComposition`): the hub recomputes every range position from the reported
/// `liquidity`, `tickLower` and `tickUpper` at the price-source price and ignores the spot amounts. The test runs the
/// same attack (push, report, push back, deliver, claim) and asserts it now FAILS: Share Assets and the Payout are
/// those of the honest report and the remaining Shareholder keeps its value. `setTick` on the pool stand-in plays the
/// attacker's two swaps: moving `slot0` is all a swap does to this read.
contract SpotManipulatedReportPoC is CrossChainFixture {
    int24 internal constant RANGE = 4050; // 1.0001^4050 = 1.4993: the range spans -33% to +50% around the price.

    MockPermit2 internal permit2;
    MockV4 internal v4;
    PoolKey internal key;
    bytes32 internal poolId;
    bool internal wethIsToken0;
    int24 internal tick0;

    function _spokeCap() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function _beforeFundDeployment() internal override {
        permit2 = new MockPermit2();
        v4 = new MockV4(permit2);
        wethIsToken0 = address(spokeWeth) < address(usdg);
        (address c0, address c1) =
            wethIsToken0 ? (address(spokeWeth), address(usdg)) : (address(usdg), address(spokeWeth));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 500, 10, IHooks(address(0)));
        poolId = PoolId.unwrap(key.toId());
        // 2,500 USDG per WETH: 2.5e-9 USDG base units per WETH base unit is tick -198,080; the inverse is +198,080.
        tick0 = wethIsToken0 ? int24(-198_080) : int24(198_080);
        v4.setTick(poolId, tick0);
        // The pool stand-in pays swap outputs from its own balance; USDG in, WETH out at 2,500.
        spokeWeth.mint(address(v4), 1000e18);
        v4.setSwap(4e26, 10_000);
    }

    function _deploySpokePositionAdapter(address predictedSpokeVault)
        internal
        override
        returns (address adapter, bytes32 poolKey)
    {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        adapter = address(
            new UniswapV4Adapter(
                predictedSpokeVault,
                guardian,
                IPoolManager(address(v4)),
                IPositionManager(address(v4)),
                IStateView(address(v4)),
                IAllowanceTransfer(address(permit2)),
                keys
            )
        );
        return (adapter, poolId);
    }

    function test_SEC_S1_spotManipulatedReportNoLongerInflatesPayout() public {
        // Two Shareholders. The attacker holds one sixth of the shares.
        _deposit(alice, 1_000_000e6);
        (uint256 attackerShares,) = _deposit(attacker, 200_000e6);
        uint256 aliceShares = shares.balanceOf(alice);

        // The manager allocates 900,000 USDC to Robinhood and opens a WETH/USDG position around the price.
        (, uint256 depositId) = _sendToSpoke(900_000e6);
        _fillOnSpoke(depositId);
        _openSpokePosition();
        _reportAndDeliver(900);
        uint256 honestAssets = core.shareAssets();
        assertApproxEqRel(honestAssets, 1_196_550e6, 0.001e18, "Idle 297,000 + spoke 899,550");

        vm.prank(attacker);
        core.requestPayout(250_000e6, ICoreVault.PayoutMode.Standard);
        skip(72 hours);
        _reportAndDeliver(900);
        assertApproxEqRel(core.shareAssets(), honestAssets, 0.0001e18, "nothing moved in 72 hours");
        uint256 fairValue = attackerShares / 1e18 * core.sharePrice() / 1e18;
        uint256 aliceValueBefore = aliceShares / 1e18 * core.sharePrice() / 1e18;

        // 1. One transaction on the spoke: push the pool price out of the position's range, report, push it back.
        vm.chainId(SPOKE);
        v4.setTick(poolId, tick0 + RANGE);
        spoke.report();
        v4.setTick(poolId, tick0);
        uint256 manipulated = spokeWormhole.publishedCount() - 1;
        vm.chainId(HUB);

        // 2. Deliver and claim in one transaction. The oracle price never moved.
        skip(900);
        _deliver(manipulated);
        assertApproxEqRel(core.shareAssets(), honestAssets, 0.00001e18, "S-1: the pushed report reads the honest value");
        vm.prank(attacker);
        ICoreVault.PayoutReceipt memory receipt = core.claimPayout("");

        assertEq(receipt.sharesBurned, attackerShares, "every share burned");
        assertLe(receipt.usdcGross, fairValue + 10e6, "S-1: paid no more than the shares' worth");

        // The next honest report: Alice's shares kept their value.
        _reportAndDeliver(900);
        uint256 aliceValueAfter = aliceShares / 1e18 * core.sharePrice() / 1e18;
        assertGe(aliceValueAfter + 10e6, aliceValueBefore, "S-1: nothing taken from the remaining Shareholder");
    }

    /// @dev The manager swaps half of the USDG into WETH and opens one position over `tick0 +- RANGE`.
    function _openSpokePosition() internal {
        vm.chainId(SPOKE);
        vm.startPrank(manager);
        uint256 wethBought = spoke.swapExactInput(spokeAdapter, poolId, address(usdg), 445_000e6, 0, "");
        uint256 usdgLeft = spoke.unallocatedBalance(address(usdg));
        (uint256 amount0, uint256 amount1) = wethIsToken0 ? (wethBought, usdgLeft) : (usdgLeft, wethBought);
        spoke.openPosition(
            spokeAdapter,
            poolId,
            amount0,
            amount1,
            abi.encode(
                UniswapV4Adapter.OpenParams({
                    tickLower: tick0 - RANGE,
                    tickUpper: tick0 + RANGE,
                    liquidity: 0,
                    amount0Max: uint128(amount0),
                    amount1Max: uint128(amount1),
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            )
        );
        vm.stopPrank();
        vm.chainId(HUB);
    }
}
