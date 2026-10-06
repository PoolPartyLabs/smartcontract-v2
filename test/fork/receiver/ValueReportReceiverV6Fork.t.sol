pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {ValueReportReceiverV6} from "../../../src/report/ValueReportReceiverV6.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {ReportCodecV6} from "../../../src/libraries/ReportCodecV6.sol";
import {SolanaSpokeRegistryV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {MockReceiverCoreVault} from "../../mocks/receiver/MockReceiverCoreVault.sol";
import {SolanaFixture} from "../../unit/solana/SolanaFixture.sol";

/// @notice Real Core verification on a read-only fork, with SDK test-only Guardian override (DEC-192).
contract ValueReportReceiverV6ForkTest is Test {
    using AdvancedWormholeOverride for ICoreBridge;
    ICoreBridge private bridge;
    ValueReportReceiverV6 private receiver;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), 512_239_244);
        bridge = ICoreBridge(0xa5f208e072434bC67592E4C49C1B991BA79BCA46);
        bridge.setUpOverride();
        MockReceiverCoreVault vault = new MockReceiverCoreVault();
        vm.mockCall(address(vault), abi.encodeWithSignature("mandateHash()"), abi.encode(bytes32(uint256(2))));
        receiver = new ValueReportReceiverV6(
            address(bridge),
            address(vault),
            bytes32(uint256(1)),
            SolanaFixture.spokes(),
            new SolanaSpokeRegistryV6(SolanaFixture.nativeConfig())
        );
        vault.setReceiver(address(receiver));
    }

    function testRealCoreVerifiesFinalizedSolanaV6AndRejectsConfirmed() public {
        bytes memory payload = ReportCodecV6.encode(SolanaFixture.report(uint64(block.timestamp)));
        bridge.setConsistencyLevel(32);
        bytes memory finalized = bridge.craftVaa(1, SolanaFixture.EMITTER, payload);
        receiver.deliver(finalized);
        assertTrue(receiver.hasReport(1));
        bridge.setConsistencyLevel(1);
        bytes memory confirmed = bridge.craftVaa(1, SolanaFixture.EMITTER, payload);
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.NotFinalized.selector, uint8(1)));
        receiver.deliver(confirmed);
    }
}
