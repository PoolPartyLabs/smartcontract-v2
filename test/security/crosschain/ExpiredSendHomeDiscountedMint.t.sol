// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {BridgeQuote, TransferKind, TransitState} from "../../../src/interfaces/FundTypes.sol";
import {CrossChainFixture} from "./helpers/CrossChainFixture.sol";
import {SecAcrossSpokePool} from "./helpers/SecAcrossSpokePool.sol";

/// @title Regression (security review S-3): an expired transfer home stays in a value base until its refund, so
///        nobody mints at a discount
/// @notice Was PoC `test_POC_expiredSendHomeDiscountedMint` (high, cross-chain lens): `SpokeCrossChainLib._stillInFlight`
///         dropped an unfilled hub-bound transit at `fillDeadline + maxReportAge` ("presumed filled"), so from then
///         until its Across refund was recognized and reported the 400,000 USDG were in no base; Share Assets fell
///         40% and a 600,000 USDC entrant kept about 180,000 USDC of the earlier Shareholder's value.
///
/// Fix (S-3): the spoke lists a send home until its refund is recognized (the next report recognizes a landed refund
/// itself) or `ReportCodec.HUB_BOUND_RETENTION` after its deadline. The test replays the sequence and asserts the
/// attack now FAILS: Share Assets never drop, the entrant's shares are priced fairly and its round trip loses the fees.
/// The expiry is forced by simply never filling; the exclusivity lever of the original PoC is closed separately (S-9).
contract ExpiredSendHomeDiscountedMintPoC is CrossChainFixture {
    function _spokeCap() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function test_SEC_S3_expiredSendHomeNoLongerAllowsADiscountedMint() public {
        _deposit(alice, 1_000_000e6);
        (, uint256 outboundDeposit) = _sendToSpoke(500_000e6, 499_750e6);
        _fillOnSpoke(outboundDeposit);
        _reportAndDeliver(900);
        assertEq(core.shareAssets(), SEED_IDLE + 997_250e6);
        uint256 aliceShares = shares.balanceOf(alice);

        // 1. A transfer home that nobody fills.
        BridgeQuote memory quote = BridgeQuote({
            outputAmount: 399_800e6,
            quoteTimestamp: uint32(block.timestamp),
            exclusivityDeadline: 0,
            exclusiveRelayer: address(0)
        });
        (bytes32 homeTransit, uint256 homeDeposit) = _sendToHub(400_000e6, TransferKind.Principal, quote);
        _reportAndDeliver(900);
        assertEq(
            core.shareAssets(), SEED_IDLE + 997_050e6, "Idle 497,500 + spoke 99,750 + return leg 399,800 + the seed"
        );

        // 2. fillDeadline + maxReportAge passes: the spoke keeps listing the unrefunded transfer.
        vm.warp(uint256(spokePool.deposit(homeDeposit).fillDeadline) + MAX_REPORT_AGE + 1);
        _reportAndDeliver(900);
        assertEq(core.shareAssets(), SEED_IDLE + 997_050e6, "S-3: the 400,000 USDG are still counted in flight");

        // 3. A would-be attacker mints at the fair Share Price.
        (uint256 attackerShares,) = _deposit(attacker, 600_000e6);
        assertLt(attackerShares, aliceShares, "S-3: 600,000 USDC buy fewer shares than Alice's 1,000,000 USDC");

        // 4. The Across refund lands in the escrow; the next report recognizes it by itself.
        skip(45 minutes);
        vm.chainId(SPOKE);
        spokePool.refundExpired(homeDeposit);
        vm.chainId(HUB);
        _reportAndDeliver(900);
        vm.chainId(SPOKE);
        assertEq(
            uint8(spoke.hubBoundTransit(homeTransit).state),
            uint8(TransitState.RefundRecognized),
            "recognized by the report"
        );
        vm.chainId(HUB);

        // 5. The attacker exits with an Instant Payout, paying the 2% Payout Fee and the flow fee.
        uint256 attackerValue = attackerShares / 1e18 * core.sharePrice() / 1e18;
        vm.startPrank(attacker);
        core.requestPayout(attackerValue, ICoreVault.PayoutMode.Instant);
        core.claimPayout("");
        vm.stopPrank();
        assertLt(usdc.balanceOf(attacker), 600_000e6, "S-3: the round trip loses the fees, no profit");

        uint256 aliceValue = aliceShares / 1e18 * core.sharePrice() / 1e18;
        assertGe(aliceValue + 1e6, 997_050e6, "S-3: the earlier Shareholder paid no discount");
    }
}
