// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {CoreAHubFixture} from "./CoreAHubFixture.sol";

/// @notice Measurement only (consolidated L-04, register S-40): cost of the wrapped hub read versus the work a claim
///         does after it, to judge whether a claimant can starve `buildReport` of gas (63/64 rule) and still finish on
///         the fallback. Re-run on main after S-1 (the valuation now recomputes each position from liquidity and
///         ticks) and S-12 (fees through `trySafeTransfer`).
/// @dev Numbers on main, one hub position: the original measurement (reads warmed by the first `buildReport`)
///      gives hub buildReport 135,456, full valuation 86,251, claimPayout 173,959; the cold measurement (claim first,
///      then every contract cooled) gives claimPayout 275,449 and hub buildReport 123,458, so about 152k of claim work
///      beside the read and a starvation threshold near 63 x 152k = 9.6M gas of hub read. The review reported 135k for
///      the hub read and about 157k of work after it on `e5c778a` (threshold 9.9M).
contract GasFallbackMeasure is CoreAHubFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 600_000e6);
        _deposit(mallory, 400_000e6);
        _managerOpensHubPosition(400_000e6);
    }

    /// @dev Mallory's Instant request of 100,000, which is its own claim (DEC-120 item 1).
    function _mallorysClaim() internal {
        vm.prank(mallory);
        vault.requestPayout(100_000e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
    }

    function test_measure_buildReportVersusClaim() public {
        uint256 g0 = gasleft();
        hubVault.buildReport();
        uint256 buildCost = g0 - gasleft();
        g0 = gasleft();
        vault.shareAssets();
        uint256 valuationCost = g0 - gasleft();
        g0 = gasleft();
        _mallorysClaim();
        uint256 claimCost = g0 - gasleft();
        console2.log("hub buildReport gas", buildCost);
        console2.log("full valuation gas ", valuationCost);
        console2.log("claimPayout gas     ", claimCost);
        console2.log("work after the hub read (approx)", claimCost - buildCost);
        // For the fallback to be forced, buildReport must need more than 63x the work left after the catch.
        assertLt(buildCost, 63 * (claimCost - buildCost), "hub read far below 63x the remaining work");
    }

    /// @dev Same measurement with cold storage on both sides: the claim first, then the hub read with every contract
    ///      it touches cooled.
    function test_measure_coldClaimVersusColdHubRead() public {
        uint256 g0 = gasleft();
        _mallorysClaim();
        uint256 claimCost = g0 - gasleft();
        vm.cool(address(vault));
        vm.cool(address(hubVault));
        vm.cool(address(adapter));
        vm.cool(address(v4));
        vm.cool(address(prices));
        g0 = gasleft();
        hubVault.buildReport();
        uint256 buildCost = g0 - gasleft();
        console2.log("cold claimPayout gas  ", claimCost);
        console2.log("cold hub buildReport  ", buildCost);
        console2.log("claim work beside the read", claimCost - buildCost);
        assertLt(buildCost, 63 * (claimCost - buildCost), "hub read far below 63x the remaining work");
    }
}
