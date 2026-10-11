// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {CoreAHubFixture} from "./CoreAHubFixture.sol";

/// @notice Review port of core-a C01, consolidated finding C-02 (register S-1). On `e5c778a` Share Assets valued a
///         Uniswap V4 position as (token amounts at the pool's SPOT price) x (oracle price), minimised at spot ==
///         oracle, so one swap moved the Share Price of every mint and burn (+10,243 USDC on this fixture, a claimant
///         kept 3,049 shares, a sandwiched entrant lost 923 USDC). Since S-1 (`CoreVaultLogic._oracleComposition`) the
///         position is recomputed from liquidity and ticks at the price-source price. These tests assert the corrected
///         behaviour and re-attack it: spot pushed above, below, inside the range and to the extreme ticks, a claim and
///         a deposit sandwiched by the push. The reported composition does move with the spot (the push is real); the
///         value the Core Vault derives from it does not.
contract C01_SpotCompositionValuation is CoreAHubFixture {
    uint256 internal constant ONE_SHARE = 1e18;
    /// @dev Share Assets of the fixture after the setUp (the manager's one-share seed, deposits 600,000 + 400,000,
    ///      25 bps flow fee, a 400,000 USDC hub position; no hub Operating Cash since DEC-127, CoreAHubFixture).
    uint256 internal constant FAIR_ASSETS = 997_500_999_998;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 600_000e6);
        _deposit(mallory, 400_000e6);
        _managerOpensHubPosition(400_000e6);
    }

    /// @dev Every spot an attacker could reach inside one unlock leaves Share Assets at the fair value.
    function test_REVIEW_C02_sharePriceIgnoresTheSpotInEveryDirection() public {
        uint256 fair = vault.sharePrice();
        assertEq(vault.shareAssets(), FAIR_ASSETS, "fair Share Assets");
        ReportCodec.Report memory before = hubVault.buildReport();

        int24[6] memory pushes = [
            tickUpper + 10, // just above the range (the review's push: +10,243 USDC on e5c778a)
            tickLower - 10, // just below the range
            tick0 + HALF_RANGE / 2, // inside the range, half way up
            tick0 - HALF_RANGE / 2, // inside the range, half way down
            TickMath.MAX_TICK - 1, // the whole pool drained one way
            TickMath.MIN_TICK + 1 // and the other
        ];
        for (uint256 i; i < pushes.length; ++i) {
            _moveSpot(pushes[i]);
            ReportCodec.Report memory during = hubVault.buildReport();
            assertTrue(
                during.positions[0].principal0 != before.positions[0].principal0
                    || during.positions[0].principal1 != before.positions[0].principal1,
                "the push moved the reported composition"
            );
            assertEq(vault.shareAssets(), FAIR_ASSETS, "Share Assets unchanged by the push");
            assertEq(vault.sharePrice(), fair, "Share Price unchanged by the push");
            _restoreSpot();
        }
        console2.log("fair Share Assets, every push", FAIR_ASSETS);
    }

    /// @dev The claimant's sandwich (push -> claimPayout -> restore) burns exactly the shares an honest claim burns.
    function test_REVIEW_C02_claimAroundASpotMoveBurnsTheFairShares() public {
        _request(mallory, 300_000e6, ICoreVaultPayouts.PayoutMode.Standard);
        vm.warp(block.timestamp + 72 hours + 1);

        uint256 snap = vm.snapshotState();
        uint256 fairPrice = vault.sharePrice();
        ICoreVault.PayoutReceipt memory fair = _claim(mallory);
        uint256 priceAfterFair = vault.sharePrice();
        vm.revertToState(snap);

        _moveSpot(tickUpper + 10);
        ICoreVault.PayoutReceipt memory pushed = _claim(mallory);
        _restoreSpot();

        console2.log("shares burned honest / pushed", fair.sharesBurned / ONE_SHARE, pushed.sharesBurned / ONE_SHARE);
        console2.log("USDC paid honest / pushed    ", fair.usdcPaid, pushed.usdcPaid);
        assertEq(pushed.unwindProceeds, 0, "Idle-paid: no unwind");
        assertEq(pushed.sharePrice, fairPrice, "burn priced at the fair price");
        assertEq(pushed.sharesBurned, fair.sharesBurned, "same shares burned");
        assertEq(pushed.sharesBurned, 300_000 * ONE_SHARE, "300,000 shares, as without the push");
        assertEq(pushed.usdcPaid, fair.usdcPaid, "same USDC paid");
        assertEq(vault.sharePrice(), priceAfterFair, "the remaining holders keep the fair price");
    }

    /// @dev A deposit sandwiched by the push mints exactly the shares an honest deposit mints.
    function test_REVIEW_C02_depositSandwichedBySpotMoveMintsTheFairShares() public {
        prices.setPrice(address(weth), WETH_PRICE_1E18); // fresh price for the mint path (same value)
        uint256 snap = vm.snapshotState();
        uint256 fairMinted = _deposit(victim, 100_000e6);
        vm.revertToState(snap);

        _moveSpot(tickUpper + 10);
        uint256 minted = _deposit(victim, 100_000e6);
        _restoreSpot();

        console2.log("victim shares minted honest / pushed", fairMinted / ONE_SHARE, minted / ONE_SHARE);
        assertEq(minted, fairMinted, "same shares as at the fair price");
        assertEq(minted, 99_750 * ONE_SHARE, "99,750 shares for 99,750 USDC after the flow fee");
    }
}
