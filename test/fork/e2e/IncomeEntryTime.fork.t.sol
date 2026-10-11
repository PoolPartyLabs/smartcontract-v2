// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {VaaLib, VaaBody, VaaEnvelope} from "wormhole-sdk/libraries/VaaLib.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {EndToEndScenario} from "./EndToEnd.t.sol";

contract IncomeEntryTimeForkTest is EndToEndScenario {
    using AdvancedWormholeOverride for ICoreBridge;

    function test_DEC145_realReportCycleExcludesLateEntryOnBothChains() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _phase3HubAllocationAndIncome();
        _phase4SendToRobinhood();
        _phase5FillPositionAndReport();
        _phase6DeliverReport();
        _onRobinhood();
        _advance(1);
        _generateFees(
            robinhoodRouter, _spokePoolKey(), RH_V4_STATE_VIEW, _center(RH_V4_STATE_VIEW, RH_WETH_USDG_POOL_ID)
        );
        vm.recordLogs();
        spokeVault.report();
        VaaBody[] memory published = ICoreBridge(RH_WORMHOLE_CORE).fetchPublishedMessages(vm.getRecordedLogs());
        _onArbitrum();
        _advance(1);
        _refreshEthUsdFeed();
        _brunoDeposits();
        uint256 before = core.incomeToken(1, RH_WETH).counter;
        VaaEnvelope memory envelope = published[0].envelope;
        envelope.timestamp = uint32(block.timestamp);
        receiver.deliver(VaaLib.encode(ICoreBridge(ARB_WORMHOLE_CORE).sign(VaaBody(envelope, published[0].payload))));
        assertGt(core.incomeToken(1, RH_WETH).counter, before);
        assertEq(core.unconvertedIncome(bruno, 1, RH_WETH), 0);
        assertEq(core.unconvertedIncome(bruno, 1, RH_USDG), 0);
        _deliverFreshSpokeReport();
        assertEq(core.unconvertedIncome(bruno, 1, RH_WETH), 0, "straddling interval is excluded too");
        _onRobinhood();
        _advance(1);
        _generateFees(
            robinhoodRouter, _spokePoolKey(), RH_V4_STATE_VIEW, _center(RH_V4_STATE_VIEW, RH_WETH_USDG_POOL_ID)
        );
        _deliverFreshSpokeReport();
        assertGt(core.unconvertedIncome(bruno, 1, RH_WETH), 0, "first eligible interval earns income");
    }
}
