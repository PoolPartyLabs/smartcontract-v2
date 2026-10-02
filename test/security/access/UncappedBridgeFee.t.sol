// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title Regression (security review S-9): a Mandate can no longer authorize a one-send drain of Free Idle through
///        the bridge fee
/// @notice Was PoC `test_POC_mandateWithAHundredPercentBridgeFeeDrainsFreeIdleInOneSend` (medium, raised by the access
///         verifier): `MandateLib.validate` capped `maxBridgeFeeBps` only at 100%, so a fund created with 10,000 bps
///         let one `sendToSpoke` deliver 1 base unit of USDG for all Free Idle, the manager relaying exclusively.
/// @notice FIX (S-9, then DEC-156 and DEC-162 with Mandate v2): the Mandate no longer carries a bridge fee bound; the
///         Across adapter fixes the amount to arrive from its own rule, capped at 1% (`AcrossBridgeAdapter.CAP_RATE`),
///         and both vaults reject a quote that names an exclusive relayer or an exclusivity period. The test asserts
///         the attack now FAILS at every step.
contract UncappedBridgeFeePoC is AccessFundFixture {
    function test_SEC_S9_mandateCanNoLongerAuthorizeADrainThroughTheBridgeFee() public {
        // The manager can no longer price a send at all (DEC-158, DEC-162): a quote of one base unit, or with the
        // manager as exclusive relayer, is refused by the Across adapter, and the send of all Free Idle delivers the
        // adapter's amount (0.08% plus 0.03); no Mandate value can widen it (DEC-156).
        FundPlan memory plan = _plan();
        (IFundFactory.FundAddresses memory a,) = _createFund(plan);
        CoreVault core = CoreVault(a.coreVault);
        _deposit(core, alice, 600_000e6);
        _deliverFirstReport(a); // S-14: the spoke has reported once before the hub funds it
        uint256 idle = core.idle();
        vm.prank(manager);
        vm.expectRevert(AcrossBridgeAdapter.QuotesNotSupported.selector);
        core.sendToSpoke(0, idle, 0, abi.encode(uint256(1), manager, uint32(3600)));
        assertEq(core.idle(), idle, "nothing left the Core Vault");
        vm.prank(manager);
        bytes32 id = core.sendToSpoke(0, idle, 0, "");
        assertEq(core.transit(id).amountToArrive, idle - _ruleFee(idle), "the adapter's amount, never one base unit");
    }
}
