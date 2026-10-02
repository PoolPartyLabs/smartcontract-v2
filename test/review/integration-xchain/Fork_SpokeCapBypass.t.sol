// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {XChainBase, LiveRelayData, BatchRelayer} from "./XChainBase.sol";

/// @notice Review port of integration-xchain `Fork_SpokeCapBypass`: consolidated H-03 (report 03 H-01, register S-13),
///         on the factory-created fund, both forks, real fills (live `fillRelay` on the Robinhood SpokePool), real
///         Wormhole delivery (13-of-19 signatures verified by the real Arbitrum Core). On `e5c778a` an expiry attested
///         on time alone released `inFlightSent` of a transit that had arrived: 11,985.20 USDG sat on a spoke capped at
///         4,000 (variant A) and 12,753.20 with reports flowing and a fourth send accepted (variant B).
/// @dev Adaptation to the fix branch, interface only: the spoke's first report is delivered before the first send
///      (S-14); sends carry no exclusivity (S-9; since DEC-158 / DEC-162 the Across adapter fixes every term), so in
///      variant B the manager's relayer fills the genuine send because it is first, not because it is the only one
///      allowed.
contract Fork_SpokeCapBypass is XChainBase {
    uint256 internal constant SEND = SPOKE_CAP; // 4,000 USDC, the whole cap of the project's Mandate
    uint256 internal constant ARRIVES = SPOKE_CAP - BRIDGE_FEE; // 3,996.77 USDG (DEC-162: 0.08% plus 0.03)

    function _setUpFund() internal {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits(); // 10,000 USDC
        _depositAs(bruno, 20_000e6);
        _report(); // S-14: the spoke's first report, before the first send
    }

    /// @notice FIXED. Variant A: after the first report no report of the spoke is accepted. The transit arrives (real
    ///         fill) and its expiry is attested through the time path; the cap now stays held (S-13), so the second
    ///         cap-sized send is refused. Mints close once the first report ages out (on e5c778a a spoke without any
    ///         accepted report was skipped and mints stayed open, L-03).
    function test_REVIEW_H03_withheldReportsKeepTheCapHeldAfterATimeAttestation() public {
        _setUpFund();
        (bytes32 id, LiveRelayData memory relay) = _sendToSpoke(SEND);
        _fillOnRobinhood(relay, relayer); // the live pool pays the Spoke Vault and calls its handler
        assertEq(SpokeVaultView(address(spokeVault)).arrivals(id), ARRIVES, "credited by id on the spoke");

        _onArbitrum();
        Transit memory t = core.transit(id);
        _advance(uint256(t.fillDeadline) + ROBINHOOD_MAX_REPORT_AGE + 1 - block.timestamp);
        vm.prank(stranger);
        core.attestExpiry(id); // time path: no report needed
        assertEq(uint8(core.transit(id).state), uint8(TransitState.ExpiryAttested));
        assertTrue(core.spokeCapHeld(id), "S-13: time path, the cap stays held");
        assertEq(_capUsed(), SEND, "the arrived transit still uses the cap");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeCapExceeded.selector, 0, SEND, SEND, SPOKE_CAP));
        core.sendToSpoke(0, SEND, 0, "");

        address carol = makeAddr("carol");
        _refreshEthUsdFeed();
        deal(ARB_USDC, carol, 1000e6);
        vm.startPrank(carol);
        IERC20(ARB_USDC).approve(address(core), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.StaleSpokeReport.selector, 0));
        core.deposit(1000e6, 0);
        vm.stopPrank();

        // Reporting resumes: the arrival is confirmed and the held cap moves to the spoke's value, counted once.
        _report();
        assertEq(uint8(core.transit(id).state), uint8(TransitState.ArrivalConfirmed));
        assertFalse(core.spokeCapHeld(id));
        (uint256 spokeValue, uint256 inFlightSent,,) = core.spokeCapUsage(0);
        _log("spokeValue after the first report since the send (USDC)", spokeValue);
        assertEq(inFlightSent, 0);
        assertEq(spokeValue, ARRIVES - SPOKE_OPERATING_CASH_TOP_UP, "priced 1:1, Operating Cash outside");
    }

    /// @notice FIXED. Variant B: reports flow. The manager cannot name a relayer (S-9, DEC-158: a quote passed to the
    ///         Across adapter is refused); without exclusivity the manager's relayer contract
    ///         still fills the genuine send first and, in the same Robinhood transaction, 256 of the manager's own
    ///         one-USDG deposits (fresh ids, real deposits on Arbitrum), so the genuine id leaves the 256-id window
    ///         before any report is built. The time-path attestation now keeps the cap (S-13), and the next cap-sized
    ///         send is refused: the spoke never holds more than one cap of the fund's sends.
    function test_REVIEW_H03_evictedArrivalKeepsItsCapWhileReportsFlow() public {
        _setUpFund();
        _onRobinhood();
        BatchRelayer mine = new BatchRelayer(manager);

        _onArbitrum();
        vm.prank(manager);
        vm.expectRevert(AcrossBridgeAdapter.QuotesNotSupported.selector);
        core.sendToSpoke(0, SEND, 0, abi.encode(ARRIVES, address(mine), uint32(21_600)));

        (bytes32 id, LiveRelayData memory relay) = _sendToSpoke(SEND);
        LiveRelayData[] memory dust = _managerDustDeposits(256, address(mine));
        LiveRelayData[] memory all = new LiveRelayData[](257);
        all[0] = relay;
        for (uint256 i; i < 256; ++i) {
            all[i + 1] = dust[i];
        }
        _onRobinhood();
        deal(RH_USDG, address(mine), ARRIVES + 256e6);
        vm.prank(manager);
        mine.fillAll(RH_ACROSS_SPOKE_POOL, RH_USDG, all, ARBITRUM); // one transaction

        _report(); // the keeper keeps reporting
        ReportCodec.Report memory r = _latest();
        assertEq(r.arrivedTransits.length, 256, "full window");
        for (uint256 i; i < r.arrivedTransits.length; ++i) {
            assertTrue(r.arrivedTransits[i].transitId != id, "the genuine id never reached a report");
        }
        assertEq(uint8(core.transit(id).state), uint8(TransitState.Sent), "never confirmed");

        _onArbitrum();
        Transit memory t = core.transit(id);
        _advance(uint256(t.fillDeadline) + ROBINHOOD_MAX_REPORT_AGE + 1 - block.timestamp);
        _report(); // still reporting, fresh
        vm.prank(stranger);
        core.attestExpiry(id);
        assertTrue(core.spokeCapHeld(id), "S-13: time path, the cap stays held");
        uint256 used = _capUsed();
        _log("cap used after the time-path attestation (USDC)", used);
        assertGe(used, SEND, "the arrived value is still in a term of the cap");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeCapExceeded.selector, 0, used, SEND, SPOKE_CAP));
        core.sendToSpoke(0, SEND, 0, "");
        _onRobinhood();
        _log("spoke Unallocated Balance (USDG)", spokeVault.unallocatedBalance(RH_USDG));
    }

    /// @dev Manager: `n` real one-USDG Across deposits on Arbitrum to the Spoke Vault with fresh ids, exclusive to its
    ///      relayer (a private deposit, not a vault send); returns their relay data.
    function _managerDustDeposits(uint256 n, address relayer_) internal returns (LiveRelayData[] memory relays) {
        _onArbitrum();
        deal(ARB_USDC, manager, IERC20(ARB_USDC).balanceOf(manager) + n * 1e6);
        vm.startPrank(manager);
        IERC20(ARB_USDC).approve(ARB_ACROSS_SPOKE_POOL, n * 1e6);
        vm.recordLogs();
        for (uint256 i; i < n; ++i) {
            IAcrossSpokePool(ARB_ACROSS_SPOKE_POOL)
                .depositV3(
                    manager,
                    address(spokeVault),
                    ARB_USDC,
                    RH_USDG,
                    1e6,
                    1e6,
                    ROBINHOOD,
                    relayer_,
                    uint32(block.timestamp),
                    uint32(block.timestamp) + 21_600,
                    21_600,
                    TransitMessage.encode(fundId, ARBITRUM, _freshId(), TransferKind.Principal)
                );
        }
        vm.stopPrank();
        relays = _relaysFrom(vm.getRecordedLogs(), ARB_ACROSS_SPOKE_POOL, ARBITRUM);
        require(relays.length == n, "deposits");
    }
}

interface SpokeVaultView {
    function arrivals(bytes32 transitId) external view returns (uint256);
}
