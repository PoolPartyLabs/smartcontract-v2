// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
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

/// @title Regression (security review S-11): dust sends home can no longer make `report()` exceed the block gas limit
/// @notice Was PoC `test_POC_dustSendsHomeBrickTheSpokeReportForGood` (high, access lens): `sendToHub` had no bound on
///         how many transfers could be listed at once, and `report()` walks and encodes the whole list, so 3,000 sends
///         of 2 base units made every report exceed the 32,000,000 gas a block allows on Arbitrum One and Robinhood
///         Chain, for good.
/// @notice FIX (S-11): `sendToHub` first recognizes landed refunds and drops entries past their retention, then
///         reverts `HubBoundInFlightLimit` once `SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT` sends are listed. The test
///         repeats the dust attack and asserts it now FAILS: the 65th send reverts and a report with a full list still
///         fits a tenth of a block.
contract ReportGasBrickPoC is AccessFundFixture {
    /// @dev Per-block and per-transaction gas limit of Arbitrum One and Robinhood Chain.
    uint256 internal constant BLOCK_GAS_LIMIT = 32_000_000;

    function test_SEC_S11_dustSendsHomeCanNoLongerBrickTheSpokeReport() public {
        FundFactory spokeFactory = _spokeFactory();
        bytes32 fundId = spokeFactory.fundIdOf(HUB, 1, manager);
        Mandate memory m = _buildMandate(spokeFactory, fundId, _plan());
        vm.prank(manager);
        IFundFactory.ChainAddresses memory c = spokeFactory.createSpoke(1, m, _spokeParams(MandateLib.hash(m), _plan()));
        SpokeVault spoke = SpokeVault(c.spokeVault);
        vm.etch(address(spokeWormhole), address(new LogOnlyWormholeCore()).code);

        bytes memory message = TransitMessage.encode(fundId, HUB, keccak256("hub transit 1"), TransferKind.Principal);
        usdg.mint(address(spoke), 500_000e6);
        vm.prank(address(spokeAcross));
        spoke.handleV3AcrossMessage(address(usdg), 500_000e6, stranger, message);

        // The manager tries 3,000 sends home of 2 base units each: the list stops at the bound.
        uint256 limit = SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT;
        vm.startPrank(manager);
        for (uint256 i; i < limit; ++i) {
            spoke.sendToHub(2, TransferKind.Principal, 0, _quote(2, address(0)));
        }
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.HubBoundInFlightLimit.selector, limit));
        spoke.sendToHub(2, TransferKind.Principal, 0, _quote(2, address(0)));
        vm.stopPrank();
        assertEq(spoke.inFlightTransitIds().length, limit, "S-11: bounded");

        // A report with the full list fits a tenth of a block, in flight and after the retention.
        vm.cool(address(spoke));
        spoke.report{gas: BLOCK_GAS_LIMIT / 10}();
        vm.warp(block.timestamp + 21_600 + ReportCodec.HUB_BOUND_RETENTION + 1);
        vm.cool(address(spoke));
        spoke.report{gas: BLOCK_GAS_LIMIT / 10}();
        assertEq(spoke.inFlightTransitIds().length, 0, "S-11: the list drains after the retention");
        assertEq(spoke.reportSequence(), 2);

        // The manager can send home again.
        vm.prank(manager);
        spoke.sendToHub(1000e6, TransferKind.Principal, 0, _quote(999e6, address(0)));
    }
}
