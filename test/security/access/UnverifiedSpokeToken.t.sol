// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title Regression (security review S-7, closed by S-14 and S-6): a Mandate naming a worthless spoke token can no
///        longer bridge Idle into it
/// @notice Was PoC `test_POC_managerBridgesIdleIntoAWorthlessSpokeToken` (high, access lens): `createFund` never
///         checked a spoke's `spokeToken`, the Core Vault used it as the Across output token, and the manager bridged
///         all Free Idle into a token it minted, relaying the fill and collecting the USDC.
/// @notice FIX. `sendToSpoke` now requires an accepted report from the spoke (S-14). The only emitter the hub accepts
///         is the fund's predicted Spoke Vault, which only `createSpoke` can deploy, and `createSpoke` refuses a spoke
///         token that is not the spoke chain's base token (`BaseTokenMismatch`); a Spoke Vault created from any other
///         Mandate reports another `mandateHash`, which the hub rejects (S-6). So a fund whose Mandate names a
///         worthless token can never fund that spoke: the test asserts the send now FAILS and Idle stays. The
///         protocol-level supported-chain registry of DEC-089 remains the complete fix (docs/security/KNOWN-LIMITATIONS.md).
contract UnverifiedSpokeTokenPoC is AccessFundFixture {
    function test_SEC_S7_hubCanNoLongerBridgeIdleIntoAWorthlessSpokeToken() public {
        MockToken worthless = new MockToken("USDG", 6);
        FundPlan memory plan = _plan();
        plan.spokeToken = address(worthless);

        // ---------------------------------------------------------------- Spoke Chain (its own state, run first)
        // The spoke of that Mandate can never be created: the spoke factory refuses a token that is not USDG.
        FundFactory spokeFactory = _spokeFactory();
        Mandate memory m = _buildMandate(spokeFactory, spokeFactory.fundIdOf(HUB, 1, manager), plan);
        IFundFactory.SpokeParams memory params = _spokeParams(MandateLib.hash(m), plan);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(IFundFactory.BaseTokenMismatch.selector, address(worthless), address(usdg))
        );
        spokeFactory.createSpoke(1, m, params);

        // ---------------------------------------------------------------- Hub Chain
        // So no report can ever be accepted and the hub never funds the spoke.
        _hubFactory();
        (IFundFactory.FundAddresses memory a,) = _createFund(plan);
        CoreVault core = CoreVault(a.coreVault);
        _deposit(core, alice, 600_000e6);
        _deposit(core, bob, 400_000e6);
        uint256 idle = core.idle();
        uint256 output = idle - idle * 50 / 10_000;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeNotReporting.selector, 0));
        core.sendToSpoke(0, idle, 0, _quote(output, address(0)));
        assertEq(core.idle(), idle, "S-7: Idle stays in the Core Vault");
        assertEq(core.inFlightValue(), 0);
    }
}
