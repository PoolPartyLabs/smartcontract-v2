// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransitState} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice Adversarial verification, round 3, of the consolidation stage: the amount rule of arrival confirmation
///         (OQ-01, OQ-09, DEC-066, DEC-080, DEC-085, DEC-104) at its boundaries and in every transit state it can meet.
contract CoreVaultConsolidateVerifyRound3Test is CoreVaultFixture {
    uint256 internal constant SENT = 1000e6;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 10_000e6); // Idle 9,975 after the 25 bps flow fee
    }

    // ---------------------------------------------------------------------------------------------------------------
    // OQ-09 / OQ-01 / DEC-085: the rule is on `amountToArrive` (the Across `outputAmount`), not on the amount sent.
    // One unit below it is no arrival; exactly it is.
    // ---------------------------------------------------------------------------------------------------------------
    function test_OQ09_DEC085_listingConfirmsExactlyAtTheAmountToArriveNotOneUnitBelow() public {
        uint256 arrives = 999_500_000; // a 5 bps route fee, under the Mandate's 50 bps
        bytes32 id = _send(SENT, arrives);
        uint256 assets0 = vault.shareAssets();
        assertEq(assets0, SEED_IDLE + 8975e6 + arrives, "DEC-085: in flight at the amount that will arrive");

        _deliver(_arrived(_spokeReport(arrives - 1, arrives - 1), id, arrives - 1));
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.Sent), "one unit short is no arrival");
        assertEq(vault.inFlightValue(), arrives);
        assertEq(vault.shareAssets(), assets0, "the under-listed credit is unknown-origin value");

        _deliver(_arrived(_spokeReport(arrives, arrives), id, arrives));
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ArrivalConfirmed), "exactly the amount confirms");
        assertEq(vault.inFlightValue(), 0);
        assertEq(vault.shareAssets(), assets0, "DEC-104: the value moved bases, it did not change");
        assertEq(_bucketSum(), vault.shareAssets());
    }

    // ---------------------------------------------------------------------------------------------------------------
    // OQ-09 / OQ-01 / DEC-066: a listing at the amount reaching an ExpiryAttested transit whose Across refund already
    // sits in the escrow. The stranger made the fund whole: the transit is confirmed, Share Assets are unchanged, and
    // the refund stays in the escrow (the documented cost falls on the stranger, never on the fund).
    // ---------------------------------------------------------------------------------------------------------------
    function test_OQ09_listingAtTheAmountAfterAttestedExpiryConfirmsAndLeavesTheFundWhole() public {
        bytes32 id = _send(SENT, SENT);
        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        vault.attestExpiry(id);
        pool.refund(0);
        address escrow = vault.transit(id).escrow;
        assertEq(usdc.balanceOf(escrow), SENT, "the Across refund landed");

        _deliver(_arrived(_spokeReport(SENT, SENT), id, SENT));
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ArrivalConfirmed));
        assertEq(vault.inFlightValue(), 0);
        assertEq(vault.shareAssets(), SEED_IDLE + 9975e6, "the fund holds Idle 8,975 plus 1,000 on the spoke");
        assertEq(_bucketSum(), vault.shareAssets());

        vm.expectRevert(
            abi.encodeWithSelector(ICoreVault.InvalidTransitState.selector, id, uint8(TransitState.ArrivalConfirmed))
        );
        vault.recognizeRefund(id);
        assertEq(usdc.balanceOf(escrow), SENT, "the refund is stranded, outside every base");
        assertEq(vault.shareAssets(), SEED_IDLE + 9975e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // OQ-09 / OQ-01 / DEC-080: a dust listing of a RefundRecognized id (its amount is already back in Idle) does not
    // confirm it, so `confirmedArrived` does not grow by the whole amount and the dust stays unknown-origin value; a
    // later listing at the amount is the donation path and counts once.
    // ---------------------------------------------------------------------------------------------------------------
    function test_OQ09_dustListingOfARefundRecognizedIdStaysUnknownOriginValue() public {
        bytes32 id = _send(SENT, SENT);
        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        vault.attestExpiry(id);
        pool.refund(0);
        vault.recognizeRefund(id);
        assertEq(vault.idle(), SEED_IDLE + 9975e6);

        _deliver(_arrived(_spokeReport(1e6, 1e6), id, 1e6));
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.RefundRecognized), "dust confirms nothing");
        (uint256 spokeValue,,,) = vault.spokeCapUsage(0);
        assertEq(spokeValue, 0, "the dust is deducted as unknown-origin value");
        assertEq(vault.shareAssets(), SEED_IDLE + 9975e6);

        _deliver(_arrived(_spokeReport(SENT, SENT), id, SENT));
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ArrivalConfirmed), "a full listing is a donation");
        assertEq(vault.inFlightValue(), 0, "In-flight Value was already released by the refund");
        assertEq(
            vault.shareAssets(),
            SEED_IDLE + 9975e6 + SENT,
            "counted once: Idle holds the refund, the spoke the donation"
        );
        assertEq(_bucketSum(), vault.shareAssets());
    }

    // ---------------------------------------------------------------------------------------------------------------
    // OQ-09: the under-listing proof of non-arrival keeps the full-window exclusion. A report built after the deadline
    // whose 256 entries include the id below its amount proves nothing (the real fill may have been evicted); only
    // the deadline plus report lifetime path applies.
    // ---------------------------------------------------------------------------------------------------------------
    function test_OQ09_underListedIdInAFullWindowAfterTheDeadlineIsNoProof() public {
        bytes32 id = _send(SENT, SENT);
        vm.warp(uint256(vault.transit(id).fillDeadline) + 1);
        ReportCodec.Report memory r = _spokeReport(257e6, 257e6);
        r.arrivedTransits = new ReportCodec.TransitAmount[](ReportCodec.ARRIVAL_WINDOW);
        r.arrivedTransits[0] = ReportCodec.TransitAmount(id, 1e6);
        for (uint256 i = 1; i < r.arrivedTransits.length; ++i) {
            r.arrivedTransits[i] = ReportCodec.TransitAmount(keccak256(abi.encode("spam", i)), 1e6);
        }
        _deliver(r);
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.Sent));

        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ExpiryNotProvable.selector, id));
        vault.attestExpiry(id);

        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        vault.attestExpiry(id);
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ExpiryAttested));
        assertEq(vault.shareAssets(), SEED_IDLE + 9975e6, "counted once through the fund-level deduction");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // OQ-09 / DEC-066: an under-listing in a report built before the deadline proves nothing once the hub clock passes
    // it: the real fill can still land on the spoke until the deadline, so only a report built after it counts.
    // ---------------------------------------------------------------------------------------------------------------
    function test_OQ09_underListingInAReportBuiltBeforeTheDeadlineIsNoProof() public {
        bytes32 id = _send(SENT, SENT);
        _deliver(_arrived(_spokeReport(1e6, 1e6), id, 1e6));
        vm.warp(uint256(vault.transit(id).fillDeadline) + 1);

        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ExpiryNotProvable.selector, id));
        vault.attestExpiry(id);
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.Sent));
    }
}
