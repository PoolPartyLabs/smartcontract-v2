// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";

/// @notice Adversarial verification, round 3, of the consolidation stage on the spoke side: the per-id credited total
///         the hub confirms against (OQ-01, OQ-09, DEC-085, DEC-092) under messages a stranger can send through Across.
contract SpokeVaultConsolidateVerifyRound3Test is SpokeVaultTestBase {
    bytes32 internal constant GENUINE = keccak256("hub transit genuine");

    function setUp() public {
        _setUpMocks();
        _deploySpoke();
        _disableOperatingCash();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // OQ-09 / OQ-01 / DEC-085 / DEC-092: an Income-kind message carrying a real id is credited to the collected income
    // bucket (outside Share Assets) and must not raise the listed total the hub confirms Share-Assets-bearing value
    // against; otherwise a stranger could confirm a transit with money the fund never books as principal.
    // ---------------------------------------------------------------------------------------------------------------
    function test_OQ09_incomeKindMessageCannotInflateTheListedTotalOfAPrincipalId() public {
        _arrive(1000e6, GENUINE, TransferKind.Income);
        _arrive(1e6, GENUINE, TransferKind.Principal);

        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.arrivedTransits.length, 1);
        assertEq(r.arrivedTransits[0].transitId, GENUINE);
        assertEq(r.arrivedTransits[0].amount, 1e6, "only the Principal part is listed");
        assertEq(vault.arrivals(GENUINE), 1e6);
        assertEq(r.cumulativeReceived, 1e6, "and only it counts as received principal");
        assertEq(vault.unallocatedBalance(address(usdg)), 1e6);
        assertEq(vault.collectedIncome(address(usdg)), 1000e6, "the Income part sits in the collected bucket");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // OQ-09 liveness limit (author's disclosure, round 3): a stranger's listing pushes the real id into the window,
    // a full window of listable spam evicts it, and the real fill that follows is credited to the same entry but is
    // never listed again. The transit falls back to the time path on the hub; the hub's fund-level deduction keeps it
    // counted once. Cost to the stranger: 257 USDG donated. Pinned here so a change to the rule is deliberate.
    // ---------------------------------------------------------------------------------------------------------------
    function test_OQ09_realFillAfterAStrangerListingAndAFlushIsCreditedButNeverListedAgain() public {
        _arrive(SpokeVaultTypes.MIN_LISTED_ARRIVAL, GENUINE, TransferKind.Principal);
        for (uint256 i; i < SpokeVaultTypes.ARRIVAL_WINDOW; ++i) {
            _arrive(SpokeVaultTypes.MIN_LISTED_ARRIVAL, keccak256(abi.encode("spam", i)), TransferKind.Principal);
        }
        _arrive(1000e6, GENUINE, TransferKind.Principal);

        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.arrivedTransits.length, ReportCodec.ARRIVAL_WINDOW);
        for (uint256 i; i < r.arrivedTransits.length; ++i) {
            assertTrue(r.arrivedTransits[i].transitId != GENUINE, "the real fill is not listed again");
        }
        assertEq(vault.arrivals(GENUINE), 1000e6 + SpokeVaultTypes.MIN_LISTED_ARRIVAL, "credited to the same entry");
        assertEq(
            r.cumulativeReceived,
            1000e6 + (SpokeVaultTypes.ARRIVAL_WINDOW + 1) * SpokeVaultTypes.MIN_LISTED_ARRIVAL,
            "carried for the hub to deduct as unknown-origin value"
        );
    }
}
