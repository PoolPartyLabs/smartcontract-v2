// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
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
///         Mandate reports another `mandateHash`, which the hub rejects (S-6). Since Mandate v2 (DEC-123 level 1,
///         WP-07 B3) the hub refuses the fund itself: every Mandate token of every chain, the spoke's base token
///         included, must have a price from the protocol's price source when the Core Vault is created. The
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
        // DEC-123 level 1: the price source has no price for the worthless token, so the fund is never created.
        _hubFactory();
        Mandate memory hubMandate = _buildMandate(factory, factory.fundIdOf(HUB, 1, manager), plan);
        IFundFactory.HubParams memory p = _hubParams(1, plan, _coreVaultCreationCode(hubDeployment));
        _fundManagerSeed(address(usdc), manager, address(factory), p.seedAmount);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.TokenNotPriced.selector, SPOKE, address(worthless)));
        factory.createFund(hubMandate, p);
    }
}
