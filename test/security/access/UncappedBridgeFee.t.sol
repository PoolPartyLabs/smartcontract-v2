// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title Regression (security review S-9): a Mandate can no longer authorize a one-send drain of Free Idle through
///        the bridge fee
/// @notice Was PoC `test_POC_mandateWithAHundredPercentBridgeFeeDrainsFreeIdleInOneSend` (medium, raised by the access
///         verifier): `MandateLib.validate` capped `maxBridgeFeeBps` only at 100%, so a fund created with 10,000 bps
///         let one `sendToSpoke` deliver 1 base unit of USDG for all Free Idle, the manager relaying exclusively.
/// @notice FIX (S-9): `MandateLib.MAX_BRIDGE_FEE_BPS` (1%) caps the Mandate value, and both vaults reject a quote that
///         names an exclusive relayer or an exclusivity period. The test asserts the attack now FAILS at every step.
contract UncappedBridgeFeePoC is AccessFundFixture {
    function test_SEC_S9_mandateCanNoLongerAuthorizeADrainThroughTheBridgeFee() public {
        // The 100% Mandate is refused at creation.
        FundPlan memory plan = _plan();
        plan.maxBridgeFeeBps = 10_000;
        Mandate memory m = _buildMandate(factory, factory.fundIdOf(HUB, 1, plan.manager), plan);
        IFundFactory.HubParams memory params = _hubParams(1, plan, _coreVaultCreationCode(hubDeployment.coreVaultLogic));
        vm.prank(plan.manager);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.BpsAboveMax.selector, 10_000, MandateLib.MAX_BRIDGE_FEE_BPS));
        factory.createFund(m, params);

        // At the cap, one base unit for all Free Idle is refused, and so is the manager as exclusive relayer.
        plan.maxBridgeFeeBps = MandateLib.MAX_BRIDGE_FEE_BPS;
        (IFundFactory.FundAddresses memory a,) = _createFund(plan);
        CoreVault core = CoreVault(a.coreVault);
        _deposit(core, alice, 600_000e6);
        uint256 idle = core.idle();
        vm.prank(manager);
        vm.expectPartialRevert(ICoreVault.BridgeFeeAboveMax.selector);
        core.sendToSpoke(0, idle, 0, _quote(1, address(0)));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ExclusiveRelayerNotAllowed.selector, manager));
        core.sendToSpoke(0, idle, 0, _quote(idle - idle / 100, manager));
        assertEq(core.idle(), idle, "S-9: nothing left the Core Vault");
    }
}
