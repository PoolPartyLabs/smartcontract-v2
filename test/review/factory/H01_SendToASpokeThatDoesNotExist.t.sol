// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {TransitState} from "../../../src/interfaces/FundTypes.sol";
import {Mandate} from "../../../src/mandate/Mandate.sol";
import {FactoryReviewFixture} from "./FactoryReviewFixture.sol";

/// @notice Review port of factory H01, consolidated finding H-05 (register S-14). On `e5c778a` nothing on the hub
///         required the destination Spoke Vault to exist before `sendToSpoke`: a send filled before `createSpoke` went
///         to an address without code (the live SpokePool skips the callback), was swept to the Protocol Recipient
///         once the vault existed, and stayed in Share Assets as In-flight Value for good (a holder left with 97,358
///         USDC against 49,750 of real assets). Since S-14 `sendToSpoke` reverts `SpokeNotReporting` until the fund's
///         receiver accepted a report from that spoke, and an accepted report proves the vault exists at the Mandate
///         address (Wormhole attests the emitter) and, with S-6, runs the hub's Mandate.
/// @dev The review's scenario is NOT_CONSTRUCTIBLE on main: its first step, the send before `createSpoke`, reverts.
contract H01_SendToASpokeThatDoesNotExist is FactoryReviewFixture {
    uint256 internal constant DEPOSIT = 100_000e6;
    uint256 internal constant SEND = 50_000e6;
    uint256 internal constant ARRIVES = 49_975e6; // 5 bps route fee, inside the 50 bps Mandate maximum

    struct Ctx {
        IFundFactory.FundAddresses a;
        address named;
        uint256 hubState;
        bytes payload;
        uint64 seq;
        uint256 reportAt;
    }

    function _arbitrumCreateAndDeposit(Ctx memory c) internal returns (CoreVault vault) {
        Deployment memory d = _hubChain();
        _refreshPrices();
        Mandate memory m;
        (c.a, m) = _createFund(d, _plan());
        vault = CoreVault(c.a.coreVault);
        c.named = address(uint160(uint256(m.spokes[0].spokeVault)));
        _deposit(vault, alice, DEPOSIT); // 99,750 USDC to Idle, 99,750 shares (25 bps flow fee)
    }

    /// @dev The review's step 3: the send before `createSpoke` is refused, nothing leaves Idle.
    function test_REVIEW_H05_sendBeforeTheSpokeExistsReverts() public {
        Ctx memory c;
        CoreVault vault = _arbitrumCreateAndDeposit(c);
        assertEq(c.named.code.length, 0, "createSpoke has not run");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeNotReporting.selector, 0));
        vault.sendToSpoke(0, SEND, 0, _quote(ARRIVES));
        assertEq(vault.idle(), SEED_IDLE + 99_750e6);
        assertEq(vault.inFlightValue(), 0);
        assertEq(vault.shareAssets(), SEED_IDLE + 99_750e6);
    }

    /// @dev Re-attack: a VAA naming the Mandate's spoke address from another Wormhole chain (where an address without
    ///      the fund's code could emit) is an unknown emitter, so it cannot open the gate either.
    function test_REVIEW_H05_aReportFromAnotherEmitterChainCannotOpenTheGate() public {
        Ctx memory c;
        CoreVault vault = _arbitrumCreateAndDeposit(c);
        c.hubState = vm.snapshotState();

        // A genuine spoke payload exists only once the spoke exists; build one on the spoke chain.
        FundFactory spokeFactory = _spokeChain();
        vm.warp(T0 + 5 minutes);
        (SpokeVault spoke,) = _createSpoke(spokeFactory, c.a.creationNumber, _plan());
        c.reportAt = block.timestamp;
        (c.payload, c.seq) = _publish(spoke);

        _enterHub(c.hubState, c.reportAt + FINALITY);
        ValueReportReceiver receiver = ValueReportReceiver(c.a.valueReportReceiver);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IValueReportReceiver.UnknownEmitter.selector, 23, bytes32(uint256(uint160(c.named))))
        );
        receiver.deliver(_vaaFrom(23, c.named, c.payload, c.seq));
        assertFalse(receiver.hasReport(0));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeNotReporting.selector, 0));
        vault.sendToSpoke(0, SEND, 0, _quote(ARRIVES));
    }

    /// @dev The runbook order: `createSpoke`, `report()`, delivery on the hub, then the first send. The send goes to a
    ///      vault that exists, so the live pool calls its handler and the arrival is credited.
    function test_REVIEW_H05_firstSendFollowsTheSpokesFirstAcceptedReport() public {
        Ctx memory c;
        CoreVault vault = _arbitrumCreateAndDeposit(c);
        c.hubState = vm.snapshotState();

        FundFactory spokeFactory = _spokeChain();
        vm.warp(T0 + 5 minutes);
        (SpokeVault spoke,) = _createSpoke(spokeFactory, c.a.creationNumber, _plan());
        assertEq(address(spoke), c.named);
        c.reportAt = block.timestamp;
        (c.payload, c.seq) = _publish(spoke);

        _enterHub(c.hubState, c.reportAt + FINALITY);
        _deliver(ValueReportReceiver(c.a.valueReportReceiver), _vaa(c.named, c.payload, c.seq));
        vm.prank(manager);
        bytes32 id = vault.sendToSpoke(0, SEND, 0, _quote(ARRIVES));
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.Sent));
        assertEq(vault.inFlightValue(), ARRIVES);
        assertEq(vault.shareAssets(), SEED_IDLE + 99_750e6 - (SEND - ARRIVES));
    }
}
