// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {CrossChainFixture} from "./helpers/CrossChainFixture.sol";

/// @title Regression (security review S-13): pre-listing a future transit id no longer keeps its arrival unconfirmed or
///        releases the Spoke Cap
/// @notice Was PoC `test_POC_preListedTransitReleasesSpokeCap` (medium, cross-chain lens): hub transit ids are
///         predictable, the spoke listed an id only once (when its total first reached 1 USDG), so a stranger's 1 USDG
///         pre-fill plus a flush of the 256-id window kept the real fill from ever being listed; the time-path expiry
///         then released the cap and the manager sent it again (299,850 USDG on a spoke capped at 100,000).
///
/// Fix (S-13): the spoke lists an id again on every credit of at least the listing minimum, so the real fill is listed
/// and confirmed by the next report; and a time-path expiry keeps the Spoke Cap. The test repeats the attack and asserts
/// it now FAILS: both sends are confirmed and the next send of the whole cap is refused.
contract SpokeCapBypassPoC is CrossChainFixture {
    uint256 internal constant CAP = 100_000e6;

    function test_SEC_S13_preListedTransitIsConfirmedAndTheSpokeCapHolds() public {
        assertEq(_spokeCap(), CAP);
        _deposit(alice, 400_000e6);
        uint256 assetsBefore = core.shareAssets();

        // 1. Pre-list the id of the next hub send with 1 USDG, then flush the ring with 256 dust arrivals.
        bytes32 first = _hubTransitId(1);
        _strangerFillOnSpoke(attacker, first, 1e6, TransferKind.Principal);
        for (uint256 i; i < 256; ++i) {
            _strangerFillOnSpoke(attacker, keccak256(abi.encode("dust", i)), 1e6, TransferKind.Principal);
        }

        // 2. The send of the whole cap is filled; the real fill lists the id again and the report confirms it.
        (bytes32 id, uint256 depositId) = _sendToSpoke(CAP);
        assertEq(id, first, "the transit id was predictable");
        _fillOnSpoke(depositId);
        _reportAndDeliver(900);
        assertEq(uint8(core.transit(id).state), uint8(TransitState.ArrivalConfirmed), "S-13: confirmed");

        // 3. The cap holds: another send of the cap is refused.
        vm.prank(manager);
        vm.expectPartialRevert(ICoreVault.SpokeCapExceeded.selector);
        core.sendToSpoke(0, CAP, 0, "");
        assertEq(core.inFlightValue(), 0);
        assertApproxEqAbs(
            core.shareAssets(), assetsBefore - _ruleFee(CAP), 1e6, "only the bridge fee left (the dust is a gift)"
        );
    }

    function _hubTransitId(uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(HUB, address(core), nonce));
    }
}
