// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {toUniversalAddress} from "wormhole-sdk/Utils.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {SpokeConfig} from "../../../src/mandate/Mandate.sol";
import {MockReceiverCoreVault} from "../../mocks/receiver/MockReceiverCoreVault.sol";

/// @notice ValueReportReceiver against the real Arbitrum Wormhole Core (guardian set overridden by the SDK's
///         WormholeOverride, advanced variant for sequence control),
///         with VAAs crafted as if the Robinhood Chain Spoke Vault had published them.
contract ValueReportReceiverForkTest is Test {
    using AdvancedWormholeOverride for ICoreBridge;

    address internal constant ARB_WORMHOLE_CORE = 0xa5f208e072434bC67592E4C49C1B991BA79BCA46;
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    uint16 internal constant WH_ARBITRUM = 23;
    uint16 internal constant WH_ROBINHOOD = 72;
    uint256 internal constant ROBINHOOD = 4663;
    uint32 internal constant MAX_AGE = 1588; // research value 1,587 s plus one 0.1 s block, rounded up (Q66 OPEN)
    bytes32 internal constant FUND = keccak256("pool-party/fund/1");

    ICoreBridge internal core;
    MockReceiverCoreVault internal vault;
    ValueReportReceiver internal receiver;
    bytes32 internal spokeVault;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        core = ICoreBridge(ARB_WORMHOLE_CORE);
        assertEq(core.chainId(), WH_ARBITRUM);
        core.setUpOverride();

        spokeVault = toUniversalAddress(makeAddr("robinhood-spoke-vault"));
        SpokeConfig[] memory spokes = new SpokeConfig[](1);
        spokes[0] = SpokeConfig({
            chainId: ROBINHOOD,
            wormholeChainId: WH_ROBINHOOD,
            spokeVault: spokeVault,
            spokeToken: RH_USDG,
            spokeCap: 1_000_000e6,
            maxReportAge: MAX_AGE
        });
        vault = new MockReceiverCoreVault();
        receiver = new ValueReportReceiver(address(core), address(vault), FUND, spokes, 0);
        vault.setReceiver(address(receiver));
    }

    function _report(uint64 sequence, uint256 age) internal view returns (ReportCodec.Report memory r) {
        r.fundId = FUND;
        r.sequence = sequence;
        r.spokeChainId = ROBINHOOD;
        r.blockNumber = uint64(vm.envUint("ROBINHOOD_FORK_BLOCK"));
        r.timestamp = uint64(block.timestamp - age);
        r.unallocated = new ReportCodec.TokenAmount[](1);
        r.unallocated[0] = ReportCodec.TokenAmount(RH_USDG, 4000e6);
        r.positions = new ReportCodec.PositionReport[](1);
        r.positions[0] = ReportCodec.PositionReport({
            adapter: address(0xADA),
            poolKey: keccak256("weth-usdg-500"),
            poolId: 0xfcfae8fa0bd6da961bcf5d990f27690932deac4f093e99bf3e871691c6586593,
            tickLower: -200_000,
            tickUpper: -190_000,
            liquidity: 1e15,
            token0: RH_WETH,
            token1: RH_USDG,
            principal0: 1e18,
            principal1: 2500e6,
            income0: 1e15,
            income1: 3e6
        });
        r.cumulativeIncome = new ReportCodec.TokenAmount[](1);
        r.cumulativeIncome[0] = ReportCodec.TokenAmount(RH_USDG, 3e6);
        r.cumulativeReceived = 9000e6;
    }

    /// @dev Crafts a VAA signed by the overridden guardian set; sequence and consistency come from the override state.
    function _craft(bytes32 emitter, ReportCodec.Report memory r) internal returns (bytes memory) {
        return core.craftVaa(WH_ROBINHOOD, emitter, ReportCodec.encode(r));
    }

    function test_DEC093_forkAcceptsFinalizedReportFromSpokeVault() public {
        ReportCodec.Report memory r = _report(1, 900);
        bytes memory vaa = _craft(spokeVault, r); // Wormhole sequence 0
        uint256 gasBefore = gasleft();
        vm.prank(makeAddr("anyone")); // DEC-093: permissionless delivery
        (uint256 spokeIndex, uint64 reportSequence) = receiver.deliver(vaa);
        // In-test measurement (addresses warmed by setUp stay warm): first delivery writes every report slot from zero.
        console2.log("first deliver gas (real Core, quorum signatures):", gasBefore - gasleft());

        assertEq(spokeIndex, 0);
        assertEq(reportSequence, 1);
        assertEq(vault.calls(), 1);
        assertTrue(receiver.isReportFresh(0));
        (ReportCodec.Report memory stored, uint64 wormholeSequence, uint64 acceptedAt) = receiver.latestReport(0);
        assertEq(keccak256(abi.encode(stored)), keccak256(abi.encode(r)));
        assertEq(wormholeSequence, 0);
        assertEq(acceptedAt, block.timestamp);

        // the next report from the same emitter is accepted
        vm.warp(block.timestamp + 384);
        vaa = _craft(spokeVault, _report(2, 900));
        receiver.deliver(vaa);
        assertEq(receiver.lastWormholeSequence(0), 1);
        assertEq(vault.calls(), 2);
    }

    function test_DEC093_forkRejectsReplay() public {
        bytes memory vaa = _craft(spokeVault, _report(1, 900));
        receiver.deliver(vaa);
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.SequenceNotIncreasing.selector, 0, 0));
        receiver.deliver(vaa);
    }

    function test_DEC093_forkRejectsOutOfOrderSequence() public {
        core.setSequence(5);
        bytes memory later = _craft(spokeVault, _report(6, 900)); // Wormhole sequence 5
        core.setSequence(4);
        bytes memory earlier = _craft(spokeVault, _report(5, 900)); // Wormhole sequence 4, delivered late
        receiver.deliver(later);
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.SequenceNotIncreasing.selector, 5, 4));
        receiver.deliver(earlier);
    }

    function test_DEC086_forkRejectsWrongEmitter() public {
        bytes32 stranger = toUniversalAddress(makeAddr("stranger"));
        bytes memory vaa = _craft(stranger, _report(1, 900));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.UnknownEmitter.selector, WH_ROBINHOOD, stranger));
        receiver.deliver(vaa);
    }

    function test_DEC093_forkRejectsInstantConsistency() public {
        core.setConsistencyLevel(200);
        bytes memory vaa = _craft(spokeVault, _report(1, 60));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.NotFinalized.selector, uint8(200)));
        receiver.deliver(vaa);
    }

    function test_DEC099_forkRejectsTooOldReport() public {
        bytes memory vaa = _craft(spokeVault, _report(1, MAX_AGE + 1));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.ReportTooOld.selector, MAX_AGE + 1, MAX_AGE));
        receiver.deliver(vaa);
    }

    function test_DEC070_forkRejectsAnotherFundsPayload() public {
        ReportCodec.Report memory r = _report(1, 900);
        r.fundId = keccak256("pool-party/fund/2");
        bytes memory vaa = _craft(spokeVault, r);
        vm.expectRevert(IValueReportReceiver.ReportMismatch.selector);
        receiver.deliver(vaa);
    }

    function test_DEC086_forkRejectsTamperedVaa() public {
        bytes memory vaa = _craft(spokeVault, _report(1, 900));
        vaa[vaa.length - 1] = bytes1(uint8(vaa[vaa.length - 1]) ^ 0x01); // flip one payload bit after signing
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.InvalidVaa.selector, "VM signature invalid"));
        receiver.deliver(vaa);
    }
}
