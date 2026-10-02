// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockAcrossSpokePool as AcrossPoolStandIn} from "../../mocks/across/MockAcrossSpokePool.sol";
import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";

/// @title Regression (security review S-9, restated for DEC-158 / DEC-162): the manager cannot be its own exclusive
///        Across relayer, nor choose what a relayer keeps
/// @notice Was PoC `test_POC_managerSelfRelaysAtTheMaximumFeeRoundAfterRound` (high, access lens): the vaults passed
///         the quote's `exclusiveRelayer` and exclusivity window to Across untouched, so the manager named itself
///         exclusive relayer, filled its own deposits and kept the whole `maxBridgeFeeBps` bound on every leg (9.5% of
///         the fund in ten round trips).
/// @notice FIX (S-9, then DEC-158 / DEC-162): the manager passes no bridge parameter at all. The Across adapter fixes
///         every term of the deposit: no exclusive relayer, no exclusivity, the quote time, the deadline and the amount
///         to arrive by its fee rule (0.08% plus 0.03 on a first send). A quote in `bridgeData` is refused, so the
///         self-relay quote FAILS; whoever fills first keeps the rule's fee, never a gap the manager chose. The old S-9
///         residual (an over-quote up to the Mandate bound handed to the first relayer) is gone.
/// @notice REMAINING RESIDUAL (review round 1): the manager can still force expiries, with oversize sends above the
///         route's maximum or dust sends no relayer fills, and every noted expiry steps the rule one band up: about 7
///         rounds of about 7.4 h (about 2 days) reach the 1% cap (`test_DEC162_ratchetStopsAtTheCap`); the manager
///         then pre-fills its own sends at the cap, and with three parallel sends per round (each noted expiry steps
///         one send) the whole window, so the reference, sits at the cap. Without signed quotes nothing brings the
///         rate back down (`test_DEC162_withoutQuotesTheRateNeverFalls`), and the adapter is immutable per fund
///         (DEC-058), so a ratcheted route, or one raised by an Across outage (D-09), stays high for the fund's life.
///         Bounded by the cap per send (doc 12 §5: the band and the mean only delay the climb; the class DEC-129
///         accepts). Signed API quotes (WP-11, R-162-B) are the rule's only way down.
/// @dev Real Core Vault on the repository's unit fixture, with the real Across adapter over the SpokePool stand-in.
contract BridgeFeeChurnPoC is CoreVaultFixture {
    function test_SEC_S9_managerCanNoLongerSelfRelayExclusively() public {
        (, AcrossPoolStandIn acrossPool) = _deployWithAcross(100_000e6);
        uint256 sent = vault.freeIdle();
        uint256 ruleFee = (sent * 8e14 + 1e18 - 1) / 1e18 + 30_000;

        // The self-relay quote (the manager exclusive for the whole window, half a percent kept) is refused.
        vm.prank(manager);
        vm.expectRevert(AcrossBridgeAdapter.QuotesNotSupported.selector);
        vault.sendToSpoke(0, sent, 0, abi.encode(sent - sent * 50 / 10_000, uint32(21_600), manager));

        // The only send there is carries the adapter's terms: no relayer, no exclusivity, the rule's amount.
        vm.expectCall(address(acrossPool), _expectedDeposit(sent, sent - ruleFee));
        vm.prank(manager);
        vault.sendToSpoke(0, sent, 0, "");
        assertEq(vault.freeIdle(), 0);
        assertEq(vault.inFlightValue(), sent - ruleFee);
    }

    /// @dev The exact `depositV3` call the vault's first send makes: transit id and escrow clone are predictable.
    function _expectedDeposit(uint256 sent, uint256 arrives) internal view returns (bytes memory) {
        bytes32 id = keccak256(abi.encode(block.chainid, address(vault), uint256(1)));
        address escrow = vm.computeCreateAddress(address(vault), vm.getNonce(address(vault)));
        return abi.encodeCall(
            IAcrossSpokePool.depositV3,
            (
                escrow,
                spokeVaultAddress,
                address(usdc),
                address(usdg),
                sent,
                arrives,
                SPOKE,
                address(0),
                uint32(block.timestamp),
                uint32(block.timestamp) + 21_600,
                0,
                TransitMessage.encode(FUND_ID, HUB, id, TransferKind.Principal)
            )
        );
    }
}
