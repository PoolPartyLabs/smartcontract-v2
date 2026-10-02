// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {XChainBase, LiveRelayData} from "./XChainBase.sol";

/// @notice Review port of integration-xchain `Fork_RelayerAndOperatingCash`: consolidated M-01 (report 03 M-01,
///         register S-9: the manager as exclusive relayer at the Mandate's maximum bridge fee, and the 100% bridge-fee
///         Mandate the factory accepted) against the live SpokePools in both directions, and H-08 (reports 02 H-01, 04
///         H-02, 05 H-02, register S-5: Operating Cash with no bound and no outflow) on the factory-created fund.
/// @dev Adaptation to the fix branch, interface only: the spoke's first report is delivered before the first send
///      (S-14); a quote carries no exclusivity (S-9).
contract Fork_RelayerAndOperatingCash is XChainBase {
    uint256 internal constant ARRIVES = BRIDGE_AMOUNT - BRIDGE_FEE;

    address internal managerRelayer = makeAddr("managerRelayer");

    // -----------------------------------------------------------------------------------------------------------------
    // M-01 (report 03 M-01; S-9)
    // -----------------------------------------------------------------------------------------------------------------

    /// @notice PARTIAL. Exclusivity is refused on both vaults, so the live pools would take a stranger's fill; but no
    ///         rule keeps the manager's relayer from filling the fund's own sends when it is first, and Across then
    ///         repays it the input. At the scripts' 4 bps bound the round trip still hands it 3.19536 USDC, as on
    ///         e5c778a (3.195); what changed is that the fill is contested.
    function test_POC_REVIEW_M01_managerRelayerStillKeepsTheFeeWhenItFillsFirst() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _report(); // S-14
        uint256 assets = core.shareAssets();

        _onArbitrum();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ExclusiveRelayerNotAllowed.selector, managerRelayer));
        core.sendToSpoke(0, BRIDGE_AMOUNT, 0, _exclusiveQuote(ARRIVES, managerRelayer));
        (, LiveRelayData memory out) = _sendToSpoke(BRIDGE_AMOUNT, _quote(ARRIVES));
        assertEq(out.exclusiveRelayer, bytes32(0));
        assertEq(out.exclusivityDeadline, 0);
        assertEq(assets - core.shareAssets(), BRIDGE_FEE, "Share Assets drop by the fee at once");

        // A stranger's fill would now be accepted by the live pool; the manager's relayer is simply first.
        _onRobinhood();
        uint256 snap = vm.snapshotState();
        _fill(RH_ACROSS_SPOKE_POOL, RH_USDG, out, stranger);
        vm.revertToState(snap);
        _fillOnRobinhood(out, managerRelayer);
        // Across repays the filler the input amount on its repayment chain (relayer-refund leaf; LP fee not modelled).
        _onArbitrum();
        _acrossRefund(ARB_ACROSS_SPOKE_POOL, ARB_USDC, managerRelayer, out.inputAmount);
        assertEq(IERC20(ARB_USDC).balanceOf(managerRelayer), BRIDGE_AMOUNT, "repaid 4,000 USDC for 3,998.40 USDG");
        _report();

        // Spoke to hub: the same on the way home.
        _onRobinhood();
        uint256 all = spokeVault.unallocatedBalance(RH_USDG);
        uint256 maxFee = all * MAX_BRIDGE_FEE_BPS / 10_000;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.ExclusiveRelayerNotAllowed.selector, managerRelayer));
        spokeVault.sendToHub(all, TransferKind.Principal, 0, _exclusiveQuote(all - maxFee, managerRelayer));
        (, LiveRelayData memory home) = _sendToHub(all, TransferKind.Principal, _quote(all - maxFee));
        _onArbitrum();
        _advance(2 minutes);
        _fillOnArbitrum(home, managerRelayer);
        _report(); // credited to Idle as listed
        assertEq(core.unmatchedArrivals(), 0);
        _onRobinhood();
        _acrossRefund(RH_ACROSS_SPOKE_POOL, RH_USDG, managerRelayer, home.inputAmount);

        _onArbitrum();
        uint256 captured = BRIDGE_FEE + maxFee;
        _log("fees the manager's relayer kept over the round trip", captured);
        _log("Share Assets lost over the round trip", assets - core.shareAssets());
        // The other 10 USDG are the spoke's Operating Cash top-up at the first arrival (DEC-096), not a relayer gain.
        assertApproxEqAbs(assets - core.shareAssets(), captured + SPOKE_OPERATING_CASH_TOP_UP, 1);
        assertEq(captured, 3_195_360);
    }

    /// @notice FIXED. The 10,000 bps Mandate the real factory created on e5c778a (one send moved 3,999.999999 out of
    ///         Share Assets to the manager's relayer) now reverts `BpsAboveMax(10000, 100)`; at the 100 bps cap one
    ///         4,000 send can give a relayer at most 40.
    function test_REVIEW_M01_bridgeFeeBoundCappedAtOnePercent() public {
        _createForks();
        FundPlan memory plan = _plan();
        plan.maxBridgeFeeBps = 10_000;
        (FundFactory factory,, Mandate memory m, IFundFactory.HubParams memory p) = _hubInputs(plan);
        _fundManagerSeed(ARB_USDC, manager, address(factory), p.seedAmount);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.BpsAboveMax.selector, 10_000, MandateLib.MAX_BRIDGE_FEE_BPS));
        factory.createFund(m, p);

        // The highest bound a Mandate may now carry.
        plan.maxBridgeFeeBps = MandateLib.MAX_BRIDGE_FEE_BPS;
        _createHub(plan);
        _createSpokeFrom(plan);
        _phase2AnaDeposits();
        _report(); // S-14
        uint256 assets = core.shareAssets();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BridgeFeeAboveMax.selector, 40e6 + 1, 40e6));
        core.sendToSpoke(0, BRIDGE_AMOUNT, 0, _quote(BRIDGE_AMOUNT - 40e6 - 1));
        _sendToSpoke(BRIDGE_AMOUNT, _quote(BRIDGE_AMOUNT - 40e6));
        assertEq(assets - core.shareAssets(), 40e6, "at most 1% of the send leaves Share Assets");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // H-08 (reports 02 H-01, 04 H-02, 05 H-02; S-5 open)
    // -----------------------------------------------------------------------------------------------------------------

    /// @notice STILL_PRESENT (S-5 open; one-way since the interim release verb was removed, S-63). One parameter change and a 1-unit allocation move all Free Idle but one unit into
    ///         hub Operating Cash; a reserved Standard request is then paid at the collapsed price.
    function test_POC_REVIEW_H08_hubOperatingCashSinksFreeIdle() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        uint256 brunoShares = _depositAs(bruno, 10_000e6);
        vm.prank(bruno);
        core.requestPayout(5000e6, ICoreVault.PayoutMode.Standard);
        uint256 free = core.freeIdle();
        uint256 assets = core.shareAssets();

        vm.prank(manager);
        core.setOperatingCashParameters(type(uint256).max, free - 1);
        vm.prank(manager);
        core.allocateToHubSpokeVault(1);
        assertEq(core.operatingCash(), free - 1, "all Free Idle but one unit moved to Operating Cash");
        assertEq(core.freeIdle(), 0);
        assertEq(assets - core.shareAssets(), free - 1, "out of Share Assets");
        assertEq(core.sweepExcess(ARB_USDC), 0, "ledger, so never swept");
        vm.prank(manager);
        core.setOperatingCashParameters(0, 0);
        assertEq(core.operatingCash(), free - 1, "resetting the parameters returns nothing");

        _advance(72 hours);
        uint256 before = IERC20(ARB_USDC).balanceOf(bruno);
        vm.prank(bruno);
        ICoreVault.PayoutReceipt memory receipt = core.claimPayout("");
        _log("Free Idle sunk into hub Operating Cash", free - 1);
        _log("shares burned for the reserved 5,000", receipt.sharesBurned);
        _log("Bruno's shares before", brunoShares);
        _log("Bruno received", IERC20(ARB_USDC).balanceOf(bruno) - before);
        assertEq(receipt.sharesBurned, brunoShares, "paid at the collapsed price: all his shares burned");

        // No verb returns it (the interim release was removed as S-63): the sink is one-way until a cap is ruled.
        uint256 cash = core.operatingCash();
        vm.prank(manager);
        (bool released,) = address(core).call(abi.encodeWithSignature("releaseOperatingCash(uint256)", cash));
        assertFalse(released, "no release verb");
        assertEq(core.operatingCash(), cash);
    }

    /// @notice STILL_PRESENT (S-5 open). A stranger's real 1 USDC Across deposit and 1 USDG fill run the spoke's
    ///         top-up, which moves the whole principal into spoke Operating Cash; the next report drops it from Share
    ///         Assets and from the Spoke Cap, so the next full tranche can follow and sink too.
    function test_POC_REVIEW_H08_spokeOperatingCashSinksThePrincipalAndFreesTheCap() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _depositAs(bruno, 10_000e6);
        _report(); // S-14
        (, LiveRelayData memory out) = _sendToSpoke(BRIDGE_AMOUNT, _quote(ARRIVES));
        _fillOnRobinhood(out, relayer);
        _report();
        uint256 assets = core.shareAssets();
        _onRobinhood();
        uint256 principal = spokeVault.unallocatedBalance(RH_USDG);

        vm.prank(manager);
        spokeVault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        _strangerOneUsdgArrival(); // a stranger's real 1 USDG Across fill runs the top-up
        assertEq(spokeVault.unallocatedBalance(RH_USDG), 0, "all Unallocated Balance moved");
        assertEq(spokeVault.operatingCash(), SPOKE_OPERATING_CASH_TOP_UP + principal + 1e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.InsufficientUnallocatedBalance.selector, RH_USDG, 0, 1e6));
        spokeVault.sendToHub(1e6, TransferKind.Principal, 0, _quote(1e6));
        assertEq(spokeVault.sweepExcess(RH_USDG), 0, "ledger, never swept");

        _report();
        _log("Share Assets before", assets);
        _log("Share Assets after the next report", core.shareAssets());
        assertApproxEqAbs(assets - core.shareAssets(), principal, 1e6, "the spoke principal left Share Assets");
        assertEq(_capUsed(), 0, "and the Spoke Cap reads empty");

        // The manager sends the next full tranche; its own arrival sinks it too.
        (, LiveRelayData memory again) = _sendToSpoke(BRIDGE_AMOUNT, _quote(ARRIVES));
        _fillOnRobinhood(again, relayer);
        _report();
        _onRobinhood();
        _log("spoke Operating Cash (USDG)", spokeVault.operatingCash());
        assertGt(spokeVault.operatingCash(), 2 * ARRIVES - 1e6, "twice the cap sunk");
        _onArbitrum();
        _log("Share Assets now", core.shareAssets());
        assertEq(_capUsed(), 0);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // S-63: the S-5 interim exit turned the sink into a lever; the verb is gone
    // -----------------------------------------------------------------------------------------------------------------

    /// @notice FIXED (S-63). With the interim `releaseOperatingCash` the manager sank Free Idle into hub Operating Cash,
    ///         leaving 0.01 USDC of Share Assets, let an ally deposit 10,000 at that price and released the cash back:
    ///         the ally was paid 19,900.11 and Ana kept 0.02 of her 9,975. With the verb removed the sink cannot be
    ///         undone, so the ally buys only its own deposit back.
    function test_REVIEW_S63_sinkWithoutReleaseHandsTheAllyNothing() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits(); // Ana: 9,975 shares, Share Assets 9,975
        address ally = makeAddr("managersAlly");

        uint256 free = core.freeIdle();
        vm.startPrank(manager);
        core.setOperatingCashParameters(type(uint256).max, free - 10_000);
        core.allocateToHubSpokeVault(1);
        core.setOperatingCashParameters(0, 0);
        vm.stopPrank();
        assertEq(core.shareAssets(), 10_000, "0.01 USDC of Share Assets left");

        uint256 allyShares = _depositAs(ally, 10_000e6);
        uint256 cash = core.operatingCash();
        vm.prank(manager);
        (bool released,) = address(core).call(abi.encodeWithSignature("releaseOperatingCash(uint256)", cash));
        assertFalse(released, "no release verb");

        uint256 allyValue = ShareMath.usdcFor(allyShares, core.sharePrice());
        _log("ally's value after its 10,000 deposit", allyValue);
        assertLe(allyValue, 10_000e6, "the ally owns no more than it paid");
    }

    /// @notice FIXED (S-63). With the interim release, three cap-sized tranches sunk on arrival and then released left
    ///         11,995.20 USDC of spoke value on a 4,000 Spoke Cap. Without it the sunk tranches never come back into
    ///         the spoke's principal.
    function test_REVIEW_S63_spokeSinkCanNoLongerBeReleasedAboveTheCap() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _depositAs(bruno, 20_000e6);
        _report(); // S-14
        _onRobinhood();
        vm.prank(manager);
        spokeVault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        _onArbitrum();
        (, LiveRelayData memory out) = _sendToSpoke(SPOKE_CAP, _quote(SPOKE_CAP - BRIDGE_FEE));
        _fillOnRobinhood(out, relayer);
        _report();
        _onRobinhood();
        uint256 cash = spokeVault.operatingCash();
        vm.startPrank(manager);
        spokeVault.setOperatingCashParameters(0, 0);
        (bool released,) = address(spokeVault).call(abi.encodeWithSignature("releaseOperatingCash(uint256)", cash));
        vm.stopPrank();
        assertFalse(released, "no release verb");
        _report();
        (uint256 spokeValue,,, uint256 cap) = core.spokeCapUsage(0);
        assertLe(spokeValue, cap, "the spoke never holds value above its cap");
    }

    /// @dev A stranger deposits 1 USDC on Arbitrum to the Spoke Vault with a fresh id and fills it on Robinhood.
    function _strangerOneUsdgArrival() internal {
        _onArbitrum();
        deal(ARB_USDC, stranger, 1e6);
        vm.startPrank(stranger);
        IERC20(ARB_USDC).approve(ARB_ACROSS_SPOKE_POOL, 1e6);
        vm.recordLogs();
        IAcrossSpokePool(ARB_ACROSS_SPOKE_POOL)
            .depositV3(
                stranger,
                address(spokeVault),
                ARB_USDC,
                RH_USDG,
                1e6,
                1e6,
                ROBINHOOD,
                address(0),
                uint32(block.timestamp),
                uint32(block.timestamp) + 21_600,
                0,
                TransitMessage.encode(fundId, ARBITRUM, _freshId(), TransferKind.Principal)
            );
        vm.stopPrank();
        LiveRelayData memory r = _one(_relaysFrom(vm.getRecordedLogs(), ARB_ACROSS_SPOKE_POOL, ARBITRUM));
        _fillOnRobinhood(r, stranger);
    }
}
