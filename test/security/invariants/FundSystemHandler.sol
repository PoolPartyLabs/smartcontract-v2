// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoreBridgeVM, GuardianSignature} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {IncomeAccumulator} from "../../../src/libraries/IncomeAccumulator.sol";
import {MandateLib} from "../../../src/mandate/Mandate.sol";
import {CoreMockToken} from "../../mocks/core/CoreMockTokens.sol";
import {MockAcrossSpokePool} from "../../mocks/core/MockAcrossSpokePool.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {MockBridgeNextArrive} from "../../mocks/across/MockBridgeNextArrive.sol";
import {FundSystem} from "./FundSystemFixture.sol";

/// @title Handler of the whole-fund invariant suites
/// @notice Drives one fund (test/security/invariants/FundSystemFixture.sol) through deposits, payouts, allocations,
///         positions, income, sends in both directions, Across fills and refunds, value reports, refund recognition,
///         donations and sweeps, with four shareholders, the manager and a stranger who donates, bridges to the
///         vaults with forged messages and calls every permissionless verb. It keeps the ghost state the invariants
///         compare the contracts against.
/// @dev `fail_on_revert` is on: calls that may legitimately revert are wrapped in try/catch, and every check the
///      handler makes inside an action is a hard assertion, so a violated per-action property fails the campaign with
///      its call sequence.
/// @dev Two switches state the liveness assumptions the value invariants need (docs/security/reports/
///      dynamic-analysis.md). With a switch off the handler leaves the corresponding window open and the invariants
///      are expected to fail; test/security/invariants/FundSystemPoC.t.sol shows each window as a scripted scenario.
///      - `listSendsHomeAtOnce`: every send home is followed at once by a delivered report that lists it, so the hub
///        knows the transfer before it arrives or expires.
///      - `recognizeRefundsBeforeReports`: an expired send home is refunded and its refund recognized on the spoke
///        before the next report is built. Since the security review's S-3 fix the report itself recognizes a landed
///        refund and keeps an unrefunded send listed for `ReportCodec.HUB_BOUND_RETENTION`, so the value invariants
///        also hold with this switch off (`SEC_LATE_REFUNDS=true`) as long as Across refunds within that retention.
contract FundSystemHandler is Test {
    uint256 internal constant HUB = 42_161;
    uint256 internal constant SPOKE = 4663;
    uint16 internal constant WH_SPOKE = 72;
    uint256 internal constant MAX_BRIDGE_FEE_BPS = 50;

    /// @dev The spoke's mock bridge adapter (the amount to arrive of a send home is set on it).
    address internal _spokeBridge;
    uint256 internal constant MAX_POSITIONS = 3;
    bytes32 internal constant HUB_POOL = keccak256("hub WETH/USDC");
    bytes32 internal constant AAVE_USDC = keccak256("aave USDC");
    bytes32 internal constant SPOKE_POOL = keccak256("spoke WETH/USDG");

    /// @dev Outcome of an Across deposit as the handler (relayer and refund) decided it.
    uint8 internal constant PENDING = 0;
    uint8 internal constant FILLED = 1;
    uint8 internal constant REFUNDED = 2;

    /// @notice A hub-to-spoke send and what really happened to it.
    struct HubSend {
        bytes32 id;
        uint256 depositIndex;
        uint256 amountSent;
        uint256 amountToArrive;
        uint32 deadline;
        uint8 outcome;
        uint256 strangerListed;
        uint256 escrowDonated;
        bool recognized;
        TransitState lastState;
    }

    /// @notice A spoke-to-hub send and what really happened to it.
    struct HomeSend {
        bytes32 id;
        uint256 depositIndex;
        uint256 amountSent;
        uint256 amountToArrive;
        uint32 deadline;
        TransferKind kind;
        uint8 outcome;
        bool recognized;
        uint256 escrowDonated;
    }

    FundSystem internal s;
    bytes32 internal fundId;
    bool public listSendsHomeAtOnce;
    bool public recognizeRefundsBeforeReports;

    address[] internal _actors;
    address internal stranger = makeAddr("stranger");

    HubSend[] internal _hubSends;
    HomeSend[] internal _homeSends;
    uint256 internal _fakeIds;
    uint256 internal _delivered;

    // ---- ghost state ----

    /// @notice USDC each shareholder paid for deposits (flow fee included) and received from payouts.
    mapping(address => uint256) public paidIn;
    mapping(address => uint256) public paidOut;
    /// @notice Deposits, payouts and refunds executed so far; each can shift under two USDC base units of rounding.
    uint256 public valueOps;
    /// @notice Bridge fees the fund got back through recognized refunds: a holder who entered between the send and
    ///         the refund legitimately gains a part of it.
    uint256 public refundedBridgeFees;
    /// @notice Each shareholder's part of the Payout Fees of executed Instant Payouts: a fee stays in Idle (DEC-144),
    ///         so the holders who stay legitimately gain it, pro rata to their shares after the leaver's burn.
    mapping(address => uint256) public payoutFeeGain;
    /// @notice Principal that entered the fund's ledgers from outside: what deposits bought, plus Principal a
    ///         stranger bridged to the Spoke Vault.
    uint256 public principalIn;
    /// @notice Principal that left the fund's ledgers: payouts (gross less the Payout Fee, which stays in Idle,
    ///         DEC-144) and the bridge fee of every filled Principal transfer.
    uint256 public principalOut;
    /// @notice Principal strangers bridged to the Spoke Vault (value of unknown origin, DEC-080).
    uint256 public strangerSpokePrincipal;
    /// @notice Income strangers bridged to the Spoke Vault.
    uint256 public strangerSpokeIncome;
    /// @notice What strangers bridged to the Core Vault with ids no report ever lists.
    uint256 public strangerHubArrivals;
    /// @notice Principal arrivals the handler delivered to the Spoke Vault (real fills and strangers).
    uint256 public spokePrincipalArrivals;
    /// @notice USDC moved between Idle and the hub Spoke Vault.
    uint256 public allocatedToHubVault;
    uint256 public returnedFromHubVault;
    /// @notice Collected income that reached the Core Vault and the fees that left it, per token.
    mapping(address => uint256) public incomeGross;
    mapping(address => uint256) public incomeFees;
    mapping(address => uint256) public incomeForwardedFromHubVault;
    /// @notice Spoke collected income: swaps between the two tokens of the bucket.
    uint256 public spokeIncomeSwappedIn;
    uint256 public spokeIncomeSwappedOut;
    uint64 public lastReportSequence;
    uint256 public lastSpokeIncomeUsdg;
    uint256 public lastSpokeIncomeWeth;

    // ---- call statistics (successful calls) ----
    mapping(bytes32 => uint256) public done;

    constructor(FundSystem memory system, bool listSendsHomeAtOnce_, bool recognizeRefundsBeforeReports_) {
        s = system;
        _spokeBridge = system.spokeVault.bridgeAdapters()[0];
        fundId = system.core.fundId();
        listSendsHomeAtOnce = listSendsHomeAtOnce_;
        recognizeRefundsBeforeReports = recognizeRefundsBeforeReports_;
        // DEC-127: the manager's seed is the first principal in.
        principalIn = system.core.idle() + system.core.operatingCash();
        _actors.push(makeAddr("shareholder0"));
        _actors.push(makeAddr("shareholder1"));
        _actors.push(makeAddr("shareholder2"));
        _actors.push(makeAddr("attacker"));
    }

    // ===============================================================================================================
    // Shareholders
    // ===============================================================================================================

    function deposit(uint256 actorSeed, uint256 amount, bool freshReport) external {
        address who = _actor(actorSeed);
        if (freshReport) _publishAndDeliver();
        amount = bound(amount, s.shares.totalSupply() == 0 ? 100e6 : 1e6, 200_000e6);
        s.usdc.mint(who, amount);
        uint256 before = s.core.idle() + s.core.operatingCash();
        vm.startPrank(who);
        s.usdc.approve(address(s.core), amount);
        try s.core.deposit(amount, 0) returns (uint256 shares, uint256 charged) {
            uint256 credited = s.core.idle() + s.core.operatingCash() - before;
            assertEq(charged, credited + ShareMath.flowFee(amount, s.core.flowFeeBps()), "deposit charge");
            assertEq(shares % 1e18, 0, "DEC-091: whole shares");
            paidIn[who] += charged;
            principalIn += credited;
            ++valueOps;
            ++done["deposit"];
        } catch {}
        vm.stopPrank();
        _observe();
    }

    function requestPayout(uint256 actorSeed, uint256 amount, bool standard) external {
        address who = _actor(actorSeed);
        uint256 balance = s.shares.balanceOf(who);
        if (balance == 0 || s.core.payoutRequest(who).open) return;
        uint256 price = _sharePrice();
        if (price == 0) return;
        uint256 oneShare = (price + 1e18 - 1) / 1e18;
        uint256 worth = ShareMath.usdcFor(balance, price);
        amount = bound(amount, oneShare, worth * 2 > oneShare ? worth * 2 : oneShare);
        Before memory b = _before(who);
        vm.prank(who);
        try s.core
            .requestPayout(
                amount, standard ? ICoreVaultPayouts.PayoutMode.Standard : ICoreVaultPayouts.PayoutMode.Instant, 0
            ) returns (
            ICoreVault.PayoutReceipt memory r
        ) {
            ++done["requestPayout"];
            // An Instant request is its own claim (DEC-120 item 1).
            if (!standard) _bookClaim(who, b, r, amount);
        } catch {}
        _observe();
    }

    function claimPayout(uint256 actorSeed, bool waitForTerm) external {
        address who = _actor(actorSeed);
        ICoreVault.PayoutRequest memory req = s.core.payoutRequest(who);
        if (!req.open) return;
        if (block.timestamp < req.termEndsAt) {
            if (!waitForTerm) return;
            _warp(req.termEndsAt - block.timestamp);
        }
        Before memory b = _before(who);
        vm.prank(who);
        try s.core.claimPayout(0) returns (ICoreVault.PayoutReceipt memory r) {
            _bookClaim(who, b, r, req.usdcOutstanding);
        } catch {}
        _observe();
    }

    /// @dev What a claim is checked against: the claimant's USDC, the USDC income taken and the hub principal.
    struct Before {
        uint256 balance;
        uint256 taken;
        uint256 hubVault;
    }

    function _before(address who) internal view returns (Before memory b) {
        b.balance = s.usdc.balanceOf(who);
        b.taken = s.core.incomeState(address(s.usdc)).taken;
        b.hubVault = _hubVaultPrincipal();
    }

    /// @dev Checks and books a claim's receipt (an Instant request's or a claim's).
    function _bookClaim(address who, Before memory b, ICoreVault.PayoutReceipt memory r, uint256 outstanding) internal {
        uint256 income = s.core.incomeState(address(s.usdc)).taken - b.taken;
        assertEq(s.usdc.balanceOf(who) - b.balance, r.usdcPaid + income, "claimant receives exactly the receipt");
        assertLe(r.usdcGross, outstanding, "DEC-077: never more than requested");
        assertEq(r.usdcGross, r.usdcPaid + r.payoutFee + r.flowFee, "receipt adds up");
        assertEq(r.sharesBurned % 1e18, 0, "DEC-091: whole shares");
        paidOut[who] += r.usdcPaid;
        principalOut += r.usdcGross - r.payoutFee;
        _creditPayoutFee(r.payoutFee);
        returnedFromHubVault += b.hubVault - _hubVaultPrincipal();
        ++valueOps;
        ++done["claimPayout"];
    }

    /// @notice A whole exit in one step: the request (if none is open) and its claim, after the term for a Standard
    ///         Payout.
    function payout(uint256 actorSeed, uint256 amount, bool standard) external {
        address who = _actor(actorSeed);
        if (s.shares.balanceOf(who) == 0) return;
        if (!s.core.payoutRequest(who).open) this.requestPayout(actorSeed, amount, standard);
        this.claimPayout(actorSeed, true);
    }

    function withdrawIncome(uint256 actorSeed, bool inWeth) external {
        address who = _actor(actorSeed);
        CoreMockToken token = inWeth ? s.weth : s.usdc;
        uint256 owed = s.core.attributedIncome(who, address(token));
        uint256 collected = s.core.collectedIncome(address(token));
        uint256 before = token.balanceOf(who);
        vm.prank(who);
        uint256 amount = s.core.withdrawIncome(address(token));
        assertEq(amount, owed < collected ? owed : collected, "LC-100: min(owed, collected)");
        assertEq(token.balanceOf(who) - before, amount, "income paid");
        if (amount != 0) ++done["withdrawIncome"];
        _observe();
    }

    // ===============================================================================================================
    // Manager: hub
    // ===============================================================================================================

    function allocateToHubVault(uint256 amount) external {
        uint256 free = s.core.freeIdle();
        if (free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(s.manager);
        try s.core.allocateToHubSpokeVault(amount) {
            allocatedToHubVault += amount;
            ++done["allocateToHubVault"];
        } catch {}
        _observe();
    }

    function returnToCoreVault(uint256 amount) external {
        uint256 available = s.hubVault.unallocatedBalance(address(s.usdc));
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(s.manager);
        s.hubVault.returnToCoreVault(amount);
        returnedFromHubVault += amount;
        ++done["returnToCoreVault"];
        _observe();
    }

    /// @param action 0 open on the Uniswap mock, 1 open on the Aave mock, 2 decrease, 3 close, 4 collect, 5 earn.
    function hubPosition(uint256 action, uint256 index, uint256 amount, uint256 amount2) external {
        action = action % 6;
        ISpokeVault.PositionRef[] memory refs = s.hubVault.positions();
        if (action <= 1) {
            if (refs.length >= MAX_POSITIONS) return;
            if (s.hubVault.unallocatedBalance(address(s.usdc)) == 0) this.allocateToHubVault(amount);
            uint256 available = s.hubVault.unallocatedBalance(address(s.usdc));
            if (available == 0) return;
            amount = bound(amount, 1, available);
            vm.prank(s.manager);
            if (action == 0) s.hubVault.openPosition(address(s.hubUni), HUB_POOL, 0, amount, "");
            else s.hubVault.openPosition(address(s.hubAave), AAVE_USDC, amount, 0, "");
            ++done["hubOpen"];
        } else {
            if (refs.length == 0) return;
            ISpokeVault.PositionRef memory ref = refs[index % refs.length];
            if (action == 5) {
                _earn(MockPositionAdapter(ref.adapter), ref.positionKey, s.weth, s.usdc, amount, amount2);
                ++done["hubEarn"];
            } else {
                _exit(s.hubVault, ref, action, amount);
                ++done["hubExit"];
            }
        }
        _observe();
    }

    /// @notice Income on a hub position from earning to the shareholders' accumulator: earn, collect, forward.
    function hubIncomeCycle(uint256 index, uint256 amountWeth, uint256 amountStable, bool forwardWeth) external {
        if (s.hubVault.positions().length == 0) this.hubPosition(index % 2, 0, amountStable, 0);
        ISpokeVault.PositionRef[] memory refs = s.hubVault.positions();
        if (refs.length == 0) return;
        ISpokeVault.PositionRef memory ref = refs[index % refs.length];
        _earn(MockPositionAdapter(ref.adapter), ref.positionKey, s.weth, s.usdc, amountWeth, amountStable);
        _exit(s.hubVault, ref, 4, 0);
        this.forwardIncome(false);
        if (forwardWeth) this.forwardIncome(true);
    }

    function forwardIncome(bool inWeth) external {
        CoreMockToken token = inWeth ? s.weth : s.usdc;
        uint256 amount = s.hubVault.collectedIncome(address(token));
        if (amount == 0) return;
        uint256 feesBefore = _feeBalances(token);
        uint256 collectedBefore = s.core.collectedIncome(address(token));
        s.hubVault.forwardIncomeToCoreVault(address(token));
        uint256 fees = _feeBalances(token) - feesBefore;
        assertEq(fees + s.core.collectedIncome(address(token)) - collectedBefore, amount, "income split adds up");
        incomeGross[address(token)] += amount;
        incomeFees[address(token)] += fees;
        incomeForwardedFromHubVault[address(token)] += amount;
        ++done["forwardIncome"];
        _observe();
    }

    /// @dev DEC-110, DEC-184: the performance fee only falls, and never below the 10% floor.
    function decreaseManagerFee(uint256 bps) external {
        uint16 current = s.core.performanceFeeBps();
        if (current <= MandateLib.MIN_PERFORMANCE_FEE_BPS) return;
        vm.prank(s.manager);
        // forge-lint: disable-next-line(unsafe-typecast)
        s.core.decreaseManagerFee(uint16(bound(bps, MandateLib.MIN_PERFORMANCE_FEE_BPS, current - 1)), 0);
        ++done["decreaseManagerFee"];
        _observe();
    }

    /// @dev DEC-096, DEC-100: the manager may move the floor and the top-up; kept small here so Operating Cash stays a
    ///      side bucket (the unbounded case is a finding of its own, see the report).
    function setOperatingCash(bool onSpoke, uint256 floor, uint256 topUp) external {
        floor = bound(floor, 0, 50e6);
        topUp = bound(topUp, 0, 20e6);
        vm.prank(s.manager);
        if (onSpoke) s.spokeVault.setOperatingCashParameters(floor, topUp);
        else s.core.setOperatingCashParameters(floor, topUp);
        _observe();
    }

    // ===============================================================================================================
    // Manager: sends, and the relayer
    // ===============================================================================================================

    function sendToSpoke(uint256 amount, uint256 feeBps) external {
        uint256 free = s.core.freeIdle();
        if (free == 0) return;
        amount = bound(amount, 1, free);
        uint256 output = amount - amount * bound(feeBps, 0, MAX_BRIDGE_FEE_BPS) / 10_000;
        if (output == 0) return;
        // Security review S-14: the hub funds a spoke only once it accepted a report from it.
        if (!s.receiver.hasReport(0)) _publishAndDeliver();
        uint256 depositIndex = s.hubPool.numberOfDeposits();
        vm.prank(s.manager);
        try s.core.sendToSpoke(0, amount, 0, _hubQuote(output)) returns (bytes32 id) {
            Transit memory t = s.core.transit(id);
            assertEq(t.amountSent, amount, "transit amount sent");
            assertEq(t.amountToArrive, output, "transit amount to arrive");
            _hubSends.push(
                HubSend(id, depositIndex, amount, output, t.fillDeadline, PENDING, 0, 0, false, TransitState.Sent)
            );
            ++done["sendToSpoke"];
        } catch {}
        _observe();
    }

    /// @notice The relayer fills a hub-to-spoke deposit on the spoke, before its fill deadline.
    function fillOnSpoke(uint256 index) external {
        if (_hubSends.length == 0) return;
        HubSend storage h = _hubSends[index % _hubSends.length];
        if (h.outcome != PENDING || block.timestamp > h.deadline) return;
        _fillOnSpoke(h);
        ++done["fillOnSpoke"];
        _observe();
    }

    /// @notice Across refunds an unfilled hub-to-spoke deposit to its escrow, after its fill deadline.
    function refundHubSend(uint256 index) external {
        if (_hubSends.length == 0) return;
        HubSend storage h = _hubSends[index % _hubSends.length];
        if (h.outcome != PENDING || block.timestamp <= h.deadline) return;
        h.outcome = REFUNDED;
        s.hubPool.refund(h.depositIndex);
        ++done["refundHubSend"];
        _observe();
    }

    function attestExpiry(uint256 index) external {
        if (_hubSends.length == 0) return;
        HubSend storage h = _hubSends[index % _hubSends.length];
        vm.prank(stranger);
        try s.core.attestExpiry(h.id) {
            assertGt(block.timestamp, h.deadline, "DEC-066: expiry attested before the fill deadline");
            ++done["attestExpiry"];
        } catch {}
        _observe();
    }

    function recognizeRefundOnHub(uint256 index) external {
        if (_hubSends.length == 0) return;
        _recognizeOnHub(_hubSends[index % _hubSends.length]);
        _observe();
    }

    /// @notice A hub-to-spoke deposit nobody fills, to the end: the deadline passes, Across refunds the escrow, a
    ///         report built after the deadline is delivered, the expiry is attested and the refund recognized.
    function expireHubSend(uint256 index) external {
        if (_hubSends.length == 0) return;
        HubSend storage h = _hubSends[index % _hubSends.length];
        if (h.outcome != PENDING) return;
        if (block.timestamp <= h.deadline) _warp(h.deadline + 1 - block.timestamp);
        h.outcome = REFUNDED;
        s.hubPool.refund(h.depositIndex);
        _publishAndDeliver();
        _observe();
        vm.prank(stranger);
        try s.core.attestExpiry(h.id) {
            ++done["attestExpiry"];
        } catch {}
        _observe();
        _recognizeOnHub(h);
        _observe();
    }

    /// @notice A spoke-to-hub deposit nobody fills, to the end: deadline, Across refund, refund recognized.
    function expireHomeSend(uint256 index) external {
        if (_homeSends.length == 0) return;
        HomeSend storage h = _homeSends[index % _homeSends.length];
        if (h.outcome != PENDING) return;
        if (block.timestamp <= h.deadline) _warp(h.deadline + 1 - block.timestamp);
        h.outcome = REFUNDED;
        s.spokePool.refund(h.depositIndex);
        ++done["refundHomeSend"];
        _recognizeOnSpoke(h);
        _observe();
    }

    function sendHome(uint256 amount, bool income, uint256 feeBps) external {
        uint256 available = income ? s.spokeVault.collectedIncome(address(s.usdg)) : _spokeUsdgAfterTopUp();
        if (available == 0) return;
        // Security review S-11: a full hub-bound list makes `sendToHub` revert; deep campaigns stop sending there.
        if (s.spokeVault.inFlightTransitIds().length >= SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT) return;
        amount = bound(amount, 1, available);
        uint256 output = amount - amount * bound(feeBps, 0, MAX_BRIDGE_FEE_BPS) / 10_000;
        if (output == 0) return;
        TransferKind kind = income ? TransferKind.Income : TransferKind.Principal;
        uint256 depositIndex = s.spokePool.numberOfDeposits();
        _willArrive(output);
        vm.prank(s.manager);
        bytes32 id = s.spokeVault.sendToHub(amount, kind, 0);
        Transit memory t = s.spokeVault.hubBoundTransit(id);
        _homeSends.push(HomeSend(id, depositIndex, amount, output, t.fillDeadline, kind, PENDING, false, 0));
        ++done["sendHome"];
        if (listSendsHomeAtOnce) _publishAndDeliver();
        _observe();
    }

    /// @notice The relayer fills a spoke-to-hub deposit on the hub, before its fill deadline.
    function fillOnHub(uint256 index) external {
        if (_homeSends.length == 0) return;
        HomeSend storage h = _homeSends[index % _homeSends.length];
        if (h.outcome != PENDING || block.timestamp > h.deadline) return;
        _fillOnHub(h);
        ++done["fillOnHub"];
        _observe();
    }

    /// @notice Across refunds an unfilled spoke-to-hub deposit to its escrow, after its fill deadline.
    function refundHomeSend(uint256 index) external {
        if (_homeSends.length == 0) return;
        HomeSend storage h = _homeSends[index % _homeSends.length];
        if (h.outcome != PENDING || block.timestamp <= h.deadline) return;
        h.outcome = REFUNDED;
        s.spokePool.refund(h.depositIndex);
        ++done["refundHomeSend"];
        _observe();
    }

    function recognizeRefundOnSpoke(uint256 index) external {
        if (_homeSends.length == 0) return;
        _recognizeOnSpoke(_homeSends[index % _homeSends.length]);
        _observe();
    }

    // ===============================================================================================================
    // Manager: spoke
    // ===============================================================================================================

    /// @param action 0 open, 2 decrease, 3 close, 4 collect, 5 earn, 1 swap collected WETH income into USDG.
    function spokePosition(uint256 action, uint256 index, uint256 amount, uint256 amount2) external {
        action = action % 6;
        ISpokeVault.PositionRef[] memory refs = s.spokeVault.positions();
        if (action == 0) {
            uint256 available = _spokeUsdgAfterTopUp();
            if (available == 0 || refs.length >= MAX_POSITIONS) return;
            vm.prank(s.manager);
            s.spokeVault.openPosition(address(s.spokeUni), SPOKE_POOL, 0, bound(amount, 1, available), "");
            ++done["spokeOpen"];
        } else if (action == 1) {
            uint256 available = s.spokeVault.collectedIncome(address(s.spokeWeth));
            if (available == 0) return;
            amount = bound(amount, 1, available);
            // The swap adapter stand-in swaps one base unit for one base unit (DEC-136).
            vm.prank(s.manager);
            uint256 out = s.spokeVault.swapCollectedIncome(address(s.spokeSwap), address(s.spokeWeth), amount, 0, "");
            spokeIncomeSwappedIn += amount;
            spokeIncomeSwappedOut += out;
            ++done["spokeSwapIncome"];
        } else {
            if (refs.length == 0) return;
            ISpokeVault.PositionRef memory ref = refs[index % refs.length];
            if (action == 5) {
                _earn(s.spokeUni, ref.positionKey, s.spokeWeth, s.usdg, amount, amount2);
                ++done["spokeEarn"];
            } else {
                _exit(s.spokeVault, ref, action, amount);
                ++done["spokeExit"];
            }
        }
        _observe();
    }

    /// @notice Income on a spoke position from earning to the hub: earn, collect, swap the WETH part into USDG
    ///         (CV-OQ-2) and, optionally, send it home as Income.
    function spokeIncomeCycle(uint256 index, uint256 amountWeth, uint256 amountStable, bool home) external {
        if (s.spokeVault.positions().length == 0) this.spokePosition(0, 0, amountStable, 0);
        ISpokeVault.PositionRef[] memory refs = s.spokeVault.positions();
        if (refs.length == 0) return;
        ISpokeVault.PositionRef memory ref = refs[index % refs.length];
        _earn(s.spokeUni, ref.positionKey, s.spokeWeth, s.usdg, amountWeth, amountStable);
        _exit(s.spokeVault, ref, 4, 0);
        this.spokePosition(1, 0, type(uint256).max, 0);
        if (home) this.sendHome(type(uint256).max, true, amountWeth);
    }

    // ===============================================================================================================
    // Anyone: reports
    // ===============================================================================================================

    function publishAndDeliverReport() external {
        _publishAndDeliver();
        _observe();
    }

    /// @notice A report is published and nobody delivers it (yet).
    function publishReport() external {
        _publish();
        _observe();
    }

    /// @notice Someone delivers an older published report out of order; the receiver decides.
    function deliverPublished(uint256 index) external {
        uint256 count = s.wormhole.publishedCount();
        if (count == 0) return;
        _deliver(index % count);
        _observe();
    }

    function warp(uint256 seconds_) external {
        _warp(bound(seconds_, 1, 9 hours));
        _observe();
    }

    // ===============================================================================================================
    // Stranger
    // ===============================================================================================================

    /// @notice A stranger's Across deposit reaches the Spoke Vault with this fund's message: a fabricated transit id
    ///         or a real hub-to-spoke one (the ids are public, `SentToSpoke`).
    function strangerArrivalOnSpoke(uint256 amount, uint256 idSeed, bool income) external {
        amount = bound(amount, 1, 5000e6);
        bytes32 id;
        if (_hubSends.length != 0 && idSeed % 2 == 0) {
            HubSend storage h = _hubSends[(idSeed / 2) % _hubSends.length];
            id = h.id;
            if (!income) h.strangerListed += amount;
        } else {
            id = keccak256(abi.encode("fabricated", ++_fakeIds));
        }
        uint256 priceBefore = _sharePrice();
        TransferKind kind = income ? TransferKind.Income : TransferKind.Principal;
        s.spokePool.fill(address(s.spokeVault), address(s.usdg), amount, TransitMessage.encode(fundId, HUB, id, kind));
        if (income) {
            strangerSpokeIncome += amount;
        } else {
            strangerSpokePrincipal += amount;
            spokePrincipalArrivals += amount;
            principalIn += amount;
        }
        assertEq(_sharePrice(), priceBefore, "DEC-080: a stranger's spoke arrival moved the Share Price at once");
        ++done["strangerArrivalOnSpoke"];
        _observe();
    }

    /// @notice A stranger's Across deposit reaches the Core Vault with this fund's message and an id no report lists.
    function strangerArrivalOnHub(uint256 amount, bool income, bool fromSpokeChain) external {
        amount = bound(amount, 1, 5000e6);
        bytes32 id = keccak256(abi.encode("fabricated", ++_fakeIds));
        uint256 priceBefore = _sharePrice();
        uint256 idleBefore = s.core.idle();
        uint256 collectedBefore = s.core.collectedIncome(address(s.usdc));
        uint256 unmatchedBefore = s.core.unmatchedArrivals();
        TransferKind kind = income ? TransferKind.Income : TransferKind.Principal;
        s.hubPool
            .fill(
                address(s.core),
                address(s.usdc),
                amount,
                TransitMessage.encode(fundId, fromSpokeChain ? SPOKE : 8453, id, kind)
            );
        assertEq(s.core.idle(), idleBefore, "DEC-080: a fabricated arrival reached Idle");
        assertEq(
            s.core.collectedIncome(address(s.usdc)), collectedBefore, "DEC-080: a fabricated arrival became income"
        );
        assertEq(s.core.unmatchedArrivals(), unmatchedBefore + amount, "OQ-01: a fabricated arrival is held apart");
        assertEq(_sharePrice(), priceBefore, "DEC-080: a fabricated arrival moved the Share Price");
        strangerHubArrivals += amount;
        ++done["strangerArrivalOnHub"];
        _observe();
    }

    /// @notice A direct token transfer to a vault or to a transit escrow never moves the Share Price (DEC-080).
    /// @param target 0-1 Core Vault, 2-3 hub Spoke Vault, 4-5 spoke Spoke Vault, 6 a hub escrow, 7 a spoke escrow.
    function donate(uint256 target, uint256 amount, uint256 index) external {
        target = target % 8;
        amount = bound(amount, 1, 100_000e6);
        uint256 priceBefore = _sharePrice();
        uint256 assetsBefore = _shareAssets();
        if (target == 0) {
            s.usdc.mint(address(s.core), amount);
        } else if (target == 1) {
            s.weth.mint(address(s.core), amount);
        } else if (target == 2) {
            s.usdc.mint(address(s.hubVault), amount);
        } else if (target == 3) {
            s.weth.mint(address(s.hubVault), amount);
        } else if (target == 4) {
            s.usdg.mint(address(s.spokeVault), amount);
        } else if (target == 5) {
            s.spokeWeth.mint(address(s.spokeVault), amount);
        } else if (target == 6) {
            // Less than the amount sent in total: a full-amount donation is a gift the fund may recognize as a
            // refund (CV-OQ-6), which is value a stranger gives away, not a property of the vault.
            if (_hubSends.length == 0) return;
            HubSend storage h = _hubSends[index % _hubSends.length];
            if (h.escrowDonated + 1 >= h.amountSent) return;
            amount = bound(amount, 1, h.amountSent - h.escrowDonated - 1);
            h.escrowDonated += amount;
            s.usdc.mint(s.core.transit(h.id).escrow, amount);
        } else {
            if (_homeSends.length == 0) return;
            HomeSend storage h = _homeSends[index % _homeSends.length];
            if (h.escrowDonated + 1 >= h.amountSent) return;
            amount = bound(amount, 1, h.amountSent - h.escrowDonated - 1);
            h.escrowDonated += amount;
            s.usdg.mint(s.spokeVault.hubBoundTransit(h.id).escrow, amount);
        }
        assertEq(_sharePrice(), priceBefore, "DEC-080: a donation moved the Share Price");
        assertEq(_shareAssets(), assetsBefore, "DEC-080: a donation moved Share Assets");
        ++done["donate"];
        _observe();
    }

    /// @notice The garbage collector takes exactly the balance above the ledger and never a ledger unit (DEC-101).
    /// @param target 0-1 Core Vault, 2-3 hub Spoke Vault, 4-5 spoke Spoke Vault (USDC-like token, then WETH).
    function sweepExcess(uint256 target) external {
        target = target % 6;
        CoreMockToken token;
        address vault;
        if (target < 2) (vault, token) = (address(s.core), target == 0 ? s.usdc : s.weth);
        else if (target < 4) (vault, token) = (address(s.hubVault), target == 2 ? s.usdc : s.weth);
        else (vault, token) = (address(s.spokeVault), target == 4 ? s.usdg : s.spokeWeth);

        uint256 ledger = ledgerOf(vault, address(token));
        uint256 balance = token.balanceOf(vault);
        uint256 recipientBefore = token.balanceOf(s.excessRecipient);
        uint256 priceBefore = _sharePrice();
        vm.prank(stranger);
        uint256 swept = vault == address(s.core)
            ? s.core.sweepExcess(address(token))
            : SpokeVault(vault).sweepExcess(address(token));
        assertEq(swept, balance - ledger, "DEC-101: swept exactly the excess");
        assertEq(token.balanceOf(s.excessRecipient) - recipientBefore, swept, "excess reaches the excess recipient");
        assertEq(ledgerOf(vault, address(token)), ledger, "DEC-080: the sweep changed the ledger");
        assertEq(token.balanceOf(vault), ledger, "DEC-080: the ledger is exactly backed after a sweep");
        assertEq(_sharePrice(), priceBefore, "DEC-080: a sweep moved the Share Price");
        if (swept != 0) ++done["sweepExcess"];
        _observe();
    }

    // ===============================================================================================================
    // Settlement (called from inside an invariant: its state changes are discarded afterwards)
    // ===============================================================================================================

    /// @notice Brings the fund to rest: every Across deposit is filled (before its deadline) or refunded (after it),
    ///         every refund is recognized, and a fresh report is delivered. At rest no value is in flight, so the
    ///         hub's view must equal the ledgers.
    function settle() external {
        for (uint256 i; i < _hubSends.length; ++i) {
            HubSend storage h = _hubSends[i];
            if (h.outcome != PENDING) continue;
            if (block.timestamp <= h.deadline) {
                _fillOnSpoke(h);
            } else {
                h.outcome = REFUNDED;
                s.hubPool.refund(h.depositIndex);
            }
        }
        for (uint256 i; i < _homeSends.length; ++i) {
            HomeSend storage h = _homeSends[i];
            if (h.outcome == PENDING) {
                if (block.timestamp <= h.deadline) {
                    _fillOnHub(h);
                } else {
                    h.outcome = REFUNDED;
                    s.spokePool.refund(h.depositIndex);
                }
            }
            if (h.outcome == REFUNDED && !h.recognized) _recognizeOnSpoke(h);
        }
        assertTrue(_publishAndDeliver(), "settlement: the fresh report was not accepted");
        for (uint256 i; i < _hubSends.length; ++i) {
            HubSend storage h = _hubSends[i];
            if (h.outcome != REFUNDED) continue;
            if (s.core.transit(h.id).state == TransitState.Sent) {
                try s.core.attestExpiry(h.id) {} catch {}
            }
        }
        // Observed between the two steps: Sent to RefundRecognized is two edges, never one.
        _observe();
        for (uint256 i; i < _hubSends.length; ++i) {
            if (_hubSends[i].outcome == REFUNDED) _recognizeOnHub(_hubSends[i]);
        }
        _observe();
    }

    /// @notice Publishes and delivers a report now and changes nothing else (called from inside an invariant).
    function deliverFreshReport() external {
        assertTrue(_publishAndDeliver(), "the fresh report was not accepted");
        _observe();
    }

    // ===============================================================================================================
    // Views for the invariants
    // ===============================================================================================================

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function hubSendCount() external view returns (uint256) {
        return _hubSends.length;
    }

    function hubSend(uint256 index) external view returns (HubSend memory) {
        return _hubSends[index];
    }

    function homeSendCount() external view returns (uint256) {
        return _homeSends.length;
    }

    function homeSend(uint256 index) external view returns (HomeSend memory) {
        return _homeSends[index];
    }

    /// @notice Principal the fund's ledgers hold: Idle, both Spoke Vaults' Unallocated Balance and position principal.
    function principalHeld() public view returns (uint256) {
        return s.core.idle() + _hubVaultPrincipal() + _spokeVaultPrincipal();
    }

    function operatingCashHeld() public view returns (uint256) {
        return s.core.operatingCash() + s.spokeVault.operatingCash();
    }

    function hubVaultPrincipal() external view returns (uint256) {
        return _hubVaultPrincipal();
    }

    function spokeVaultPrincipal() external view returns (uint256) {
        return _spokeVaultPrincipal();
    }

    /// @notice What a vault's ledger says it holds of `token`.
    function ledgerOf(address vault, address token) public view returns (uint256 total) {
        if (vault == address(s.core)) {
            total = s.core.collectedIncome(token);
            if (token == address(s.usdc)) {
                total += s.core.idle() + s.core.operatingCash() + s.core.unmatchedArrivals();
            }
        } else {
            SpokeVault v = SpokeVault(vault);
            total = v.unallocatedBalance(token) + v.collectedIncome(token);
            if (token == v.baseToken()) total += v.operatingCash();
        }
    }

    /// @notice Sum of the amounts of the hub-to-spoke transits in `state`: what arrives (`toArrive`) or what was sent.
    function hubSendsIn(TransitState state, bool toArrive) public view returns (uint256 total) {
        for (uint256 i; i < _hubSends.length; ++i) {
            if (s.core.transit(_hubSends[i].id).state == state) {
                total += toArrive ? _hubSends[i].amountToArrive : _hubSends[i].amountSent;
            }
        }
    }

    /// @notice Amount sent of every hub send that holds the Spoke Cap: still Sent, or ExpiryAttested by time alone
    ///         (security review S-13).
    function hubSendsHoldingTheCap() public view returns (uint256 total) {
        for (uint256 i; i < _hubSends.length; ++i) {
            bytes32 id = _hubSends[i].id;
            TransitState state = s.core.transit(id).state;
            if (state == TransitState.Sent || (state == TransitState.ExpiryAttested && s.core.spokeCapHeld(id))) {
                total += _hubSends[i].amountSent;
            }
        }
    }

    /// @notice Refunds that can never be recognized because a stranger's arrival confirmed the transit first: the
    ///         stranger made the fund whole on the spoke and the Across refund stays in the escrow (OQ-01, OQ-09).
    function strandedRefunds() public view returns (uint256 total) {
        for (uint256 i; i < _hubSends.length; ++i) {
            HubSend storage h = _hubSends[i];
            if (h.outcome == REFUNDED && !h.recognized && s.core.transit(h.id).state == TransitState.ArrivalConfirmed) {
                total += h.amountSent;
            }
        }
    }

    /// @notice Value strangers gave the fund for good: a transit whose Across refund was recognized and which a
    ///         stranger's later arrival then confirmed counts the stranger's value as the fund's (RefundRecognized
    ///         to ArrivalConfirmed). Shareholders legitimately gain it.
    function strangerGifts() public view returns (uint256 total) {
        for (uint256 i; i < _hubSends.length; ++i) {
            HubSend storage h = _hubSends[i];
            if (h.recognized && s.core.transit(h.id).state == TransitState.ArrivalConfirmed) total += h.amountToArrive;
        }
    }

    /// @notice Amounts to arrive of the transits the hub confirmed although the relayer never filled them (a
    ///         stranger's arrival carried the id): the stranger's value stands in for the fill.
    function confirmedWithoutFill() public view returns (uint256 total) {
        for (uint256 i; i < _hubSends.length; ++i) {
            HubSend storage h = _hubSends[i];
            if (h.outcome != FILLED && s.core.transit(h.id).state == TransitState.ArrivalConfirmed) {
                total += h.amountToArrive;
            }
        }
    }

    /// @notice Principal sent home whose value is in no ledger yet: the deposit is still with Across, or Across
    ///         refunded its escrow and the refund is not recognized. At the amount that will arrive (DEC-085).
    function principalOnTheWayHome() public view returns (uint256 total) {
        for (uint256 i; i < _homeSends.length; ++i) {
            HomeSend storage h = _homeSends[i];
            if (h.kind != TransferKind.Principal || h.outcome == FILLED || h.recognized) continue;
            total += h.amountToArrive;
        }
    }

    /// @notice The pending Principal return leg the hub should count: entries of the latest accepted report whose
    ///         fill has not reached the Core Vault.
    function pendingPrincipalReturnLeg() public view returns (uint256 total) {
        if (!s.receiver.hasReport(0)) return 0;
        (ReportCodec.Report memory r,,) = s.receiver.latestReport(0);
        for (uint256 i; i < r.inFlightToHub.length; ++i) {
            if (r.inFlightToHub[i].kind != TransferKind.Principal) continue;
            if (_homeSendOutcome(r.inFlightToHub[i].transitId) != FILLED) total += r.inFlightToHub[i].amount;
        }
    }

    // ===============================================================================================================
    // Internals
    // ===============================================================================================================

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }

    /// @dev Credits each shareholder with its part of a Payout Fee left in Idle, rounded up (DEC-144).
    function _creditPayoutFee(uint256 fee) internal {
        uint256 supply = s.shares.totalSupply();
        if (fee == 0 || supply == 0) return;
        for (uint256 i; i < _actors.length; ++i) {
            payoutFeeGain[_actors[i]] += (fee * s.shares.balanceOf(_actors[i]) + supply - 1) / supply;
        }
    }

    /// @dev DEC-158, DEC-162: the vaults pass no amount to arrive; the mock bridge adapters fix it. On the hub the mock
    ///      reads this `bridgeData` word as its amount (a stand-in for a quote an adapter verifies itself).
    function _hubQuote(uint256 outputAmount) internal pure returns (bytes memory) {
        return abi.encode(outputAmount);
    }

    /// @dev The spoke's mock adapter delivers `outputAmount` on the next send home (DEC-158, DEC-162: the manager
    ///      passes no bridge parameter).
    function _willArrive(uint256 outputAmount) internal {
        MockBridgeNextArrive.set(_spokeBridge, outputAmount);
    }

    function _sharePrice() internal view returns (uint256) {
        return s.core.sharePrice();
    }

    function _shareAssets() internal view returns (uint256) {
        return s.core.shareAssets();
    }

    function _feeBalances(CoreMockToken token) internal view returns (uint256) {
        return token.balanceOf(s.protocolRecipient) + token.balanceOf(s.core.managerFeeVault());
    }

    function _warp(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        vm.roll(block.number + seconds_ / 12 + 1);
        // A live feed: the price source answers with a current timestamp (a mint reverts on a stale price, OQ-10).
        s.prices.setPrice(address(s.weth), 2.5e9);
        s.prices.setPrice(address(s.spokeWeth), 2.5e9);
        s.prices.setPrice(address(s.usdg), 1e18);
    }

    function _hubVaultPrincipal() internal view returns (uint256 total) {
        total = s.hubVault.unallocatedBalance(address(s.usdc));
        ISpokeVault.PositionRef[] memory refs = s.hubVault.positions();
        for (uint256 i; i < refs.length; ++i) {
            (, uint256 principal0, uint256 principal1,,,) =
                MockPositionAdapter(refs[i].adapter).position(refs[i].positionKey);
            total += refs[i].adapter == address(s.hubAave) ? principal0 : principal1;
        }
    }

    function _spokeVaultPrincipal() internal view returns (uint256 total) {
        total = s.spokeVault.unallocatedBalance(address(s.usdg));
        ISpokeVault.PositionRef[] memory refs = s.spokeVault.positions();
        for (uint256 i; i < refs.length; ++i) {
            (,, uint256 principal1,,,) = s.spokeUni.position(refs[i].positionKey);
            total += principal1;
        }
    }

    /// @dev DEC-096: Unallocated USDG left after the top-up the next value-moving operation runs.
    function _spokeUsdgAfterTopUp() internal view returns (uint256 available) {
        available = s.spokeVault.unallocatedBalance(address(s.usdg));
        if (s.spokeVault.operatingCash() < s.spokeVault.operatingCashFloor()) {
            uint256 topUp = s.spokeVault.operatingCashTopUp();
            available -= topUp < available ? topUp : available;
        }
    }

    function _earn(
        MockPositionAdapter adapter,
        bytes32 positionKey,
        CoreMockToken weth,
        CoreMockToken stable,
        uint256 amountWeth,
        uint256 amountStable
    ) internal {
        amountWeth = bound(amountWeth, 0, 1e18);
        amountStable = bound(amountStable, 0, 10_000e6);
        if (adapter.isExactValue()) {
            // The Aave mock pool holds one token (token0).
            stable.mint(address(adapter), amountStable);
            adapter.earnIncome(positionKey, amountStable, 0);
        } else {
            weth.mint(address(adapter), amountWeth);
            stable.mint(address(adapter), amountStable);
            adapter.earnIncome(positionKey, amountWeth, amountStable);
        }
    }

    function _exit(SpokeVault vault, ISpokeVault.PositionRef memory ref, uint256 action, uint256 bps) internal {
        vm.prank(s.manager);
        if (action == 2) vault.decreasePosition(ref.adapter, ref.positionKey, abi.encode(bound(bps, 0, 10_000)));
        else if (action == 3) vault.closePosition(ref.adapter, ref.positionKey, "");
        else vault.collectIncome(ref.adapter, ref.positionKey);
    }

    function _fillOnSpoke(HubSend storage h) internal {
        h.outcome = FILLED;
        MockAcrossSpokePool.Deposit memory d = s.hubPool.deposit(h.depositIndex);
        assertEq(d.recipient, address(s.spokeVault), "DEC-087: the vault fixes the recipient");
        assertEq(d.depositor, s.core.transit(h.id).escrow, "DEC-066: the escrow is the depositor");
        uint256 before = s.spokeVault.cumulativeReceived();
        s.spokePool.fill(address(s.spokeVault), address(s.usdg), d.outputAmount, d.message);
        assertEq(s.spokeVault.cumulativeReceived() - before, h.amountToArrive, "the fill is credited as Principal");
        spokePrincipalArrivals += h.amountToArrive;
        principalOut += h.amountSent - h.amountToArrive;
    }

    function _fillOnHub(HomeSend storage h) internal {
        h.outcome = FILLED;
        MockAcrossSpokePool.Deposit memory d = s.spokePool.deposit(h.depositIndex);
        assertEq(d.recipient, address(s.core), "DEC-087: the vault fixes the recipient");
        uint256 idleBefore = s.core.idle();
        uint256 feesBefore = _feeBalances(s.usdc);
        uint256 collectedBefore = s.core.collectedIncome(address(s.usdc));
        s.hubPool.fill(address(s.core), address(s.usdc), d.outputAmount, d.message);
        uint256 toIdle = s.core.idle() - idleBefore;
        uint256 fees = _feeBalances(s.usdc) - feesBefore;
        uint256 toIncome = s.core.collectedIncome(address(s.usdc)) - collectedBefore + fees;
        if (h.kind == TransferKind.Principal) {
            assertEq(toIncome, 0, "OQ-01: a Principal transfer home was credited as income");
            if (listSendsHomeAtOnce) assertEq(toIdle, h.amountToArrive, "a listed Principal arrival reaches Idle");
            principalOut += h.amountSent - h.amountToArrive;
        } else {
            assertEq(toIdle, 0, "DEC-092: an Income transfer home reached Idle");
            if (listSendsHomeAtOnce) assertEq(toIncome, h.amountToArrive, "a listed Income arrival is collected");
            incomeGross[address(s.usdc)] += toIncome;
            incomeFees[address(s.usdc)] += fees;
        }
    }

    function _recognizeOnHub(HubSend storage h) internal {
        uint256 idleBefore = s.core.idle();
        vm.prank(stranger);
        try s.core.recognizeRefund(h.id) returns (uint256 amount) {
            assertEq(h.outcome, REFUNDED, "DEC-063: a refund was recognized that Across never paid");
            assertEq(amount, h.amountSent, "DEC-063: the refund is the amount sent");
            assertEq(s.core.idle() - idleBefore, h.amountSent, "exactly the amount sent enters Idle");
            assertFalse(h.recognized, "DEC-066: a refund was recognized twice");
            h.recognized = true;
            refundedBridgeFees += h.amountSent - h.amountToArrive;
            ++valueOps;
            ++done["recognizeRefundOnHub"];
        } catch {}
    }

    function _recognizeOnSpoke(HomeSend storage h) internal {
        address token = address(s.usdg);
        uint256 before = h.kind == TransferKind.Principal
            ? s.spokeVault.unallocatedBalance(token)
            : s.spokeVault.collectedIncome(token);
        uint256 cashBefore = s.spokeVault.operatingCash();
        vm.prank(stranger);
        try s.spokeVault.recognizeRefund(h.id) returns (uint256 amount) {
            assertEq(h.outcome, REFUNDED, "DEC-063: a refund was recognized that Across never paid");
            assertFalse(h.recognized, "DEC-066: a refund was recognized twice");
            assertEq(amount, h.amountSent, "DEC-063: the refund is the amount sent");
            uint256 afterward = h.kind == TransferKind.Principal
                ? s.spokeVault.unallocatedBalance(token) + s.spokeVault.operatingCash() - cashBefore
                : s.spokeVault.collectedIncome(token);
            assertEq(afterward - before, h.amountSent, "the refund returns to the bucket the send debited");
            h.recognized = true;
            if (h.kind == TransferKind.Principal) refundedBridgeFees += h.amountSent - h.amountToArrive;
            ++valueOps;
            ++done["recognizeRefundOnSpoke"];
        } catch {}
    }

    function _homeSendOutcome(bytes32 id) internal view returns (uint8) {
        for (uint256 i; i < _homeSends.length; ++i) {
            if (_homeSends[i].id == id) return _homeSends[i].outcome;
        }
        return PENDING;
    }

    /// @dev With `recognizeRefundsBeforeReports`, an expired send home is refunded and recognized before a report is
    ///      built, so no report ever drops a transfer whose value sits in an escrow.
    function _beforeReport() internal {
        if (!recognizeRefundsBeforeReports) return;
        for (uint256 i; i < _homeSends.length; ++i) {
            HomeSend storage h = _homeSends[i];
            if (h.outcome == PENDING && block.timestamp > h.deadline) {
                h.outcome = REFUNDED;
                s.spokePool.refund(h.depositIndex);
            }
            if (h.outcome == REFUNDED && !h.recognized) _recognizeOnSpoke(h);
        }
    }

    function _publish() internal returns (uint256 index) {
        _beforeReport();
        index = s.wormhole.publishedCount();
        (uint64 sequence,) = s.spokeVault.report();
        _syncRecognizedByReport();
        assertEq(sequence, lastReportSequence + 1, "DEC-093: the report sequence increases by one");
        lastReportSequence = sequence;
        ++done["report"];
    }

    /// @dev Security review S-3: `report()` recognizes an expired send home whose refund landed; the ghost state
    ///      follows it exactly as it follows a `recognizeRefund` call.
    function _syncRecognizedByReport() internal {
        for (uint256 i; i < _homeSends.length; ++i) {
            HomeSend storage h = _homeSends[i];
            if (h.recognized || s.spokeVault.hubBoundTransit(h.id).state != TransitState.RefundRecognized) continue;
            assertEq(h.outcome, REFUNDED, "DEC-063: a refund was recognized that Across never paid");
            h.recognized = true;
            if (h.kind == TransferKind.Principal) refundedBridgeFees += h.amountSent - h.amountToArrive;
            ++valueOps;
            ++done["recognizeRefundOnSpoke"];
        }
    }

    function _publishAndDeliver() internal returns (bool) {
        return _deliver(_publish());
    }

    /// @dev Wraps a published payload into the VAA the mock Core Bridge accepts and delivers it (anyone may).
    function _deliver(uint256 index) internal returns (bool accepted) {
        MockWormholeCore.Published memory p = s.wormhole.published(index);
        CoreBridgeVM memory m;
        m.version = 1;
        m.emitterChainId = WH_SPOKE;
        m.emitterAddress = bytes32(uint256(uint160(p.emitter)));
        m.sequence = p.sequence;
        m.consistencyLevel = p.consistencyLevel;
        m.payload = p.payload;
        m.signatures = new GuardianSignature[](0);
        vm.prank(stranger);
        try s.receiver.deliver(abi.encode(m)) {
            assertGe(index + 1, _delivered, "DEC-093: an older report replaced a newer one");
            _delivered = index + 1;
            ++done["deliver"];
            return true;
        } catch {
            return false;
        }
    }

    /// @dev After every action: the transit state machine only moves along its edges (DEC-066, DEC-090), and the
    ///      spoke's monotonic counters never regress (Q60, DEC-093).
    function _observe() internal {
        for (uint256 i; i < _hubSends.length; ++i) {
            HubSend storage h = _hubSends[i];
            TransitState state = s.core.transit(h.id).state;
            if (state == h.lastState) continue;
            assertTrue(_edge(h.lastState, state), "DEC-066: a transit moved along a forbidden edge");
            h.lastState = state;
        }
        uint256 incomeUsdg = s.spokeVault.cumulativeIncome(address(s.usdg));
        uint256 incomeWeth = s.spokeVault.cumulativeIncome(address(s.spokeWeth));
        assertGe(incomeUsdg, lastSpokeIncomeUsdg, "Q60: cumulative income regressed");
        assertGe(incomeWeth, lastSpokeIncomeWeth, "Q60: cumulative income regressed");
        lastSpokeIncomeUsdg = incomeUsdg;
        lastSpokeIncomeWeth = incomeWeth;
    }

    /// @dev Sent -> ArrivalConfirmed | ExpiryAttested; ExpiryAttested -> RefundRecognized | ArrivalConfirmed (a late
    ///      report lists it); RefundRecognized -> ArrivalConfirmed (the escrow held a donation, the arrival is real).
    function _edge(TransitState from, TransitState to) internal pure returns (bool) {
        if (from == TransitState.Sent) return to == TransitState.ArrivalConfirmed || to == TransitState.ExpiryAttested;
        if (from == TransitState.ExpiryAttested) {
            return to == TransitState.RefundRecognized || to == TransitState.ArrivalConfirmed;
        }
        if (from == TransitState.RefundRecognized) return to == TransitState.ArrivalConfirmed;
        return false;
    }
}
