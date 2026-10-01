// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {IAaveV3Pool} from "../../../src/interfaces/external/IAaveV3Pool.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {XChainBase, LiveRelayData} from "./XChainBase.sol";

/// @notice Review port of the integration-xchain value-conservation walk (report 09 "Conservation walk"; consolidated
///         H-01, I-14, I-15, I-17; register S-1, S-3, S-14). DEC-104: a unit of value is never outside all bases and
///         never in two. The project's end-to-end scenario, extended with the flows it does not walk (real fills, a send
///         home as Income and as Principal, a refund in each direction, a donation, and since S-3 a refund that lands
///         after `HUB_BOUND_RETENTION`), on the factory-created fund on both forks.
/// @dev After every step two totals are compared, in USDC through the fund's own price source:
///      (a) holdings: token balances of the Core Vault, both Spoke Vaults, every adapter and every open transit's
///          escrow; the fund's aUSDC; the amounts the fund's V4 positions would return (principal and fees, from the
///          PoolManager's state through the adapter's view); and Across deposits the fund made that are neither filled
///          nor refunded, at their output amount;
///      (b) books: Share Assets + Operating Cash (hub, spoke) + collected income (Core Vault, hub Spoke Vault, spoke)
///          + uncollected position income (hub, spoke) + `unmatchedArrivals`.
///      D = (a) - (b) - basis is recorded twice: "now" (the hub's books as they are) and "fresh" (after one more report
///      is published and delivered, on per-fork snapshots that are then reverted), so report lag separates from real
///      gaps. "basis" (S-1): Share Assets value V4 principal at the oracle-implied composition, the holdings at the
///      spot composition, both at the price source; the difference is logged per step and taken out of D.
/// @dev Adaptation to the fix branch, interface only: phase 4 delivers the spoke's first report before the first send
///      (S-14), and the unfilled send home of W22 carries no exclusivity (S-9): nobody fills it. The review's single
///      state snapshot covered the active fork only, so its "fresh" report's publication stayed on Robinhood; the port
///      snapshots each fork.
/// @dev Divergences on `e5c778a` (D now / D fresh, USDC): W4 -9.999999 / 0 (I-15), W12 fresh +0.553832 (I-14), W13
///      -500 / 0 (hold-apart), W20 +0.16 (refunded fee), W23 +299.88 / +299.88 and W24 +300.00 / +300.00 (H-01), W26
///      +1,234 (donation). On this branch W23 and W24 close (S-3); W4, W12, W13, W20 and W26 are unchanged. Added W28
///      to W31: the S-3 residual, a refund later than the retention reopens the H-01 gap.
contract Fork_ConservationWalk is XChainBase {
    uint256 internal constant TOL = 1000; // 0.001 USDC: pricing floors and Aave's scaled rounding
    uint256 internal constant ARRIVES = BRIDGE_AMOUNT - BRIDGE_FEE;

    struct Tracked {
        bool hubToSpoke;
        address escrow;
        uint256 inputAmount;
        uint256 outputAmount;
        bool filled;
        bool refunded;
        bool recognized;
    }

    struct Row {
        string step;
        uint256 a;
        uint256 b;
        int256 dNow;
        int256 dFresh;
        int256 basis;
    }

    Tracked[] internal tracked;
    Row[] internal rows;
    int256 internal lastBasis;
    address internal carol = makeAddr("carol");

    // -----------------------------------------------------------------------------------------------------------------
    // (a) holdings and (b) books
    // -----------------------------------------------------------------------------------------------------------------

    function _v4Amounts(address adapter, ISpokeVault.PositionRef[] memory ps)
        internal
        view
        returns (uint256 amount0, uint256 amount1, uint256 income0, uint256 income1)
    {
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].adapter != adapter) continue;
            IAdapter.PositionValue memory v = IAdapter(adapter).positionValue(ps[i].positionKey);
            amount0 += v.principal0 + v.income0;
            amount1 += v.principal1 + v.income1;
            income0 += v.income0;
            income1 += v.income1;
        }
    }

    function _holdings() internal returns (uint256 total) {
        _onRobinhood();
        uint256 usdg;
        uint256 weth;
        address[3] memory rh = [address(spokeVault), spokeUniswap, spokeAcross];
        for (uint256 i; i < rh.length; ++i) {
            usdg += IERC20(RH_USDG).balanceOf(rh[i]);
            weth += IERC20(RH_WETH).balanceOf(rh[i]);
        }
        (uint256 w, uint256 g,,) = _v4Amounts(spokeUniswap, spokeVault.positions());
        weth += w;
        usdg += g;
        for (uint256 i; i < tracked.length; ++i) {
            if (!tracked[i].hubToSpoke) usdg += IERC20(RH_USDG).balanceOf(tracked[i].escrow);
        }

        _onArbitrum();
        total = _usdcValue(RH_USDG, usdg) + _usdcValue(RH_WETH, weth);
        uint256 usdc;
        uint256 wethA;
        address[5] memory hub = [address(core), address(hubSpoke), hubUniswap, hubAave, hubAcross];
        for (uint256 i; i < hub.length; ++i) {
            usdc += IERC20(ARB_USDC).balanceOf(hub[i]);
            wethA += IERC20(ARB_WETH).balanceOf(hub[i]);
        }
        usdc += IERC20(IAaveV3Pool(ARB_AAVE_V3_POOL).getReserveData(ARB_USDC).aTokenAddress).balanceOf(hubAave);
        (uint256 w0, uint256 u1,,) = _v4Amounts(hubUniswap, hubSpoke.positions());
        wethA += w0;
        usdc += u1;
        for (uint256 i; i < tracked.length; ++i) {
            Tracked memory t = tracked[i];
            if (t.hubToSpoke) usdc += IERC20(ARB_USDC).balanceOf(t.escrow);
            if (t.filled || t.refunded) continue;
            // An Across deposit neither filled nor refunded: what the fund is owed if it is filled.
            total += t.hubToSpoke ? _usdcValue(RH_USDG, t.outputAmount) : t.outputAmount;
        }
        total += usdc + _usdcValue(ARB_WETH, wethA);
    }

    function _books() internal returns (uint256 total) {
        _onRobinhood();
        uint256 ocSpoke = spokeVault.operatingCash();
        uint256 colUsdg = spokeVault.collectedIncome(RH_USDG);
        uint256 colWeth = spokeVault.collectedIncome(RH_WETH);
        (,, uint256 incWeth, uint256 incUsdg) = _v4Amounts(spokeUniswap, spokeVault.positions());

        _onArbitrum();
        total = core.shareAssets() + core.operatingCash() + core.unmatchedArrivals();
        total += _usdcValue(RH_USDG, ocSpoke + colUsdg + incUsdg) + _usdcValue(RH_WETH, colWeth + incWeth);
        total += core.collectedIncome(ARB_USDC) + hubSpoke.collectedIncome(ARB_USDC);
        total += _usdcValue(ARB_WETH, core.collectedIncome(ARB_WETH) + hubSpoke.collectedIncome(ARB_WETH));
        ISpokeVault.PositionRef[] memory ps = hubSpoke.positions();
        (,, uint256 hubIncWeth, uint256 hubIncUsdc) = _v4Amounts(hubUniswap, ps);
        total += hubIncUsdc + _usdcValue(ARB_WETH, hubIncWeth);
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].adapter == hubAave) total += IAdapter(hubAave).positionValue(ps[i].positionKey).income0;
        }
        // Q60: what holders are owed never exceeds what the Core Vault holds as collected income.
        uint256 owedUsdc = core.attributedIncome(ana, ARB_USDC) + core.attributedIncome(bruno, ARB_USDC)
            + core.attributedIncome(carol, ARB_USDC);
        uint256 owedWeth = core.attributedIncome(ana, ARB_WETH) + core.attributedIncome(bruno, ARB_WETH)
            + core.attributedIncome(carol, ARB_WETH);
        assertLe(owedUsdc, core.collectedIncome(ARB_USDC), "Q60: owed USDC within collected");
        assertLe(owedWeth, core.collectedIncome(ARB_WETH), "Q60: owed WETH within collected");
    }

    function _diff() internal returns (int256 d, uint256 a, uint256 b) {
        a = _holdings();
        b = _books();
        d = int256(a) - int256(b) - _basis();
    }

    /// @dev Security review S-1: Share Assets value a V4 position's principal at the oracle-implied composition, the
    ///      holdings above at the PoolManager's spot composition (both priced at the price source). The difference is
    ///      a valuation basis, not value outside a book; it is taken out of D and logged.
    function _basis() internal returns (int256 basis) {
        _onRobinhood();
        IAdapter.PositionValue[] memory spoke = _v4Values(spokeUniswap, spokeVault.positions());
        _onArbitrum();
        IAdapter.PositionValue[] memory hub = _v4Values(hubUniswap, hubSpoke.positions());
        basis = _basisOf(spoke) + _basisOf(hub);
        lastBasis = basis;
    }

    function _v4Values(address adapter, ISpokeVault.PositionRef[] memory ps)
        internal
        view
        returns (IAdapter.PositionValue[] memory vs)
    {
        uint256 n;
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].adapter == adapter) ++n;
        }
        vs = new IAdapter.PositionValue[](n);
        n = 0;
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].adapter == adapter) vs[n++] = IAdapter(adapter).positionValue(ps[i].positionKey);
        }
    }

    function _basisOf(IAdapter.PositionValue[] memory vs) internal view returns (int256 basis) {
        for (uint256 i; i < vs.length; ++i) {
            IAdapter.PositionValue memory v = vs[i];
            ReportCodec.PositionReport memory p;
            (p.tickLower, p.tickUpper, p.liquidity, p.token0, p.token1) =
            (v.tickLower, v.tickUpper, v.liquidity, v.token0, v.token1);
            (p.principal0, p.principal1) = (v.principal0, v.principal1);
            (uint256 o0, uint256 o1) = _oracleAmounts(p);
            basis += int256(_usdcValue(v.token0, v.principal0) + _usdcValue(v.token1, v.principal1))
            - int256(_usdcValue(v.token0, o0) + _usdcValue(v.token1, o1));
        }
    }

    /// @dev Records the step; `dNow` and `dFresh` are asserted against the expected divergences (0 unless explained).
    function _step(string memory label, int256 expectNow, bool checkNow, int256 expectFresh) internal {
        (int256 dNow, uint256 a, uint256 b) = _diff();
        int256 basisNow = lastBasis;
        int256 dFresh = _dFresh();
        rows.push(Row(label, a, b, dNow, dFresh, basisNow));
        if (checkNow) assertApproxEqAbs(dNow, expectNow, TOL, string.concat(label, ": D now"));
        assertApproxEqAbs(dFresh, expectFresh, TOL, string.concat(label, ": D with a fresh report"));
    }

    /// @dev D after one more report is published and delivered, on snapshots that are then reverted. A snapshot
    ///      reverts storage but not a fork's warp, so both forks' clocks and blocks are kept and put back.
    function _dFresh() internal returns (int256 dFresh) {
        uint256 active = vm.activeFork();
        vm.selectFork(arbitrumFork);
        uint256[4] memory saved;
        (saved[0], saved[1]) = (block.timestamp, block.number);
        vm.selectFork(robinhoodFork);
        (saved[2], saved[3]) = (block.timestamp, block.number);
        // A state snapshot covers the active fork only: one per fork, or the fresh report's publication (sequence,
        // landed-refund recognition) would stay on Robinhood.
        vm.selectFork(arbitrumFork);
        uint256 snapArbitrum = vm.snapshotState();
        vm.selectFork(robinhoodFork);
        uint256 snapRobinhood = vm.snapshotState();
        vm.selectFork(active);
        _report();
        (dFresh,,) = _diff();
        vm.selectFork(robinhoodFork);
        vm.revertToState(snapRobinhood);
        vm.selectFork(arbitrumFork);
        vm.revertToState(snapArbitrum);
        vm.selectFork(arbitrumFork);
        vm.warp(saved[0]);
        vm.roll(saved[1]);
        vm.selectFork(robinhoodFork);
        vm.warp(saved[2]);
        vm.roll(saved[3]);
        vm.selectFork(active);
    }

    function _printTable() internal view {
        console2.log("step | (a) holdings | (b) books | D now | D after a fresh report   (USDC base units)");
        for (uint256 i; i < rows.length; ++i) {
            Row memory r = rows[i];
            console2.log(r.step);
            console2.log("    a", r.a, "b", r.b);
            console2.log("    D now", r.dNow);
            console2.log("    D fresh", r.dFresh);
            console2.log("    S-1 basis (taken out of D)", r.basis);
        }
    }

    function _track(bool hubToSpoke, bytes32 id, LiveRelayData memory relay) internal returns (uint256 index) {
        address escrow = hubToSpoke ? core.transit(id).escrow : _spokeEscrow(id);
        tracked.push(Tracked(hubToSpoke, escrow, relay.inputAmount, relay.outputAmount, false, false, false));
        index = tracked.length - 1;
    }

    function _spokeEscrow(bytes32 id) internal returns (address) {
        _onRobinhood();
        return spokeVault.hubBoundTransit(id).escrow;
    }

    // -----------------------------------------------------------------------------------------------------------------
    // The walk
    // -----------------------------------------------------------------------------------------------------------------

    /// @notice H-01 window FIXED (W23, W24: 0 and +0.12, the refunded fee, instead of +299.88 and +300.00); I-15
    ///         (W4, -10 USDG until the next report) and I-14 (W12, Income in flight home in no base) STILL_PRESENT;
    ///         the S-3 residual (a refund later than the 3-day retention) reopens the H-01 gap (W29, W30).
    function test_POC_REVIEW_I15_conservationWalkOverTheScenario() public {
        _createForks();
        _phase1CreateFund();
        _step("W0  fund created on both chains", 0, true, 0);
        _phase2AnaDeposits();
        _step("W1  Ana deposits 10,000", 0, true, 0);
        _phase3HubAllocationAndIncome();
        _step("W2  hub allocation, Aave, V4 position, fees", 0, true, 0);

        // Hub to spoke, filled for real.
        _phase4SendToRobinhood();
        LiveRelayData memory out = _relayOfHubTransit(transitId);
        uint256 outIndex = _track(true, transitId, out);
        _step("W3  send 4,000 to Robinhood", 0, true, 0);
        _fillOnRobinhood(out, relayer);
        tracked[outIndex].filled = true;
        // The spoke's first arrival tops up Operating Cash (10 USDG); until a report confirms the transit, the hub
        // counts those 10 USDG both in In-flight Value and in the spoke's Operating Cash.
        _step("W4  real fill on Robinhood (no report yet)", -int256(SPOKE_OPERATING_CASH_TOP_UP), true, 0);

        _onRobinhood();
        _openSpokeUniswapPosition();
        robinhoodRouter = _deployRouter(RH_V4_POOL_MANAGER, RH_WETH, RH_USDG, 10_000e18, 50_000_000e6);
        _generateFees(
            robinhoodRouter, _spokePoolKey(), RH_V4_STATE_VIEW, _center(RH_V4_STATE_VIEW, RH_WETH_USDG_POOL_ID)
        );
        _step("W5  spoke swap, V4 position, fees (report lag)", 0, false, 0);
        _report();
        _step("W6  report delivered", 0, true, 0);

        // Hub income, fee split, entry, income withdrawal.
        _onArbitrum();
        vm.startPrank(manager);
        hubSpoke.collectIncome(hubUniswap, hubUniswapPosition);
        hubSpoke.collectIncome(hubAave, hubAavePosition);
        vm.stopPrank();
        _step("W7  hub income collected", 0, true, 0);
        vm.startPrank(keeper);
        hubSpoke.forwardIncomeToCoreVault(ARB_USDC);
        hubSpoke.forwardIncomeToCoreVault(ARB_WETH);
        vm.stopPrank();
        _step("W8  hub income forwarded, fees split", 0, true, 0);
        _brunoDeposits();
        _step("W9  Bruno deposits 11,000", 0, true, 0);
        vm.startPrank(ana);
        core.withdrawIncome(ARB_USDC);
        core.withdrawIncome(ARB_WETH);
        vm.stopPrank();
        _step("W10 Ana withdraws her income", 0, true, 0);

        // Spoke income home as Income, principal home as Principal.
        _onRobinhood();
        vm.startPrank(manager);
        spokeVault.collectIncome(spokeUniswap, spokeUniswapPosition);
        spokeVault.swapCollectedIncome(
            spokeUniswap, RH_WETH_USDG_POOL_ID, RH_WETH, spokeVault.collectedIncome(RH_WETH), 0, _swapParams()
        );
        vm.stopPrank();
        _step("W11 spoke income collected and swapped to USDG", 0, false, 0);
        _onRobinhood();
        uint256 income = spokeVault.collectedIncome(RH_USDG);
        uint256 incomeOut = income - income * MAX_BRIDGE_FEE_BPS / 10_000;
        (bytes32 homeIncome, LiveRelayData memory incomeRelay) =
            _sendToHub(income, TransferKind.Income, _quote(incomeOut));
        uint256 incomeIndex = _track(false, homeIncome, incomeRelay);
        (bytes32 homePrincipal, LiveRelayData memory principalRelay) =
            _sendToHub(500e6, TransferKind.Principal, _quote(500e6 - 0.2e6));
        uint256 principalIndex = _track(false, homePrincipal, principalRelay);
        // An Income transfer in flight home is in no base: out of the spoke's collected bucket, out of Share Assets
        // (DEC-092) and in no hub bucket until it arrives (report 02 I-04).
        _step("W12 sends home: Income and Principal 500", 0, false, int256(incomeOut));

        _onArbitrum();
        _advance(2 minutes);
        _fillOnArbitrum(incomeRelay, relayer);
        _fillOnArbitrum(principalRelay, relayer);
        tracked[incomeIndex].filled = true;
        tracked[principalIndex].filled = true;
        // Both arrivals are held apart until a report lists them (OQ-01); the Principal 500 is still in the spoke's
        // last report too, so the books count it twice until the next report (report lag plus hold-apart).
        _step("W13 both filled on Arbitrum, held apart", -int256(500e6), true, 0);
        assertEq(core.shareAssets(), _sumOfBuckets(), "EndToEndBase._sumOfBuckets agrees here too");
        _report();
        assertEq(core.unmatchedArrivals(), 0, "matched");
        _step("W14 report lists them: credited", 0, true, 0);

        // Payouts.
        _phase8AnaStandardPayout();
        _step("W15 Ana's Standard Payout of 3,000", 0, true, 0);
        _phase9BrunoInstantPayoutWithUnwind();
        _step("W16 Bruno's Instant Payout with unwind", 0, true, 0);
        _report();
        _depositAs(carol, 5000e6);
        _step("W17 fresh report, Carol deposits 5,000", 0, true, 0);

        // Refund, hub to spoke: a send nobody fills.
        (bytes32 lost, LiveRelayData memory lostRelay) = _sendToSpoke(400e6, _quote(400e6 - 0.16e6));
        uint256 lostIndex = _track(true, lost, lostRelay);
        _step("W18 send 400 to Robinhood, never filled", 0, true, 0);
        _onRobinhood();
        _advance(uint256(lostRelay.fillDeadline) + 60 - block.timestamp);
        _report();
        vm.prank(stranger);
        core.attestExpiry(lost);
        _step("W19 expiry attested (report path)", 0, true, 0);
        _acrossRefund(ARB_ACROSS_SPOKE_POOL, ARB_USDC, tracked[lostIndex].escrow, lostRelay.inputAmount);
        tracked[lostIndex].refunded = true;
        // The escrow holds the full input; the books still count the output until recognition: the bridge fee.
        int256 fee = int256(lostRelay.inputAmount - lostRelay.outputAmount);
        _step("W20 Across refund lands in the hub escrow", fee, true, fee);
        vm.prank(stranger);
        core.recognizeRefund(lost);
        tracked[lostIndex].recognized = true;
        _step("W21 refund recognized on the hub", 0, true, 0);

        // Refund, spoke to hub: a send home nobody fills (report 02 H-02 window).
        _onRobinhood();
        (bytes32 back, LiveRelayData memory backRelay) =
            _sendToHub(300e6, TransferKind.Principal, _quote(300e6 - 0.12e6));
        uint256 backIndex = _track(false, back, backRelay);
        _report();
        _step("W22 send home 300, never filled, listed", 0, true, 0);
        _onRobinhood();
        _advance(uint256(backRelay.fillDeadline) + ROBINHOOD_MAX_REPORT_AGE + 1 - block.timestamp);
        _report();
        // S-3: the spoke keeps listing the send home past `fillDeadline + maxReportAge` (on e5c778a: +299.88 here).
        assertEq(_latest().inFlightToHub.length, 1, "S-3: still listed");
        _step("W23 past fillDeadline + maxReportAge: still listed", 0, true, 0);
        assertEq(core.shareAssets(), _sumOfBuckets(), "EndToEndBase._sumOfBuckets agrees with Share Assets");
        _onRobinhood();
        _acrossRefund(RH_ACROSS_SPOKE_POOL, RH_USDG, tracked[backIndex].escrow, backRelay.inputAmount);
        tracked[backIndex].refunded = true;
        // The escrow holds the full input while the hub counts the listed output: the bridge fee, until a report
        // recognizes the landed refund (S-3: `report()` does it), so D fresh is 0 (on e5c778a: +300.00 both).
        int256 backFee = int256(backRelay.inputAmount - backRelay.outputAmount);
        _step("W24 Across refund lands in the spoke escrow", backFee, true, 0);
        _onRobinhood();
        vm.prank(stranger);
        spokeVault.recognizeRefund(back);
        tracked[backIndex].recognized = true;
        _report();
        _step("W25 refund recognized on the spoke, reported", 0, true, 0);

        // A donation reaches no base and is swept.
        _onArbitrum();
        deal(ARB_USDC, address(core), IERC20(ARB_USDC).balanceOf(address(core)) + DONATION);
        _step("W26 donation to the Core Vault", int256(DONATION), true, int256(DONATION));
        core.sweepExcess(ARB_USDC);
        _step("W27 donation swept", 0, true, 0);

        // S-3 residual: a refund that lands after `fillDeadline + HUB_BOUND_RETENTION` (Across measured 53 to 107 min;
        // the 3 days are the margin). The spoke stops listing the send home and its sweep no longer sees the id.
        (bytes32 late, LiveRelayData memory lateRelay) =
            _sendToHub(200e6, TransferKind.Principal, _quote(200e6 - 0.08e6));
        uint256 lateIndex = _track(false, late, lateRelay);
        _report();
        _step("W28 send home 200, never filled, listed", 0, true, 0);
        _onRobinhood();
        _advance(uint256(lateRelay.fillDeadline) + ReportCodec.HUB_BOUND_RETENTION + 1 - block.timestamp);
        _report();
        assertEq(_latest().inFlightToHub.length, 0, "past the retention: no longer listed");
        int256 lateGap = int256(lateRelay.outputAmount);
        _step("W29 past fillDeadline + HUB_BOUND_RETENTION: dropped", lateGap, true, lateGap);
        _onRobinhood();
        _acrossRefund(RH_ACROSS_SPOKE_POOL, RH_USDG, tracked[lateIndex].escrow, lateRelay.inputAmount);
        tracked[lateIndex].refunded = true;
        // A fresh report does not recognize it (the id left the list); only a `recognizeRefund` call does.
        int256 lateIn = int256(lateRelay.inputAmount);
        _step("W30 late refund lands in the spoke escrow", lateIn, true, lateIn);
        _onRobinhood();
        vm.prank(stranger);
        spokeVault.recognizeRefund(late);
        _report();
        _step("W31 late refund recognized, reported", 0, true, 0);

        _printTable();
    }

    /// @dev Relay data of a hub-to-spoke transit, from the Core Vault's books and the phase-4 message.
    function _relayOfHubTransit(bytes32 id) internal view returns (LiveRelayData memory r) {
        Transit memory t = core.transit(id);
        r.depositor = bytes32(uint256(uint160(t.escrow)));
        r.recipient = bytes32(uint256(uint160(address(spokeVault))));
        r.inputToken = bytes32(uint256(uint160(ARB_USDC)));
        r.outputToken = bytes32(uint256(uint160(RH_USDG)));
        r.inputAmount = t.amountSent;
        r.outputAmount = t.amountToArrive;
        r.originChainId = ARBITRUM;
        r.depositId = uint256(t.bridgeRef);
        r.fillDeadline = t.fillDeadline;
        r.message = acrossMessage;
    }
}
