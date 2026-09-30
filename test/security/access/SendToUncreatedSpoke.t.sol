// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {Transit, TransitState} from "../../../src/interfaces/FundTypes.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title PoC: `sendToSpoke` works before the fund's Spoke Vault exists; the principal is lost to the fund and stays
///        in Share Assets for good
/// @notice TRIGGER. `createFund` (hub) and `createSpoke` (spoke) are two transactions on two chains and nothing on the
///         hub knows whether the second one ever ran: `CoreVaultLogic.sendToSpoke` (CoreVaultLogic.sol:576) needs no
///         accepted report from the spoke. A manager who sends before creating the spoke (a mistake in the documented
///         two-step flow, docs/DEPLOYMENT.md, or a spoke that can never be created, see
///         `test_DEC087_verify_hubMandateMayNameASpokeThatCanNeverBeCreated`) bridges principal to an address without
///         code. Across delivers the token and skips the message handler for a recipient without code, so the fill
///         succeeds and no refund will ever come.
/// @notice IMPACT. Hub: the transit is never listed by a report, so it can only be attested expired (deadline plus
///         report lifetime); `recognizeRefund` reverts `NoRefund` for ever, and under the QB11 stance the amount stays
///         in In-flight Value and in Share Assets for good (DEC-104 broken: value that left the fund keeps backing
///         shares). Whoever exits first is paid at the overstated Share Price out of the real USDC, and whoever
///         enters next pays it. Spoke: once the Spoke Vault is created at that address the tokens are above its
///         ledger, and anyone sweeps them to the protocol's fee wallet (`sweepExcess`).
/// @notice FIX. `sendToSpoke` requires `IValueReportReceiver.hasReport(spokeIndex)`: a first accepted report proves
///         the Spoke Vault exists at the Mandate's address with the fund's code (and, with the Mandate hash in the
///         report, with the hub's rules; see RogueSpokeMandate.t.sol). Optionally let a transit that stayed
///         `ExpiryAttested` longer than a bound be written off explicitly instead of backing shares indefinitely.
contract SendToUncreatedSpokePoC is AccessFundFixture {
    function test_POC_hubSendsPrincipalToASpokeThatWasNeverCreated() public {
        (IFundFactory.FundAddresses memory a,) = _createFund(_plan());
        CoreVault core = CoreVault(a.coreVault);
        _deposit(core, alice, 500_000e6);
        assertEq(core.idle(), 498_750e6);
        assertFalse(ValueReportReceiver(a.valueReportReceiver).hasReport(0), "no report: no evidence of a spoke");

        // The manager sends 300,000 USDC to the spoke. Nothing stops it.
        vm.prank(manager);
        bytes32 transitId = core.sendToSpoke(0, 300_000e6, 0, _quote(299_700e6, address(0)));
        assertEq(core.idle(), 198_750e6);

        // A relayer fills it on the spoke: plain token transfer to an address without code (see the next test).
        // On the hub nothing reports the arrival. After the deadline plus the report lifetime anyone attests expiry.
        vm.warp(block.timestamp + 21_600 + MAX_REPORT_AGE + 1);
        prices.setPrice(address(usdg), 1e18);
        core.attestExpiry(transitId);
        Transit memory t = core.transit(transitId);
        assertEq(uint8(t.state), uint8(TransitState.ExpiryAttested));

        // No refund ever reaches the escrow (the deposit was filled), so this is the final state.
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NoRefund.selector, transitId));
        core.recognizeRefund(transitId);
        assertEq(core.inFlightValue(), 299_700e6, "the lost principal is In-flight Value for good");
        assertEq(core.shareAssets(), 198_750e6 + 299_700e6, "and backs shares although only Idle is real");

        // Bob enters at about 1.00 USDC per share; the USDC really behind each share is about 0.40.
        uint256 bobShares = _deposit(core, bob, 200_000e6);
        assertApproxEqRel(bobShares, 199_500e18, 0.01e18);

        // Alice leaves first, paid in real USDC at the overstated price.
        vm.startPrank(alice);
        core.requestPayout(390_000e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory r = core.claimPayout("");
        vm.stopPrank();
        assertEq(r.usdcOutstanding, 0);
        assertApproxEqRel(r.sharePrice, 1e24, 0.01e18);

        // Bob's shares are now backed by under 10,000 USDC of Idle and a transit that will never arrive.
        assertLt(core.idle(), 10_000e6);
        assertEq(core.inFlightValue(), 299_700e6);
        assertEq(_shares(core, bob), bobShares);
    }

    function test_POC_aFillToTheUncreatedSpokeVaultIsSweptToTheProtocolRecipient() public {
        FundFactory spokeFactory = _spokeFactory();
        bytes32 fundId = spokeFactory.fundIdOf(HUB, 1, manager);
        address predicted = spokeFactory.addressOf(fundId, "SpokeVault", SPOKE);
        assertEq(predicted.code.length, 0);

        // The relayer's fill of the hub's send: Across transfers the output token and, because the recipient has no
        // code, calls no handler.
        usdg.mint(predicted, 299_700e6);

        // The manager creates the spoke afterwards, from the hub's Mandate.
        Mandate memory m = _buildMandate(spokeFactory, fundId, _plan());
        vm.prank(manager);
        IFundFactory.ChainAddresses memory c = spokeFactory.createSpoke(1, m, _spokeParams(MandateLib.hash(m), _plan()));
        SpokeVault spoke = SpokeVault(c.spokeVault);
        assertEq(address(spoke), predicted);

        // The fund's principal is outside the ledger: never Unallocated Balance, never reported to the hub...
        assertEq(spoke.unallocatedBalance(address(usdg)), 0);
        assertEq(spoke.cumulativeReceived(), 0);
        assertEq(spoke.buildReport().arrivedTransits.length, 0);
        // ...and anyone sends it to the protocol's fee wallet.
        vm.prank(stranger);
        assertEq(spoke.sweepExcess(address(usdg)), 299_700e6);
        assertEq(_balance(usdg, recipient), 299_700e6);
        assertEq(_balance(usdg, address(spoke)), 0);
    }
}
