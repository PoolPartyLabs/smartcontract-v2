// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title Regression (security review S-3): an expired send home stays in a value base until its refund; a new
///        entrant can no longer take the refund from the shareholders
/// @notice Was PoC `test_POC_expiredSendHomeLeavesEveryBaseAndANewEntrantCapturesTheRefund` (high, access lens): the
///         Spoke Vault presumed a send home filled at `fillDeadline + maxReportAge` and dropped it from
///         `inFlightToHub` while the Across refund was still 30 minutes away, so Share Assets fell by the whole transfer
///         and a 1,000,000 USDC deposit captured about 249,000 of a 299,000 USDC refund.
/// @notice FIX (S-3): the send stays listed until its refund is recognized or `ReportCodec.HUB_BOUND_RETENTION` after
///         its deadline (the hub already nets out what it credited). The test replays the sequence and asserts it now
///         FAILS: Share Assets never drop, the entrant pays the fair price and cannot cash out above its deposit.
contract ExpiredSendHomeMintPoC is AccessFundFixture {
    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant FILL_WINDOW = 21_600;

    /// @dev What the spoke chain produced, carried across the chain switch in memory.
    struct SpokeSide {
        address spokeVault;
        bytes reportAfterArrival;
        bytes reportWhileInFlight;
        bytes reportAfterPresumedFill;
        bytes reportAfterRefund;
        uint256 presumedFilledAt;
        uint256 refundedAt;
    }

    function test_SEC_S3_expiredSendHomeStaysInABaseAndANewEntrantTakesNothing() public {
        // ---------------------------------------------------------------- Spoke Chain (its own state, run first)
        SpokeSide memory s = _spokeSide();

        // ---------------------------------------------------------------- Hub Chain
        _hubFactory();
        (IFundFactory.FundAddresses memory a,) = _createFund(_plan());
        CoreVault core = CoreVault(a.coreVault);
        _deposit(core, alice, 500_000e6);
        vm.prank(manager);
        core.sendToSpoke(0, 300_000e6, 0, _quote(299_700e6, address(0)));

        vm.warp(T0 + 900);
        _deliverReport(a.valueReportReceiver, s.spokeVault, 0, s.reportAfterArrival);
        _deliverReport(a.valueReportReceiver, s.spokeVault, 1, s.reportWhileInFlight);
        uint256 fairAssets = core.shareAssets();
        assertEq(fairAssets, 198_750e6 + 690e6 + 298_999e6, "Idle + spoke + the send home in flight");
        uint256 fairPrice = core.sharePrice();
        uint256 aliceFair = _shares(core, alice) * fairPrice / 1e36;

        // The send home expired unfilled; past the report lifetime the spoke still lists it.
        vm.warp(s.presumedFilledAt + 900);
        prices.setPrice(address(usdg), 1e18);
        vm.prank(stranger);
        _deliverReport(a.valueReportReceiver, s.spokeVault, 2, s.reportAfterPresumedFill);
        assertEq(core.shareAssets(), fairAssets, "S-3: the transfer is still counted in flight");

        // The would-be attacker enters at the fair price.
        uint256 attackerShares = _deposit(core, stranger, 1_000_000e6);
        assertLt(attackerShares, 1_000_000e18, "S-3: no discount");

        // The Across refund lands and is recognized; the next report says so.
        vm.warp(s.refundedAt + 900);
        prices.setPrice(address(usdg), 1e18);
        _deliverReport(a.valueReportReceiver, s.spokeVault, 3, s.reportAfterRefund);

        uint256 price = core.sharePrice();
        assertGe(_shares(core, alice) * price / 1e36 + 1e6, aliceFair, "S-3: Alice's shares kept their value");

        uint256 before = _balance(usdc, stranger);
        vm.startPrank(stranger);
        core.requestPayout(attackerShares * price / 1e36, ICoreVault.PayoutMode.Instant);
        core.claimPayout("");
        vm.stopPrank();
        assertLt(_balance(usdc, stranger) - before, 1_000_000e6, "S-3: the entrant cashes out less than it put in");
    }

    /// @dev The spoke's half: the hub's send arrives; the manager sends 299,000 USDG home with a quote nobody fills;
    ///      the vault still lists it after `fillDeadline + maxReportAge`; the Across refund reaches the escrow 55
    ///      minutes after the deadline and is recognized. One report after each step.
    function _spokeSide() internal returns (SpokeSide memory s) {
        FundFactory spokeFactory = _spokeFactory();
        bytes32 fundId = spokeFactory.fundIdOf(HUB, 1, manager);
        Mandate memory m = _buildMandate(spokeFactory, fundId, _plan());
        vm.prank(manager);
        IFundFactory.ChainAddresses memory c = spokeFactory.createSpoke(1, m, _spokeParams(MandateLib.hash(m), _plan()));
        SpokeVault spoke = SpokeVault(c.spokeVault);
        s.spokeVault = c.spokeVault;

        bytes32 hubTransitId = keccak256(abi.encode(HUB, spokeFactory.addressOf(fundId, "CoreVault", HUB), uint256(1)));
        bytes memory message = TransitMessage.encode(fundId, HUB, hubTransitId, TransferKind.Principal);
        usdg.mint(address(spoke), 299_700e6);
        vm.prank(address(spokeAcross));
        spoke.handleV3AcrossMessage(address(usdg), 299_700e6, stranger, message);
        spoke.report();
        s.reportAfterArrival = spokeWormhole.published(0).payload;

        vm.prank(manager);
        bytes32 homeTransitId = spoke.sendToHub(299_000e6, TransferKind.Principal, 0, _quote(298_999e6, address(0)));
        spoke.report();
        s.reportWhileInFlight = spokeWormhole.published(1).payload;

        // Nobody fills. Past the deadline plus the report lifetime the vault still lists it (security review S-3).
        vm.warp(T0 + FILL_WINDOW + MAX_REPORT_AGE + 1);
        spoke.report();
        s.reportAfterPresumedFill = spokeWormhole.published(2).payload;
        s.presumedFilledAt = block.timestamp;
        assertEq(spoke.buildReport().inFlightToHub.length, 1);
        assertEq(spoke.unallocatedBalance(address(usdg)), 690e6);

        // Across refunds the depositor of record (the escrow) 55 minutes after the deadline; anyone recognizes it.
        vm.warp(T0 + FILL_WINDOW + 55 minutes);
        usdg.mint(spoke.hubBoundTransit(homeTransitId).escrow, 299_000e6);
        vm.prank(stranger);
        spoke.recognizeRefund(homeTransitId);
        spoke.report();
        s.reportAfterRefund = spokeWormhole.published(3).payload;
        s.refundedAt = block.timestamp;
        assertEq(spoke.unallocatedBalance(address(usdg)), 299_690e6);
    }
}
