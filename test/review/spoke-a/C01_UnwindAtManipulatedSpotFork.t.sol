// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";

import {CoreVault} from "../../../src/core/CoreVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {SpokeAForkBase, PoolTrader} from "./SpokeAForkBase.sol";

/// @notice A shareholder contract that runs the whole attack in one transaction: it moves the real pool, claims its
///         own Payout Request, and moves the pool back. Its WETH stands for a flash loan (the test checks the WETH is
///         all there at the end).
contract UnwindAttacker is PoolTrader {
    CoreVault internal immutable core;
    IERC20 internal immutable usdc;

    constructor(IPoolManager pm_, CoreVault core_, IERC20 usdc_, PoolKey memory key_) PoolTrader(pm_, key_) {
        core = core_;
        usdc = usdc_;
    }

    /// @dev The Instant request is its own claim (DEC-120 item 1), so it is kept and sent inside `attack`.
    uint256 internal pendingRequest;

    function depositAndRequest(uint256 amount, uint256 request) external {
        usdc.approve(address(core), amount);
        core.deposit(amount, 0);
        pendingRequest = request;
    }

    /// @param crushTick Tick the WETH sale pushes the pool to.
    /// @param jitLower Lower tick of the liquidity left right below `crushTick` (USDC only).
    /// @param jitLiquidity Liquidity of that range.
    /// @param restoreTick Tick the pool is swapped back to.
    function attack(int24 crushTick, int24 jitLower, uint128 jitLiquidity, int24 restoreTick)
        external
        returns (ICoreVault.PayoutReceipt memory receipt)
    {
        swapTo(true, crushTick);
        modify(jitLower, crushTick, int256(uint256(jitLiquidity)));
        receipt = core.requestPayout(pendingRequest, ICoreVaultPayouts.PayoutMode.Instant, 0);
        modify(jitLower, crushTick, -int256(uint256(jitLiquidity)));
        swapTo(false, restoreTick);
    }
}

/// @notice [C-01] (spoke-a) fork PoC, ported to main (S-2 regression): the unwind attack against the real Uniswap V4 WETH/USDC 0.05% pool on Arbitrum
///         (docs/INTEGRATIONS.md, the pool the project's own fork tests use), with the real PoolManager,
///         PositionManager, StateView and Permit2, and the real CoreVault + hub SpokeVault + UniswapV4Adapter. The
///         oracle is set to the pool's own price before the attack and never moves.
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 100>
///      forge test --match-path 'test/review/spoke-a/C01_UnwindAtManipulatedSpotFork.t.sol' -vv
contract C01_UnwindAtManipulatedSpotFork is SpokeAForkBase {
    struct Snap {
        uint256 assets;
        uint256 alice;
        uint256 attackerShares;
        uint256 weth;
        uint256 usdc;
    }

    function test_REVIEW_C01_fork_crushedSpotClaimNoLongerTakesThePosition() public {
        UnwindAttacker attacker = _setUpFund();
        uint256 price1e18 = _poolPrice();
        Snap memory b = _snap(address(attacker));
        console2.log("oracle = spot, USDC per WETH (1e6)", price1e18);
        console2.log("free idle", vault.freeIdle());
        console2.log("share assets before", b.assets);
        console2.log("alice value before", b.alice);

        // The attacker's flash capital: 1,000 WETH.
        uint256 flash = 1000e18;
        deal(WETH, address(attacker), flash);

        // One transaction: push the WETH price to 1/1,000 of the oracle, leave 5e16 of liquidity over the 1,000 ticks
        // below it, claim, take the liquidity back, swap back to the starting tick.
        int24 crush = _floor10(tick0 - 69_080);
        ICoreVault.PayoutReceipt memory r = attacker.attack(crush, crush - 1000, 5e16, tick0);

        (, int24 tickAfter,,) = IStateView(SV).getSlot0(PoolId.wrap(poolId));
        Snap memory a = _snap(address(attacker));
        console2.log("tick before", tick0);
        console2.log("tick after", tickAfter);
        console2.log("unwind proceeds", r.unwindProceeds);
        console2.log("paid to the attacker as claimant", r.usdcPaid);
        console2.log("hub positions left", hubVault.positions().length);
        console2.log("share assets after", a.assets);
        console2.log("alice value after", a.alice);
        console2.log("attacker WETH end (flash was 1000e18)", a.weth);
        console2.log("attacker USDC end", a.usdc);
        // Attacker wealth change at the unchanged oracle price: WETH delta + USDC + share value delta.
        int256 wethDeltaUsdc = (int256(a.weth) - int256(flash)) * int256(price1e18) / 1e18;
        int256 profit = wethDeltaUsdc + int256(a.usdc) + int256(a.attackerShares) - int256(b.attackerShares);
        console2.log("attacker WETH delta in USDC", wethDeltaUsdc);
        console2.log("attacker profit (USDC)", profit);
        console2.log("fund loss (USDC)", int256(b.assets) - int256(a.assets));

        // The pool is back where it was (within one tick) and the attacker still holds its flash WETH.
        assertApproxEqAbs(int256(tickAfter), int256(tick0), 1);
        assertGe(a.weth + 1e18, flash, "flash capital intact to within 1 WETH of fees");
        // Ported to main (S-2): the unwind swap is floored at the price source less 5%, so the crushed-spot sale
        // reverts, the unwind reverts whole and the claim is paid from Free Idle only. e5c778a: position closed,
        // Alice 199,497 -> 9,234, attacker +189,994 USDC.
        assertGt(r.unwindProceeds, 0, "DEC-136: the independent V3 route delivers");
        assertEq(hubVault.positions().length, 1, "the fund keeps its position");
        // DEC-144: the claimant's Payout Fee stays in Idle, so Alice even gains.
        assertGe(a.alice, b.alice, "the holder who stays loses nothing");
        assertLe(r.usdcPaid, b.assets - b.alice, "paid at most Free Idle");
        assertLt(profit, 0, "the round trip costs the attacker its pool fees");
    }

    /// @dev Alice 200,000 USDC; the attacker contract 10,000 USDC with an Instant request of 9,900; the manager puts
    ///      200,000 USDC in a range order below the price (USDC only, about -1% to -20%).
    function _setUpFund() internal returns (UnwindAttacker attacker) {
        _depositAs(alice, 200_000e6);
        attacker = new UnwindAttacker(IPoolManager(PM), vault, IERC20(USDC), key);
        deal(USDC, address(attacker), 10_000e6);
        attacker.depositAndRequest(10_000e6, 9900e6);

        vm.prank(manager);
        vault.allocateToHubSpokeVault(200_000e6);
        bytes memory params = abi.encode(
            UniswapV4Adapter.OpenParams({
                tickLower: _floor10(tick0 - 2230),
                tickUpper: _floor10(tick0 - 110),
                liquidity: 0,
                amount0Max: 0,
                amount1Max: 200_000e6,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.prank(manager);
        (positionKey,,) = hubVault.openPosition(address(adapter), poolId, 0, 200_000e6, params);
    }

    function _snap(address attacker) internal view returns (Snap memory s) {
        s.assets = vault.shareAssets();
        uint256 supply = shares.totalSupply();
        s.alice = Math.mulDiv(shares.balanceOf(alice), s.assets, supply);
        s.attackerShares = Math.mulDiv(shares.balanceOf(attacker), s.assets, supply);
        s.weth = IERC20(WETH).balanceOf(attacker);
        s.usdc = IERC20(USDC).balanceOf(attacker);
    }
}
