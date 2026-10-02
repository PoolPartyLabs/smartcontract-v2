// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {BridgeQuote, TransferKind, TransitState} from "../../../src/interfaces/FundTypes.sol";
import {CrossChainFixture} from "./helpers/CrossChainFixture.sol";

/// @title Regression (security review S-3): an expired transfer home keeps its place in the Spoke Cap's return leg
///        until its refund, so the manager cannot exceed the cap with it
/// @notice Was PoC `test_POC_expiredSendHomeReleasesTheSpokeCap` (medium, raised by the cross-chain verifier; same
///         root cause as S-3): after `fillDeadline + maxReportAge` the unfilled transfer counted neither as spoke value
///         nor as the return leg, so the manager sent the freed room to the spoke and the refund landed on top of it
///         (899,550 USDG against a 500,000 USDC cap).
///
/// Fix (S-3): the spoke lists the send until its refund is recognized or the retention passes, and a report recognizes
/// a landed refund itself. The test replays the sequence and asserts the attack now FAILS: the cap stays full through
/// the report lifetime and the second send reverts `SpokeCapExceeded`.
contract ExpiredSendHomeCapBypassPoC is CrossChainFixture {
    uint256 internal constant CAP = 500_000e6;

    function _spokeCap() internal pure override returns (uint256) {
        return CAP;
    }

    function test_SEC_S3_expiredSendHomeNoLongerReleasesTheSpokeCap() public {
        _deposit(alice, 1_000_000e6);
        (, uint256 outboundDeposit) = _sendToSpoke(CAP, 499_750e6);
        _fillOnSpoke(outboundDeposit);
        _reportAndDeliver(900);
        (uint256 spokeValue,, uint256 inFlightToHub, uint256 cap) = core.spokeCapUsage(0);
        assertEq(cap, CAP);
        assertEq(spokeValue, 499_750e6, "the cap is full");

        // 1. A transfer home that nobody fills.
        BridgeQuote memory quote = BridgeQuote({
            outputAmount: 399_800e6,
            quoteTimestamp: uint32(block.timestamp),
            exclusivityDeadline: 0,
            exclusiveRelayer: address(0)
        });
        (bytes32 homeTransit, uint256 homeDeposit) = _sendToHub(400_000e6, TransferKind.Principal, quote);
        uint32 deadline = spokePool.deposit(homeDeposit).fillDeadline;

        // 2. fillDeadline + maxReportAge passes: the return leg still holds the cap.
        vm.warp(uint256(deadline) + MAX_REPORT_AGE + 1);
        _reportAndDeliver(900);
        (spokeValue,, inFlightToHub,) = core.spokeCapUsage(0);
        assertEq(spokeValue + inFlightToHub, 499_550e6, "S-3: spoke 99,750 + return leg 399,800, still counted");

        // 3. The manager cannot send the transfer's room to the spoke.
        vm.prank(manager);
        vm.expectPartialRevert(ICoreVault.SpokeCapExceeded.selector);
        core.sendToSpoke(0, 400_000e6, 0, _quote(399_800e6));

        // 4. The refund lands; the next report recognizes it and the room is taken by the refunded principal.
        skip(45 minutes);
        vm.chainId(SPOKE);
        spokePool.refundExpired(homeDeposit);
        vm.chainId(HUB);
        _reportAndDeliver(900);
        vm.chainId(SPOKE);
        assertEq(uint8(spoke.hubBoundTransit(homeTransit).state), uint8(TransitState.RefundRecognized));
        vm.chainId(HUB);
        (spokeValue,, inFlightToHub, cap) = core.spokeCapUsage(0);
        assertEq(inFlightToHub, 0);
        assertLe(spokeValue, cap, "S-3: the Spoke Cap holds");
        assertEq(core.shareAssets(), SEED_IDLE + 997_500e6 - 250e6, "no loss beyond the one bridge fee");
    }
}
