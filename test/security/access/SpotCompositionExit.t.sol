// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title Regression (security review S-1): a shareholder who pushes the pool's spot price no longer exits at an
///        inflated Share Price
/// @notice Was PoC `test_POC_shareholderExitsAtASharePriceInflatedBySpotComposition` (high, access lens): Share
///         Assets valued a Uniswap V4 position as the tokens it would return at the pool's CURRENT spot price, each
///         priced by the oracle, so pushing the pool past the fund's range read the position 17.5% too high and an
///         Instant Payout burned about 12% fewer shares than an honest exit of the same USDC.
/// @notice FIX (S-1, `CoreVaultLogic._oracleComposition`): the range is valued from its liquidity and ticks at the
///         price-source price. The test repeats the attack and asserts it now FAILS: the pushed pool leaves Share
///         Assets unchanged and the exit burns what an honest exit burns.
/// @dev The mock Uniswap V4 has no swap-driven price; `setTick` stands in for the attacker's swap and its reversal.
contract SpotCompositionExitPoC is AccessFundFixture {
    function test_SEC_S1_shareholderNoLongerExitsAtASpotInflatedSharePrice() public {
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

        // The attacker pushes the pool's spot price past the range, exits, and lets the price come back.
        v4.setTick(poolId, 6000);
        assertEq(core.shareAssets(), fairAssets, "S-1: Share Assets do not follow the pushed spot price");
        uint256 attackBurn = _exit(core, 190_000e6);
        v4.setTick(poolId, 0);

        assertEq(attackBurn, honestBurn, "S-1: the exit burns what an honest exit burns");
        assertApproxEqAbs(core.shareAssets(), fairAssets - 190_000e6, 1e6, "the fund paid the same 190,000 USDC");
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
