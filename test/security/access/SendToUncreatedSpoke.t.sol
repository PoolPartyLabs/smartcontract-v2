// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title Regression (security review S-14): `sendToSpoke` no longer funds a spoke whose Spoke Vault never reported
/// @notice Was PoC `test_POC_hubSendsPrincipalToASpokeThatWasNeverCreated` (medium, access lens): nothing on the hub
///         knew whether `createSpoke` had run, so the hub could bridge principal to an address without code; Across
///         delivers the token and skips the handler, no refund ever comes, and the amount stayed in In-flight Value
///         and Share Assets for good while only Idle was real.
/// @notice FIX (S-14): `sendToSpoke` reverts `SpokeNotReporting` until the fund's ValueReportReceiver accepted a report
///         from that spoke, which proves the Spoke Vault exists at the Mandate's address with the fund's code (and,
///         with S-6, runs the hub's Mandate). The first test asserts the send now FAILS; the second shows what a stray
///         fill to an uncreated Spoke Vault becomes (swept excess, DEC-101), which no hub send can cause any more.
contract SendToUncreatedSpokePoC is AccessFundFixture {
    function test_SEC_S14_hubCanNoLongerSendToASpokeThatNeverReported() public {
        (IFundFactory.FundAddresses memory a,) = _createFund(_plan());
        CoreVault core = CoreVault(a.coreVault);
        _deposit(core, alice, 500_000e6);
        assertEq(core.idle(), 498_750e6);
        assertFalse(ValueReportReceiver(a.valueReportReceiver).hasReport(0), "no report: no evidence of a spoke");

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeNotReporting.selector, 0));
        core.sendToSpoke(0, 300_000e6, 0, _quote(299_700e6, address(0)));
        assertEq(core.idle(), 498_750e6, "S-14: nothing left the Core Vault");
        assertEq(core.inFlightValue(), 0, "S-14: nothing in flight to a spoke that does not exist");

        // Once the spoke has reported, the same send goes through.
        _deliverFirstReport(a);
        vm.prank(manager);
        core.sendToSpoke(0, 300_000e6, 0, _quote(299_700e6, address(0)));
        assertEq(core.idle(), 198_750e6);
    }

    function test_SEC_S14_aStrayFillToAnUncreatedSpokeVaultIsSweptExcess() public {
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
