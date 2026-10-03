// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {XChainBase, LiveRelayData} from "./XChainBase.sol";

/// @notice Review port of integration-xchain `Fork_RelayerAndOperatingCash`: consolidated M-01 (report 03 M-01,
///         register S-9: the manager as exclusive relayer at the Mandate's maximum bridge fee, and the 100% bridge-fee
///         Mandate the factory accepted) against the live SpokePools in both directions, and H-08 (reports 02 H-01, 04
///         H-02, 05 H-02, register S-5: Operating Cash with no bound and no outflow) on the factory-created fund.
/// @dev Adaptation to the fix branch, interface only: the spoke's first report is delivered before the first send
///      (S-14); since DEC-158 / DEC-162 the Across adapter fixes every term of a send (no exclusivity, the amount to
///      arrive by its fee rule; the manager passes no bridge parameter), so no Mandate bound or manager input sets
///      what a relayer keeps.
contract Fork_RelayerAndOperatingCash is XChainBase {
    uint256 internal constant ARRIVES = BRIDGE_AMOUNT - BRIDGE_FEE;

    address internal managerRelayer = makeAddr("managerRelayer");

    // -----------------------------------------------------------------------------------------------------------------
    // M-01 (report 03 M-01; S-9)
    // -----------------------------------------------------------------------------------------------------------------

    /// @notice PARTIAL, bounded by DEC-162. The manager can name no relayer and no amount (a quote to the hub's Across
    ///         adapter is refused; `sendToHub` takes no bridge parameter), so the live pools take a stranger's
    ///         fill; no rule keeps the manager's relayer from filling the fund's own sends when it is first, and Across
    ///         then repays it the input. What it keeps is the adapter's rule fee (0.08% plus 0.03 per send), never a
    ///         gap the manager chose.
    function test_POC_REVIEW_M01_managerRelayerStillKeepsTheFeeWhenItFillsFirst() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _report(); // S-14
        uint256 assets = core.shareAssets();

        _onArbitrum();
        vm.prank(manager);
        vm.expectRevert(AcrossBridgeAdapter.QuotesNotSupported.selector);
        core.sendToSpoke(0, BRIDGE_AMOUNT, 0, abi.encode(ARRIVES, managerRelayer, uint32(21_600)));
        (, LiveRelayData memory out) = _sendToSpoke(BRIDGE_AMOUNT);
        assertEq(out.outputAmount, ARRIVES, "the adapter's amount to arrive");
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
        assertEq(IERC20(ARB_USDC).balanceOf(managerRelayer), BRIDGE_AMOUNT, "repaid 4,000 USDC for 3,996.77 USDG");
        _report();

        // Spoke to hub: the same on the way home. The manager has no quote to pass (no amount out, no relayer of its
        // own): the deposit carries the adapter's terms.
        _onRobinhood();
        uint256 all = spokeVault.unallocatedBalance(RH_USDG);
        vm.recordLogs();
        vm.prank(manager);
        spokeVault.sendToHub(all, TransferKind.Principal, 0);
        LiveRelayData memory home = _one(_relaysFrom(vm.getRecordedLogs(), RH_ACROSS_SPOKE_POOL, ROBINHOOD));
        assertEq(home.exclusiveRelayer, bytes32(0), "no exclusive relayer");
        assertEq(home.exclusivityDeadline, 0);
        uint256 homeFee = _ruleFee(all);
        assertEq(home.outputAmount, all - homeFee, "the adapter's amount");
        _onArbitrum();
        _advance(2 minutes);
        _fillOnArbitrum(home, managerRelayer);
        _report(); // credited to Idle as listed
        assertEq(core.unmatchedArrivals(), 0);
        _onRobinhood();
        _acrossRefund(RH_ACROSS_SPOKE_POOL, RH_USDG, managerRelayer, home.inputAmount);

        _onArbitrum();
        uint256 captured = BRIDGE_FEE + homeFee;
        _log("fees the manager's relayer kept over the round trip", captured);
        _log("Share Assets lost over the round trip", assets - core.shareAssets());
        // The other 10 USDG are the spoke's Operating Cash top-up at the first arrival (DEC-096), not a relayer gain.
        assertApproxEqAbs(assets - core.shareAssets(), captured + SPOKE_OPERATING_CASH_TOP_UP, 1);
        assertEq(captured, _ruleFee(BRIDGE_AMOUNT) + _ruleFee(all), "the rule's fee each way, nothing more");
    }

    /// @notice FIXED. The 10,000 bps Mandate the real factory created on e5c778a (one send moved 3,999.999999 out of
    ///         Share Assets to the manager's relayer) cannot be written any more: since DEC-162 the Across adapter
    ///         prices every send and Mandate v2 removed the Mandate bound (DEC-156), so a 4,000 send gives a relayer
    ///         the adapter's 3.23, not 40 or 3,999.999999.
    function test_REVIEW_M01_bridgeFeeBoundCappedAtOnePercent() public {
        _createForks();
        FundPlan memory plan = _plan();
        _createHub(plan);
        _createSpokeFrom(plan);
        _phase2AnaDeposits();
        _report(); // S-14
        uint256 assets = core.shareAssets();
        _sendToSpoke(BRIDGE_AMOUNT);
        assertEq(assets - core.shareAssets(), BRIDGE_FEE, "the adapter's fee leaves Share Assets, not the bound");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // H-08 (reports 02 H-01, 04 H-02, 05 H-02; S-5 open)
    // -----------------------------------------------------------------------------------------------------------------

    /// @notice STILL_PRESENT (S-5 open; one-way since the interim release verb was removed, S-63). One parameter change and a 1-unit allocation move all Free Idle but one unit into
    ///         hub Operating Cash; a reserved Standard request is then paid at the collapsed price.
    function test_REGRESSION_REVIEW_H08_hubOperatingCashSinksFreeIdle() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        core.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(core.operatingCash(), 0);
    }

    /// @notice STILL_PRESENT (S-5 open). A stranger's real 1 USDC Across deposit and 1 USDG fill run the spoke's
    ///         top-up, which moves the whole principal into spoke Operating Cash; the next report drops it from Share
    ///         Assets and from the Spoke Cap, so the next full tranche can follow and sink too.
    function test_REGRESSION_REVIEW_H08_spokeOperatingCashSinksThePrincipalAndFreesTheCap() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _onRobinhood();
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        spokeVault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(spokeVault.operatingCash(), 0);
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
        _phase2AnaDeposits();
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        core.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(core.operatingCash(), 0);
    }

    /// @notice FIXED (S-63). With the interim release, three cap-sized tranches sunk on arrival and then released left
    ///         11,995.20 USDC of spoke value on a 4,000 Spoke Cap. Without it the sunk tranches never come back into
    ///         the spoke's principal.
    function test_REVIEW_S63_spokeSinkCanNoLongerBeReleasedAboveTheCap() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _onRobinhood();
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        spokeVault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(spokeVault.operatingCash(), 0);
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
